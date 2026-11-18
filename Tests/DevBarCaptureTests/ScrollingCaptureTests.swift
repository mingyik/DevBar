import CoreGraphics
import Foundation
import Testing

@testable import DevBarCapture

private actor Frames {
  let images: [CGImage]
  var index = 0
  let repeatingLast: Bool
  init(_ images: [CGImage], repeatingLast: Bool = false) {
    self.images = images
    self.repeatingLast = repeatingLast
  }
  func next() -> CGImage? {
    guard index < images.count || repeatingLast else { return nil }
    let image = images[min(index, images.count - 1)]
    index += 1
    return image
  }
}

private final class PreviewClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: TimeInterval = 0
  private var cancelled = false
  private var waiters: [Waiter] = []

  private final class Waiter {
    let deadline: TimeInterval
    let continuation: CheckedContinuation<Void, Error>
    var resumed = false
    init(deadline: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
      self.deadline = deadline
      self.continuation = continuation
    }
  }

  func now() -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return time
  }

  var hasWaiter: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !waiters.isEmpty
  }

  func sleep(_ seconds: TimeInterval) async throws {
    let deadline = now() + seconds
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        if cancelled || Task.isCancelled {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        if time >= deadline {
          lock.unlock()
          continuation.resume()
          return
        }
        waiters.append(Waiter(deadline: deadline, continuation: continuation))
        lock.unlock()
      }
    } onCancel: {
      self.cancelWaiters()
    }
  }

  func advance(to newTime: TimeInterval) {
    lock.lock()
    time = max(time, newTime)
    let ready = waiters.filter { time >= $0.deadline && !$0.resumed }
    for waiter in ready { waiter.resumed = true }
    waiters.removeAll { $0.resumed }
    lock.unlock()
    for waiter in ready { waiter.continuation.resume() }
  }

  func advance(by delta: TimeInterval) { advance(to: now() + delta) }

  func waitUntilSleeping() async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !hasWaiter {
      if ContinuousClock.now >= deadline { return false }
      await Task.yield()
    }
    return true
  }

  private func cancelWaiters() {
    lock.lock()
    cancelled = true
    let pending = waiters.filter { !$0.resumed }
    for waiter in pending { waiter.resumed = true }
    waiters.removeAll { $0.resumed }
    lock.unlock()
    for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
  }
}

@MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(2)
  while !condition() {
    if ContinuousClock.now >= deadline { return false }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return true
}

private func previewSleepFinishes(
  _ sleeper: Task<Void, Error>, clock: PreviewClock, timeout: Duration = .seconds(1)
) async -> Bool {
  await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      _ = await sleeper.result
      return true
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return false
    }
    let finished = await group.next() ?? false
    // Cancelling the child awaiting sleeper.result cannot stop that wait.
    // Release the independent sleeper before the group drains its children.
    if !finished { clock.advance(to: .greatestFiniteMagnitude) }
    group.cancelAll()
    return finished
  }
}

@Test func previewClockCancelledSleepDoesNotHang() async {
  let clock = PreviewClock()
  let sleeper = Task { try await clock.sleep(30) }
  #expect(await clock.waitUntilSleeping())
  sleeper.cancel()
  let finished = await previewSleepFinishes(sleeper, clock: clock)
  #expect(finished)
  guard case .failure(is CancellationError) = await sleeper.result else {
    Issue.record("expected cancellation")
    return
  }
}

@Test func previewClockSleepAfterCancelDoesNotHang() async {
  let clock = PreviewClock()
  let sleeper = Task {
    while !Task.isCancelled { await Task.yield() }
    try await clock.sleep(30)
  }
  sleeper.cancel()
  let finished = await previewSleepFinishes(sleeper, clock: clock)
  #expect(finished)
  guard case .failure(is CancellationError) = await sleeper.result else {
    Issue.record("expected cancellation")
    return
  }
}

@Test func previewClockWatchdogReleasesSleepingTaskOnTimeout() async {
  let clock = PreviewClock()
  // Deliberately leave this task uncancelled to exercise timeout cleanup,
  // independently of the clock's cancellation implementation.
  let sleeper = Task { try await clock.sleep(30) }
  guard await clock.waitUntilSleeping() else {
    clock.advance(to: .greatestFiniteMagnitude)
    _ = await sleeper.result
    Issue.record("expected a sleeping task before the watchdog started")
    return
  }
  let finished = await previewSleepFinishes(sleeper, clock: clock, timeout: .zero)
  #expect(!finished)
  guard case .success = await sleeper.result else {
    Issue.record("timeout cleanup did not release the sleeping task")
    return
  }
}

