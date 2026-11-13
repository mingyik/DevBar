import CoreGraphics
import Foundation

public enum DragCard: Sendable {
  public static let height: CGFloat = 56
  public static let minWidth: CGFloat = 160
  public static let maxWidth: CGFloat = 260

  /// Bound work before AppKit text layout; clipboard bytes are never truncated.
  public static func firstLine(_ text: String) -> String {
    var result = ""
    var count = 0
    var started = false
    for character in text {
      if !started {
        if character.isWhitespace { continue }
        started = true
      }
      if character == "\n" || character == "\r" || character == "\r\n" { break }
      if count == 160 { return result + "…" }
      result.append(character)
      count += 1
    }
    return result.trimmingCharacters(in: .whitespaces)
  }

  /// Keep a small multiline sample for the floating clipboard card.
  public static func previewText(_ text: String, maxCharacters: Int = 320) -> String {
    let sample = String(text.prefix(maxCharacters + 1))
    guard sample.count > maxCharacters else { return sample }
    return String(sample.prefix(maxCharacters)) + "…"
  }

  public static func width(
    title: String, hasThumb: Bool, trailingAccessoryWidth: CGFloat = 0
  ) -> CGFloat {
    let text = CGFloat(title.count) * 7.2
    let thumb: CGFloat = hasThumb ? 48 : 0
    return min(
      maxWidth, max(minWidth, (24 + thumb + text + trailingAccessoryWidth).rounded(.up)))
  }

  public static func textSubtitle(characters: Int) -> String { "\(characters) 字符" }

  /// The title already shows the names; the subtitle only adds the count.
  public static func fileSubtitle(names: [String]) -> String {
    names.count > 1 ? "\(names.count) 个文件" : ""
  }
}
