import AppKit
import Testing

@testable import DevBar

@MainActor @Test func screenshotPasteboardContainsImageAndFileURL() throws {
  let png = try #require(
    NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?.tiffRepresentation)
  let file = URL(fileURLWithPath: "/tmp/devbar-test.png")
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  #expect(PasteboardBridge.writePNG(png, file: file, board: board))
  let item = try #require(board.pasteboardItems?.first)
  #expect(item.data(forType: .png) == png)
  #expect(item.string(forType: .fileURL) == file.absoluteString)
  let capture = try #require(ClipboardCapture(screenshotPNG: png, file: file))
  #expect(capture.kind == .image)
  let restored = try #require(ClipboardController.pasteboardItems(payloads: capture.payloads).first)
  #expect(restored.data(forType: .png) == png)
  #expect(restored.string(forType: .fileURL) == file.absoluteString)
}