private func frame(offset: Int, footer: Int = 0, salt: Int = 0, header: Int = 0) -> CGImage {
  let width = 64
  let height = 120
  var pixels = [UInt8](repeating: 0, count: width * height)
  for row in 0..<height {
    for col in 0..<width {
      let y =
        row < header ? row + 2000 : (row >= height - footer ? row + 1000 : row - header + offset)
      pixels[row * width + col] = UInt8(salt == 0 ? (y * 17 + col * 31 + (y / 7) * 13) % 251 : 0)
    }
  }
  let provider = CGDataProvider(data: Data(pixels) as CFData)!
  return CGImage(
    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// Deterministic but non-periodic rows, so a large offset cannot alias onto
/// another offset the way the simple pattern above can.
private func uniqueFrame(offset: Int, footer: Int = 0) -> CGImage {
  let width = 64
  let height = 120
  var pixels = [UInt8](repeating: 0, count: width * height)
  for row in 0..<height {
    for col in 0..<width {
      let y = row >= height - footer ? 1000 + row : row + offset
      var value =
        UInt32(truncatingIfNeeded: y) &* 747_796_405 &+ UInt32(col * 19 + 2_891_336_453)
      value = ((value >> ((value >> 28) + 4)) ^ value) &* 277_803_737
      pixels[row * width + col] = UInt8(truncatingIfNeeded: (value >> 22) ^ value)
    }
  }
  let provider = CGDataProvider(data: Data(pixels) as CFData)!
  return CGImage(
    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func testRegion() throws -> CaptureRegion {
  try CaptureRegion(
    displayID: 1, globalRect: CGRect(x: 0, y: 0, width: 64, height: 120),
    screenFrame: CGRect(x: 0, y: 0, width: 64, height: 120), scale: 1)
}

@MainActor @Test func scrollingCollectsBothDirectionsWithoutDuplicatingVisitedRows() async throws {
  for footer in [0, 18] {
    func capture(_ offsets: [Int]) async throws -> CGImage {
      let frames = Frames(offsets.map { frame(offset: $0, footer: footer) })
      let result = await ScreenshotScrollingCapture.captureFrames(
        region: try testRegion(), finishSignal: .init(),
        onProgress: { _, _ in }, nextFrame: { await frames.next() })
      guard case .partial(let image) = result else {
        Issue.record("expected complete retained pixels when the source ends")
        throw CaptureError.noImage
      }
      return image
    }
    let forward = try await capture([0, 42, 84, 126])
    let both = try await capture([84, 42, 0, 42, 84, 126, 84])
    #expect(forward.height == 246)
    #expect(both.height == forward.height)
    #expect(both.width == forward.width)
    #expect(both.dataProvider?.data as Data? == forward.dataProvider?.data as Data?)
  }
}

@Test func scrollingPreviewUsesBoundedPixelsAndPreservesAspectRatio() {
  let preview = ScreenshotScrollingCapture.makePreview(Array(repeating: frame(offset: 0), count: 8))
  #expect(preview?.width == 53)
  #expect(preview?.height == 800)
  #expect(ScreenshotScrollingCapture.makePreview([]) == nil)
}

@MainActor @Test func scrollingPreviewCatchesUpWhenGrowthWasThrottled() async throws {
  let frames = Frames([0, 42, 84, 126].map { frame(offset: $0) })
  var previews: [CGImage] = []
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onPreview: { previews.append($0) },
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  guard case .partial(let image) = result else {
    Issue.record("expected a retained image")
    return
  }
  let expected = ScreenshotScrollingCapture.makePreview([image])
  #expect(previews.last?.height == expected?.height)
  #expect((previews.last?.height ?? 0) > (previews.first?.height ?? 0))
}

@MainActor @Test func scrollingPreviewCatchesUpBeforeFinishWhileStillRunning() async throws {
  let clock = PreviewClock()
  let frames = Frames([0, 42, 84, 126].map { frame(offset: $0) }, repeatingLast: true)
  let finish = ScreenshotScrollingCapture.FinishSignal()
  let region = try testRegion()
  final class State {
    var previews: [Int] = []
    var height = 0
    var progressCount = 0
    var progressAtFullPreview: Int?
    var result: ScreenshotScrollingCapture.Result?
  }
  let state = State()
  let capture = Task { @MainActor in
    state.result = await ScreenshotScrollingCapture.captureFrames(
      region: region, finishSignal: finish,
      onPreview: { preview in
        state.previews.append(preview.height)
        if preview.height >= 246, state.progressAtFullPreview == nil {
          state.progressAtFullPreview = state.progressCount
        }
      },
      onProgress: { value, _ in
        state.height = value
        state.progressCount += 1
      },
      nextFrame: { await frames.next() },
      currentTime: { clock.now() },
      sleep: { try await clock.sleep($0) })
  }
  defer { capture.cancel() }

  guard await waitUntil({ state.previews == [120] && state.height == 120 }) else {
    Issue.record("expected the initial preview before any clock movement")
    return
  }
  #expect(clock.now() == 0)

  while state.height < 246 {
    guard await clock.waitUntilSleeping() else {
      Issue.record("capture did not wait for the next sample")
      return
    }
    let next = clock.now() + 0.03
    guard next < 0.25 else {
      Issue.record("growth left the throttle window at \(clock.now())")
      return
    }
    clock.advance(to: next)
  }
  guard await clock.waitUntilSleeping() else {
    Issue.record("capture did not stop on the throttled preview")
    return
  }
  #expect(state.height == 246)
  #expect(state.previews == [120])
  #expect(clock.now() < 0.25)

  let progressBeforeFlush = state.progressCount
  clock.advance(to: 0.25)
  guard await waitUntil({ state.previews.contains(246) }) else {
    Issue.record("idle flush did not publish the grown preview")
    return
  }
  #expect(state.progressAtFullPreview == progressBeforeFlush)
  #expect(!finish.isRequested)
  finish.request()
  let pump = Task {
    let deadline = ContinuousClock.now + .seconds(2)
    while !Task.isCancelled, ContinuousClock.now < deadline {
      if clock.hasWaiter { clock.advance(by: 0.03) }
      await Task.yield()
    }
    if !Task.isCancelled { capture.cancel() }
  }
  await capture.value
  pump.cancel()
  guard case .success(let image) = state.result else {
    Issue.record("expected the idle preview flush to finish the capture")
    return
  }
  #expect(image.height == 246)
}

@Test func scrollingMatchesAndKeepsFixedFooter() async throws {
  let frames = Frames([frame(offset: 0, footer: 18), frame(offset: 42, footer: 18)])
  let finish = ScreenshotScrollingCapture.FinishSignal()
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: finish,
    onProgress: { height, _ in if height > 120 { finish.request() } },
    nextFrame: { await frames.next() })
  guard case .success(let image) = result else {
    Issue.record("expected success")
    return
  }
  #expect(image.width == 64)
  #expect(image.height == 162)
}

@Test func scrollingUnmatchedKeepsPartialResult() async throws {
  let frames = Frames([frame(offset: 0), frame(offset: 0, salt: 111)])
  let finish = ScreenshotScrollingCapture.FinishSignal()
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: finish,
    onProgress: { _, unmatched in if unmatched { finish.request() } },
    nextFrame: { await frames.next() })
  guard case .partial(let image) = result else {
    Issue.record("expected partial")
    return
  }
  #expect(image.height == 120)
}

@MainActor @Test func scrollingRecoversAfterTransientUnmatchedFrames() async throws {
  // Salted frames leave only the initial anchor. An approximate move is not
  // corroborated; returning to that exact frame clears the hold, and the
  // following forward move is ordinary evidence.
  let frames = Frames(
    [frame(offset: 0)] + Array(repeating: frame(offset: 0, salt: 111), count: 5)
      + [frame(offset: 0), frame(offset: 42)])
  let finish = ScreenshotScrollingCapture.FinishSignal()
  let timeout = Task {
    try? await Task.sleep(for: .seconds(2))
    finish.request()
  }
  defer { timeout.cancel() }
  var sawUnmatched = false
  var recovered = false
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: finish,
    onProgress: { height, unmatched in
      if unmatched { sawUnmatched = true }
      if sawUnmatched && height > 120 && !unmatched {
        recovered = true
        finish.request()
      }
    }, nextFrame: { await frames.next() })
  #expect(sawUnmatched)
  #expect(recovered)
  guard case .success(let image) = result else {
    Issue.record("expected recovery using the last matched frame")
    return
  }
  #expect(image.height == 162)
}

@MainActor @Test func scrollingHoldsApproximateMoveAfterUnmatchedWithOneAnchor() async throws {
  let frames = Frames(
    [frame(offset: 0), frame(offset: 0, salt: 111), frame(offset: 42)])
  var grew = false
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { height, _ in if height > 120 { grew = true } },
    nextFrame: { await frames.next() })
  #expect(!grew)
  guard case .partial(let image) = result else {
    Issue.record("expected the initial frame to be retained")
    return
  }
  #expect(image.height == 120)
}

