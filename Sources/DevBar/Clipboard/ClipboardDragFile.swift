import AppKit
import DevBarCore
import UniformTypeIdentifiers

/// One drag item offers original content to editors and a promised file to Finder.
@MainActor final class ClipboardDragFile: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
  private let payloads: [ClipboardPayload]
  private let fileData: Data
  private let fileName: String

  init?(payloads: [ClipboardPayload]) {
    guard !payloads.contains(where: { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue })
    else { return nil }
    let image = payloads.first { UTType($0.type)?.conforms(to: .image) == true }
    guard
      let content = image
        ?? payloads.first(where: {
          $0.type == NSPasteboard.PasteboardType.string.rawValue
        })
    else { return nil }
    let type = image.flatMap { UTType($0.type) } ?? .plainText
    let suffix = image == nil ? "txt" : type.preferredFilenameExtension
    guard let suffix else { return nil }
    self.payloads = payloads
    fileData = content.data
    fileName = "DevBar-\(UUID().uuidString).\(suffix)"
    super.init()
    fileType = type.identifier
    delegate = self
  }

  override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
    var types = super.writableTypes(for: pasteboard)
    for payload in payloads {
      let type = NSPasteboard.PasteboardType(payload.type)
      if !types.contains(type) { types.append(type) }
    }
    return types
  }

  override func pasteboardPropertyList(
    forType type: NSPasteboard.PasteboardType
  ) -> Any? {
    if let payload = payloads.first(where: { $0.type == type.rawValue }) { return payload.data }
    return super.pasteboardPropertyList(forType: type)
  }

  override func writingOptions(
    forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard
  ) -> NSPasteboard.WritingOptions {
    if payloads.contains(where: { $0.type == type.rawValue }) { return [] }
    return super.writingOptions(forType: type, pasteboard: pasteboard)
  }

  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
  )
    -> String
  {
    fileName
  }

  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
    completionHandler: @escaping (Error?) -> Void
  ) {
    do {
      try fileData.write(to: url, options: .withoutOverwriting)
      completionHandler(nil)
    } catch {
      completionHandler(error)
    }
  }
}
