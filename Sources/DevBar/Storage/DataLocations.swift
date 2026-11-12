import Foundation

/// User data, not disposable cache. Explicit roots keep tests away from user files.
enum DataLocations {
  static let dataKey = "dataStorageRoot"
  static let captureKey = "captureStorageRoot"
  static var root: URL {
    #if DEBUG
      if let isolated = SelfCheckEnvironment.stateDirectory {
        return isolated.deletingLastPathComponent()
      }
    #endif
    if let path = UserDefaults.standard.string(forKey: dataKey) {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return URL.applicationSupportDirectory.appending(path: "DevBar")
  }
  static var captures: URL {
    if let path = UserDefaults.standard.string(forKey: captureKey) {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
  }
  static func destination(in parent: URL) -> URL {
    parent.lastPathComponent == "DevBar" ? parent : parent.appending(path: "DevBar")
  }
  static func prepare(_ root: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let legacyPaste = root.appending(path: "clipboard")
    let paste = root.appending(path: "Paste")
    if fm.fileExists(atPath: legacyPaste.path), !fm.fileExists(atPath: paste.path) {
      try fm.moveItem(at: legacyPaste, to: paste)
    }
    for (key, name) in [("json", "Json"), ("qr", "QrCode"), ("doc", "Markdown")] {
      let destination = root.appending(path: name + "/state.json")
      let old = root.appending(path: "state/" + key + ".json")
      let legacy =
        key == "json" && !fm.fileExists(atPath: old.path)
        ? root.appending(path: "state/tools.json") : old
      if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: legacy.path) {
        try fm.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: legacy, to: destination)
      }
    }
  }
  enum LocationError: Error { case nestedDestination, occupiedDestination }
  static func move(from source: URL, to destination: URL) throws {
    let source = source.resolvingSymlinksInPath().standardizedFileURL
    let target = destination.resolvingSymlinksInPath().standardizedFileURL
    if source == target { return }
    guard !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/")
    else {
      throw LocationError.nestedDestination
    }
    guard !FileManager.default.fileExists(atPath: target.path) else {
      throw LocationError.occupiedDestination
    }
    try prepare(source)
    try FileManager.default.moveItem(at: source, to: target)
  }
}