@MainActor @Test func scrollingDoesNotAdoptASingleAnchorApproximateAlias() async throws {
  // sample(168) falsely matches sample(0) as a 35-row rollback. After an
  // unmatched frame only one anchor exists, so that alias must not prepend.
  let frames = Frames(
    [frame(offset: 168), frame(offset: 168, salt: 111), frame(offset: 0)])
  var grew = false
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { height, _ in if height > 120 { grew = true } },
    nextFrame: { await frames.next() })
  #expect(!grew)
  guard case .partial(let image) = result else {
    Issue.record("expected the alias to be held")
    return
  }
  #expect(image.height == 120)
  #expect(image.width == 64)
}

private func selectionRegion(width: CGFloat, windowID: CGWindowID? = nil) throws -> CaptureRegion {
  try CaptureRegion(
    displayID: 1,
    globalRect: CGRect(x: 12, y: 18, width: width, height: 120),
    screenFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
    scale: 1,
    windowID: windowID)
}

private func frameWithSideAlpha(offset: Int, width: Int) -> CGImage {
  let height = 120
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  for row in 0..<height {
    for col in 0..<width {
      let edge = col < 4 || col >= width - 4
      let y = row + offset
      let value = CGFloat((y * 17 + col * 31 + (y / 7) * 13) % 251) / 255
      if edge {
        context.setFillColor(CGColor(gray: 0, alpha: 40.0 / 255))  // devbar:allow-color
      } else {
        context.setFillColor(CGColor(gray: value, alpha: 1))  // devbar:allow-color
      }
      context.fill(CGRect(x: col, y: row, width: 1, height: 1))
    }
  }
  return context.makeImage()!
}

@MainActor @Test func scrollingKeepsSelectionWidthIncludingWindowEdges() async throws {
  for width in [48, 96] {
    let region = try selectionRegion(width: CGFloat(width), windowID: 7)
    let frames = Frames([
      frameWithSideAlpha(offset: 0, width: width),
      frameWithSideAlpha(offset: 42, width: width),
    ])
    let result = await ScreenshotScrollingCapture.captureFrames(
      region: region, finishSignal: .init(),
      onProgress: { _, _ in }, nextFrame: { await frames.next() })
    guard case .partial(let image) = result else {
      Issue.record("expected a stitched image at the selection width")
      return
    }
    #expect(image.width == Int(region.pixelRect.width))
    #expect(image.width == width)
    #expect(image.height > 120)
  }
}

private func repaintedBand(_ image: CGImage, columns: Range<Int>) -> CGImage {
  let width = image.width
  let height = image.height
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))  // devbar:allow-color
  context.fill(
    CGRect(x: columns.lowerBound, y: 0, width: columns.count, height: height))
  return context.makeImage()!
}

@MainActor @Test func scrollingTreatsATransientRepaintAsStationary() async throws {
  // Window activation repaints a narrow band while the viewport stays put.
  // That must not lock the capture; the next real movement has to append.
  let base = frame(offset: 0)
  let frames = Frames([
    base,
    repaintedBand(base, columns: 16..<24),
    repaintedBand(frame(offset: 42), columns: 16..<24),
  ])
  var sawUnmatched = false
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, unmatched in if unmatched { sawUnmatched = true } },
    nextFrame: { await frames.next() })
  guard case .partial(let image) = result else {
    Issue.record("expected retained pixels when the source ends")
    return
  }
  #expect(!sawUnmatched)
  #expect(image.height == 162)
}

@MainActor @Test func scrollingRecoversWhileReversingDirection() async throws {
  let frames = Frames(
    [frame(offset: 84), frame(offset: 42)]
      + Array(repeating: frame(offset: 0, salt: 111), count: 5)
      + [0, 42, 84, 126].map { frame(offset: $0) })
  let finish = ScreenshotScrollingCapture.FinishSignal()
  let timeout = Task {
    try? await Task.sleep(for: .seconds(3))
    finish.request()
  }
  defer { timeout.cancel() }
  var sawUnmatched = false
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: finish,
    onProgress: { height, unmatched in
      if unmatched { sawUnmatched = true }
      if height == 246 && !unmatched { finish.request() }
    }, nextFrame: { await frames.next() })
  #expect(sawUnmatched)
  guard case .success(let image) = result else {
    Issue.record("expected recovery followed by bidirectional capture")
    return
  }
  #expect(image.height == 246)
  let baseline = Frames([0, 42, 84, 126].map { frame(offset: $0) })
  let expected = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await baseline.next() })
  guard case .partial(let reference) = expected else {
    Issue.record("expected baseline image")
    return
  }
  #expect(image.dataProvider?.data as Data? == reference.dataProvider?.data as Data?)
}

@MainActor @Test func scrollingRelocatesToOlderCapturedRegionAfterLargeJump() async throws {
  let offsets = [0, 42, 84, 126, 168, 0, 0, 42, 84, 126, 168, 210]
  let frames = Frames(offsets.map { frame(offset: $0) })
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  guard case .partial(let image) = result else {
    Issue.record("expected retained result when the source ends")
    return
  }
  #expect(image.height == 330)
  let baseline = Frames([0, 42, 84, 126, 168, 210].map { frame(offset: $0) })
  let expected = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await baseline.next() })
  guard case .partial(let reference) = expected else {
    Issue.record("expected baseline image")
    return
  }
  #expect(image.dataProvider?.data as Data? == reference.dataProvider?.data as Data?)
}

@MainActor @Test func scrollingKeepsFixedHeaderAndFooterOnceInBothDirections() async throws {
  func capture(_ offsets: [Int]) async throws -> CGImage {
    let frames = Frames(offsets.map { frame(offset: $0, footer: 16, header: 14) })
    let result = await ScreenshotScrollingCapture.captureFrames(
      region: try testRegion(), finishSignal: .init(),
      onProgress: { _, _ in }, nextFrame: { await frames.next() })
    guard case .partial(let image) = result else { throw CaptureError.noImage }
    return image
  }
  let forward = try await capture([0, 35, 70, 105])
  let both = try await capture([70, 35, 0, 35, 70, 105, 70])
  #expect(forward.height == 225)
  #expect(both.height == 225)
  #expect(both.dataProvider?.data as Data? == forward.dataProvider?.data as Data?)
  func gray(_ image: CGImage) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height)
    let context = try #require(
      CGContext(
        data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Data(bytes)
  }
  let source = frame(offset: 0, footer: 16, header: 14)
  let expectedTop = try #require(source.cropping(to: CGRect(x: 0, y: 0, width: 64, height: 14)))
  let actualTop = try #require(both.cropping(to: CGRect(x: 0, y: 0, width: 64, height: 14)))
  let expectedBottom = try #require(
    source.cropping(to: CGRect(x: 0, y: 104, width: 64, height: 16)))
  let actualBottom = try #require(both.cropping(to: CGRect(x: 0, y: 209, width: 64, height: 16)))
  #expect(try gray(actualTop) == gray(expectedTop))
  #expect(try gray(actualBottom) == gray(expectedBottom))
}

