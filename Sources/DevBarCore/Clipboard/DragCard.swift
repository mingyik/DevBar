import CoreGraphics
import Foundation

public enum DragCard: Sendable {
  public static let height: CGFloat = 56
  public static let minWidth: CGFloat = 160
  public static let maxWidth: CGFloat = 260

  public static func firstLine(_ text: String) -> String {
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { return String(trimmed) }
    }
    return ""
  }

  public static func width(title: String, hasThumb: Bool) -> CGFloat {
    let text = CGFloat(title.count) * 7.2
    let thumb: CGFloat = hasThumb ? 48 : 0
    return min(maxWidth, max(minWidth, (24 + thumb + text).rounded(.up)))
  }

  public static func textSubtitle(characters: Int) -> String { "\(characters) 字符" }

  public static func fileSubtitle(names: [String]) -> String {
    guard let first = names.first else { return "" }
    return names.count == 1 ? first : "\(first) 等 \(names.count) 个文件"
  }
}
