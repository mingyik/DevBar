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
    let direction: ScreenshotSupport.ScrollingDirection?
    let footer: CGImage?
  }

  /// One contiguous captured piece, in its own coordinates.
  /// The origin piece uses document coordinates. A detached piece uses local
  /// coordinates until a frame overlaps both and supplies the shift.
  private struct Coverage {
    var slices: [CGImage]
    var top: Int
    var bottom: Int
    var viewportTop: Int
    var anchors: ScreenshotSupport.ScrollingAnchors
    var sample: ScreenshotSupport.ScrollingSample
    var direction: ScreenshotSupport.ScrollingDirection?
    var pixels: Int
  }

  private static let sampleInterval: TimeInterval = 0.03
  private static let settleInterval: TimeInterval = 0.22
  private static let finishGraceInterval: TimeInterval = 0.85

  public static func capture(
    region: CaptureRegion,
    finishSignal: FinishSignal,
    onPreview: @escaping @MainActor (CGImage) -> Void = { _ in },
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
      onProgress: onProgress,
      pendingFrames: { source.queuedFrameCount },
      nextFrame: { await source.nextFrame(wait: !finishSignal.isRequested) })
  }

  static func captureFrames(
    region: CaptureRegion,
    finishSignal: FinishSignal,
    frameLimit: Int = ScreenshotSupport.scrollingCaptureMaximumFrames,
    onPreview: @escaping @MainActor (CGImage) -> Void = { _ in },
    onProgress: @escaping @MainActor (Int, Bool) -> Void,
    pendingFrames: @escaping @Sendable () -> Int = { 0 },
    nextFrame: @escaping @Sendable () async -> CGImage?
  ) async -> Result {
    do {
      guard let firstFrame = await nextFrame(), let first = contentFrame(firstFrame) else {
        return Task.isCancelled ? .cancelled : .failed
      }
      guard first.width <= ScreenshotSupport.scrollingCaptureMaximumPixels / first.height else {
        return .failed
      }
      try Task.checkCancellation()
      guard let firstSample = sample(first) else { return .failed }

      let startedAt = ProcessInfo.processInfo.systemUptime
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
      var detached: [Coverage] = []
      var previousDirection: ScreenshotSupport.ScrollingDirection?
      var fixedBottomPixels = 0
      var footerSlice: CGImage?
      func contentWithHeader() -> [CGImage] { headerSlice.map { [$0] + slices } ?? slices }
      var rollback: AppendRollback?
      var fixedLayoutChanged = false
      var hasUnmatchedContent = false
      var lastChangedAt = startedAt
      var lastCaptureAt = ProcessInfo.processInfo.systemUptime
      var scrollPending = false
      var finishRequestedAt: TimeInterval?
      if let preview = makePreview(slices) { await onPreview(preview) }
      await onProgress(totalHeight, false)

      while true {
        try Task.checkCancellation()

        let now = ProcessInfo.processInfo.systemUptime
        if finishSignal.isRequested, finishRequestedAt == nil {
          finishRequestedAt = now
          // Take one final frame even if no wheel event was delivered.
          scrollPending = true
        }
        if let finishRequestedAt, pendingFrames() == 0,
          !scrollPending || now - finishRequestedAt >= finishGraceInterval
        {
          return completedByUser(
            slices: contentWithHeader(),
            footerSlice: footerSlice,
            region: region,
            hasUnmatchedContent: hasUnmatchedContent)
        }
        if now - startedAt
          >= ScreenshotSupport.scrollingCaptureMaximumDuration
          || capturedFrames >= frameLimit
        {
          return completed(
            slices: contentWithHeader(),
            footerSlice: footerSlice,
            region: region,
            result: .limited)
        }

        // Observe pixels throughout the session. Wheel monitors miss
        // scrollbar drags, keyboard scrolling and some other apps.
        // A queued frame is already captured; waiting would let the return
        // path fall out of the 48-frame buffer.
        let sinceLastCapture = now - lastCaptureAt
        if pendingFrames() == 0, sinceLastCapture < sampleInterval {
          try await Task.sleep(
            nanoseconds: UInt64(
              (sampleInterval - sinceLastCapture) * 1_000_000_000))
          continue
        }

        guard let frame = await nextFrame() else {
          if finishSignal.isRequested {
            try await Task.sleep(nanoseconds: 30_000_000)
            continue
          }
          return completed(
            slices: contentWithHeader(), footerSlice: footerSlice,
            region: region, result: .partial)
        }
        guard let current = contentFrame(frame),
          let currentSample = sample(current)
        else {
          return completed(
            slices: contentWithHeader(), footerSlice: footerSlice,
            region: region, result: .partial)
        }
        try Task.checkCancellation()
        capturedFrames += 1
        lastCaptureAt = ProcessInfo.processInfo.systemUptime
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
          case .advanced(let overlap, _, let matchedColumns) = transition
        {
          // Fixed strips are identified only after moving content has matched.
          let top = ScreenshotSupport.scrollingFixedTopRows(
            previous: previousSample, current: currentSample, overlap: overlap,
            contentColumns: matchedColumns)
          let bottom = ScreenshotSupport.scrollingFixedBottomRows(
            previous: previousSample, current: currentSample, overlap: overlap,
            contentColumns: matchedColumns)
          guard top + bottom < current.height,
            let cropped = copiedStrip(
              from: first, columns: 0..<first.width, topCrop: top, bottomCrop: bottom),
            let initialContent = ScreenshotSupport.scrollingContentSample(
              firstSample, top: top, bottom: bottom)
          else { return .failed }
          fixedTopPixels = top
          fixedBottomPixels = bottom
          contentSampleColumns = matchedColumns
          contentPixelColumns = 0..<current.width
          if top > 0 {
            headerSlice = copiedStrip(
              from: first, columns: 0..<first.width,
              topCrop: 0, bottomCrop: first.height - top)
            guard headerSlice != nil else { return .failed }
          }
          if bottom > 0 {
            footerSlice = copiedStrip(
              from: first, columns: 0..<first.width,
              topCrop: first.height - bottom, bottomCrop: 0)
            guard footerSlice != nil else { return .failed }
          }
          slices[0] = cropped
          totalHeight = cropped.height
          capturedBottom = totalHeight
          retainedPixels = cropped.width * cropped.height
          anchors = .init()
          anchors.remember(initialContent, at: 0)
        }

        guard current.width == first.width, current.height == first.height,
          let previousContent = ScreenshotSupport.scrollingContentSample(
            previousSample, top: fixedTopPixels, bottom: fixedBottomPixels),
          let currentContent = ScreenshotSupport.scrollingContentSample(
            currentSample, top: fixedTopPixels, bottom: fixedBottomPixels)
        else {
          return completed(
            slices: contentWithHeader(), footerSlice: footerSlice,
            region: region, result: .partial)
        }
        if contentSampleColumns != nil {
          transition = ScreenshotSupport.scrollingTransition(
            previous: previousContent, current: currentContent,
            contentColumns: contentSampleColumns)
        }

        if !frameIsStable, let columns = contentSampleColumns,
          let observedPrevious = ScreenshotSupport.scrollingContentSample(
            observedBefore, top: fixedTopPixels, bottom: fixedBottomPixels),
          let observedCurrent = ScreenshotSupport.scrollingContentSample(
            currentSample, top: fixedTopPixels, bottom: fixedBottomPixels),
          case .advanced(let observedOverlap, _, _) = ScreenshotSupport.scrollingTransition(
            previous: observedPrevious, current: observedCurrent, contentColumns: columns)
        {
          // Recheck stationary edges during actual movement, including bars
          // that become sticky later. Changing the crop after committing slices
          // would silently change coordinates, so pause instead of guessing.
          // A fast jump has no reliable overlap; skip the scan rather than
          // treating shifted rows as a layout change.
          let top = ScreenshotSupport.scrollingFixedTopRows(
            previous: observedBefore, current: currentSample,
            overlap: observedOverlap, contentColumns: columns)
          let bottom = ScreenshotSupport.scrollingFixedBottomRows(
            previous: observedBefore, current: currentSample,
            overlap: observedOverlap, contentColumns: columns)
          fixedLayoutChanged =
            abs(top - fixedTopPixels) > 2 || abs(bottom - fixedBottomPixels) > 2
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
            detached.removeAll()
            anchors = .init()
            anchors.remember(saved.sample, at: saved.viewport)
            previousDirection = saved.direction
            footerSlice = saved.footer
            rollback = nil
            if let preview = makePreview(
              footerSlice.map { contentWithHeader() + [$0] } ?? contentWithHeader())
            {
              await onPreview(preview)
            }
          }
          hasUnmatchedContent = true
          // Stay locked until a later moving frame shows the original bands.
          scrollPending = false
          await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, true)
          continue
        }

        let origin = Coverage(
          slices: slices, top: capturedTop, bottom: capturedBottom, viewportTop: viewportTop,
          anchors: anchors, sample: originSample, direction: previousDirection,
          pixels: retainedPixels)
        var hits:
          [(
            index: Int?, position: Int, direction: ScreenshotSupport.ScrollingDirection?,
            trusted: Bool
          )] = []
        if let placed = placement(
          of: currentContent, on: origin, columns: contentSampleColumns,
          fixedTop: fixedTopPixels, fixedBottom: fixedBottomPixels)
        {
          hits.append((nil, placed.position, placed.direction, placed.trusted))
        }
        for index in detached.indices {
          if let placed = placement(
            of: currentContent, on: detached[index], columns: contentSampleColumns,
            fixedTop: fixedTopPixels, fixedBottom: fixedBottomPixels)
          {
            hits.append((index, placed.position, placed.direction, placed.trusted))
          }
        }
        let minimumBridge = currentContent.height / 4
        hits.removeAll { hit in
          guard !hit.trusted else { return false }
          let coverage = hit.index.map { detached[$0] } ?? origin
          let overlap =
            min(coverage.bottom, hit.position + currentContent.height)
            - max(coverage.top, hit.position)
          return overlap < minimumBridge
        }

        guard let columns = contentPixelColumns else {
          if let originHit = hits.first(where: { $0.index == nil }) {
            viewportTop = originHit.position
            previousSample = currentSample
            originSample = currentSample
            if let direction = originHit.direction { previousDirection = direction }
            anchors.remember(currentContent, at: originHit.position)
            hasUnmatchedContent = false
            await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, false)
          } else {
            hasUnmatchedContent = true
            scrollPending = false
            await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, true)
            continue
          }
          scrollPending = !frameIsStable || lastCaptureAt - lastChangedAt < settleInterval
          continue
        }

        if hits.isEmpty {
          let used = retainedPixels + detached.reduce(0) { $0 + $1.pixels }
          if detached.count < 8,
            let strip = copiedStrip(
              from: current, columns: columns,
              topCrop: fixedTopPixels, bottomCrop: fixedBottomPixels),
            used + strip.width * strip.height
              <= ScreenshotSupport.scrollingCaptureMaximumRetainedPixels
          {
            var heldAnchors = ScreenshotSupport.ScrollingAnchors()
            heldAnchors.remember(currentContent, at: 0)
            detached.append(
              Coverage(
                slices: [strip], top: 0, bottom: currentContent.height, viewportTop: 0,
                anchors: heldAnchors, sample: currentSample, direction: nil,
                pixels: strip.width * strip.height))
            previousSample = currentSample
          }
          hasUnmatchedContent = true
          fixedLayoutChanged = false
          scrollPending = false
          await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, true)
          continue
        }

        let contentHeight = currentContent.height
        let originHit = hits.first { $0.index == nil }
        let sideHits = hits.compactMap {
          hit -> (index: Int, position: Int, direction: ScreenshotSupport.ScrollingDirection?)? in
          guard let index = hit.index else { return nil }
          return (index, hit.position, hit.direction)
        }
        var extendedSides = detached
        for hit in sideHits {
          switch extend(
            &extendedSides[hit.index], frame: current, content: currentContent,
            fullSample: currentSample, at: hit.position, direction: hit.direction,
            columns: columns, fixedTop: fixedTopPixels, fixedBottom: fixedBottomPixels)
          {
          case .failed: return .failed
          case .rejected, .placed: break
          }
        }

        if let originHit {
          var unionTop = min(capturedTop, originHit.position)
          var unionBottom = max(capturedBottom, originHit.position + contentHeight)
          for hit in sideHits {
            let shift = originHit.position - hit.position
            let side = extendedSides[hit.index]
            unionTop = min(unionTop, side.top + shift)
            unionBottom = max(unionBottom, side.bottom + shift)
          }
          let extraRows = (capturedTop - unionTop) + (unionBottom - capturedBottom)
          let edgePixels = (fixedTopPixels + fixedBottomPixels) * columns.count
          let detachedPixels = detached.reduce(0) { $0 + $1.pixels }
          guard
            totalHeight + extraRows + fixedTopPixels + fixedBottomPixels
              <= ScreenshotSupport.scrollingCaptureMaximumPixels / columns.count,
            retainedPixels + detachedPixels + extraRows * columns.count + edgePixels
              <= ScreenshotSupport.scrollingCaptureMaximumRetainedPixels
          else {
            return completed(
              slices: contentWithHeader(), footerSlice: footerSlice,
              region: region, result: .limited)
          }
          if extraRows > 0 {
            rollback = AppendRollback(
              slices: slices, height: totalHeight, top: capturedTop, bottom: capturedBottom,
              viewport: viewportTop, pixels: retainedPixels, sample: originSample,
              direction: previousDirection, footer: footerSlice)
          }
          if fixedBottomPixels > 0 {
            footerSlice = copiedStrip(
              from: current, columns: columns,
              topCrop: current.height - fixedBottomPixels, bottomCrop: 0)
            guard footerSlice != nil else { return .failed }
          }
          var originCoverage = origin
          switch extend(
            &originCoverage, frame: current, content: currentContent, fullSample: currentSample,
            at: originHit.position, direction: originHit.direction, columns: columns,
            fixedTop: fixedTopPixels, fixedBottom: fixedBottomPixels)
          {
          case .failed: return .failed
          case .rejected:
            hasUnmatchedContent = true
            await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, true)
            continue
          case .placed:
            let absorbed = Set(sideHits.map(\.index))
            for hit in sideHits {
              let shift = originHit.position - hit.position
              guard
                absorb(extendedSides[hit.index], shift: shift, into: &originCoverage)
              else { return .failed }
            }
            slices = originCoverage.slices
            capturedTop = originCoverage.top
            capturedBottom = originCoverage.bottom
            viewportTop = originCoverage.viewportTop
            anchors = originCoverage.anchors
            retainedPixels = originCoverage.pixels
            totalHeight = capturedBottom - capturedTop
            originSample = currentSample
            previousSample = currentSample
            if let direction = originHit.direction { previousDirection = direction }
            detached = extendedSides.enumerated().compactMap {
              absorbed.contains($0.offset) ? nil : $0.element
            }
            hasUnmatchedContent = false
            if extraRows > 0,
              let preview = makePreview(
                footerSlice.map { contentWithHeader() + [$0] } ?? contentWithHeader())
            {
              await onPreview(preview)
            }
            await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, false)
          }
        } else if sideHits.count >= 2, let primary = sideHits.first {
          var combined = extendedSides[primary.index]
          for hit in sideHits.dropFirst() {
            let shift = primary.position - hit.position
            guard absorb(extendedSides[hit.index], shift: shift, into: &combined) else {
              return .failed
            }
          }
          let absorbed = Set(sideHits.map(\.index))
          detached = extendedSides.enumerated().compactMap {
            if $0.offset == primary.index { return combined }
            return absorbed.contains($0.offset) ? nil : $0.element
          }
          previousSample = currentSample
          hasUnmatchedContent = true
          fixedLayoutChanged = false
          scrollPending = false
          await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, true)
          continue
        } else {
          detached = extendedSides
          previousSample = currentSample
          hasUnmatchedContent = true
          fixedLayoutChanged = false
          scrollPending = false
          await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, true)
          continue
        }

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
  /// Remove only fully transparent outer rows/columns before matching, so the
  /// overlap and strip coordinates describe the same actual screen pixels.
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
    var left = 0
    var right = width
    while top < bottom && alpha[(top * width)..<((top + 1) * width)].allSatisfy({ $0 == 0 }) {
      top += 1
    }
    while bottom > top && alpha[((bottom - 1) * width)..<(bottom * width)].allSatisfy({ $0 == 0 }) {
      bottom -= 1
    }
    guard top < bottom else { return nil }
    while left < right && (top..<bottom).allSatisfy({ alpha[$0 * width + left] == 0 }) {
      left += 1
    }
    while right > left && (top..<bottom).allSatisfy({ alpha[$0 * width + right - 1] == 0 }) {
      right -= 1
    }
    guard left < right else { return nil }
    if top == 0 && bottom == height && left == 0 && right == width { return image }
    return image.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top))
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
    let width = slices.map(\.width).min() ?? first.width
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
  private enum ExtendOutcome {
    case placed(extra: Int)
    case rejected
    case failed
  }

  /// Locate this frame on one piece. Continuous motion is trusted; anchors are
  /// consulted only when direction reverses or the previous viewport no longer
  /// overlaps. A position that does not touch the piece is not a hit.
  private static func placement(
    of content: ScreenshotSupport.ScrollingSample,
    on coverage: Coverage,
    columns: Range<Int>?,
    fixedTop: Int,
    fixedBottom: Int
  ) -> (position: Int, direction: ScreenshotSupport.ScrollingDirection?, trusted: Bool)? {
    guard
      let previousContent = ScreenshotSupport.scrollingContentSample(
        coverage.sample, top: fixedTop, bottom: fixedBottom)
    else { return nil }
    let transition = ScreenshotSupport.scrollingTransition(
      previous: previousContent, current: content, contentColumns: columns)
    var position: Int?
    var direction: ScreenshotSupport.ScrollingDirection?
    var tryAnchor = false
    var trusted = false
    switch transition {
    case .advanced(let overlap, let movement, _):
      let delta = content.height - overlap
      position = coverage.viewportTop + (movement == .forward ? delta : -delta)
      direction = movement
      trusted = true
      tryAnchor = coverage.direction != nil && coverage.direction != movement
    case .end:
      position = coverage.viewportTop
      trusted = true
    case .unmatched:
      tryAnchor = true
    }
    if columns != nil && tryAnchor {
      switch coverage.anchors.registration(
        matching: content, columns: columns, allowOverlap: true)
      {
      case .position(let anchored):
        if let position, abs(position - anchored) > 1 { trusted = false }
        position = anchored
      case .ambiguous: position = nil
      case .unavailable: break
      }
    }
    guard let position else { return nil }
    let bottom = position + content.height
    let extra = max(0, coverage.top - position) + max(0, bottom - coverage.bottom)
    guard extra <= content.height, position <= coverage.bottom, bottom >= coverage.top else {
      return nil
    }
    return (position, direction, trusted)
  }

  private static func extend(
    _ coverage: inout Coverage,
    frame: CGImage,
    content: ScreenshotSupport.ScrollingSample,
    fullSample: ScreenshotSupport.ScrollingSample,
    at position: Int,
    direction: ScreenshotSupport.ScrollingDirection?,
    columns: Range<Int>,
    fixedTop: Int,
    fixedBottom: Int
  ) -> ExtendOutcome {
    let bottom = position + content.height
    let prepend = max(0, coverage.top - position)
    let append = max(0, bottom - coverage.bottom)
    let extra = prepend + append
    guard extra <= content.height, position <= coverage.bottom, bottom >= coverage.top else {
      return .rejected
    }
    if prepend > 0 {
      guard
        let strip = copiedStrip(
          from: frame, columns: columns,
          topCrop: fixedTop, bottomCrop: frame.height - fixedTop - prepend)
      else { return .failed }
      coverage.slices.insert(strip, at: 0)
      coverage.top = position
      coverage.pixels += strip.width * strip.height
    }
    if append > 0 {
      guard
        let strip = copiedStrip(
          from: frame, columns: columns,
          topCrop: frame.height - fixedBottom - append, bottomCrop: fixedBottom)
      else { return .failed }
      coverage.slices.append(strip)
      coverage.bottom = bottom
      coverage.pixels += strip.width * strip.height
    }
    coverage.viewportTop = position
    coverage.sample = fullSample
    if let direction { coverage.direction = direction }
    coverage.anchors.remember(content, at: position)
    return .placed(extra: extra)
  }

  /// Copy rows of `side` that fall outside `origin`. `shift` maps side-local tops
  /// onto the destination piece. Overlapping rows stay with the destination.
  private static func absorb(
    _ side: Coverage,
    shift: Int,
    into origin: inout Coverage
  ) -> Bool {
    var cursor = side.top
    var prepends: [CGImage] = []
    var appends: [CGImage] = []
    for slice in side.slices {
      let doc = cursor + shift
      let height = slice.height
      if doc < origin.top {
        let rows = min(height, origin.top - doc)
        guard
          let strip = copiedStrip(
            from: slice, columns: 0..<slice.width, topCrop: 0, bottomCrop: height - rows)
        else { return false }
        prepends.append(strip)
      }
      let docBottom = doc + height
      if docBottom > origin.bottom {
        let start = max(0, origin.bottom - doc)
        let rows = height - start
        if rows > 0 {
          guard
            let strip = copiedStrip(
              from: slice, columns: 0..<slice.width, topCrop: start,
              bottomCrop: height - start - rows)
          else { return false }
          appends.append(strip)
        }
      }
      cursor += height
    }
    for strip in prepends.reversed() {
      origin.slices.insert(strip, at: 0)
      origin.pixels += strip.width * strip.height
    }
    if !prepends.isEmpty { origin.top = side.top + shift }
    for strip in appends {
      origin.slices.append(strip)
      origin.pixels += strip.width * strip.height
    }
    if !appends.isEmpty { origin.bottom = max(origin.bottom, side.bottom + shift) }
    for entry in side.anchors.entries {
      origin.anchors.remember(entry.sample, at: entry.top + shift)
    }
    return true
  }

}
