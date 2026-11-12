#if DEBUG
  import AppKit
  import DevBarCore
  import WebKit

  /// Uses production WebKit/bridge with synthetic input and isolated state.
  @MainActor enum R9UICheck {
    static func runIfRequested(panel: PanelController) {
      let args = CommandLine.arguments
      guard let index = args.firstIndex(of: "--devbar-r9check"), index + 4 < args.count else {
        return
      }
      let output = URL(fileURLWithPath: args[index + 1])
      let scenario = args[index + 2]
      let theme = args[index + 3]
      let large = args[index + 4] == "large"
      Task {
        panel.panel.ignoresMouseEvents = true
        panel.model.autoImport = false
        var result: [String: Any] = ["scenario": scenario, "theme": theme, "large": large]
        if scenario == "mem-idle" {
          let ready = await waitForReady(panel.webHost)
          result["ready"] = ready
          result["processID"] = ProcessInfo.processInfo.processIdentifier
          write(result, to: output)
          return
        }
        if scenario == "mem-daily" {
          panel.theme.mode = theme == "dark" ? .dark : .light
          panel.model.pinned = true
          panel.model.page = .json
          panel.show(anchor: nil, activateApplication: false)
          let text = "{\"daily\":{\"items\":[1,2,3,4,5],\"ready\":true}}"
          let payload = BridgeEnvelope(
            v: 1, id: UUID().uuidString, type: "tools.import",
            payload: [
              "text": .string(text), "mode": .string("replace"), "page": .string("json"),
            ]
          ).encoded()
          let document = BridgeEnvelope(
            v: 1, id: UUID().uuidString, type: "doc.import",
            payload: [
              "text": .string("# Daily\n\nA short synthetic document."),
              "docMode": .string("markdown"),
            ]
          ).encoded()
          let ready = await waitForReady(panel.webHost)
          if ready {
            for value in ["daily clip one", "daily clip two", "daily clip three"] {
              if let capture = ClipboardCapture(payloads: [
                ClipboardPayload(
                  type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.utf8))
              ]) {
                await panel.clipboard.record(capture, source: nil)
              }
            }
            _ = try? await panel.webHost.webView.callAsyncJavaScript(
              "await window.__devbar.receive(docRaw); return await window.__devbar.receive(raw)",
              arguments: ["raw": payload, "docRaw": document], in: nil,
              contentWorld: .page)
            _ = try? await panel.webHost.webView.evaluateJavaScript(
              "document.dispatchEvent(new KeyboardEvent('keydown',{key:'e',metaKey:true,bubbles:true}))"
            )
            for _ in 0..<100 {
              if (try? await panel.webHost.webView.evaluateJavaScript(
                "!!document.querySelector('#tools .tree-root')")) as? Bool == true
              {
                break
              }
              try? await Task.sleep(for: .milliseconds(50))
            }
          }
          result["ready"] = ready
          result["syntheticClipboardItems"] = panel.clipboard.items.count
          result["jsonBytes"] = text.utf8.count
          result["jsonTreeMounted"] =
            (try? await panel.webHost.webView.evaluateJavaScript(
              "!!document.querySelector('#tools .tree-root')")) as? Bool ?? false
          result["processID"] = ProcessInfo.processInfo.processIdentifier
          panel.dismiss()
          write(result, to: output)
          return
        }
        panel.theme.mode = theme == "dark" ? .dark : .light
        panel.model.pinned = true
        panel.model.page = scenario == "json" ? .json : .doc
        panel.show(anchor: nil, activateApplication: false)
        panel.model.enlarged = large
        panel.show(anchor: nil, activateApplication: false)
        do {
          for _ in 0..<150 {
            if (try? await panel.webHost.webView.evaluateJavaScript("!!window.__devbar")) as? Bool
              == true
            {
              break
            }
            try await Task.sleep(for: .milliseconds(100))
          }
          let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
          let source = root.appending(
            path: "Samples/"
              + (scenario == "pure"
                ? "样张.mmd"
                : scenario == "export-dark-long"
                  ? "R9-深色长图.md"
                  : scenario == "export"
                    ? "R9-截全图.md" : scenario == "perfdoc" ? "R9-性能1000行.md" : "样张.md"))
          let text =
            scenario == "error"
            ? "```mermaid\nflowchart LR\nA --> [\n```\n\n后续段落仍可阅读。"
            : try String(contentsOf: source, encoding: .utf8)
          let raw = BridgeEnvelope(
            v: 1, id: UUID().uuidString, type: "doc.import",
            payload: [
              "text": .string(text), "fileName": .string(source.lastPathComponent),
              "docMode": .string(scenario == "pure" ? "mermaid" : "markdown"),
            ]
          ).encoded()
          _ = try await panel.webHost.webView.callAsyncJavaScript(
            "return await window.__devbar.receive(raw)", arguments: ["raw": raw], in: nil,
            contentWorld: .page)
          let scriptURL = root.appending(path: "Web/tests/r9-runtime.mjs")
          let script = try String(contentsOf: scriptURL, encoding: .utf8)
          let jsonSample =
            (scenario == "perfjson" || scenario == "memory")
            ? try String(contentsOf: root.appending(path: "Samples/样张.json"), encoding: .utf8) : ""
          let measurements = try await panel.webHost.webView.callAsyncJavaScript(
            "return await (" + script.replacingOccurrences(of: "export default ", with: "")
              + ")(scenario, jsonSample)",
            arguments: ["scenario": scenario, "jsonSample": jsonSample], in: nil,
            contentWorld: .page)
          if var values = measurements as? [String: Any] {
            if let artifacts = values.removeValue(forKey: "artifacts") as? [[String: Any]] {
              let directory = root.appending(
                path: "Screenshots/R9/catalog-\(theme)-\(large ? "large" : "normal")")
              try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
              for item in artifacts {
                if let index = item["index"] as? Int, let base64 = item["pngBase64"] as? String,
                  let data = Data(base64Encoded: base64)
                {
                  try data.write(to: directory.appending(path: "\(index).png"))
                }
              }
              values["artifactCount"] = artifacts.count
            }
            if scenario == "copy", let data = NSPasteboard.general.data(forType: .png) {
              let file = root.appending(path: "Screenshots/R9/单图复制-\(theme).png")
              try data.write(to: file)
              values["clipboardPNGBytes"] = data.count
            }
            if scenario == "json" {
              values["actualClipboard"] = NSPasteboard.general.string(forType: .string)
            }
            result["measurements"] = values
          } else {
            result["measurements"] = measurements
          }
          result["windowNumber"] = panel.panel.windowNumber
          result["frame"] = [
            panel.panel.frame.minX, panel.panel.frame.minY, panel.panel.frame.width,
            panel.panel.frame.height,
          ]
        } catch { result["error"] = String(describing: error) }
        result["processID"] = ProcessInfo.processInfo.processIdentifier
        write(result, to: output)
        if scenario == "memory" {
          panel.dismiss()
          if args.contains("--verify-idle-release") {
            let generation = panel.webHost.generation
            try? await Task.sleep(for: .seconds(65))
            result["hiddenReleaseOccurred"] = panel.webHost.generation > generation
            panel.model.page = .doc
            panel.show(anchor: nil, activateApplication: false)
            result["readyAfterReopen"] = await waitForReady(panel.webHost)
            for _ in 0..<150 {
              if (try? await panel.webHost.webView.evaluateJavaScript(
                "document.querySelectorAll('#doc .mmd:not(.mmd-error) svg').length")) as? Int == 22
              {
                break
              }
              try? await Task.sleep(for: .milliseconds(100))
            }
            result["restoredDiagramCount"] =
              (try? await panel.webHost.webView.evaluateJavaScript(
                "document.querySelectorAll('#doc .mmd:not(.mmd-error) svg').length")) as? Int ?? 0
            panel.dismiss()
            write(result, to: output)
          }
        }
      }
    }

    private static func waitForReady(_ host: WebHost) async -> Bool {
      for _ in 0..<150 {
        if (try? await host.webView.evaluateJavaScript("!!window.__devbar")) as? Bool == true {
          return true
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return false
    }

    private static func write(_ result: [String: Any], to output: URL) {
      guard
        let data = try? JSONSerialization.data(
          withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      else { return }
      try? data.write(to: output)
    }
  }
#endif
