import Foundation

struct ClipboardColor: Equatable {
  let red: Double
  let green: Double
  let blue: Double
  let alpha: Double

  static func parse(_ text: String) -> Self? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("#") {  // devbar:allow-color
      let hex = String(text.dropFirst())
      guard [3, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
      let expanded = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
      guard let value = UInt64(expanded, radix: 16) else { return nil }
      let rgba = expanded.count == 8 ? value : value * 256 + 255
      return Self(
        red: Double((rgba >> 24) & 255) / 255,
        green: Double((rgba >> 16) & 255) / 255, blue: Double((rgba >> 8) & 255) / 255,
        alpha: Double(rgba & 255) / 255)
    }
    let components = #"^rgba?\(\s*([0-9]+)\s*,\s*([0-9]+)\s*,"#  // devbar:allow-color
    let ending = #"\s*([0-9]+)\s*(?:,\s*(0(?:\.\d+)?|1(?:\.0+)?|\.\d+)\s*)?\)$"#
    let pattern = components + ending
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    let values = (1...4).compactMap { index -> Double? in
      guard let range = Range(match.range(at: index), in: text) else { return nil }
      return Double(text[range])
    }
    guard values.count == (text.hasPrefix("rgba") ? 4 : 3),
      values.prefix(3).allSatisfy({ $0 <= 255 })
    else { return nil }
    return Self(
      red: values[0] / 255, green: values[1] / 255, blue: values[2] / 255,
      alpha: values.count == 4 ? values[3] : 1)
  }
}
