import Foundation

enum WebFileMap {
  static func file(for url: URL, root: URL) -> URL? {
    guard url.scheme == "devbar", url.host == "app" else { return nil }
    let rawPath = url.path.isEmpty ? "/" : url.path
    guard !rawPath.contains(".."), !rawPath.contains("\0") else { return nil }
    let relative = rawPath == "/" ? "index.html" : String(rawPath.dropFirst())
    guard !relative.isEmpty, !relative.hasPrefix("/") else { return nil }
    let rootStandard = root.standardizedFileURL
    let candidate = rootStandard.appending(path: relative).standardizedFileURL
    let rootPrefix = rootStandard.path.hasSuffix("/") ? rootStandard.path : rootStandard.path + "/"
    guard candidate.path == rootStandard.path || candidate.path.hasPrefix(rootPrefix) else {
      return nil
    }
    return candidate
  }

  static func mimeType(for file: URL) -> String {
    switch file.pathExtension.lowercased() {
    case "html": "text/html"
    case "js", "mjs": "text/javascript"
    case "css": "text/css"
    case "json": "application/json"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "woff2": "font/woff2"
    default: "application/octet-stream"
    }
  }
}
