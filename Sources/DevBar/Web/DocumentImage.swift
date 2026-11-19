import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DocumentImage {
  private static let byteLimit = 8 * 1024 * 1024

  static func load(_ address: String, relativeTo document: URL?) async -> String? {
    let task = Task.detached(priority: .utility) { () throws -> String? in
      guard let components = URLComponents(string: address), !address.isEmpty else { return nil }
      let data: Data
      if let scheme = components.scheme?.lowercased() {
        guard ["http", "https"].contains(scheme), let url = components.url,
          url.host != nil, url.user == nil, url.password == nil
        else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (bytes, response) = try? await session.bytes(from: url),
          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          http.expectedContentLength <= Int64(byteLimit)
        else { return nil }
        var buffer = Data()
        for try await byte in bytes {
          guard buffer.count < byteLimit else { return nil }
          buffer.append(byte)
        }
        data = buffer
      } else {
        guard let document, components.host == nil, !components.path.hasPrefix("/"),
          !components.path.isEmpty, !components.path.contains("\0")
        else { return nil }
        let base = document.deletingLastPathComponent().resolvingSymlinksInPath()
          .standardizedFileURL
        let file = base.appendingPathComponent(components.path).resolvingSymlinksInPath()
          .standardizedFileURL
        guard file.path.hasPrefix(base.path == "/" ? "/" : base.path + "/"),
          let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
          values.isRegularFile == true, let size = values.fileSize, size <= byteLimit,
          let contents = try? Data(contentsOf: file), contents.count <= byteLimit
        else { return nil }
        data = contents
      }
      guard let image = CGImageSourceCreateWithData(data as CFData, nil),
        let identifier = CGImageSourceGetType(image) as String?,
        let mime = UTType(identifier)?.preferredMIMEType,
        [
          "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp", "image/tiff",
          "image/x-icon", "image/heic",
        ].contains(mime)
      else { return nil }
      return "data:" + mime + ";base64," + data.base64EncodedString()
    }
    return try? await task.value
  }
}
