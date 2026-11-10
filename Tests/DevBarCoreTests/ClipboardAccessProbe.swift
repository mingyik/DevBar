// V3 剪贴板读取授权实测用的独立探针。
// 只在显式 -D DEVBAR_CLIPBOARD_PROBE 时编译，不参与 app 和 swift test。
// 日志只记事件、授权状态、类型数量和长度，绝不输出剪贴板内容。
#if DEVBAR_CLIPBOARD_PROBE
  import AppKit
  import Foundation

  @main
  @MainActor
  final class ClipboardAccessProbe: NSObject, NSApplicationDelegate {
    private var log: FileHandle?

    static func main() {
      let app = NSApplication.shared
      app.setActivationPolicy(.accessory)
      let delegate = ClipboardAccessProbe()
      app.delegate = delegate
      withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
      let args = CommandLine.arguments
      let logPath = value(after: "--log", in: args) ?? "/tmp/devbar-v3-probe.log"
      if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
      }
      log = FileHandle(forWritingAtPath: logPath)
      log?.seekToEndOfFile()

      Task { @MainActor in
        let board = NSPasteboard.general
        write("start step=\(value(after: "--step", in: args) ?? "-") \(statusLine(board))")
        if args.contains("--types") {
          let count = board.types?.count ?? -1
          write("types_read count=\(count) \(statusLine(board))")
        }
        if args.contains("--detect") {
          await detect(board)
        }
        if args.contains("--read") {
          read(board)
        }
        if let seconds = value(after: "--monitor", in: args).flatMap(Double.init) {
          await monitor(board, seconds: seconds, readAnyway: args.contains("--read-anyway"))
        }
        write("end \(statusLine(board))")
        NSApplication.shared.terminate(nil)
      }
    }

    // MARK: - 动作

    private func read(_ board: NSPasteboard) {
      let started = Date()
      let text = board.string(forType: .string)
      let ms = Int(Date().timeIntervalSince(started) * 1000)
      // 只记是否读到和长度。
      write(
        "read_string got=\(text != nil) length=\(text?.count ?? 0) ms=\(ms) \(statusLine(board))")
    }

    private func detect(_ board: NSPasteboard) async {
      for line in await Self.detectSummary() { write(line) }
      write("detect_done \(statusLine(board))")
    }

    /// 在非主线程上下文里自己取 general 剪贴板，避免跨隔离域传递非 Sendable 对象。
    nonisolated private static func detectSummary() async -> [String] {
      guard #available(macOS 15.4, *) else { return ["detect unavailable"] }
      let board = NSPasteboard.general
      var lines: [String] = []
      do {
        let patterns = try await board.detectedPatterns(for: [
          \.probableWebURL, \.number, \.links, \.emailAddresses,
        ])
        // 只记命中了几种模式，不取值。
        lines.append("detect_patterns matched=\(patterns.count)")
      } catch {
        let e = error as NSError
        lines.append("detect_patterns error domain=\(e.domain) code=\(e.code)")
      }
      do {
        let metadata = try await board.detectedMetadata(for: [\.contentType])
        lines.append("detect_metadata has_content_type=\(metadata.contentType != nil)")
      } catch {
        let e = error as NSError
        lines.append("detect_metadata error domain=\(e.domain) code=\(e.code)")
      }
      return lines
    }

    /// 按方案 §4.4：只轮询 changeCount；允许时才读内容。`readAnyway` 用于观察非允许状态下读内容的系统表现。
    private func monitor(_ board: NSPasteboard, seconds: Double, readAnyway: Bool) async {
      var last = board.changeCount
      write("monitor_begin seconds=\(seconds) read_anyway=\(readAnyway) change=\(last)")
      let deadline = Date().addingTimeInterval(seconds)
      while Date() < deadline {
        try? await Task.sleep(for: .milliseconds(500))
        let current = board.changeCount
        guard current != last else { continue }
        last = current
        let behavior = behaviorName(board)
        if behavior == "alwaysAllow" || behavior == "unavailable" || readAnyway {
          write("change \(current) behavior=\(behavior) action=read")
          read(board)
        } else {
          write("change \(current) behavior=\(behavior) action=skip_pending")
        }
      }
      write("monitor_end")
    }

    // MARK: - 工具

    private func statusLine(_ board: NSPasteboard) -> String {
      "behavior=\(behaviorName(board)) change=\(board.changeCount)"
    }

    private func behaviorName(_ board: NSPasteboard) -> String {
      guard #available(macOS 15.4, *) else { return "unavailable" }
      switch board.accessBehavior {
      case .default: return "default"
      case .ask: return "ask"
      case .alwaysAllow: return "alwaysAllow"
      case .alwaysDeny: return "alwaysDeny"
      @unknown default: return "unknown(\(board.accessBehavior.rawValue))"
      }
    }

    private func value(after flag: String, in args: [String]) -> String? {
      guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
      return args[index + 1]
    }

    private func write(_ line: String) {
      let stamp = ISO8601DateFormatter().string(from: Date())
      log?.write(Data("\(stamp) \(line)\n".utf8))
    }
  }
#endif
