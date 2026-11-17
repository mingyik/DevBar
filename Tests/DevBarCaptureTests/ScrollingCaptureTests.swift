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
  // The jump frames are unverified and must not be appended. Returning to the
  // confirmed frame and scrolling forward continues from that position.
  let frames = Frames([0, 40, 200, 240, 40, 80, 120].map(uniqueFrame))
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await frames.next() })
  guard case .partial(let image) = result else {
    Issue.record("expected retained result when the source ends")
    return
  }
  let referenceFrames = Frames([0, 40, 80, 120].map(uniqueFrame))
  let referenceResult = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: .init(),
    onProgress: { _, _ in }, nextFrame: { await referenceFrames.next() })
  guard case .partial(let reference) = referenceResult else {
    Issue.record("expected baseline image")
    return
  }
  #expect(image.height == 240)
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