@Test func scrollingAnchorStorageIsBoundedAndKeepsExtremes() {
  var anchors = ScreenshotSupport.ScrollingAnchors()
  for index in 0..<40 {
    let sample = ScreenshotSupport.ScrollingSample(
      width: 64, height: 120, pixels: Array(frame(offset: index * 10).dataProvider!.data! as Data))
    anchors.remember(sample, at: index * 10)
  }
  #expect(anchors.entries.count <= ScreenshotSupport.ScrollingAnchors.maximumCount)
  #expect(anchors.retainedBytes <= ScreenshotSupport.ScrollingAnchors.maximumBytes)
  #expect(anchors.entries.first?.top == 0)
  #expect(anchors.entries.last?.top == 390)
  let last = anchors.entries.last!
  #expect(
    anchors.registration(matching: last.sample, columns: nil, allowOverlap: false) == .position(390)
  )
  let tooLarge = ScreenshotSupport.ScrollingSample(
    width: 1, height: ScreenshotSupport.ScrollingAnchors.maximumBytes + 1,
    pixels: Array(repeating: 0, count: ScreenshotSupport.ScrollingAnchors.maximumBytes + 1))
  anchors.remember(tooLarge, at: 999)
  #expect(anchors.entries.last?.top == 390)
  for index in 0..<8 {
    anchors.remember(
      .init(
        width: 128, height: 8192, pixels: Array(repeating: UInt8(index), count: 128 * 8192)),
      at: 1000 + index * 100)
  }
  #expect(anchors.retainedBytes <= ScreenshotSupport.ScrollingAnchors.maximumBytes)
  #expect(anchors.entries.count <= ScreenshotSupport.ScrollingAnchors.maximumCount)
}

@Test func scrollingAnchorsFindOverlapAndRejectConflictingPositions() {
  func sample(_ offset: Int) -> ScreenshotSupport.ScrollingSample {
    ScreenshotSupport.ScrollingSample(
      width: 64, height: 120, pixels: Array(frame(offset: offset).dataProvider!.data! as Data))
  }
  var anchors = ScreenshotSupport.ScrollingAnchors()
  anchors.remember(sample(0), at: 0)
  #expect(
    anchors.registration(matching: sample(30), columns: nil, allowOverlap: true) == .position(30))
  anchors.remember(sample(0), at: 500)
  #expect(
    anchors.registration(matching: sample(30), columns: nil, allowOverlap: true) == .ambiguous)
  #expect(
    anchors.registration(matching: sample(0), columns: nil, allowOverlap: false) == .ambiguous)
}

@Test func scrollingDoesNotTreatBlankTopBandAsFixedHeader() {
  func sample(_ offset: Int) -> ScreenshotSupport.ScrollingSample {
    let pixels = (0..<80).flatMap { row in
      (0..<8).map { column in UInt8(row < 12 ? 0 : (row * 17 + column * 13 + offset) % 251) }
    }
    return .init(width: 8, height: 80, pixels: pixels)
  }
  #expect(
    ScreenshotSupport.scrollingFixedTopRows(
      previous: sample(0), current: sample(35), overlap: 50, contentColumns: 0..<8) == 0)
}

@MainActor @Test func scrollingRepeatedNewRegionsDoNotJumpToAnOldAnchor() async throws {
  func repeated(_ offset: Int) -> CGImage {
    let pixels = (0..<120).flatMap { row in
      (0..<64).map { column -> UInt8 in
        var value =
          UInt32((row + offset) % 240) &* 747_796_405 &+ UInt32(column * 19 + 2_891_336_453)
        value = ((value >> ((value >> 28) + 4)) ^ value) &* 277_803_737
        return UInt8(truncatingIfNeeded: (value >> 22) ^ value)
      }
    }
    return CGImage(
      width: 64, height: 120, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 64,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .init(rawValue: 0),
      provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }
  let frames = Frames(stride(from: 0, through: 560, by: 40).map(repeated))
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  guard case .partial(let image) = result else { throw CaptureError.noImage }
  #expect(image.height == 680)
}

@Test func scrollingDoesNotTreatSimilarTextRowsAsFixedFooter() {
  func sample(_ offset: Int) -> ScreenshotSupport.ScrollingSample {
    let width = 256
    let height = 120
    var pixels = [UInt8](repeating: 255, count: width * height)
    for row in 0..<112 {
      for column in 0..<width {
        pixels[row * width + column] = UInt8((row * 17 + column * 13 + offset) % 251)
      }
    }
    // Similar text lines: one dark glyph per row, moved slightly between frames.
    for row in 112..<height {
      pixels[row * width + (row + offset) % width] = 0
    }
    return .init(width: width, height: height, pixels: pixels)
  }
  #expect(
    ScreenshotSupport.scrollingFixedBottomRows(
      previous: sample(0), current: sample(3), overlap: 100, contentColumns: 0..<256) == 0)
}

@Test func scrollingDoesNotTreatBlankBottomBandAsFixedFooter() {
  func sample(_ offset: Int) -> ScreenshotSupport.ScrollingSample {
    let pixels = (0..<80).flatMap { row in
      (0..<8).map { column in UInt8(row >= 68 ? 0 : (row * 17 + column * 13 + offset) % 251) }
    }
    return .init(width: 8, height: 80, pixels: pixels)
  }
  #expect(
    ScreenshotSupport.scrollingFixedBottomRows(
      previous: sample(0), current: sample(35), overlap: 50, contentColumns: 0..<8) == 0)
}

@MainActor @Test func scrollingPausesWhenAFixedBarAppearsLater() async throws {
  for top in [true, false] {
    let images =
      [frame(offset: 0), frame(offset: 35)]
      + [70, 105, 140].map {
        frame(offset: $0, footer: top ? 0 : 16, header: top ? 14 : 0)
      }
    let frames = Frames(images)
    var pausedAt: Int?
    var grewAfterPause = false
    let result = await ScreenshotScrollingCapture.captureFrames(
      region: try testRegion(), finishSignal: .init(),
      onProgress: { height, unmatched in
        if let pausedAt, height > pausedAt { grewAfterPause = true }
        if unmatched && pausedAt == nil { pausedAt = height }
      }, nextFrame: { await frames.next() })
    #expect(pausedAt != nil)
    #expect(!grewAfterPause)
    guard case .partial(let image) = result else { throw CaptureError.noImage }
    #expect(image.height == pausedAt)
    #expect(image.height == 155)
  }
}

@MainActor @Test func scrollingResumesAfterReturningToOriginalFixedLayout() async throws {
  let frames = Frames(
    [frame(offset: 0), frame(offset: 35)]
      + [70, 105, 140].map { frame(offset: $0, header: 14) }
      + [35, 70, 105, 140, 175].map { frame(offset: $0) })
  var paused = false
  var resumed = false
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { height, unmatched in
      if unmatched { paused = true }
      if paused && !unmatched && height > 155 { resumed = true }
    }, nextFrame: { await frames.next() })
  #expect(paused)
  #expect(resumed)
  guard case .partial(let image) = result else { throw CaptureError.noImage }
  #expect(image.height == 295)
  let baseline = Frames([0, 35, 70, 105, 140, 175].map { frame(offset: $0) })
  let expected = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await baseline.next() })
  guard case .partial(let reference) = expected else { throw CaptureError.noImage }
  #expect(image.dataProvider?.data as Data? == reference.dataProvider?.data as Data?)
}

