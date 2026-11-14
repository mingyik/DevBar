import CoreGraphics
import Foundation
import Testing

@testable import DevBarCapture

private actor Frames {
  let images: [CGImage]
  var index = 0
  init(_ images: [CGImage]) { self.images = images }
  func next() -> CGImage {
    let image = images[min(index, images.count - 1)]
    index += 1
    return image
  }
}

private func frame(offset: Int, footer: Int = 0, salt: Int = 0) -> CGImage {
  let width = 64
  let height = 120
  var pixels = [UInt8](repeating: 0, count: width * height)
  for row in 0..<height {
    for col in 0..<width {
      let y = row >= height - footer ? row + 1000 : row + offset
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
        region: try testRegion(), finishSignal: .init(), frameLimit: offsets.count + 2,
        onProgress: { _, _ in }, nextFrame: { await frames.next() })
      guard case .limited(let image) = result else {
        Issue.record("expected complete retained pixels at frame limit")
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

@Test func scrollingMatchesAndKeepsFixedFooter() async throws {
  let frames = Frames([frame(offset: 0, footer: 18), frame(offset: 42, footer: 18)])
  let finish = ScreenshotScrollingCapture.FinishSignal()
  let result = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: finish, frameLimit: 12,
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
    region: try testRegion(), finishSignal: finish, frameLimit: 12,
    onProgress: { _, unmatched in if unmatched { finish.request() } },
    nextFrame: { await frames.next() })
  guard case .partial(let image) = result else {
    Issue.record("expected partial")
    return
  }
  #expect(image.height == 120)
}

@Test func scrollingFrameLimitAndCancellation() async throws {
  let frames = Frames([frame(offset: 0)])
  let finish = ScreenshotScrollingCapture.FinishSignal()
  let limited = await ScreenshotScrollingCapture.captureFrames(
    region: try testRegion(), finishSignal: finish, frameLimit: 2,
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
