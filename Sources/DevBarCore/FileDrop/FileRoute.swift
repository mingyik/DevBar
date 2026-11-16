import Foundation

public enum DocMode: String, Sendable { case markdown, mermaid }
public enum FileDropReason: Error, Equatable, Sendable {
  case unsupportedType, notRegularFile, tooLarge, notUTF8, noFile, unreadable
}
public enum FileRoute: Equatable, Sendable {
  /// Markdown and Mermaid files supported by the document editor. JSON stays routed to Tools.
  public static let documentExtensions = ["md", "markdown", "mmd", "mermaid"]

  case tools
  case doc(DocMode?)
  case rejected(FileDropReason)
  public static func route(fileName: String, sniff: String?) -> FileRoute {
    switch (fileName as NSString).pathExtension.lowercased() {
    case "json", "jsonc", "geojson": return .tools
    case "md", "markdown": return .doc(.markdown)
    case "mmd", "mermaid": return .doc(.mermaid)
    case "txt", "":
      let prefix = sniff?.trimmingCharacters(in: .whitespacesAndNewlines).first
      return prefix == "{" || prefix == "[" ? .tools : .rejected(.unsupportedType)
    default: return .rejected(.unsupportedType)
    }
  }
}
public struct DroppedFile: Equatable, Sendable {
  public let text: String
  public let fileName: String
  public let route: FileRoute
  public let multiple: Bool
}
public enum FileDropReader {
  public static let byteLimit = 10 * 1024 * 1024
  public static func sniff(_ url: URL) -> String? {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= byteLimit,
      let handle = try? FileHandle(forReadingFrom: url)
    else { return nil }
    defer { try? handle.close() }
    guard var data = try? handle.read(upToCount: 4096) else { return nil }
    if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
    // Only the leading marker affects routing. Full strict decoding happens on drop.
    return String(decoding: data, as: UTF8.self)
  }
  public static func read(_ urls: [URL]) -> Result<DroppedFile, FileDropReason> {
    guard let file = urls.first, file.isFileURL else { return .failure(.noFile) }
    do {
      let values = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isPackageKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isPackage != true else {
        return .failure(.notRegularFile)
      }
      guard let size = values.fileSize, size <= byteLimit else { return .failure(.tooLarge) }
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      var data = try handle.read(upToCount: byteLimit + 1) ?? Data()
      guard data.count <= byteLimit else { return .failure(.tooLarge) }
      let preserveBytes = ["mmd", "mermaid"].contains(file.pathExtension.lowercased())
      if !preserveBytes && data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
      guard let decoded = String(data: data, encoding: .utf8) else { return .failure(.notUTF8) }
      let text = preserveBytes ? String(decoding: data, as: UTF8.self) : decoded
      let sniff = String(text.prefix(4096))
      let route = FileRoute.route(fileName: file.lastPathComponent, sniff: sniff)
      if case .rejected(let reason) = route { return .failure(reason) }
      return .success(
        DroppedFile(
          text: text, fileName: file.lastPathComponent, route: route, multiple: urls.count > 1))
    } catch { return .failure(.unreadable) }
  }
}