@MainActor @Test func scrollingHeightLimitAndCancellation() async throws {
  let frames = Frames([frame(offset: 0)])
  let finish = ScreenshotScrollingCapture.FinishSignal()
  let limited = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: finish, heightLimit: 120,
    onLimitReached: { finish.request() },
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  guard case .limited = limited else {
    Issue.record("expected limit")
    return
  }
  let region = try testRegion()
  let task = Task {
    let result = await ScreenshotScrollingCapture.captureFrames(
      region: region, finishSignal: finish,
      onProgress: { _, _ in }, nextFrame: { await frames.next() })
    if case .cancelled = result { return true }
    return false
  }
  task.cancel()
  guard await task.value else {
    Issue.record("expected cancellation")
    return
  }
}

@MainActor @Test func scrollingIdleFramesDoNotConsumeHeightBudget() async throws {
  let clock = PreviewClock()
  let still = frame(offset: 0)
  let frames = Frames(Array(repeating: still, count: 600) + [frame(offset: 42), frame(offset: 84)])
  let finish = ScreenshotScrollingCapture.FinishSignal()
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: finish,
    onProgress: { height, _ in if height == 204 { finish.request() } },
    nextFrame: { await frames.next() }, currentTime: { clock.now() },
    sleep: { seconds in clock.advance(by: max(1, seconds)) })
  guard case .success(let image) = result else {
    Issue.record("idle frames must not end capture before later scrolling")
    return
  }
  #expect(image.height == 204)
  #expect(await frames.index >= 602)
  #expect(clock.now() > 120)
}

@MainActor @Test func scrollingHeightLimitWaitsForUserWithoutReadingMoreFrames() async throws {
  for offsets in [[0, 42, 84], [84, 42, 0]] {
    let clock = PreviewClock()
    let frames = Frames(offsets.map { frame(offset: $0, footer: 16, header: 14) })
    let finish = ScreenshotScrollingCapture.FinishSignal()
    let region = try testRegion()
    final class State {
      var paused = false
      var height = 0
      var result: ScreenshotScrollingCapture.Result?
    }
    let state = State()
    let task = Task { @MainActor in
      state.result = await ScreenshotScrollingCapture.captureFrames(
        region: region, finishSignal: finish, heightLimit: 162,
        onLimitReached: { state.paused = true },
        onProgress: { height, _ in state.height = height },
        nextFrame: { await frames.next() }, currentTime: { clock.now() },
        sleep: { try await clock.sleep($0) })
    }
    defer { task.cancel() }
    for _ in 0..<20 {
      if state.paused { break }
      #expect(await clock.waitUntilSleeping())
      clock.advance(by: 0.05)
      await Task.yield()
    }
    #expect(await waitUntil { state.paused })
    #expect(state.result == nil)
    #expect(state.height == 162)
    let consumedAtPause = await frames.index
    #expect(await clock.waitUntilSleeping())
    clock.advance(by: 300)
    #expect(await clock.waitUntilSleeping())
    #expect(await frames.index == consumedAtPause)
    #expect(state.result == nil)
    finish.request()
    clock.advance(by: 0.05)
    await task.value
    guard case .limited(let image) = state.result else {
      Issue.record("only the user's finish action may return the limited image")
      continue
    }
    #expect(image.height == 162)
  }
}

@MainActor @Test func scrollingPausedHeightLimitCanBeCancelled() async throws {
  let clock = PreviewClock()
  let frames = Frames([frame(offset: 0)])
  let region = try testRegion()
  var paused = false
  let task = Task { @MainActor in
    let result = await ScreenshotScrollingCapture.captureFrames(
      region: region, finishSignal: .init(), heightLimit: 120,
      onLimitReached: { paused = true }, onProgress: { _, _ in },
      nextFrame: { await frames.next() }, currentTime: { clock.now() },
      sleep: { try await clock.sleep($0) })
    if case .cancelled = result { return true }
    return false
  }
  #expect(await waitUntil { paused })
  task.cancel()
  guard await task.value else {
    Issue.record("cancelling the paused capture must not return an image")
    return
  }
}

@Test func captureNamesAndSavesWithoutOverwriting() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let date = Date(timeIntervalSince1970: 0)
  let first = try CaptureFileWriter.save(
    frame(offset: 0), directory: directory, scrolling: false, date: date)
  let second = try CaptureFileWriter.save(
    frame(offset: 0), directory: directory, scrolling: false, date: date)
  #expect(first.0.lastPathComponent.hasPrefix("DevBar 截图 "))
  #expect(second.0.lastPathComponent.hasSuffix(" (2).png"))
  #expect(try Data(contentsOf: first.0) == first.1)
  #expect(try Data(contentsOf: second.0) == second.1)
}

@Test func scrollingIgnoresPeriodicColumnsWhenMatchingFastScroll() {
  func sample(_ offset: Int) -> ScreenshotSupport.ScrollingSample {
    var pixels = [UInt8](repeating: 0, count: 64 * 160)
    for row in 0..<160 {
      for column in 0..<64 {
        if column < 32 {
          pixels[row * 64 + column] = UInt8((row + offset) % 16 * 15)
        } else {
          let seed = UInt32(row + offset)
          var value = seed &* 2_654_435_761
          value &+= UInt32(column) &* 97
          value = ((value >> ((value >> 27) + 5)) ^ value) &* 2_246_822_519
          pixels[row * 64 + column] = UInt8(truncatingIfNeeded: (value >> 19) ^ value)
        }
      }
    }
    return .init(width: 64, height: 160, pixels: pixels)
  }
  guard
    case .advanced(let overlap, .forward, let columns) =
      ScreenshotSupport.scrollingTransition(previous: sample(0), current: sample(40))
  else {
    Issue.record("expected a unique match through the text columns")
    return
  }
  #expect(overlap == 120)
  #expect(columns.lowerBound >= 32)
}

@Test func scrollingPausesWhenEveryColumnIsPeriodic() {
  func sample(_ offset: Int) -> ScreenshotSupport.ScrollingSample {
    let pixels = (0..<(64 * 160)).map { index in
      UInt8((index / 64 + offset) % 16 * 15)
    }
    return .init(width: 64, height: 160, pixels: pixels)
  }
  #expect(
    ScreenshotSupport.scrollingTransition(previous: sample(0), current: sample(40))
      == .unmatched)
}

