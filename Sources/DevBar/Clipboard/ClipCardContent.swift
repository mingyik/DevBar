import AppKit
import DevBarCore
import UniformTypeIdentifiers

/// What a clipboard card shows, shared by the ⌘ cycling card and the list drag card.
/// Built from in-memory payloads only: no file system reads.
struct ClipCardContent {
  var title = ""
  var subtitle = ""
  var icon: NSImage?
  var stack = 0
  var swatch: NSColor?
  var tag = ""
  var multiline = false
  var note: String?

  @MainActor static func make(
    item: ClipItem, payloads: [ClipboardPayload], thumbnail: NSImage?
  ) -> ClipCardContent {
    var content = ClipCardContent()
    switch item.kind {
    case .text:
      let source =
        payloads.first { $0.type == NSPasteboard.PasteboardType.string.rawValue }
        .flatMap { String(data: $0.data, encoding: .utf8) } ?? item.preview
      content.multiline = true
      content.title = DragCard.previewText(source)
      content.note = DragCard.textSubtitle(characters: source.count)
      content.tag = ClipTag.label(kind: .text, types: [], fileNames: [], text: source)
      content.swatch = ClipboardColor.parse(item.preview).map {
        NSColor(  // devbar:allow-color
          srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
      }
    case .image:
      content.icon = thumbnail
      content.title = item.preview
      let bytes = payloads.map(\.data.count).max() ?? 0
      content.subtitle = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
      content.tag = ClipTag.label(
        kind: .image, types: payloads.map(\.type), fileNames: [], text: "")
    case .files:
      let urls = payloads.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
        .compactMap { String(data: $0.data, encoding: .utf8) }.compactMap(URL.init(string:))
      let names = urls.map(\.lastPathComponent)
      content.tag = ClipTag.label(
        kind: .files, types: [],
        fileNames: urls.map {
          $0.hasDirectoryPath ? $0.lastPathComponent + "/" : $0.lastPathComponent
        },
        text: "")
      content.stack = urls.count
      content.icon = urls.first.map(icon(for:))
      if urls.count == 1, let url = urls.first {
        content.title = names[0]
        content.subtitle =
          (url.deletingLastPathComponent().path as NSString)
          .abbreviatingWithTildeInPath
      } else {
        let images = urls.allSatisfy {
          UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true
        }
        content.title = images ? "\(urls.count) 张图片" : "\(urls.count) 个文件"
        content.subtitle = names.prefix(3).joined(separator: "、")
      }
    }
    return content
  }

  /// Type icon by extension: avoids touching the file, which may be gone.
  @MainActor private static func icon(for url: URL) -> NSImage {
    let type =
      url.hasDirectoryPath
      ? UTType.folder : UTType(filenameExtension: url.pathExtension) ?? .data
    return NSWorkspace.shared.icon(for: type)
  }
}
