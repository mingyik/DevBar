import AppKit
import DevBarCore
import Testing

@testable import DevBar

@MainActor @Test func textDragOffersOriginalTextAndCreatesExactUTF8File() throws {
  let text = "中文\r\n  keep spacing\n"
  let data = Data(text.utf8)
  let writer = try #require(
    ClipboardDragFile(payloads: [
      ClipboardPayload(type: NSPasteboard.PasteboardType.string.rawValue, data: data)
    ]))
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  #expect(board.writeObjects([writer]))
  #expect(board.string(forType: .string) == text)
  let editor = NSTextView()
  editor.string = "prefix:"
  editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
  #expect(editor.readSelection(from: board))
  #expect(editor.string == "prefix:" + text)
  #expect(board.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil))
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let name = writer.filePromiseProvider(writer, fileNameForType: writer.fileType)
  #expect(name.hasSuffix(".txt"))
  let destination = directory.appending(path: name)
  var failure: Error?
  writer.filePromiseProvider(writer, writePromiseTo: destination) { failure = $0 }
  #expect(failure == nil)
  #expect(try Data(contentsOf: destination) == data)
  let existing = Data("existing file".utf8)
  try existing.write(to: destination)
  writer.filePromiseProvider(writer, writePromiseTo: destination) { failure = $0 }
  #expect(failure != nil)
  #expect(try Data(contentsOf: destination) == existing)
}

@MainActor @Test func imageDragKeepsOriginalImageBytesAndExtension() throws {
  let data = try #require(
    NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?.tiffRepresentation)
  let writer = try #require(
    ClipboardDragFile(payloads: [
      ClipboardPayload(type: NSPasteboard.PasteboardType.tiff.rawValue, data: data),
      ClipboardPayload(
        type: NSPasteboard.PasteboardType.string.rawValue, data: Data("caption".utf8)),
    ]))
  #expect(writer.pasteboardPropertyList(forType: .tiff) as? Data == data)
  #expect(writer.pasteboardPropertyList(forType: .string) as? Data == Data("caption".utf8))
  let name = writer.filePromiseProvider(writer, fileNameForType: writer.fileType)
  #expect(name.hasSuffix(".tiff") || name.hasSuffix(".tif"))
  let destination = FileManager.default.temporaryDirectory.appending(path: name)
  defer { try? FileManager.default.removeItem(at: destination) }
  var failure: Error?
  writer.filePromiseProvider(writer, writePromiseTo: destination) { failure = $0 }
  #expect(failure == nil)
  #expect(try Data(contentsOf: destination) == data)
}

@MainActor @Test func existingFileDragsDoNotBecomeNewTextFiles() {
  let writer = ClipboardDragFile(payloads: [
    ClipboardPayload(
      type: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data("file:///tmp/a".utf8)),
    ClipboardPayload(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("/tmp/a".utf8)),
  ])
  #expect(writer == nil)
}