@Test func scrollingFindsTheExactOffsetOnATallFrame() {
  func sample(_ offset: Int) -> ScreenshotSupport.ScrollingSample {
    let height = 1200
    let width = 256
    let pixels = (0..<(width * height)).map { index in
      let row = index / width
      var value = UInt32(row + offset) &* 747_796_405
      value &+= UInt32((index % width) * 19 + 2_891_336_453)
      value = ((value >> ((value >> 28) + 4)) ^ value) &* 277_803_737
      return UInt8(truncatingIfNeeded: (value >> 22) ^ value)
    }
    return .init(width: width, height: height, pixels: pixels)
  }
  guard
    case .advanced(let overlap, .forward, _) = ScreenshotSupport.scrollingTransition(
      previous: sample(0), current: sample(42))
  else {
    Issue.record("expected the exact offset")
    return
  }
  #expect(overlap == 1158)
}

private func uniqueFrame(offset: Int) -> CGImage {
  let pixels = (0..<120).flatMap { row in
    (0..<64).map { column -> UInt8 in
      var value = UInt32(row + offset) &* 747_796_405 &+ UInt32(column * 19 + 2_891_336_453)
      value = ((value >> ((value >> 28) + 4)) ^ value) &* 277_803_737
      return UInt8(truncatingIfNeeded: (value >> 22) ^ value)
    }
  }
  return CGImage(
    width: 64, height: 120, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 64,
    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .init(rawValue: 0),
    provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
    shouldInterpolate: false, intent: .defaultIntent)!
}

@MainActor @Test func scrollingHoldsOrderAfterAJumpWithNoOverlap() async throws {
  // Capture 0…200, jump to 400 without overlap, then return to the captured
  // range. The jump must not append anything, and the return must not
  // duplicate or reorder captured rows.
  let frames = Frames([0, 40, 80, 400, 0, 40, 80].map(uniqueFrame))
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  guard case .partial(let image) = result else {
    Issue.record("expected retained result when the source ends")
    return
  }
  let referenceFrames = Frames([0, 40, 80].map(uniqueFrame))
  let referenceResult = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await referenceFrames.next() })
  guard case .partial(let reference) = referenceResult else {
    Issue.record("expected baseline image")
    return
  }
  #expect(image.height == 200)
  #expect(image.dataProvider?.data as Data? == reference.dataProvider?.data as Data?)
}

@MainActor @Test func scrollingResumesAfterAJumpThatSkippedOverlap() async throws {
  // The jump frames chain into a fragment [200, 360). Returning to the
  // confirmed frame and scrolling forward to 120 bridges the fragment onto
  // the main chain and merges all of it at once.
  let frames = Frames([0, 40, 200, 240, 40, 80, 120].map(uniqueFrame))
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  guard case .partial(let image) = result else {
    Issue.record("expected retained result when the source ends")
    return
  }
  let referenceFrames = Frames([0, 40, 80, 120, 160, 200, 240].map(uniqueFrame))
  let referenceResult = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await referenceFrames.next() })
  guard case .partial(let reference) = referenceResult else {
    Issue.record("expected baseline image")
    return
  }
  #expect(image.height == 360)
  #expect(image.dataProvider?.data as Data? == reference.dataProvider?.data as Data?)
}

private func registrationSample(_ offset: Int) -> ScreenshotSupport.ScrollingSample {
  let width = 64
  let height = 120
  let pixels = (0..<(width * height)).map { index -> UInt8 in
    let row = index / width
    var value = UInt32(row + offset) &* 747_796_405
    value &+= UInt32((index % width) * 19 + 2_891_336_453)
    value = ((value >> ((value >> 28) + 4)) ^ value) &* 277_803_737
    return UInt8(truncatingIfNeeded: (value >> 22) ^ value)
  }
  return .init(width: width, height: height, pixels: pixels)
}

@Test func scrollingRejectsASecondPlausibleAnchorPosition() {
  // The frame matches three viewports at 40 and two others at 1040. The
  // stronger group must not win by vote: both positions are still plausible.
  var anchors = ScreenshotSupport.ScrollingAnchors()
  for offset in [0, 40, 80] {
    anchors.remember(registrationSample(offset), at: offset)
  }
  for offset in [0, 40] {
    anchors.remember(registrationSample(offset), at: 1000 + offset)
  }
  #expect(
    anchors.verified(
      matching: registrationSample(40), columns: 0..<64, minimumOverlap: 30) == .ambiguous)
}

@MainActor @Test func scrollingRecoversDirectionAfterAFixedBarRollback() async throws {
  let frames = Frames(
    [frame(offset: 0), frame(offset: 35)]
      + [70, 105].map { frame(offset: $0, header: 14) }
      + [35, 0, 35, 70].map { frame(offset: $0) })
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  guard case .partial(let image) = result else { throw CaptureError.noImage }
  let baseline = Frames([0, 35, 70].map { frame(offset: $0) })
  let expected = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await baseline.next() })
  guard case .partial(let reference) = expected else { throw CaptureError.noImage }
  #expect(image.height == 190)
  #expect(image.dataProvider?.data as Data? == reference.dataProvider?.data as Data?)
}

@MainActor @Test func scrollingFillsGapWithHeldFrameWhenBridgeAppears() async throws {
  for footer in [0, 18] {
    let contentHeight = 120 - footer
    let step = contentHeight / 3
    let bridge = step * 2
    let held = contentHeight + step + 1
    let frames = Frames(
      [0, step, held, bridge].map { uniqueFrame(offset: $0, footer: footer) })
    let result = await ScreenshotScrollingCapture.captureFrames(
      region: try testRegion(), finishSignal: .init(),
      onProgress: { _, _ in }, nextFrame: { await frames.next() })
    guard case .partial(let image) = result else { throw CaptureError.noImage }
    let baseline = Frames(
      [0, step, bridge, step * 3, held].map { uniqueFrame(offset: $0, footer: footer) })
    let expected = await ScreenshotScrollingCapture.captureFrames(
      region: try testRegion(), finishSignal: .init(),
      onProgress: { _, _ in }, nextFrame: { await baseline.next() })
    guard case .partial(let reference) = expected else { throw CaptureError.noImage }
    #expect(image.height == held + contentHeight + footer)
    #expect(image.dataProvider?.data as Data? == reference.dataProvider?.data as Data?)
  }
}

@MainActor @Test func scrollingDoesNotAppendAStillDisjointHeldFrame() async throws {
  let frames = Frames([frame(offset: 0), frame(offset: 500)])
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  guard case .partial(let image) = result else { throw CaptureError.noImage }
  #expect(image.height == 120)
}

@MainActor @Test func scrollingFinishesAfterGraceWhileFramesKeepArriving() async throws {
  let region = try testRegion()
  let frames = Frames([frame(offset: 0)], repeatingLast: true)
  let finish = ScreenshotScrollingCapture.FinishSignal()
  finish.request()
  let capture = Task { @MainActor in
    let result = await ScreenshotScrollingCapture.captureFrames(
      region: region, finishSignal: finish,
      onProgress: { _, _ in }, pendingFrames: { 1 },
      nextFrame: { await frames.next() })
    if case .success = result { return true }
    return false
  }
  let timeout = Task {
    try? await Task.sleep(for: .seconds(3))
    capture.cancel()
  }
  let finished = await capture.value
  timeout.cancel()
  #expect(finished, "finish must complete once the grace interval passes")
}

