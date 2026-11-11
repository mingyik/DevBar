import Foundation
import os

actor ScreenStateStore {
  private let directory: URL
  private let logger = Logger(subsystem: "local.devbar.app", category: "web")

  init() {
    #if DEBUG
      // 自检时改用独立的测试目录，不读写用户的状态目录（见 Debug/WebSelfCheck.swift）。
      if let testDirectory = SelfCheckEnvironment.stateDirectory {
        directory = testDirectory
        return
      }
    #endif
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    directory = base.appending(path: "DevBar/state")
  }

  func save(screen: String, json: String) {
    guard let file = fileURL(screen), let data = json.data(using: .utf8) else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let temporary = file.appendingPathExtension("tmp")
      try data.write(to: temporary, options: .atomic)
      if FileManager.default.fileExists(atPath: file.path) {
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: file)
      }
      logger.notice(
        "stateSave screen=\(screen, privacy: .public) bytes=\(data.count, privacy: .public)")
    } catch {
      logger.error("stateSaveFailed screen=\(screen, privacy: .public)")
    }
  }

  func load(screen: String) -> String? {
    guard let file = fileURL(screen),
      let data = try? Data(contentsOf: file),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    logger.notice(
      "stateLoad screen=\(screen, privacy: .public) bytes=\(text.utf8.count, privacy: .public)")
    return text
  }

  private func fileURL(_ screen: String) -> URL? {
    switch screen {
    case "tools": directory.appending(path: "tools.json")
    case "doc": directory.appending(path: "doc.json")
    default: nil
    }
  }
}
