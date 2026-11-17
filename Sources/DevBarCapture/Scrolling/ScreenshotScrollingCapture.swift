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
  /// Disjoint runs of frames that could not be placed on the main chain yet.
  /// Overlapping frames extend each fragment locally; once any entry in a
  /// fragment bridges to the main chain, the entire fragment merges at once.
  private struct HeldFragment {
    struct Entry {
      let content: CGImage
      let rawSample: ScreenshotSupport.ScrollingSample
      var sample: ScreenshotSupport.ScrollingSample
      var top: Int
      var imageBytes: Int { content.bytesPerRow * content.height }
    }

    var entries: [Entry]
    var imageBytes: Int { entries.reduce(0) { $0 + $1.imageBytes } }
  }

  private static let maximumHeldFragments = 4
  private static let maximumEntriesPerFragment = 16
  private static let maximumHeldImageBytes = 48 * 1024 * 1024

  public final class FinishSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var observer: (@Sendable () -> Void)?

    public init() {}

    public func request() {
      var notify: (@Sendable () -> Void)?
      lock.lock()
      if !requested {
        requested = true
        notify = observer
      }
      lock.unlock()
      notify?()
    }

    func onRequest(_ handler: (@Sendable () -> Void)?) {
      lock.lock()
      observer = handler
      let alreadyRequested = requested
      lock.unlock()
      if alreadyRequested { handler?() }
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
    let rawSample: ScreenshotSupport.ScrollingSample
    let anchors: ScreenshotSupport.ScrollingAnchors
    let fullAnchors: ScreenshotSupport.ScrollingAnchors
    let direction: ScreenshotSupport.ScrollingDirection?
    let footer: CGImage?
    let topFrame: CGImage
    let bottomFrame: CGImage
  }

  private static let sampleInterval: TimeInterval = 0.03
  private static let settleInterval: TimeInterval = 0.22
  private static let finishGraceInterval: TimeInterval = 0.85
  /// Matching needs a band of moving rows; edge bands may not consume it.
  static func minimumContentHeight(frameHeight: Int) -> Int {
    min(frameHeight, max(48, frameHeight / 3))
  }
  static func minimumContentWidth(frameWidth: Int) -> Int {
    min(frameWidth, max(32, frameWidth / 4))
  }

  public static func capture(
    region: CaptureRegion,
    finishSignal: FinishSignal,
    insets: ScrollingInsetControl? = nil,
    onInsets: @escaping @MainActor (_ top: Int, _ bottom: Int, _ right: Int) -> Void = { _, _, _ in
    },
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
    finishSignal.onRequest { source.wake() }
    insets?.onChange { source.repeatLastFrameIfIdle() }
    defer {
      finishSignal.onRequest(nil)
      insets?.onChange(nil)
      source.stop()
    }
    return await captureFrames(
      region: region, finishSignal: finishSignal, insets: insets, onInsets: onInsets,
      onPreview: onPreview,
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
    insets insetControl: ScrollingInsetControl? = nil,
    onInsets: @escaping @MainActor (Int, Int, Int) -> Void = { _, _, _ in },
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
      var insetVersion = -1
      let wantedInsets = insetControl?.changes(since: &insetVersion) ?? .init()
      var autoRightPixels = 0
      var rightCrop = min(
        max(0, wantedInsets.right ?? autoRightPixels),
        first.width - minimumContentWidth(frameWidth: first.width))
      func masked(_ sample: ScreenshotSupport.ScrollingSample) -> ScreenshotSupport.ScrollingSample
      {
        ScreenshotSupport.scrollingMaskedSample(
          sample, sourceWidth: first.width, rightPixels: rightCrop)
      }
      guard let rawFirstSample = sample(first) else { return .failed }
      var firstSample = masked(rawFirstSample)

      let startedAt = currentTime()
      var slices = [first]
      var capturedFrames = 1
      var previousFrame = first
      var lastObservedFrame = first
      var rawPreviousSample = rawFirstSample
      var previousSample = firstSample
      var rawLastObservedSample = rawFirstSample
      var lastObservedSample = firstSample
      var totalHeight = first.height
      var viewportTop = 0
      var capturedTop = 0
      var capturedBottom = first.height
      var retainedPixels = first.width * first.height
      var contentSampleColumns: Range<Int>?
      var contentPixelColumns: Range<Int>?
      var fixedTopPixels = 0
      var autoTopPixels = 0
      var autoFixedTopPixels = 0
      var headerSlice: CGImage?
      var anchors = ScreenshotSupport.ScrollingAnchors()
      anchors.remember(firstSample, at: 0)
      var fullAnchors = ScreenshotSupport.ScrollingAnchors()
      fullAnchors.remember(rawFirstSample, at: 0)
      var rawOriginSample = rawFirstSample
      var originSample = firstSample
      /// Last frame whose position was confirmed against the captured content.
      var confirmedContent = firstSample
      var lastDirection: ScreenshotSupport.ScrollingDirection?
      var fixedBottomPixels = 0
      var autoBottomPixels = 0
      var autoFixedBottomPixels = 0
      var footerSlice: CGImage?
      var heldFragments: [HeldFragment] = []
      /// Frames whose content edges are the captured top and bottom. Edge
      /// bands are re-cut from them when the person moves an inset.
      var topFrame = first
      var bottomFrame = first
      var userTopSet = wantedInsets.top != nil
      var userBottomSet = wantedInsets.bottom != nil
      var userRightSet = wantedInsets.right != nil
      let frameHeight = first.height
      let minimumContent = minimumContentHeight(frameHeight: frameHeight)
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
          let full = makePreview(
            footerSlice.map { contentWithHeader() + [$0] } ?? contentWithHeader()),
          let preview = croppedRight(
            full,
            pixels: Int(
              (Double(rightCrop) * Double(full.width) / Double(first.width)).rounded()))
        else {
          previewStale = true
          return
        }
        previewStale = false
        await onPreview(preview)
      }
      func trimLeadingRows(_ rows: Int) -> Bool {
        var remaining = rows
        while remaining > 0, !slices.isEmpty {
          let firstSlice = slices[0]
          if firstSlice.height <= remaining {
            remaining -= firstSlice.height
            retainedPixels -= firstSlice.width * firstSlice.height
            slices.removeFirst()
          } else {
            guard
              let trimmed = copiedStrip(
                from: firstSlice, columns: 0..<firstSlice.width,
                topCrop: remaining, bottomCrop: 0)
            else { return false }
            retainedPixels -= firstSlice.width * remaining
            slices[0] = trimmed
            remaining = 0
          }
        }
        return true
      }
      func trimTrailingRows(_ rows: Int) -> Bool {
        var remaining = rows
        while remaining > 0, !slices.isEmpty {
          let lastSlice = slices[slices.count - 1]
          if lastSlice.height <= remaining {
            remaining -= lastSlice.height
            retainedPixels -= lastSlice.width * lastSlice.height
            slices.removeLast()
          } else {
            guard
              let trimmed = copiedStrip(
                from: lastSlice, columns: 0..<lastSlice.width,
                topCrop: 0, bottomCrop: remaining)
            else { return false }
            retainedPixels -= lastSlice.width * remaining
            slices[slices.count - 1] = trimmed
            remaining = 0
          }
        }
        return true
      }
      func applyInsets(_ next: ScrollingInsetControl.Values) async -> Bool {
        userTopSet = next.top != nil
        userBottomSet = next.bottom != nil
        userRightSet = next.right != nil
        let maxRight = max(0, first.width - minimumContentWidth(frameWidth: first.width))
        let requestedRight = next.right ?? autoRightPixels
        let newRight = min(max(0, requestedRight), maxRight)
        let maxTotal = max(0, frameHeight - minimumContent)
        let requestedTop = next.top ?? autoTopPixels
        let requestedBottom = next.bottom ?? autoBottomPixels
        let newTop = min(max(0, requestedTop), maxTotal)
        let newBottom = min(max(0, requestedBottom), max(0, maxTotal - newTop))
        guard newTop != fixedTopPixels || newBottom != fixedBottomPixels || newRight != rightCrop
        else { return true }
        let columns = contentPixelColumns ?? (0..<first.width)
        if newTop != fixedTopPixels || newBottom != fixedBottomPixels {
          if newTop > 0 {
            headerSlice = copiedStrip(
              from: topFrame, columns: columns, topCrop: 0, bottomCrop: frameHeight - newTop)
            guard headerSlice != nil else { return false }
          } else {
            headerSlice = nil
          }
          if newBottom > 0 {
            footerSlice = copiedStrip(
              from: bottomFrame, columns: columns, topCrop: frameHeight - newBottom, bottomCrop: 0)
            guard footerSlice != nil else { return false }
          } else {
            footerSlice = nil
          }
          let deltaTop = newTop - fixedTopPixels
          if deltaTop > 0 {
            guard trimLeadingRows(deltaTop) else { return false }
          } else if deltaTop < 0 {
            guard
              let prepended = copiedStrip(
                from: topFrame, columns: columns,
                topCrop: newTop, bottomCrop: frameHeight - fixedTopPixels)
            else { return false }
            slices.insert(prepended, at: 0)
          }
          let deltaBottom = newBottom - fixedBottomPixels
          if deltaBottom > 0 {
            guard trimTrailingRows(deltaBottom) else { return false }
          } else if deltaBottom < 0 {
            guard
              let appended = copiedStrip(
                from: bottomFrame, columns: columns,
                topCrop: frameHeight - fixedBottomPixels, bottomCrop: newBottom)
            else { return false }
            slices.append(appended)
          }
          if slices.isEmpty {
            guard
              let fallback = copiedStrip(
                from: topFrame, columns: columns, topCrop: newTop, bottomCrop: newBottom)
            else { return false }
            slices = [fallback]
          }
          fixedTopPixels = newTop
          fixedBottomPixels = newBottom
          totalHeight = slices.reduce(0) { $0 + $1.height }
          capturedBottom = capturedTop + totalHeight
          retainedPixels = slices.reduce(0) { $0 + $1.width * $1.height }
          rollback = nil
          fixedLayoutChanged = false
        }
        if newRight != rightCrop {
          rightCrop = newRight
          firstSample = masked(rawFirstSample)
          previousSample = masked(rawPreviousSample)
          lastObservedSample = masked(rawLastObservedSample)
          for fragIndex in heldFragments.indices {
            for entryIndex in heldFragments[fragIndex].entries.indices {
              heldFragments[fragIndex].entries[entryIndex].sample =
                masked(heldFragments[fragIndex].entries[entryIndex].rawSample)
            }
          }
        }
        originSample = masked(rawOriginSample)
        guard
          let updatedConfirmed = ScreenshotSupport.scrollingContentSample(
            originSample, top: fixedTopPixels, bottom: fixedBottomPixels)
        else { return false }
        confirmedContent = updatedConfirmed
        anchors = .init()
        for entry in fullAnchors.entries {
          if let content = ScreenshotSupport.scrollingContentSample(
            masked(entry.sample), top: fixedTopPixels, bottom: fixedBottomPixels)
          {
            anchors.remember(content, at: entry.top)
          }
        }
        await onInsets(fixedTopPixels, fixedBottomPixels, rightCrop)
        await publishPreview(force: true)
        await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, hasUnmatchedContent)
        return true
      }
      if wantedInsets.top != nil || wantedInsets.bottom != nil || wantedInsets.right != nil {
        guard await applyInsets(wantedInsets) else { return .failed }
      } else {
        await onInsets(fixedTopPixels, fixedBottomPixels, rightCrop)
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
          slices: contentWithHeader(), footerSlice: footerSlice, rightCrop: rightCrop,
          region: region, result: .limited)
      }
      func hold(
        _ content: CGImage,
        rawSample: ScreenshotSupport.ScrollingSample,
        sample: ScreenshotSupport.ScrollingSample
      ) {
        guard sample.pixels.count <= Self.maximumHeldImageBytes,
          let heldContent = ScreenshotSupport.scrollingContentSample(
            sample, top: fixedTopPixels, bottom: fixedBottomPixels)
        else { return }
        let minimumOverlap = max(24, heldContent.height / 4)
        var matches: [(fragmentIndex: Int, localTop: Int)] = []
        for fragmentIndex in heldFragments.indices {
          for entry in heldFragments[fragmentIndex].entries.reversed() {
            guard
              let entryContent = ScreenshotSupport.scrollingContentSample(
                entry.sample, top: fixedTopPixels, bottom: fixedBottomPixels)
            else { continue }
            if ScreenshotSupport.scrollingSamplesAreStable(
              entryContent, heldContent, contentColumns: contentSampleColumns)
            {
              return
            }
            if case .advanced(let overlap, let direction, _) =
              ScreenshotSupport.scrollingTransition(
                previous: entryContent, current: heldContent, contentColumns: contentSampleColumns),
              overlap >= minimumOverlap
            {
              let delta = heldContent.height - overlap
              let localTop = entry.top + (direction == .forward ? delta : -delta)
              matches.append((fragmentIndex, localTop))
              break
            }
          }
        }
        if matches.isEmpty {
          heldFragments.append(
            HeldFragment(entries: [
              HeldFragment.Entry(content: content, rawSample: rawSample, sample: sample, top: 0)
            ]))
        } else {
          let primaryIndex = matches[0].fragmentIndex
          let primaryTop = matches[0].localTop
          if !heldFragments[primaryIndex].entries.contains(where: { abs($0.top - primaryTop) <= 4 })
          {
            heldFragments[primaryIndex].entries.append(
              HeldFragment.Entry(
                content: content, rawSample: rawSample, sample: sample, top: primaryTop))
            heldFragments[primaryIndex].entries.sort { $0.top < $1.top }
          }
          for match in matches.dropFirst().reversed() {
            let shift = primaryTop - match.localTop
            let removed = heldFragments.remove(at: match.fragmentIndex)
            for var entry in removed.entries {
              entry.top += shift
              if !heldFragments[primaryIndex].entries.contains(where: {
                abs($0.top - entry.top) <= 4
              }) {
                heldFragments[primaryIndex].entries.append(entry)
              }
            }
            heldFragments[primaryIndex].entries.sort { $0.top < $1.top }
          }
          while heldFragments[primaryIndex].entries.count > Self.maximumEntriesPerFragment {
            let entries = heldFragments[primaryIndex].entries
            let removable = Array(1..<(entries.count - 1))
            guard
              let victim = removable.min(by: {
                entries[$0 + 1].top - entries[$0 - 1].top
                  < entries[$1 + 1].top - entries[$1 - 1].top
              })
            else { break }
            heldFragments[primaryIndex].entries.remove(at: victim)
          }
        }
        while heldFragments.count > Self.maximumHeldFragments
          || heldFragments.reduce(0, { $0 + $1.imageBytes }) > Self.maximumHeldImageBytes
        {
          heldFragments.removeFirst()
        }
      }
      /// A held fragment stays detached until any of its frames overlaps the
      /// confirmed main chain. Once placed, every connected frame in that
      /// fragment merges in order and can cascade-merge remaining fragments.
      func mergeHeldFrames(
        anchor: ScreenshotSupport.ScrollingSample, at anchorTop: Int,
        columns: Range<Int>, sampleColumns: Range<Int>?, minimumOverlap: Int
      ) async throws -> (limit: Result?, merged: Bool, failed: Bool) {
        var merged = false
        var didMergePass = true
        while didMergePass {
          didMergePass = false
          for fragmentIndex in heldFragments.indices {
            var matchedShift: Int?
            for entry in heldFragments[fragmentIndex].entries {
              guard
                let entryContent = ScreenshotSupport.scrollingContentSample(
                  entry.sample, top: fixedTopPixels, bottom: fixedBottomPixels)
              else { continue }
              let entryTopOnMain: Int?
              if case .advanced(let overlap, let direction, _) =
                ScreenshotSupport.scrollingTransition(
                  previous: anchor, current: entryContent, contentColumns: sampleColumns),
                overlap >= minimumOverlap
              {
                let delta = entryContent.height - overlap
                entryTopOnMain = anchorTop + (direction == .forward ? delta : -delta)
              } else if anchors.entries.count >= 2,
                case .position(let verifiedTop) = anchors.verified(
                  matching: entryContent, columns: sampleColumns, minimumOverlap: minimumOverlap)
              {
                entryTopOnMain = verifiedTop
              } else {
                entryTopOnMain = nil
              }
              if let mainTop = entryTopOnMain,
                mainTop <= capturedBottom,
                mainTop + entryContent.height >= capturedTop
              {
                matchedShift = mainTop - entry.top
                break
              }
            }
            guard let shift = matchedShift else { continue }
            let fragment = heldFragments.remove(at: fragmentIndex)
            let positioned = fragment.entries.map { (entry: $0, mainTop: $0.top + shift) }
            let prepends = positioned.filter { $0.mainTop < capturedTop }.sorted {
              $0.mainTop > $1.mainTop
            }
            let appends = positioned.sorted { $0.mainTop < $1.mainTop }

            func applyEntry(_ entry: HeldFragment.Entry, at heldTop: Int) async throws -> (
              limit: Result?, failed: Bool
            ) {
              guard
                let heldContent = ScreenshotSupport.scrollingContentSample(
                  entry.sample, top: fixedTopPixels, bottom: fixedBottomPixels)
              else { return (nil, false) }
              let heldBottom = heldTop + heldContent.height
              let sharedRows = min(capturedBottom, heldBottom) - max(capturedTop, heldTop)
              let prepend = max(0, capturedTop - heldTop)
              let append = max(0, heldBottom - capturedBottom)
              guard sharedRows >= minimumOverlap, prepend == 0 || append == 0 else {
                return (nil, false)
              }
              if prepend == 0 && append == 0 {
                anchors.remember(heldContent, at: heldTop)
                fullAnchors.remember(entry.rawSample, at: heldTop)
                return (nil, false)
              }
              let extra = prepend + append
              guard
                totalHeight + extra + fixedTopPixels + fixedBottomPixels <= heightLimit,
                totalHeight + extra + fixedTopPixels + fixedBottomPixels
                  <= ScreenshotSupport.scrollingCaptureMaximumPixels / columns.count,
                retainedPixels + extra * columns.count
                  <= ScreenshotSupport.scrollingCaptureMaximumRetainedPixels
              else {
                return (try await waitAtLimit(), false)
              }
              if append > 0, fixedBottomPixels > 0 {
                footerSlice = copiedStrip(
                  from: entry.content, columns: columns,
                  topCrop: entry.content.height - fixedBottomPixels, bottomCrop: 0)
                guard footerSlice != nil else { return (nil, true) }
              }
              if prepend > 0 {
                let seam = min(
                  ScreenshotSupport.scrollingBestSeamDepth(
                    previousEdgeFrame: topFrame, currentFrame: entry.content,
                    sharedRows: sharedRows, topInset: fixedTopPixels,
                    bottomInset: fixedBottomPixels, rightCrop: rightCrop, fromBottom: false),
                  max(0, min(sharedRows - 1, totalHeight - 1)))
                if seam > 0 {
                  guard trimLeadingRows(seam) else { return (nil, true) }
                }
                guard
                  let strip = copiedStrip(
                    from: entry.content, columns: columns,
                    topCrop: fixedTopPixels,
                    bottomCrop: entry.content.height - fixedTopPixels - prepend - seam)
                else { return (nil, true) }
                slices.insert(strip, at: 0)
                topFrame = entry.content
                capturedTop = heldTop
                retainedPixels += strip.width * strip.height
              }
              if append > 0 {
                let seam = min(
                  ScreenshotSupport.scrollingBestSeamDepth(
                    previousEdgeFrame: bottomFrame, currentFrame: entry.content,
                    sharedRows: sharedRows, topInset: fixedTopPixels,
                    bottomInset: fixedBottomPixels, rightCrop: rightCrop, fromBottom: true),
                  max(0, min(sharedRows - 1, totalHeight - 1)))
                if seam > 0 {
                  guard trimTrailingRows(seam) else { return (nil, true) }
                }
                guard
                  let strip = copiedStrip(
                    from: entry.content, columns: columns,
                    topCrop: fixedTopPixels + (capturedBottom - seam - heldTop),
                    bottomCrop: fixedBottomPixels)
                else { return (nil, true) }
                slices.append(strip)
                bottomFrame = entry.content
                capturedBottom = heldBottom
                retainedPixels += strip.width * strip.height
              }
              totalHeight = capturedBottom - capturedTop
              anchors.remember(heldContent, at: heldTop)
              fullAnchors.remember(entry.rawSample, at: heldTop)
              return (nil, false)
            }

            for item in prepends {
              let outcome = try await applyEntry(item.entry, at: item.mainTop)
              if let limit = outcome.limit { return (limit, merged, false) }
              if outcome.failed { return (nil, merged, true) }
            }
            for item in appends where item.mainTop >= capturedTop {
              let outcome = try await applyEntry(item.entry, at: item.mainTop)
              if let limit = outcome.limit { return (limit, merged, false) }
              if outcome.failed { return (nil, merged, true) }
            }
            merged = true
            didMergePass = true
            break
          }
        }
        return (nil, merged, false)
      }
      await publishPreview(force: true)
      await onProgress(totalHeight, false)

      while true {
        try Task.checkCancellation()

        if let nextInsets = insetControl?.changes(since: &insetVersion) {
          guard await applyInsets(nextInsets) else { return .failed }
        }

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
            footerSlice: footerSlice, rightCrop: rightCrop,
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
            slices: contentWithHeader(), footerSlice: footerSlice, rightCrop: rightCrop,
            region: region, result: .partial)
        }
        guard let current = contentFrame(frame),
          let rawCurrentSample = sample(current)
        else {
          await flushStalePreview(now: now, force: true)
          return completed(
            slices: contentWithHeader(), footerSlice: footerSlice, rightCrop: rightCrop,
            region: region, result: .partial)
        }
        try Task.checkCancellation()
        if let nextInsets = insetControl?.changes(since: &insetVersion) {
          guard await applyInsets(nextInsets) else { return .failed }
        }
        var currentSample = masked(rawCurrentSample)
        capturedFrames += 1
        lastCaptureAt = currentTime()
        let frameIsStable = ScreenshotSupport.scrollingSamplesAreStable(
          lastObservedSample,
          currentSample,
          contentColumns: contentSampleColumns)
        let observedFrameBefore = lastObservedFrame
        lastObservedFrame = current
        let observedBefore = lastObservedSample
        rawLastObservedSample = rawCurrentSample
        lastObservedSample = currentSample
        if !frameIsStable { lastChangedAt = lastCaptureAt }
        var transition: ScreenshotSupport.ScrollingTransition = .unmatched
        if contentSampleColumns == nil,
          let prevBand = ScreenshotSupport.scrollingContentSample(
            previousSample, top: fixedTopPixels, bottom: fixedBottomPixels),
          let currBand = ScreenshotSupport.scrollingContentSample(
            currentSample, top: fixedTopPixels, bottom: fixedBottomPixels)
        {
          transition = ScreenshotSupport.scrollingTransition(
            previous: prevBand, current: currBand)
        }

        if contentSampleColumns == nil,
          case .advanced(let overlap, let direction, let matchedColumns) = transition,
          let prevBand = ScreenshotSupport.scrollingContentSample(
            previousSample, top: fixedTopPixels, bottom: fixedBottomPixels),
          let currBand = ScreenshotSupport.scrollingContentSample(
            currentSample, top: fixedTopPixels, bottom: fixedBottomPixels),
          overlap >= max(24, currBand.height / 4)
        {
          // Fixed strips are identified only after moving content has matched.
          let detectedTop = ScreenshotSupport.scrollingFixedTopRows(
            previous: prevBand, current: currBand, overlap: overlap,
            contentColumns: matchedColumns)
          let detectedBottom = ScreenshotSupport.scrollingFixedBottomRows(
            previous: prevBand, current: currBand, overlap: overlap,
            contentColumns: matchedColumns)
          let cornerTop = ScreenshotSupport.scrollingRoundedCornerRows(
            previous: previousFrame, current: current,
            scale: region.scale, fromTop: true, touchesWindowEdge: region.touchesWindowTop)
          let cornerBottom = ScreenshotSupport.scrollingRoundedCornerRows(
            previous: previousFrame, current: current,
            scale: region.scale, fromTop: false, touchesWindowEdge: region.touchesWindowBottom)
          let maxTotal = max(0, frameHeight - minimumContent)
          autoFixedTopPixels = fixedTopPixels + detectedTop
          let autoTop = min(max(autoFixedTopPixels, cornerTop), maxTotal)
          autoFixedBottomPixels = fixedBottomPixels + detectedBottom
          let autoBottom = min(
            max(autoFixedBottomPixels, cornerBottom), max(0, maxTotal - autoTop))
          autoTopPixels = autoTop
          autoBottomPixels = autoBottom
          let top = userTopSet ? min(fixedTopPixels, maxTotal) : autoTop
          let bottom =
            userBottomSet
            ? min(fixedBottomPixels, max(0, maxTotal - top))
            : min(autoBottom, max(0, maxTotal - top))
          let detectedRight = ScreenshotSupport.scrollingRightScrollerColumns(
            previous: previousFrame, current: current,
            advance: currBand.height - overlap, direction: direction,
            topInset: top, bottomInset: bottom, scale: region.scale)
          let maxRight = max(0, first.width - minimumContentWidth(frameWidth: first.width))
          autoRightPixels = min(detectedRight, maxRight)
          if !userRightSet && autoRightPixels != rightCrop {
            rightCrop = autoRightPixels
            firstSample = masked(rawFirstSample)
            previousSample = masked(rawPreviousSample)
            currentSample = masked(rawCurrentSample)
            lastObservedSample = currentSample
          }
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
            originOverlap >= max(24, originContent.height / 4)
          {
            continuesOrigin = true
          }
          let base = continuesOrigin ? first : current
          let rawBaseSample = continuesOrigin ? rawFirstSample : rawCurrentSample
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
          topFrame = base
          bottomFrame = base
          if top > 0 {
            headerSlice = copiedStrip(
              from: base, columns: 0..<base.width,
              topCrop: 0, bottomCrop: base.height - top)
            guard headerSlice != nil else { return .failed }
          } else {
            headerSlice = nil
          }
          if bottom > 0 {
            footerSlice = copiedStrip(
              from: base, columns: 0..<base.width,
              topCrop: base.height - bottom, bottomCrop: 0)
            guard footerSlice != nil else { return .failed }
          } else {
            footerSlice = nil
          }
          slices = [cropped]
          totalHeight = cropped.height
          capturedTop = 0
          capturedBottom = totalHeight
          viewportTop = 0
          retainedPixels = cropped.width * cropped.height
          anchors = .init()
          anchors.remember(initialContent, at: 0)
          fullAnchors = .init()
          fullAnchors.remember(rawBaseSample, at: 0)
          confirmedContent = initialContent
          rawOriginSample = rawBaseSample
          originSample = baseSample
          previousFrame = base
          rawPreviousSample = rawBaseSample
          previousSample = baseSample
          lastDirection = nil
          await onInsets(fixedTopPixels, fixedBottomPixels, rightCrop)
        }

        guard current.width == first.width, current.height == first.height,
          var currentContent = ScreenshotSupport.scrollingContentSample(
            currentSample, top: fixedTopPixels, bottom: fixedBottomPixels)
        else {
          await flushStalePreview(now: now, force: true)
          return completed(
            slices: contentWithHeader(), footerSlice: footerSlice, rightCrop: rightCrop,
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
          if case .advanced(let observedOverlap, let observedDirection, _) = observed {
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
              (!userTopSet
                && (top > fixedTopPixels + 2 || top < autoFixedTopPixels - 2))
              || (!userBottomSet
                && (bottom > fixedBottomPixels + 2 || bottom < autoFixedBottomPixels - 2))
            if !fixedLayoutChanged, !userRightSet, autoRightPixels == 0 {
              let detectedRight = ScreenshotSupport.scrollingRightScrollerColumns(
                previous: observedFrameBefore, current: current,
                advance: observedCurrent.height - observedOverlap, direction: observedDirection,
                topInset: fixedTopPixels, bottomInset: fixedBottomPixels, scale: region.scale)
              if detectedRight > 0 {
                let maxRight = max(0, first.width - minimumContentWidth(frameWidth: first.width))
                autoRightPixels = min(detectedRight, maxRight)
                if autoRightPixels > 0 {
                  guard await applyInsets(insetControl?.current ?? .init()) else { return .failed }
                  currentSample = masked(rawCurrentSample)
                  lastObservedSample = currentSample
                  if let updated = ScreenshotSupport.scrollingContentSample(
                    currentSample, top: fixedTopPixels, bottom: fixedBottomPixels)
                  {
                    currentContent = updated
                    observedTransition = nil
                  }
                }
              }
            }
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
            rawPreviousSample = saved.rawSample
            previousSample = saved.sample
            rawOriginSample = saved.rawSample
            originSample = saved.sample
            topFrame = saved.topFrame
            bottomFrame = saved.bottomFrame
            let restored =
              ScreenshotSupport.scrollingContentSample(
                saved.sample, top: fixedTopPixels, bottom: fixedBottomPixels) ?? saved.sample
            confirmedContent = restored
            anchors = saved.anchors
            fullAnchors = saved.fullAnchors
            anchors.remember(restored, at: saved.viewport)
            fullAnchors.remember(saved.rawSample, at: saved.viewport)
            lastDirection = saved.direction
            footerSlice = saved.footer
            rollback = nil
            await publishPreview(force: true)
          }
          heldFragments.removeAll()
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
          hold(current, rawSample: rawCurrentSample, sample: currentSample)
          hasUnmatchedContent = true
          scrollPending = false
          await onProgress(totalHeight + fixedTopPixels + fixedBottomPixels, true)
          continue
        }

        guard let columns = contentPixelColumns else {
          // The moving content is not cropped yet; adopt the position only.
          viewportTop = placed.position
          rawOriginSample = rawCurrentSample
          originSample = currentSample
          confirmedContent = currentContent
          anchors.remember(currentContent, at: placed.position)
          fullAnchors.remember(rawCurrentSample, at: placed.position)
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
            rawSample: rawOriginSample, anchors: anchors, fullAnchors: fullAnchors,
            direction: lastDirection, footer: footerSlice, topFrame: topFrame,
            bottomFrame: bottomFrame)
          if fixedBottomPixels > 0 {
            footerSlice = copiedStrip(
              from: current, columns: columns,
              topCrop: current.height - fixedBottomPixels, bottomCrop: 0)
            guard footerSlice != nil else { return .failed }
          }
          if prepend > 0 {
            let seam = min(
              ScreenshotSupport.scrollingBestSeamDepth(
                previousEdgeFrame: topFrame, currentFrame: current,
                sharedRows: sharedRows, topInset: fixedTopPixels,
                bottomInset: fixedBottomPixels, rightCrop: rightCrop, fromBottom: false),
              max(0, min(sharedRows - 1, totalHeight - 1)))
            if seam > 0 {
              guard trimLeadingRows(seam) else { return .failed }
            }
            guard
              let strip = copiedStrip(
                from: current, columns: columns, topCrop: fixedTopPixels,
                bottomCrop: current.height - fixedTopPixels - prepend - seam)
            else { return .failed }
            slices.insert(strip, at: 0)
            topFrame = current
            capturedTop = position
            retainedPixels += strip.width * strip.height
          }
          if append > 0 {
            let seam = min(
              ScreenshotSupport.scrollingBestSeamDepth(
                previousEdgeFrame: bottomFrame, currentFrame: current,
                sharedRows: sharedRows, topInset: fixedTopPixels,
                bottomInset: fixedBottomPixels, rightCrop: rightCrop, fromBottom: true),
              max(0, min(sharedRows - 1, totalHeight - 1)))
            if seam > 0 {
              guard trimTrailingRows(seam) else { return .failed }
            }
            guard
              let strip = copiedStrip(
                from: current, columns: columns,
                topCrop: current.height - fixedBottomPixels - append - seam,
                bottomCrop: fixedBottomPixels)
            else { return .failed }
            slices.append(strip)
            bottomFrame = current
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
        rawOriginSample = rawCurrentSample
        originSample = currentSample
        confirmedContent = currentContent
        anchors.remember(currentContent, at: position)
        fullAnchors.remember(rawCurrentSample, at: position)
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
    rightCrop: Int,
    region: CaptureRegion,
    hasUnmatchedContent: Bool
  ) -> Result {
    guard hasUnmatchedContent else {
      return completed(
        slices: slices,
        footerSlice: footerSlice, rightCrop: rightCrop,
        region: region,
        result: .success)
    }
    return completed(
      slices: slices,
      footerSlice: footerSlice, rightCrop: rightCrop,
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
    rightCrop: Int,
    region: CaptureRegion,
    result: CompletedResult
  ) -> Result {
    guard !Task.isCancelled else { return .cancelled }
    let completedSlices = footerSlice.map { slices + [$0] } ?? slices
    guard let stitched = stitch(completedSlices),
      let image = croppedRight(stitched, pixels: rightCrop)
    else {
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

  /// Leave out the excluded right band (overlay scroller, window edge).
  static func croppedRight(_ image: CGImage, pixels: Int) -> CGImage? {
    guard pixels > 0 else { return image }
    let width = image.width - pixels
    guard width > 0 else { return nil }
    return image.cropping(to: CGRect(x: 0, y: 0, width: width, height: image.height))
  }

  /// ScreenCaptureKit can pad a region with a transparent edge row. Keeping
  /// that row in each appended strip produces a dark seam in image viewers.
  /// Side columns stay: the stitched width is the selection width.
  private static func contentFrame(_ image: CGImage) -> CGImage? {
    if [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) { return image }
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    func alphaRows(y: Int, rows: Int) -> [UInt8]? {
      guard rows > 0, let strip = image.cropping(to: CGRect(x: 0, y: y, width: width, height: rows))
      else { return nil }
      var alpha = [UInt8](repeating: 0, count: width * rows)
      let drawn = alpha.withUnsafeMutableBytes { bytes -> Bool in
        guard
          let context = CGContext(
            data: bytes.baseAddress, width: width, height: rows,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return false }
        context.interpolationQuality = .none
        context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: rows))
        return true
      }
      return drawn ? alpha : nil
    }
    let edgeCheck = min(4, height)
    if height > edgeCheck * 2,
      let topAlpha = alphaRows(y: 0, rows: edgeCheck),
      let bottomAlpha = alphaRows(y: height - edgeCheck, rows: edgeCheck)
    {
      var top = 0
      while top < edgeCheck && topAlpha[(top * width)..<((top + 1) * width)].allSatisfy({ $0 == 0 })
      {
        top += 1
      }
      var bottomOffset = edgeCheck
      while bottomOffset > 0
        && bottomAlpha[((bottomOffset - 1) * width)..<(bottomOffset * width)].allSatisfy({ $0 == 0 }
        )
      {
        bottomOffset -= 1
      }
      if top < edgeCheck && bottomOffset > 0 {
        let bottom = height - (edgeCheck - bottomOffset)
        if top == 0 && bottom == height { return image }
        return image.cropping(to: CGRect(x: 0, y: top, width: width, height: bottom - top))
      }
    }
    guard let alpha = alphaRows(y: 0, rows: height) else { return nil }
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