@MainActor @Test func scrollingInsetControlCropsRightBandAndMasksScrollerColumns() async throws {
  func frameWithRightBand(offset: Int, bandSalt: Int) -> CGImage {
    let base = uniqueFrame(offset: offset)
    let width = base.width
    let height = base.height
    var bytes = [UInt8]((base.dataProvider?.data as Data?) ?? Data())
    for row in 0..<height {
      for col in (width - 12)..<width {
        bytes[row * width + col] = UInt8((row * 29 + col * 11 + bandSalt * 53) % 251)
      }
    }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .init(rawValue: 0),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }
  let insets = ScrollingInsetControl(.init(right: 12))
  var reportedInsets: [(Int, Int, Int)] = []
  let frames = Frames([
    frameWithRightBand(offset: 0, bandSalt: 1),
    frameWithRightBand(offset: 40, bandSalt: 2),
    frameWithRightBand(offset: 80, bandSalt: 3),
  ])
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(), insets: insets,
    onInsets: { reportedInsets.append(($0, $1, $2)) },
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  guard case .partial(let image) = result else {
    Issue.record("expected partial stitched image")
    return
  }
  #expect(image.width == 52)
  #expect(image.height == 200)
  #expect(reportedInsets.last?.2 == 12)
}

@MainActor @Test func scrollingInsetControlRespectsManualTopBottomOverLayoutChange() async throws {
  func frameWithChangingTop(offset: Int, topSalt: Int) -> CGImage {
    let base = uniqueFrame(offset: offset)
    let width = base.width
    let height = base.height
    var bytes = [UInt8]((base.dataProvider?.data as Data?) ?? Data())
    for row in 0..<18 {
      for col in 0..<width {
        bytes[row * width + col] = UInt8((row * 13 + col * 7 + topSalt * 41) % 251)
      }
    }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .init(rawValue: 0),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }
  let insets = ScrollingInsetControl(.init(top: 18, bottom: 10))
  let frames = Frames([
    frameWithChangingTop(offset: 0, topSalt: 1),
    frameWithChangingTop(offset: 30, topSalt: 2),
    frameWithChangingTop(offset: 60, topSalt: 3),
  ])
  var sawUnmatched = false
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(), insets: insets,
    onProgress: { _, unmatched in if unmatched { sawUnmatched = true } },
    nextFrame: { await frames.next() })
  #expect(!sawUnmatched)
  guard case .partial(let image) = result else {
    Issue.record("expected manual insets to prevent fixed-layout lock")
    return
  }
  #expect(image.height == 180)
}

@MainActor @Test func scrollingInsetControlUpdatesMidCapture() async throws {
  let insets = ScrollingInsetControl()
  actor StepFrames {
    let base: Frames
    let insets: ScrollingInsetControl
    var step = 0
    init(_ images: [CGImage], insets: ScrollingInsetControl) {
      self.base = Frames(images)
      self.insets = insets
    }
    func next() async -> CGImage? {
      step += 1
      if step == 3 {
        insets.update {
          $0.top = 14
          $0.bottom = 16
          $0.right = 8
        }
      } else if step == 4 {
        insets.update {
          $0.top = 6
          $0.right = 0
        }
      }
      return await base.next()
    }
  }
  let queue = StepFrames(
    [
      uniqueFrame(offset: 0),
      uniqueFrame(offset: 30),
      uniqueFrame(offset: 60),
      uniqueFrame(offset: 90),
    ], insets: insets)
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(), insets: insets,
    onProgress: { _, _ in },
    nextFrame: { await queue.next() })
  guard case .partial(let image) = result else {
    Issue.record("expected stitched result after mid-capture inset updates")
    return
  }
  #expect(image.width == 64)
  #expect(image.height == 210)
}

@MainActor @Test func scrollingDetectsAndPreservesBottomRoundedCornersOnce() async throws {
  func roundedCornerFrame(offset: Int) -> CGImage {
    let width = 80
    let height = 120
    var pixels = [UInt8](repeating: 255, count: width * height)
    for row in 0..<height {
      for col in 0..<width {
        let y = row + offset
        var value =
          UInt32(truncatingIfNeeded: y) &* 747_796_405 &+ UInt32(col * 19 + 2_891_336_453)
        value = ((value >> ((value >> 28) + 4)) ^ value) &* 277_803_737
        var pixel = UInt8(truncatingIfNeeded: (value >> 22) ^ value)
        // Side edges outside corners match interior side value 240.
        if col == 0 || col == width - 1 { pixel = 240 }
        // Bottom 12 rows have curved outer corners (background 30) while center scrolls.
        if row >= height - 12 {
          let cornerDepth = row - (height - 12) + 1
          if col < cornerDepth || col >= width - cornerDepth {
            pixel = 30
          }
        }
        pixels[row * width + col] = pixel
      }
    }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .init(rawValue: 0),
      provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }
  let region = try CaptureRegion(
    displayID: 1, globalRect: CGRect(x: 0, y: 0, width: 80, height: 120),
    screenFrame: CGRect(x: 0, y: 0, width: 80, height: 120), scale: 1,
    windowID: 9, touchesWindowBottom: true)
  var reportedBottom = 0
  let frames = Frames([0, 30, 60].map(roundedCornerFrame))
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: region, finishSignal: .init(),
    onInsets: { _, bottom, _ in reportedBottom = bottom },
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  #expect(reportedBottom == 12)
  guard case .partial(let image) = result else {
    Issue.record("expected stitched result with rounded corner footer")
    return
  }
  #expect(image.height == 180)
  // Verify the middle stitched region has no corner artifacts (no pixel == 30 in outer cols at row 115).
  let data = (image.dataProvider?.data as Data?) ?? Data()
  let bytes = [UInt8](data)
  let bytesPerPixel = image.bitsPerPixel / 8
  let checkOffset = 115 * image.bytesPerRow
  #expect(bytes[checkOffset] != 30)
  #expect(bytes[checkOffset + (image.width - 1) * bytesPerPixel] != 30)
}

