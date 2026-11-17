// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Adapted for DevBar.

import AppKit
import CoreGraphics

/// Watches a selected region while the person scrolls it. A frame that overlaps
/// any already captured piece is placed immediately and deduplicated; a frame
/// that overlaps none is held as its own piece. A later frame that overlaps two
/// pieces joins them, so a skipped gap can be filled by scrolling back over it.
public enum ScreenshotScrollingCapture {
  /// A frame that could not be located yet. Kept briefly so a later bridge
  /// frame can reveal where it belongs and fill the skipped rows.
  private struct HeldFrame {
    let content: CGImage
    let sample: ScreenshotSupport.ScrollingSample
    var imageBytes: Int { content.bytesPerRow * content.height }
  }

  private static let maximumHeldFrames = 4
  private static let maximumHeldImageBytes = 48 * 1024 * 1024

  public final class FinishSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    public init() {}

    public func request() {
      lock.lock()
      requested = true
      lock.unlock()
    }

    var isRequested: Bool {
      lock.lock()
      defer { lock.unlock() }
      return requested
    }
  }

  public enum Result {
    case success(CGImage)
    case partial(CGImage)
    case limited(CGImage)
    case cancelled
    case failed
  }

  /// One provisional append may contain the first appearance of a sticky bar.
  /// This snapshot shares existing slices; it does not copy the long image.
  private struct AppendRollback {
    let slices: [CGImage]
    let height: Int
    let top: Int
    let bottom: Int
    let viewport: Int
    let pixels: Int
    let sample: ScreenshotSupport.ScrollingSample
    let anchors: ScreenshotSupport.ScrollingAnchors
    let direction: ScreenshotSupport.ScrollingDirection?
    let footer: CGImage?
  }

  private static let sampleInterval: TimeInterval = 0.03
  private static let settleInterval: TimeInterval = 0.22
  private static let finishGraceInterval: TimeInterval = 0.85

  public static func capture(
    region: CaptureRegion,
    finishSignal: FinishSignal,
    onPreview: @escaping @MainActor (CGImage) -> Void = { _ in },
    onLimitReached: @escaping @MainActor () -> Void = {},
    onProgress: @escaping @MainActor (Int, Bool) -> Void
  ) async -> Result {
    guard
      let source = await ScreenshotCaptureEngine.prepareDisplayRegion(
        region: region, streaming: true)
    else {
      return Task.isCancelled ? .cancelled : .failed
    }
    defer { source.stop() }
    return await captureFrames(
      region: region, finishSignal: finishSignal, onPreview: onPreview,
      onLimitReached: {
        source.stop()
        onLimitReached()
      },
      onProgress: onProgress,
      pendingFrames: { source.queuedFrameCount },
      nextFrame: { await source.nextFrame(wait: !finishSignal.isRequested) })
  }

  static func captureFrames(
    region: CaptureRegion,
    finishSignal: FinishSignal,
    heightLimit: Int = ScreenshotSupport.scrollingCaptureMaximumHeight,
    onPreview: @escaping @MainActor (CGImage) -> Void = { _ in },
    onLimitReached: @escaping @MainActor () -> Void = {},
    onProgress: @escaping @MainActor (Int, Bool) -> Void,
    pendingFrames: @escaping @Sendable () -> Int = { 0 },
    nextFrame: @escaping @Sendable () async -> CGImage?,
    currentTime: @escaping @Sendable () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
  ) async -> Result {
    do {
      guard let firstFrame = await nextFrame(),
        let first = contentFrame(firstFrame),
        first.width == Int(region.pixelRect.width)
      else {
        return Task.isCancelled ? .cancelled : .failed
      }
      guard heightLimit > 0, first.height <= heightLimit,
        first.width <= ScreenshotSupport.scrollingCaptureMaximumPixels / first.height
      else {
        return .failed
      }
      try Task.checkCancellation()
      guard let firstSample = sample(first) else { return .failed }

      let startedAt = currentTime()
      var slices = [first]
      var capturedFrames = 1
      var previousSample = firstSample
      var lastObservedSample = firstSample
      var totalHeight = first.height
      var viewportTop = 0
      var capturedTop = 0
      var capturedBottom = first.height
      var retainedPixels = first.width * first.height
      var contentSampleColumns: Range<Int>?
      var contentPixelColumns: Range<Int>?
      var fixedTopPixels = 0
      var headerSlice: CGImage?
      var anchors = ScreenshotSupport.ScrollingAnchors()
      anchors.remember(firstSample, at: 0)
      var originSample = firstSample
      /// Last frame whose position was confirmed against the captured content.
      var confirmedContent = firstSample
      var lastDirection: ScreenshotSupport.ScrollingDirection?
      var fixedBottomPixels = 0
      var footerSlice: CGImage?
      var heldFrames: [HeldFrame] = []
      func contentWithHeader() -> [CGImage] { headerSlice.map { [$0] + slices } ?? slices }
      var rollback: AppendRollback?
      var fixedLayoutChanged = false
      var hasUnmatchedContent = false
      var lastChangedAt = startedAt
      var lastCaptureAt = currentTime()
      var scrollPending = false
      var finishRequestedAt: TimeInterval?
      var lastPreviewAt: TimeInterval = 0
      var previewStale = false
      func publishPreview(force: Bool = false) async {
        let now = currentTime()
        if !force, now - lastPreviewAt < 0.25 {
          previewStale = true
          return
        }
        lastPreviewAt = now
        guard
          let preview = makePreview(
            footerSlice.map { contentWithHeader() + [$0] } ?? contentWithHeader())
        else {
          previewStale = true
          return
        }
        previewStale = false
        await onPreview(preview)
      }
      func flushStalePreview(now: TimeInterval, force: Bool = false) async {
        guard previewStale, force || now - lastPreviewAt >= 0.25 else { return }
        await publishPreview(force: true)
      }
      func waitAtLimit() async throws -> Result {
        await publishPreview(force: true)
        await onLimitReached()
        while !finishSignal.isRequested {
          try Task.checkCancellation()
          try await sleep(0.05)
        }
        try Task.checkCancellation()
        return completed(
          slices: contentWithHeader(), footerSlice: footerSlice,
          region: region, result: .limited)
      }
      func hold(_ content: CGImage, sample: ScreenshotSupport.ScrollingSample) {
        guard sample.pixels.count <= Self.maximumHeldImageBytes else { return }
        heldFrames.append(HeldFrame(content: content, sample: sample))
        while heldFrames.count > Self.maximumHeldFrames
          || heldFrames.reduce(0, { $0 + $1.imageBytes }) > Self.maximumHeldImageBytes
        {
          heldFrames.removeFirst()
        }
      }
      /// A held frame has no position until a later frame overlaps both it and
      /// the confirmed viewport. Then its missing rows can be inserted.
      func mergeHeldFrames(
        anchor: ScreenshotSupport.ScrollingSample, at anchorTop: Int,
        columns: Range<Int>, sampleColumns: Range<Int>?, minimumOverlap: Int
      ) async throws -> (limit: Result?, merged: Bool, failed: Bool) {
        var merged = false
        var index = 0
        while index < heldFrames.count {
          let held = heldFrames[index]
          guard
            let heldContent = ScreenshotSupport.scrollingContentSample(
              held.sample, top: fixedTopPixels, bottom: fixedBottomPixels),
            case .advanced(let overlap, let direction, _) = ScreenshotSupport.scrollingTransition(
              previous: anchor, current: heldContent, contentColumns: sampleColumns),
            overlap >= minimumOverlap
          else {
            index += 1
            continue
          }
          let delta = heldContent.height - overlap
          let heldTop = anchorTop + (direction == .forward ? delta : -delta)
          let heldBottom = heldTop + heldContent.height
          guard heldTop <= capturedBottom, heldBottom >= capturedTop else {
            index += 1
            continue
          }
          let prepend = max(0, capturedTop - heldTop)
          let append = max(0, heldBottom - capturedBottom)
          if prepend == 0 && append == 0 {
            heldFrames.remove(at: index)
            continue
          }
          let extra = prepend + append
          guard
            totalHeight + extra + fixedTopPixels + fixedBottomPixels <= heightLimit,
            totalHeight + extra + fixedTopPixels + fixedBottomPixels
              <= ScreenshotSupport.scrollingCaptureMaximumPixels / columns.count,
            retainedPixels + extra * columns.count
              <= ScreenshotSupport.scrollingCaptureMaximumRetainedPixels
          else {
            return (try await waitAtLimit(), merged, false)
          }
          if append > 0, fixedBottomPixels > 0 {
            footerSlice = copiedStrip(
              from: held.content, columns: columns,
              topCrop: held.content.height - fixedBottomPixels, bottomCrop: 0)
            guard footerSlice != nil else { return (nil, merged, true) }
          }
          if prepend > 0 {
            guard
              let strip = copiedStrip(
                from: held.content, columns: columns,
                topCrop: fixedTopPixels,
                bottomCrop: held.content.height - fixedTopPixels - prepend)
            else { return (nil, merged, true) }
            slices.insert(strip, at: 0)
            capturedTop = heldTop
            retainedPixels += strip.width * strip.height
          }
          if append > 0 {
            guard
              let strip = copiedStrip(
                from: held.content, columns: columns,
                topCrop: fixedTopPixels + (capturedBottom - heldTop),
                bottomCrop: fixedBottomPixels)
            else { return (nil, merged, true) }
            slices.append(strip)
            capturedBottom = heldBottom
            retainedPixels += strip.width * strip.height
          }
          totalHeight = capturedBottom - capturedTop
          anchors.remember(heldContent, at: heldTop)
          heldFrames.remove(at: index)
          merged = true
        }
        return (nil, merged, false)
      }
      await publishPreview(force: true)
      await onProgress(totalHeight, false)

      while true {
        try Task.checkCancellation()

        let now = currentTime()
        await flushStalePreview(now: now)
        if finishSignal.isRequested, finishRequestedAt == nil {
          finishRequestedAt = now
          // Take one final frame even if no wheel event was delivered.
          scrollPending = true
        }
        if let finishRequestedAt,
          (pendingFrames() == 0 && !scrollPending)
            || now - finishRequestedAt >= finishGraceInterval
        {
          await flushStalePreview(now: now, force: true)
          return completedByUser(
            slices: contentWithHeader(),
            footerSlice: footerSlice,
            region: region,
            hasUnmatchedContent: hasUnmatchedContent)
        }
        if totalHeight + fixedTopPixels + fixedBottomPixels >= heightLimit {
          return try await waitAtLimit()
        }

        // Observe pixels throughout the session. Wheel monitors miss
        // scrollbar drags, keyboard scrolling and some other apps.
        // A queued frame is already captured; waiting would let the return
        // path fall out of the 48-frame buffer. Wake early when a throttled
        // preview is due so a stopped scroll still catches up.
        let sinceLastCapture = now - lastCaptureAt
        if pendingFrames() == 0 {
          let captureWait = max(0, sampleInterval - sinceLastCapture)
          let previewWait =
            previewStale ? max(0, 0.25 - (now - lastPreviewAt)) : captureWait
          let wait = min(captureWait, previewWait)
          if wait > 0 {
            try await sleep(wait)
            continue
          }
        }

        guard let frame = await nextFrame() else {
          if finishSignal.isRequested {
            try await sleep(0.03)
            continue
          }
          await flushStalePreview(now: now, force: true)
          return completed(
            slices: contentWithHeader(), footerSlice: footerSlice,
            region: region, result: .partial)
        }
        guard let current = contentFrame(frame),
          let currentSample = sample(current)
        else {
          await flushStalePreview(now: now, force: true)
          return completed(
            slices: contentWithHeader(), footerSlice: footerSlice,
            region: region, result: .partial)
        }
        try Task.checkCancellation()
        capturedFrames += 1
        lastCaptureAt = currentTime()
        let frameIsStable = ScreenshotSupport.scrollingSamplesAreStable(
          lastObservedSample,
          currentSample,
          contentColumns: contentSampleColumns)
        let observedBefore = lastObservedSample
        lastObservedSample = currentSample
        if !frameIsStable { lastChangedAt = lastCaptureAt }
        var transition: ScreenshotSupport.ScrollingTransition = .unmatched
        if contentSampleColumns == nil {
          transition = ScreenshotSupport.scrollingTransition(
            previous: previousSample, current: currentSample)
        }

        if contentSampleColumns == nil,
          case .advanced(let overlap, _, let matchedColumns) = transition,
          overlap >= max(24, currentSample.height / 4)
        {
          // Fixed strips are identified only after moving content has matched.
          let top = ScreenshotSupport.scrollingFixedTopRows(
            previous: previousSample, current: currentSample, overlap: overlap,
            contentColumns: matchedColumns)
          let bottom = ScreenshotSupport.scrollingFixedBottomRows(
            previous: previousSample, current: currentSample, overlap: overlap,
            contentColumns: matchedColumns)
          // Only the frame immediately after the first one has a known offset
          // with it. A later first match may still overlap the origin after
          // transient unmatched frames; only when it does not may the document
          // start at this frame instead of guessing the skipped gap.
          var continuesOrigin = capturedFrames == 2
          if !continuesOrigin,
            let originContent = ScreenshotSupport.scrollingContentSample(
              firstSample, top: top, bottom: bottom),
            let lateContent = ScreenshotSupport.scrollingContentSample(
              currentSample, top: top, bottom: bottom),
            case .advanced(let originOverlap, _, _) = ScreenshotSupport.scrollingTransition(
              previous: originContent, current: lateContent,
              contentColumns: matchedColumns),
            originOverlap >= max(24, currentSample.height / 4)
          {
            continuesOrigin = true
          }
          let base = continuesOrigin ? first : current
          let baseSample = continuesOrigin ? firstSample : currentSample
          guard top + bottom < base.height,
            let cropped = copiedStrip(
              from: base, columns: 0..<base.width, topCrop: top, bottomCrop: bottom),
            let initialContent = ScreenshotSupport.scrollingContentSample(
              baseSample, top: top, bottom: bottom)
          else { return .failed }
          fixedTopPixels = top
          fixedBottomPixels = bottom
          contentSampleColumns = matchedColumns
          contentPixelColumns = 0..<current.width
          if top > 0 {
            headerSlice = copiedStrip(
              from: base, columns: 0..<base.width,
              topCrop: 0, bottomCrop: base.height - top)
            guard headerSlice != nil else { return .failed }
          }
          if bottom > 0 {
            footerSlice = copiedStrip(
              from: base, columns: 0..<base.width,
              topCrop: base.height - bottom, bottomCrop: 0)
            guard footerSlice != nil else { return .failed }
          }
          slices = [cropped]
          totalHeight = cropped.height
          capturedTop = 0
          capturedBottom = totalHeight
          viewportTop = 0
          retainedPixels = cropped.width * cropped.height
          anchors = .init()
          anchors.remember(initialContent, at: 0)
          confirmedContent = initialContent
          originSample = baseSample
          previousSample = baseSample
          lastDirection = nil
        }

        guard current.width == first.width, current.height == first.height,
          let currentContent = ScreenshotSupport.scrollingContentSample(
            currentSample, top: fixedTopPixels, bottom: fixedBottomPixels)
        else {
          await flushStalePreview(now: now, force: true)
          return completed(
            slices: contentWithHeader(), footerSlice: footerSlice,
            region: region, result: .partial)
        }

        var observedTransition: ScreenshotSupport.ScrollingTransition?
        if !frameIsStable, let columns = contentSampleColumns,
          let observedPrevious = ScreenshotSupport.scrollingContentSample(
            observedBefore, top: fixedTopPixels, bottom: fixedBottomPixels),
          let observedCurrent = ScreenshotSupport.scrollingContentSample(
            currentSample, top: fixedTopPixels, bottom: fixedBottomPixels)
        {
          let observed = ScreenshotSupport.scrollingTransition(
            previous: observedPrevious, current: observedCurrent, contentColumns: columns)
          observedTransition = observed
          if case .advanced(let observedOverlap, _, _) = observed {
            // Recheck stationary edges during actual movement, including bars
            // that become sticky later. Changing the crop after committing
            // slices would silently change coordinates, so pause instead of
            // guessing. A fast jump has no reliable overlap; skip the scan
            // rather than treating shifted rows as a layout change.
            let top = ScreenshotSupport.scrollingFixedTopRows(
              previous: observedBefore, current: currentSample,
              overlap: observedOverlap, contentColumns: columns)
            let bottom = ScreenshotSupport.scrollingFixedBottomRows(
              previous: observedBefore, current: currentSample,
              overlap: observedOverlap, contentColumns: columns)
            fixedLayoutChanged =
              abs(top - fixedTopPixels) > 2 || abs(bottom - fixedBottomPixels) > 2
          }
        }
        if fixedLayoutChanged && currentSample == previousSample {
          fixedLayoutChanged = false
        }
        if fixedLayoutChanged {
          if let saved = rollback {
            slices = saved.slices
            totalHeight = saved.height
            capturedTop = saved.top
            capturedBottom = saved.bottom
            viewportTop = saved.viewport
            retainedPixels = saved.pixels
            previousSample = saved.sample
            originSample = saved.sample
            let restored =
              ScreenshotSupport.scrollingContentSample(
                saved.sample, top: fixedTopPixels, bottom: fixedBottomPixels) ?? saved.sample
            confirmedContent = restored
            anchors = saved.anchors
            anchors.remember(restored, at: saved.viewport)
            lastDirection = saved.direction
            footerSlice = saved.footer
            rollback = nil
            await publishPreview(force: true)
          }
          heldFrames.removeAll()
          hasUnmatchedContent = true
          // Stay locked until a later moving frame shows the original bands.
          scrollPending = false
          await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, true)
          continue
        }

        let contentHeight = currentContent.height
        let minimumOverlap = max(24, contentHeight / 4)
        let reusableTransition =
          observedBefore == originSample ? observedTransition : nil
        guard
          let placed = locate(
            content: currentContent, anchor: confirmedContent, anchorTop: viewportTop,
            anchors: anchors, columns: contentSampleColumns, minimumOverlap: minimumOverlap,
            lastDirection: lastDirection, precomputed: reusableTransition,
            needsCorroboration: hasUnmatchedContent)
        else {
          // A jump with no reliable overlap is not new content and must never
          // move the stitch. Keep the frame so a later bridge frame can place
          // it and fill the skipped rows.
          hold(current, sample: currentSample)
          hasUnmatchedContent = true
          scrollPending = false
          await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, true)
          continue
        }

        guard let columns = contentPixelColumns else {
          // The moving content is not cropped yet; adopt the position only.
          viewportTop = placed.position
          originSample = currentSample
          confirmedContent = currentContent
          anchors.remember(currentContent, at: placed.position)
          if let direction = placed.direction { lastDirection = direction }
          hasUnmatchedContent = false
          await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, false)
          scrollPending = !frameIsStable || lastCaptureAt - lastChangedAt < settleInterval
          continue
        }

        let position = placed.position
        let sharedRows = min(capturedBottom, position + contentHeight) - max(capturedTop, position)
        let prepend = max(0, capturedTop - position)
        let append = max(0, position + contentHeight - capturedBottom)
        guard sharedRows >= minimumOverlap, prepend == 0 || append == 0 else {
          // Too little shared content to trust this placement, or a jump across
          // the whole captured range. Hold instead of appending out of order.
          hasUnmatchedContent = true
          scrollPending = false
          await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, true)
          continue
        }

        let extraRows = prepend + append
        if extraRows > 0 {
          guard
            totalHeight + extraRows + fixedTopPixels + fixedBottomPixels <= heightLimit,
            totalHeight + extraRows + fixedTopPixels + fixedBottomPixels
              <= ScreenshotSupport.scrollingCaptureMaximumPixels / columns.count,
            retainedPixels + extraRows * columns.count
              <= ScreenshotSupport.scrollingCaptureMaximumRetainedPixels
          else {
            return try await waitAtLimit()
          }
          rollback = AppendRollback(
            slices: slices, height: totalHeight, top: capturedTop, bottom: capturedBottom,
            viewport: viewportTop, pixels: retainedPixels, sample: originSample,
            anchors: anchors, direction: lastDirection, footer: footerSlice)
          if fixedBottomPixels > 0 {
            footerSlice = copiedStrip(
              from: current, columns: columns,
              topCrop: current.height - fixedBottomPixels, bottomCrop: 0)
            guard footerSlice != nil else { return .failed }
          }
          if prepend > 0 {
            guard
              let strip = copiedStrip(
                from: current, columns: columns, topCrop: fixedTopPixels,
                bottomCrop: current.height - fixedTopPixels - prepend)
            else { return .failed }
            slices.insert(strip, at: 0)
            capturedTop = position
            retainedPixels += strip.width * strip.height
          }
          if append > 0 {
            guard
              let strip = copiedStrip(
                from: current, columns: columns,
                topCrop: current.height - fixedBottomPixels - append,
                bottomCrop: fixedBottomPixels)
            else { return .failed }
            slices.append(strip)
            capturedBottom = position + contentHeight
            retainedPixels += strip.width * strip.height
          }
          totalHeight = capturedBottom - capturedTop
        }

        let merge = try await mergeHeldFrames(
          anchor: currentContent, at: position, columns: columns,
          sampleColumns: contentSampleColumns, minimumOverlap: minimumOverlap)
        if let limit = merge.limit { return limit }
        if merge.failed { return .failed }
        if merge.merged { await publishPreview() }

        viewportTop = position
        originSample = currentSample
        confirmedContent = currentContent
        anchors.remember(currentContent, at: position)
        if let direction = placed.direction { lastDirection = direction }
        hasUnmatchedContent = false
        if extraRows > 0 { await publishPreview() }
        await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, false)
        scrollPending = !frameIsStable || lastCaptureAt - lastChangedAt < settleInterval
      }
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .failed
    }
  }

  private static func completedByUser(
    slices: [CGImage],
    footerSlice: CGImage?,
    region: CaptureRegion,
    hasUnmatchedContent: Bool
  ) -> Result {
    guard hasUnmatchedContent else {
      return completed(
        slices: slices,
        footerSlice: footerSlice,
        region: region,
        result: .success)
    }
    return completed(
      slices: slices,
      footerSlice: footerSlice,
      region: region,
      result: .partial)
  }

  private enum CompletedResult {
    case success
    case partial
    case limited
  }

  private static func completed(
    slices: [CGImage],
    footerSlice: CGImage?,
    region: CaptureRegion,
    result: CompletedResult
  ) -> Result {
    guard !Task.isCancelled else { return .cancelled }
    let completedSlices = footerSlice.map { slices + [$0] } ?? slices
    guard let image = stitch(completedSlices) else {
      return Task.isCancelled ? .cancelled : .failed
    }
    guard !Task.isCancelled else { return .cancelled }
    let capture = image
    switch result {
    case .success: return .success(capture)
    case .partial: return .partial(capture)
    case .limited: return .limited(capture)
    }
  }

  /// ScreenCaptureKit can pad a region with a transparent edge row. Keeping
  /// that row in each appended strip produces a dark seam in image viewers.
  /// Side columns stay: the stitched width is the selection width.
  private static func contentFrame(_ image: CGImage) -> CGImage? {
    if [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) { return image }
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var alpha = [UInt8](repeating: 0, count: width * height)
    let drawn = alpha.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
      else { return false }
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    var top = 0
    var bottom = height
    while top < bottom && alpha[(top * width)..<((top + 1) * width)].allSatisfy({ $0 == 0 }) {
      top += 1
    }
    while bottom > top && alpha[((bottom - 1) * width)..<(bottom * width)].allSatisfy({ $0 == 0 }) {
      bottom -= 1
    }
    guard top < bottom else { return nil }
    if top == 0 && bottom == height { return image }
    return image.cropping(to: CGRect(x: 0, y: top, width: width, height: bottom - top))
  }

  private static func sample(_ image: CGImage) -> ScreenshotSupport.ScrollingSample? {
    // Keep native vertical rows for exact offsets and enough horizontal
    // detail to distinguish digits in a wide Terminal. A 32-column thumbnail
    // can make different digits look identical; the matcher selects a few
    // informative columns from this wider sample to bound its work.
    let width = min(256, image.width)
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height)
    guard
      let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    context.interpolationQuality = .low
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ScreenshotSupport.ScrollingSample(
      width: width,
      height: height,
      pixels: pixels)
  }

  /// A cropped CGImage may keep its full source storage alive. Drawing the
  /// new strip into its own bitmap makes the retained-pixel guard truthful.
  private static func copiedStrip(
    from image: CGImage,
    columns: Range<Int>,
    topCrop: Int,
    bottomCrop: Int
  ) -> CGImage? {
    let height = image.height - topCrop - bottomCrop
    guard image.width > 0, height > 0,
      topCrop >= 0, bottomCrop >= 0,
      columns.lowerBound >= 0,
      columns.upperBound <= image.width,
      !columns.isEmpty,
      let source = image.cropping(
        to: CGRect(
          x: columns.lowerBound,
          y: topCrop,
          width: columns.count,
          height: height)),
      let context = CGContext(
        data: nil,
        width: columns.count,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .none
    context.draw(
      source,
      in: CGRect(
        x: 0, y: 0,
        width: columns.count, height: height))
    return context.makeImage()
  }

  /// Compose directly into a small preview, never allocate a full-resolution joined image here.
  static func makePreview(_ slices: [CGImage]) -> CGImage? {
    guard let first = slices.first else { return nil }
    let total = slices.reduce(0) { $0 + $1.height }
    let scale = min(320 / CGFloat(first.width), 800 / CGFloat(total), 1)
    let width = max(1, Int(CGFloat(first.width) * scale))
    let height = max(1, Int(CGFloat(total) * scale))
    guard
      let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .low
    var row = total
    for slice in slices {
      row -= slice.height
      context.draw(
        slice,
        in: CGRect(
          x: 0, y: CGFloat(row) * scale,
          width: CGFloat(width), height: CGFloat(slice.height) * scale))
    }
    return context.makeImage()
  }

  private static func stitch(_ slices: [CGImage]) -> CGImage? {
    guard !Task.isCancelled else { return nil }
    guard let first = slices.first else { return nil }
    guard slices.count > 1 else { return first }
    let width = first.width
    guard slices.allSatisfy({ $0.width == width }) else { return nil }
    let height = slices.reduce(0) { $0 + $1.height }
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .none

    var destinationY = height
    for slice in slices {
      guard !Task.isCancelled else { return nil }
      destinationY -= slice.height
      guard
        let piece = slice.cropping(
          to: CGRect(
            x: 0,
            y: 0,
            width: width,
            height: slice.height))
      else { return nil }
      context.draw(
        piece,
        in: CGRect(
          x: 0, y: destinationY,
          width: piece.width, height: piece.height))
    }
    guard !Task.isCancelled, destinationY == 0 else { return nil }
    return context.makeImage()
  }

  private struct Located {
    let position: Int
    let direction: ScreenshotSupport.ScrollingDirection?
  }

  /// One remembered viewpoint is not a second opinion. An approximate match
  /// can be a repeated-content alias, so accept only an exact revisit.
  private static func exactSingleAnchorRevisit(
    anchors: ScreenshotSupport.ScrollingAnchors,
    content: ScreenshotSupport.ScrollingSample,
    columns: Range<Int>?
  ) -> Located? {
    guard anchors.entries.count < 2,
      case .position(let exact) = anchors.registration(
        matching: content, columns: columns, allowOverlap: false)
    else { return nil }
    return Located(position: exact, direction: nil)
  }

  /// Locate this frame against the confirmed viewport first, then against
  /// remembered viewports. A placement that shares too few rows with the
  /// captured range is rejected; it must never append content out of order.
  private static func locate(
    content: ScreenshotSupport.ScrollingSample,
    anchor: ScreenshotSupport.ScrollingSample,
    anchorTop: Int,
    anchors: ScreenshotSupport.ScrollingAnchors,
    columns: Range<Int>?,
    minimumOverlap: Int,
    lastDirection: ScreenshotSupport.ScrollingDirection?,
    precomputed: ScreenshotSupport.ScrollingTransition? = nil,
    needsCorroboration: Bool = false
  ) -> Located? {
    let transition =
      precomputed
      ?? ScreenshotSupport.scrollingTransition(
        previous: anchor, current: content, contentColumns: columns)
    switch transition {
    case .advanced(let overlap, let direction, _):
      guard overlap >= minimumOverlap else { break }
      let delta = content.height - overlap
      let continuous = Located(
        position: anchorTop + (direction == .forward ? delta : -delta),
        direction: direction)
      // A large step keeps little shared content, a direction change can hit a
      // repeated layout, and the first match after a rejected frame can be an
      // alias far from the confirmed position. All need agreement from the
      // remembered viewports before they may move the stitch.
      let largeStep = overlap * 2 < content.height
      let reversal = lastDirection != nil && lastDirection != direction
      guard columns != nil, largeStep || reversal || needsCorroboration else {
        return continuous
      }
      guard let columns else { return continuous }
      switch anchors.verified(
        matching: content, columns: columns, minimumOverlap: minimumOverlap)
      {
      case .position(let verified):
        return Located(position: verified, direction: direction)
      case .ambiguous, .unavailable:
        if let revisit = exactSingleAnchorRevisit(
          anchors: anchors, content: content, columns: columns)
        {
          return revisit
        }
        return nil
      }
    case .end:
      return Located(position: anchorTop, direction: nil)
    case .unmatched:
      // A scrollbar fade or lazy repaint can defeat the offset search while
      // the content itself barely changed. That is a stationary frame, not a
      // jump: adopting the current position avoids stalling the capture.
      if ScreenshotSupport.scrollingSamplesAreStable(
        anchor, content, contentColumns: columns, tolerance: 4)
        || ScreenshotSupport.scrollingSamplesAreMostlyStable(
          anchor, content, contentColumns: columns, tolerance: 4)
      {
        return Located(position: anchorTop, direction: nil)
      }
      break
    }
    guard let columns else { return nil }
    switch anchors.verified(
      matching: content, columns: columns, minimumOverlap: minimumOverlap)
    {
    case .position(let top):
      return Located(position: top, direction: nil)
    case .ambiguous, .unavailable:
      if let revisit = exactSingleAnchorRevisit(
        anchors: anchors, content: content, columns: columns)
      {
        return revisit
      }
      return nil
    }
  }
}
