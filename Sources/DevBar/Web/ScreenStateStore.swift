import Foundation
import os

actor ScreenStateStore {
  private let explicitDirectory: URL?
  private var directory: URL { explicitDirectory ?? DataLocations.root }
  private let logger = Logger(subsystem: "local.devbar.app", category: "web")

  init(directory explicitDirectory: URL? = nil) {
    #if DEBUG
      self.explicitDirectory = explicitDirectory ?? SelfCheckEnvironment.stateDirectory
    #else
      self.explicitDirectory = explicitDirectory
    #endif
  }

  @discardableResult
  func save(screen: String, json: String) -> Bool {
    guard let file = fileURL(screen), let data = json.data(using: .utf8) else { return false }
    do {
      if explicitDirectory == nil { try DataLocations.prepare(directory) }
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      let temporary = file.appendingPathExtension("tmp")
      try data.write(to: temporary, options: .atomic)
      if FileManager.default.fileExists(atPath: file.path) {
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: file)
      }
      logger.notice(
        "stateSave screen=\(screen, privacy: .public) bytes=\(data.count, privacy: .public)")
      return true
    } catch {
      logger.error("stateSaveFailed screen=\(screen, privacy: .public)")
      return false
    }
  }

  func load(screen: String) -> String? {
    if explicitDirectory == nil {
      do { try DataLocations.prepare(directory) } catch { return nil }
    }
    if screen == "json" || screen == "tools",
      let file = fileURL(screen), !FileManager.default.fileExists(atPath: file.path),
      let data = try? Data(contentsOf: directory.appending(path: "tools.json")),
      let legacy = String(data: data, encoding: .utf8)
    {
      save(screen: "json", json: legacy)
    }
    guard let file = fileURL(screen),
      let data = try? Data(contentsOf: file),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    logger.notice(
      "stateLoad screen=\(screen, privacy: .public) bytes=\(text.utf8.count, privacy: .public)")
    return text
  }

  private func fileURL(_ screen: String) -> URL? {
    if explicitDirectory == nil {
      let name: String
      switch screen {
      case "tools", "json": name = "Json"
      case "qr": name = "QrCode"
      case "doc": name = "Markdown"
      default: return nil
      }
      return directory.appending(path: name + "/state.json")
    }
    return switch screen {
    case "tools", "json": directory.appending(path: "json.json")
    case "qr": directory.appending(path: "qr.json")
    case "doc": directory.appending(path: "doc.json")
    default: nil
    }
  }
}
