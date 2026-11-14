import AppKit
import DevBarCore
import UniformTypeIdentifiers

/// Images offer raw bytes, a readable file URL and a path for text-only targets.
/// Text keeps its original representation and its promised file for Finder.
@MainActor final class ClipboardDragFile: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
  private let payloads: [ClipboardPayload]
  private let fileData: Data
  private let fileName: String
  private let imageURL: URL?
  private static var sweptTemporaryImages = false

  /// A terminal normally pastes text, while an image-aware CLI can still read the PNG/TIFF.
  /// Reuse the readable export file from dragging; never rely on an old screenshot path.
  func imagePasteboardItem() -> NSPasteboardItem? {
    guard let imageURL else { return nil }
    let item = NSPasteboardItem()
    for payload in payloads { item.setData(payload.data, forType: .init(payload.type)) }
    guard item.setString(imageURL.absoluteString, forType: .fileURL),
      item.setString(imageURL.path(percentEncoded: false), forType: .string)
    else { return nil }
    return item
  }

  init?(payloads: [ClipboardPayload]) {
    let image =
      payloads.first { $0.type == NSPasteboard.PasteboardType.png.rawValue }
      ?? payloads.first { UTType($0.type)?.conforms(to: .image) == true }
    guard
      image != nil
        || !payloads.contains(where: { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue })
    else { return nil }
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
    if image != nil {
      guard let url = Self.materializeImage(content.data, name: fileName) else { return nil }
      imageURL = url
    } else {
      imageURL = nil
    }
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
    if imageURL != nil {
      for type: NSPasteboard.PasteboardType in [.fileURL, .string] where !types.contains(type) {
        types.append(type)
      }
    }
    return types
  }

  override func pasteboardPropertyList(
    forType type: NSPasteboard.PasteboardType
  ) -> Any? {
    if let imageURL {
      if type == .fileURL { return imageURL.absoluteString }
      if type == .string { return imageURL.path(percentEncoded: false) }
    }
    if let payload = payloads.first(where: { $0.type == type.rawValue }) { return payload.data }
    return super.pasteboardPropertyList(forType: type)
  }

  override func writingOptions(
    forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard
  ) -> NSPasteboard.WritingOptions {
    if imageURL != nil && (type == .fileURL || type == .string) { return [] }
    if payloads.contains(where: { $0.type == type.rawValue }) { return [] }
    return super.writingOptions(forType: type, pasteboard: pasteboard)
  }

  private static func materializeImage(_ data: Data, name: String) -> URL? {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appending(
      path: "DevBar-ImageDrags", directoryHint: .isDirectory)
    do {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      // Receivers may open the URL after drag end or retain the path. Do not delete on drop.
      // Sweep only this app's generated files from earlier sessions, after at least 24 hours.
      if !sweptTemporaryImages {
        sweptTemporaryImages = true
        let files = try manager.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        let cutoff = Date.now.addingTimeInterval(-86400)
        for file in files where file.lastPathComponent.hasPrefix("DevBar-") {
          if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate,
            date < cutoff
          {
            try? manager.removeItem(at: file)
          }
        }
      }
      let file = directory.appending(path: name)
      try data.write(to: file, options: .atomic)
      return file
    } catch { return nil }
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
