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

@MainActor @Test func dragCardImageStaysInsideWidthLimits() {
  let narrow = DragCardImage.make(
    title: "a", subtitle: "1 字符", fileCount: 1, thumbnail: nil, swatch: nil, scheme: .light)
  let wide = DragCardImage.make(
    title: String(repeating: "字", count: 80), subtitle: "x", fileCount: 3, thumbnail: nil,
    swatch: nil, scheme: .dark)
  #expect(narrow.image.size.height == DragCard.height + 20)
  #expect(narrow.image.size.width == DragCard.minWidth + 20)
  #expect(wide.image.size.width == DragCard.maxWidth + 20)
  #expect(wide.image.size.height == DragCard.height + 20)
}

@MainActor @Test func clipboardSelectionNeverReordersAndNewCaptureResetsCursor() async throws {
  _ = NSApplication.shared
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

@MainActor @Test(arguments: ["public.jpeg", "public.heic", "public.png", "public.tiff"])
func clipboardReadsAndClassifiesEachOriginalImageType(type: String) {
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  let original = Data([1, 2, 3, 4])
  board.setData(original, forType: .init(type))
  let reader = SystemPasteboardReader(name: board.name)
  let payloads = reader.read()
  #expect(payloads == [ClipboardPayload(type: type, data: original)])
  #expect(ClipboardCapture(payloads: payloads)?.kind == .image)
}

@MainActor @Test func clipboardPreservesMixedImageRepresentations() {
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  let payloads = ["public.png", "public.tiff", "public.jpeg", "public.heic"].enumerated().map {
    ClipboardPayload(type: $0.element, data: Data(repeating: UInt8($0.offset), count: 64))
  }
  #expect(board.writeObjects(ClipboardController.pasteboardItems(payloads: payloads)))
  #expect(SystemPasteboardReader(name: board.name).read() == payloads)
}

@MainActor @Test func clipboardOversizedFirstImageLeavesVisibleFeedbackAndNoHistory() async throws {
  _ = NSApplication.shared
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let controller = ClipboardController(
    theme: ThemeManager(), directory: root, startMonitoring: false)
  let payloads = [
    ClipboardPayload(
      type: "public.jpeg", data: Data(repeating: 1, count: ClipboardStore.imageByteLimit + 1))
  ]
  await controller.record(ClipboardCapture(payloads: payloads)!, source: nil)
  #expect(controller.items.isEmpty)
  #expect(controller.message == Strings.imageTooLarge)
}

@MainActor @Test func clipboardDetailUsesOriginalAndReturnsToListAfterRemoval() async throws {
  _ = NSApplication.shared
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let controller = ClipboardController(
    theme: ThemeManager(), directory: root, startMonitoring: false)
  let text = String(repeating: "原文\n", count: 300)
  let payload = ClipboardPayload(
    type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
  await controller.record(ClipboardCapture(payloads: [payload])!, source: nil)
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  controller.showDetail(0, board: board)
  let id = try #require(controller.detailID)
  #expect(controller.originals[id]?.first?.data == Data(text.utf8))
  #expect(board.string(forType: .string) == text)
  #expect(!controller.handleKey(125))
  controller.detailID = nil
  #expect(controller.handleKey(125))
  controller.showDetail(0, board: board)
  await controller.remove(id)
  #expect(controller.detailID == nil)
}
