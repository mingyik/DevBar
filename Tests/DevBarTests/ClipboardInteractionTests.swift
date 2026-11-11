import AppKit
import DevBarCore
import Testing

@testable import DevBar

@Test func clipboardCyclerWrapsAtBothEndsAndResets() {
  var cycler = ClipboardCycler()
  let newestBoundary = cycler.move(older: false, count: 10)
  #expect(!newestBoundary)
  #expect(cycler.currentIndex == 9)
  cycler.reset()
  for index in 1...9 {
    let boundary = cycler.move(older: true, count: 10)
    #expect(!boundary)
    #expect(cycler.currentIndex == index)
  }
  let oldestBoundary = cycler.move(older: true, count: 10)
  #expect(!oldestBoundary)
  #expect(cycler.currentIndex == 0)
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
  controller.focusedIndex = 9
  #expect(controller.handleKey(125, board: board))
  #expect(controller.focusedIndex == 0)
  #expect(controller.handleKey(126, board: board))
  #expect(controller.focusedIndex == 9)
  controller.focusedIndex = 5
  #expect(controller.handleKey(125, board: board))
  #expect(controller.focusedIndex == 6)
  #expect(board.string(forType: .string) == "item 3")
  #expect(controller.handleKey(126, board: board))
  #expect(controller.focusedIndex == 5)
  #expect(board.string(forType: .string) == "item 4")
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

@Test func fileURLsConvertToDecodedPathsInOrder() {
  let files = ["file:///tmp/first%20name.txt", "file:///tmp/%E4%B8%AD%E6%96%87.txt"].map {
    ClipboardPayload(type: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data($0.utf8))
  }
  #expect(ClipboardController.filePaths(payloads: files) == "/tmp/first name.txt\n/tmp/中文.txt")
  let bad = ClipboardPayload(
    type: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data("https://example.com".utf8))
  #expect(ClipboardController.filePaths(payloads: files + [bad]) == nil)
}

@MainActor @Test func clipboardDeletePreviewAddsRedWithoutChangingCardSize() throws {
  let ordinary = DragCardImage.make(
    title: "测试", subtitle: "2 字符", fileCount: 0, thumbnail: nil, swatch: nil,
    scheme: .light)
  let deleting = DragCardImage.make(
    title: "测试", subtitle: "2 字符", fileCount: 0, thumbnail: nil, swatch: nil,
    scheme: .light, deleteHover: true)
  #expect(ordinary.image.size == deleting.image.size)
  let data = try #require(deleting.image.tiffRepresentation)
  let bitmap = try #require(NSBitmapImageRep(data: data))
  var redPixels = 0
  for y in 0..<bitmap.pixelsHigh {
    for x in 0..<bitmap.pixelsWide {
      guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
      if c.alphaComponent > 0.1 && c.redComponent > c.greenComponent + 0.2
        && c.redComponent > c.blueComponent + 0.2
      {
        redPixels += 1
      }
    }
  }
  #expect(redPixels > 0)
}

@MainActor @Test func clipboardHoverPreviewTracksOnlyCurrentRow() {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let controller = ClipboardController(
    theme: ThemeManager(), directory: directory, startMonitoring: false)
  let first = UUID()
  let second = UUID()
  var observed: [UUID?] = []
  controller.onHoverPreview = { observed.append($0) }
  controller.setHovered(first, inside: true)
  controller.setHovered(second, inside: true)
  controller.setHovered(first, inside: false)
  #expect(controller.hoverID == second)
  #expect(observed.count == 2)
  controller.setHovered(second, inside: false)
  #expect(controller.hoverID == nil)
  #expect(observed.count == 3)
  #expect(observed.last! == nil)
}

@MainActor @Test func clipboardHoverPreviewFitsContentWithSquareMinimum() async throws {
  _ = NSApplication.shared
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let theme = ThemeManager()
  let controller = ClipboardController(theme: theme, directory: directory, startMonitoring: false)
  func capture(_ text: String) -> ClipboardCapture {
    ClipboardCapture(payloads: [
      ClipboardPayload(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
    ])!
  }
  await controller.record(capture("短内容"), source: nil)
  let short = try #require(controller.items.first)
  let shortView = ClipboardHoverPreview(
    item: short, payloads: try #require(controller.originals[short.id]), scheme: .light,
    theme: theme)
  #expect(shortView.preferredHeight(width: 300, maximum: 800) == 300)
  await controller.record(capture(String(repeating: "内容\n", count: 500)), source: nil)
  let long = try #require(controller.items.first)
  let longView = ClipboardHoverPreview(
    item: long, payloads: try #require(controller.originals[long.id]), scheme: .dark, theme: theme)
  #expect(longView.preferredHeight(width: 300, maximum: 800) == 800)
}