@MainActor @Test func scrollingAutoDetectsRightOverlayScrollerAndExcludesIt() async throws {
  func scrollerFrame(offset: Int, thumbRow: Int?) -> CGImage {
    let width = 80
    let height = 120
    var pixels = [UInt8](repeating: 0, count: width * height)
    for row in 0..<height {
      for col in 0..<width {
        if col >= width - 10 {
          if let thumbRow,
            row >= thumbRow && row < thumbRow + 24 && col >= width - 8 && col < width - 2
          {
            pixels[row * width + col] = 90
          } else {
            pixels[row * width + col] = 245
          }
        } else {
          let y = row + offset
          var value =
            UInt32(truncatingIfNeeded: y) &* 747_796_405 &+ UInt32(col * 19 + 2_891_336_453)
          value = ((value >> ((value >> 28) + 4)) ^ value) &* 277_803_737
          pixels[row * width + col] = UInt8(truncatingIfNeeded: (value >> 22) ^ value)
        }
      }
    }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .init(rawValue: 0),
      provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }
  let region = try CaptureRegion(
    displayID: 1, globalRect: CGRect(x: 0, y: 0, width: 80, height: 120),
    screenFrame: CGRect(x: 0, y: 0, width: 80, height: 120), scale: 1)
  // Frame 1 has no overlay scroller; frames 2 and 3 show the scroller thumb moving down.
  let frames = Frames([
    scrollerFrame(offset: 0, thumbRow: nil),
    scrollerFrame(offset: 30, thumbRow: 20),
    scrollerFrame(offset: 60, thumbRow: 40),
  ])
  var reportedRight = 0
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: region, finishSignal: .init(),
    onInsets: { _, _, right in reportedRight = right },
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  #expect(reportedRight >= 8 && reportedRight <= 10)
  guard case .partial(let image) = result else {
    Issue.record("expected stitched result with scroller cropped")
    return
  }
  #expect(image.width == 80 - reportedRight)
  #expect(image.height == 180)

  // Also verify small-advance smooth scrolling on a tall window where thumb
  // only shifts by 1px while content advances by 6px (2*advance < overlap/30).
  func tallFrame(offset: Int, thumbRow: Int) -> CGImage {
    let width = 80
    let height = 360
    var pixels = [UInt8](repeating: 35, count: width * height)
    for row in 0..<height {
      for col in 0..<(width - 10) {
        let y = row + offset
        var value =
          UInt32(truncatingIfNeeded: y) &* 747_796_405 &+ UInt32(col * 19 + 2_891_336_453)
        value = ((value >> ((value >> 28) + 4)) ^ value) &* 277_803_737
        pixels[row * width + col] = UInt8(truncatingIfNeeded: (value >> 22) ^ value)
      }
      if row >= thumbRow && row < thumbRow + 36 {
        for col in (width - 8)..<(width - 2) {
          pixels[row * width + col] = 142
        }
      }
    }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .init(rawValue: 0),
      provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }
  let tallDetected = ScreenshotSupport.scrollingRightScrollerColumns(
    previous: tallFrame(offset: 0, thumbRow: 40),
    current: tallFrame(offset: 6, thumbRow: 41),
    advance: 6, direction: .forward, topInset: 0, bottomInset: 0, scale: 1)
  #expect(tallDetected >= 8 && tallDetected <= 10)
}

@MainActor @Test func scrollingOverlapSeamReplacesBottomFadeArtifact() async throws {
  func fadedBottomFrame(offset: Int) -> CGImage {
    let base = uniqueFrame(offset: offset)
    let width = base.width
    let height = base.height
    var bytes = [UInt8]((base.dataProvider?.data as Data?) ?? Data())
    // Bottom 6 rows of each viewport have a translucent darkening fade.
    for row in (height - 6)..<height {
      for col in 0..<width {
        bytes[row * width + col] = UInt8(Int(bytes[row * width + col]) / 2)
      }
    }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .init(rawValue: 0),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }
  let frames = Frames([0, 40, 80].map(fadedBottomFrame))
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  guard case .partial(let image) = result else {
    Issue.record("expected stitched result")
    return
  }
  #expect(image.height == 200)
  // Compare rows 0..194 (everything above the final viewport's natural bottom 6px fade)
  // against the clean un-faded stitch.
  let cleanFrames = Frames([0, 40, 80].map { uniqueFrame(offset: $0) })
  let expectedResult = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await cleanFrames.next() })
  guard case .partial(let reference) = expectedResult else {
    Issue.record("expected clean reference")
    return
  }
  let actualCrop = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: 64, height: 194)))
  let expectedCrop = try #require(
    reference.cropping(to: CGRect(x: 0, y: 0, width: 64, height: 194)))
  func gray(_ img: CGImage) -> Data {
    var out = [UInt8](repeating: 0, count: img.width * img.height)
    let ctx = CGContext(
      data: &out, width: img.width, height: img.height, bitsPerComponent: 8,
      bytesPerRow: img.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return Data(out)
  }
  #expect(gray(actualCrop) == gray(expectedCrop))
}

@MainActor @Test func scrollingMergesMultiFrameFragmentChainAcrossGaps() async throws {
  // Jump past a gap, scroll across three frames [200, 240, 280] that chain
  // together, then return to [40, 80, 120] to bridge the entire fragment.
  let frames = Frames([0, 40, 200, 240, 280, 40, 80, 120].map(uniqueFrame))
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  guard case .partial(let image) = result else {
    Issue.record("expected stitched result after fragment chain merge")
    return
  }
  let referenceFrames = Frames([0, 40, 80, 120, 160, 200, 240, 280].map(uniqueFrame))
  let expectedResult = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await referenceFrames.next() })
  guard case .partial(let reference) = expectedResult else {
    Issue.record("expected baseline reference")
    return
  }
  #expect(image.height == 400)
  #expect(image.dataProvider?.data as Data? == reference.dataProvider?.data as Data?)
}

@MainActor @Test func scrollingContinuesWhenExcludedTranslucentHeaderVariesBetweenFrames()
  async throws
{
  func frameWithTint(offset: Int, headerTint: UInt8) -> CGImage {
    let width = 64
    let height = 120
    var pixels = [UInt8](repeating: 255, count: width * height)
    for row in 0..<height {
      for col in 0..<width {
        if row < 20 {
          pixels[row * width + col] = headerTint
        } else {
          let y = row + offset
          var value =
            UInt32(truncatingIfNeeded: y) &* 747_796_405 &+ UInt32(col * 19 + 2_891_336_453)
          value = ((value >> ((value >> 28) + 4)) ^ value) &* 277_803_737
          pixels[row * width + col] = UInt8(truncatingIfNeeded: (value >> 22) ^ value)
        }
      }
    }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .init(rawValue: 0),
      provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }
  let frames = Frames([
    frameWithTint(offset: 0, headerTint: 240),
    frameWithTint(offset: 35, headerTint: 240),
    frameWithTint(offset: 70, headerTint: 120),
    frameWithTint(offset: 105, headerTint: 200),
    frameWithTint(offset: 140, headerTint: 80),
  ])
  var sawUnmatched = false
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, unmatched in
      if unmatched { sawUnmatched = true }
    }, nextFrame: { await frames.next() })
  #expect(!sawUnmatched)
  guard case .partial(let image) = result else {
    Issue.record("expected full stitched image despite varying excluded translucent header")
    return
  }
  #expect(image.height == 260)
}
