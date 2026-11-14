// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Adapted for DevBar.

import AppKit
import CoreGraphics

/// Watches a selected region while the person scrolls it, then joins only
/// overlaps that can be identified confidently. Pixel polling also handles
/// scrollbar drags and keyboard scrolling without global event permissions.
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

  private static let sampleInterval: TimeInterval = 0.09
  private static let settleInterval: TimeInterval = 0.22
  private static let finishGraceInterval: TimeInterval = 0.85

  public static func capture(
    region: CaptureRegion,
    finishSignal: FinishSignal,
    onPreview: @escaping @MainActor (CGImage) -> Void = { _ in },
    onProgress: @escaping @MainActor (Int, Bool) -> Void
  ) async -> Result {
    guard let source = await ScreenshotCaptureEngine.prepareDisplayRegion(region: region) else {
      return Task.isCancelled ? .cancelled : .failed
    }
    return await captureFrames(
      region: region, finishSignal: finishSignal, onPreview: onPreview, onProgress: onProgress
    ) {
      await source.image()
    }
  }

  static func captureFrames(
    region: CaptureRegion,
    finishSignal: FinishSignal,
    frameLimit: Int = ScreenshotSupport.scrollingCaptureMaximumFrames,
    onPreview: @escaping @MainActor (CGImage) -> Void = { _ in },
    onProgress: @escaping @MainActor (Int, Bool) -> Void,
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
      var fixedBottomPixels = 0
      var footerSlice: CGImage?
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
        if let finishRequestedAt,
          !scrollPending || now - finishRequestedAt >= finishGraceInterval
        {
          return completedByUser(
            slices: slices,
            footerSlice: footerSlice,
            region: region,
            hasUnmatchedContent: hasUnmatchedContent)
        }
        if now - startedAt
          >= ScreenshotSupport.scrollingCaptureMaximumDuration
          || capturedFrames >= frameLimit
        {
          return completed(
            slices: slices,
            footerSlice: footerSlice,
            region: region,
            result: .limited)
        }

        // Observe pixels throughout the session. Wheel monitors miss
        // scrollbar drags, keyboard scrolling and some other apps.
        let sinceLastCapture = now - lastCaptureAt
        if sinceLastCapture < sampleInterval {
          try await Task.sleep(
            nanoseconds: UInt64(
              (sampleInterval - sinceLastCapture) * 1_000_000_000))
          continue
        }

        guard let frame = await nextFrame(),
          let current = contentFrame(frame),
          let currentSample = sample(current)
        else {
          return completed(
            slices: slices, footerSlice: footerSlice,
            region: region, result: .partial)
        }
        try Task.checkCancellation()
        capturedFrames += 1
        lastCaptureAt = ProcessInfo.processInfo.systemUptime
        let frameIsStable = ScreenshotSupport.scrollingSamplesAreStable(
          lastObservedSample,
          currentSample,
          contentColumns: contentSampleColumns)
        lastObservedSample = currentSample
        if !frameIsStable { lastChangedAt = lastCaptureAt }
        let transition = ScreenshotSupport.scrollingTransition(
          previous: previousSample,
          current: currentSample,
          contentColumns: contentSampleColumns)

        switch transition {
        case .end:
          if hasUnmatchedContent { await onProgress(totalHeight + fixedBottomPixels, false) }
          hasUnmatchedContent = false

        case .advanced(let sampleOverlap, let direction, let matchedColumns):
          let overlap = Int(
            (CGFloat(sampleOverlap) / CGFloat(currentSample.height)
              * CGFloat(current.height)).rounded())
          guard overlap > 0, overlap < current.height else { return .failed }
          if contentSampleColumns == nil {
            contentSampleColumns = matchedColumns
            contentPixelColumns = 0..<current.width
            let footerRows = ScreenshotSupport.scrollingFixedBottomRows(
              previous: previousSample, current: currentSample, overlap: sampleOverlap,
              contentColumns: matchedColumns)
            fixedBottomPixels = Int(
              (CGFloat(footerRows) / CGFloat(currentSample.height)
                * CGFloat(current.height)).rounded())
            guard
              let cropped = copiedStrip(
                from: first, columns: 0..<first.width,
                topCrop: 0, bottomCrop: fixedBottomPixels)
            else { return .failed }
            slices[0] = cropped
            totalHeight = cropped.height
            capturedBottom = totalHeight
            retainedPixels = cropped.width * cropped.height
          }
          guard let columns = contentPixelColumns else { return .failed }
          let delta = current.height - overlap
          viewportTop += direction == .forward ? delta : -delta
          let contentHeight = current.height - fixedBottomPixels
          let viewportBottom = viewportTop + contentHeight
          let prepend = max(0, capturedTop - viewportTop)
          let append = max(0, viewportBottom - capturedBottom)
          let extra = prepend + append
          guard extra <= contentHeight else {
            return completed(
              slices: slices, footerSlice: footerSlice, region: region, result: .partial)
          }
          if fixedBottomPixels > 0 {
            guard
              let footer = copiedStrip(
                from: current, columns: columns,
                topCrop: contentHeight, bottomCrop: 0)
            else { return .failed }
            footerSlice = footer
          }
          let footerPixels = footerSlice.map { $0.width * $0.height } ?? 0
          guard
            totalHeight + extra + fixedBottomPixels <= ScreenshotSupport
              .scrollingCaptureMaximumPixels / columns.count,
            retainedPixels + extra * columns.count + footerPixels
              <= ScreenshotSupport.scrollingCaptureMaximumRetainedPixels
          else {
            return completed(
              slices: slices, footerSlice: footerSlice, region: region, result: .limited)
          }
          if prepend > 0 {
            guard
              let strip = copiedStrip(
                from: current, columns: columns,
                topCrop: 0, bottomCrop: current.height - prepend)
            else { return .failed }
            slices.insert(strip, at: 0)
            capturedTop = viewportTop
          }
          if append > 0 {
            guard
              let strip = copiedStrip(
                from: current, columns: columns,
                topCrop: contentHeight - append, bottomCrop: fixedBottomPixels)
            else { return .failed }
            slices.append(strip)
            capturedBottom = viewportBottom
          }
          totalHeight += extra
          retainedPixels += extra * columns.count
          previousSample = currentSample
          hasUnmatchedContent = false
          if extra > 0, let preview = makePreview(footerSlice.map { slices + [$0] } ?? slices) {
            await onPreview(preview)
          }
          await onProgress(totalHeight + fixedBottomPixels, false)

        case .unmatched:
          if frameIsStable && lastCaptureAt - lastChangedAt >= settleInterval {
            hasUnmatchedContent = true
            scrollPending = false
            await onProgress(totalHeight, true)
            continue
          }
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
}
