import Foundation

/// Short Latin format tag shown on clipboard rows and cards; Chinese kind names read poorly at 11pt.
public enum ClipTag {
  public static func label(kind: ClipItem.Kind, types: [String], fileNames: [String], text: String)
    -> String
  {
    switch kind {
    case .text: return isLink(text) ? "URL" : "TXT"
    case .image: return types.lazy.compactMap { imageTags[$0] }.first ?? "IMG"
    case .files: return fileLabel(fileNames)
    }
  }

  private static let imageTags = [
    "public.png": "PNG", "public.jpeg": "JPG", "public.tiff": "TIFF", "public.heic": "HEIC",
    "com.compuserve.gif": "GIF", "public.svg-image": "SVG", "org.webmproject.webp": "WEBP",
  ]

  private static func isLink(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count <= 2048, !trimmed.contains(where: \.isWhitespace) else { return false }
    let lower = trimmed.lowercased()
    return lower.hasPrefix("http://") || lower.hasPrefix("https://")
  }

  private static func fileLabel(_ names: [String]) -> String {
    let extensions = Set(names.map { extensionTag($0) })
    let base = extensions.count == 1 ? extensions.first! : "FILE"
    return names.count > 1 ? "\(base) ×\(names.count)" : base
  }

  private static func extensionTag(_ name: String) -> String {
    let ext = (name as NSString).pathExtension.uppercased()
    return ext.isEmpty || ext.count > 6 ? "FILE" : ext
  }
}
