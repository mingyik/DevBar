import AppKit
import DevBarCore
import Testing

@testable import DevBar

@MainActor @Test func terminalImagePasteKeepsImageAndProvidesReadablePath() throws {
  let tiff = try #require(
    NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?.tiffRepresentation)
  let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
  let payloads = [
    ClipboardPayload(type: NSPasteboard.PasteboardType.png.rawValue, data: png),
    ClipboardPayload(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      data: Data("file:///missing/screenshot.png".utf8)),
  ]
  let item = try #require(ClipboardDragFile(payloads: payloads)?.imagePasteboardItem())
  let path = try #require(item.string(forType: .string))
  defer { try? FileManager.default.removeItem(atPath: path) }
  #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == png)
  #expect(item.data(forType: .png) == png)
  #expect(item.string(forType: .fileURL) == URL(fileURLWithPath: path).absoluteString)
  #expect(!path.contains("\n"))
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  #expect(board.writeObjects([item]))
  let input = NSTextView()
  input.isRichText = false
  #expect(input.readSelection(from: board, type: .string))
  #expect(input.string == path)
}

@MainActor @Test func imageDragOffersReadableFileURLAlongsideOriginalImage() throws {
  let tiff = try #require(
    NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?.tiffRepresentation)
  let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
  for extra in [
    [],
    [
      ClipboardPayload(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        data: Data("file:///missing/old-screenshot.png".utf8))
    ],
  ] {
    let writer = try #require(
      ClipboardDragFile(
        payloads: [ClipboardPayload(type: NSPasteboard.PasteboardType.png.rawValue, data: png)]
          + extra))
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    #expect(board.writeObjects([writer]))
    let urls = try #require(
      board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        as? [URL])
    let file = try #require(urls.first)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(file.isFileURL)
    #expect(file.pathExtension == "png")
    #expect(try Data(contentsOf: file) == png)
    #expect(board.data(forType: .png) == png)
    #expect(board.string(forType: .string) == file.path(percentEncoded: false))
    let editor = NSTextView()
    editor.isRichText = false
    #expect(editor.readSelection(from: board, type: .string))
    #expect(editor.string == file.path(percentEncoded: false))
    #expect(board.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil))
  }
}

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
  let path = try #require(writer.pasteboardPropertyList(forType: .string) as? String)
  defer { try? FileManager.default.removeItem(atPath: path) }
  #expect(FileManager.default.fileExists(atPath: path))
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
