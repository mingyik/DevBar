import Foundation

/// Text fidelity helpers for Markdown source files. BOM and CRLF survive a
/// load/save round trip; edited text keeps the file's original newline style.
public enum DocumentFile {
  public struct Decoded: Equatable, Sendable {
    public let text: String
    public let hadBOM: Bool
    public let newline: String
    public init(text: String, hadBOM: Bool, newline: String) {
      self.text = text
      self.hadBOM = hadBOM
      self.newline = newline
    }
  }

  public static let byteLimit = FileDropReader.byteLimit

  /// Compare editor snapshots without rewriting the source used for saving.
  public static func editorTextMatches(_ left: String, _ right: String) -> Bool {
    func normalized(_ text: String) -> String {
      text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    }
    return normalized(left) == normalized(right)
  }

  public enum ReplacementReadiness: Sendable, Equatable {
    case unavailable, clean, modified
  }

  public static func replacementReadiness(
    requiresEditorSnapshot: Bool, hasEditorSnapshot: Bool, dirty: Bool?
  ) -> ReplacementReadiness {
    guard !requiresEditorSnapshot || hasEditorSnapshot, let dirty else { return .unavailable }
    return dirty ? .modified : .clean
  }

  public static func decode(_ data: Data) -> Decoded? {
    var bytes = data
    let hadBOM = bytes.starts(with: [0xEF, 0xBB, 0xBF])
    if hadBOM { bytes.removeFirst(3) }
    guard let text = String(data: bytes, encoding: .utf8) else { return nil }
    return Decoded(text: text, hadBOM: hadBOM, newline: newline(of: text))
  }

  public static func encode(_ text: String, hadBOM: Bool, newline: String) -> Data {
    var body = text
    if newline == "\r\n" {
      body = body.replacingOccurrences(
        of: "(?<!\\r)\\n", with: "\r\n", options: .regularExpression)
    }
    var data = Data()
    if hadBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
    data.append(contentsOf: body.utf8)
    return data
  }

  /// CRLF only when the file consistently uses CRLF; mixed files keep their bytes.
  public static func newline(of text: String) -> String {
    let crlf = text.components(separatedBy: "\r\n").count - 1
    guard crlf > 0 else { return "\n" }
    let lf = text.components(separatedBy: "\n").count - 1
    return lf == crlf ? "\r\n" : "\n"
  }

  public static func signature(of url: URL) -> FileSignature? {
    guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = values[.size] as? NSNumber,
      let modified = values[.modificationDate] as? Date
    else { return nil }
    return FileSignature(
      size: size.intValue, modified: modified,
      identifier: (values[.systemFileNumber] as? NSNumber)?.stringValue)
  }
}

public struct FileSignature: Equatable, Sendable {
  public let size: Int
  public let modified: Date
  public let identifier: String?
  public init(size: Int, modified: Date, identifier: String?) {
    self.size = size
    self.modified = modified
    self.identifier = identifier
  }

  /// Identifier changes when a file is replaced or moved; timestamps can race
  /// with filesystem granularity, so both must agree.
  public func matches(_ other: FileSignature?) -> Bool {
    guard let other else { return false }
    return size == other.size && identifier == other.identifier
      && abs(modified.timeIntervalSince(other.modified)) < 0.001
  }
}

public enum RecentDocuments {
  public static let limit = 3
  public static func adding(_ url: URL, to list: [URL]) -> [URL] {
    let target = url.standardizedFileURL
    var result = [target]
    result.append(contentsOf: list.filter { $0.standardizedFileURL != target })
    return Array(result.prefix(limit))
  }
}
