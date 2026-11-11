import AppKit
import DevBarCore
import Testing

@testable import DevBar

@Test func clipboardCyclerClampsAtBothEndsAndResets() {
  var cycler = ClipboardCycler()
  let newestBoundary = cycler.move(older: false, count: 10)
  #expect(newestBoundary)
  for index in 1...9 {
    let boundary = cycler.move(older: true, count: 10)
    #expect(!boundary)
    #expect(cycler.currentIndex == index)
  }
  let oldestBoundary = cycler.move(older: true, count: 10)
  #expect(oldestBoundary)
  #expect(cycler.currentIndex == 9)
  cycler.reset()
  #expect(cycler.currentIndex == 0)
  let emptyBoundary = cycler.move(older: true, count: 0)
  #expect(emptyBoundary)
}

@Test func clipboardColorRequiresEntireValidValue() {
  #expect(ClipboardColor.parse("#abc")?.red == Double(170) / 255)  // devbar:allow-color
  #expect(ClipboardColor.parse("#11223380")?.alpha == Double(128) / 255)  // devbar:allow-color
  #expect(ClipboardColor.parse("rgba(1, 2, 3, .5)")?.alpha == 0.5)  // devbar:allow-color
  let invalid = [
    "text #abc", "#abcd",  // devbar:allow-color
    "rgb(256, 2, 3)", "rgba(1,2,3,2)", "rgb(1,2,3,.5)",  // devbar:allow-color
  ]
  for value in invalid {
    #expect(ClipboardColor.parse(value) == nil)
  }
}

@MainActor @Test func clipboardWritebackPreservesEveryRepresentationAndFileURL() {
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  let data = [
    ClipboardPayload(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("text".utf8)),
    ClipboardPayload(
      type: NSPasteboard.PasteboardType.rtf.rawValue, data: Data("{\\rtf1 original}".utf8)),
    ClipboardPayload(
      type: NSPasteboard.PasteboardType.html.rawValue, data: Data("<b>text</b>".utf8)),
  ]
  #expect(board.writeObjects(ClipboardController.pasteboardItems(payloads: data)))
  for representation in data {
    #expect(board.data(forType: .init(representation.type)) == representation.data)
  }
  let files = ["file:///tmp/first.txt", "file:///tmp/second.txt"].map {
    ClipboardPayload(type: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data($0.utf8))
  }
  board.clearContents()
  #expect(board.writeObjects(ClipboardController.pasteboardItems(payloads: files)))
  #expect(board.pasteboardItems?.count == 2)
  for (index, file) in files.enumerated() {
    #expect(board.pasteboardItems?[index].data(forType: .fileURL) == file.data)
  }
  let original = Data(repeating: 42, count: 4096)
  board.clearContents()
  #expect(
    board.writeObjects(
      ClipboardController.pasteboardItems(payloads: [
        ClipboardPayload(type: NSPasteboard.PasteboardType.png.rawValue, data: original)
      ])))
  #expect(board.data(forType: .png) == original)
}

@MainActor @Test func clipboardSelectionNeverReordersAndNewCaptureResetsCursor() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let controller = ClipboardController(
    theme: ThemeManager(), directory: root, startMonitoring: false)
  for index in 0..<10 {
    let payloads = [
      ClipboardPayload(
        type: NSPasteboard.PasteboardType.string.rawValue,
        data: Data("item \(index)".utf8))
    ]
    await controller.record(ClipboardCapture(payloads: payloads)!, source: nil)
  }
  let order = controller.items.map(\.id)
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  controller.select(5, board: board)
  #expect(controller.currentIndex == 5)
  #expect(controller.items.map(\.id) == order)
  #expect(controller.handleKey(125))
  #expect(controller.focusedIndex == 6)
  #expect(controller.handleKey(126))
  #expect(controller.focusedIndex == 5)
  #expect(!controller.handleKey(0))
  let payloads = [
    ClipboardPayload(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("new".utf8))
  ]
  await controller.record(ClipboardCapture(payloads: payloads)!, source: nil)
  #expect(controller.currentIndex == 0)
  #expect(controller.items.count == 10)
}
