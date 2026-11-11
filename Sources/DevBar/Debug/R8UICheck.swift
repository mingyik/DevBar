#if DEBUG
  import AppKit
  import DevBarCore
  import WebKit

  /// Synthetic fixtures with isolated defaults and history; no user clipboard reads.
  @MainActor enum R8UICheck {
    private static var inputWindow: NSWindow?
    static func runIfRequested(panel: PanelController) {
      let args = CommandLine.arguments
      guard let index = args.firstIndex(of: "--devbar-r8check"), index + 3 < args.count else {
        return
      }
      let output = URL(fileURLWithPath: args[index + 1])
      let scenario = args[index + 2]
      let dark = args[index + 3] == "dark"
      Task {
        panel.model.autoImport = false
        panel.theme.mode = dark ? .dark : .light
        panel.model.pinned = true
        panel.model.page = scenario == "qr" ? .qr : .json
        panel.show(anchor: nil)
        for _ in 0..<100 {
          if (try? await panel.webHost.webView.evaluateJavaScript("!!window.__devbar")) as? Bool
            == true
          {
            break
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
        @MainActor func send(_ type: String, _ payload: [String: BridgeJSON]) async {
          let raw = BridgeEnvelope(v: 1, id: UUID().uuidString, type: type, payload: payload)
            .encoded()
          _ = try? await panel.webHost.webView.callAsyncJavaScript(
            "return await window.__devbar.receive(raw)", arguments: ["raw": raw], in: nil,
            contentWorld: .page)
        }
        var text =
          #"{"status":"success","code":200,"message":"粘贴后即可处理","id":1234567890123456789,"decimal":1.0,"user":{"name":"DevBar","active":true},"items":[1,2,3]}"#
        if scenario == "url" { text = "https://example.com/a%20b?name=DevBar&lang=zh#preview" }
        if scenario == "error" { text = "{\n  \"name\": \"DevBar\",\n  \"enabled\": true,\n}" }
        if scenario == "qr" { text = "DevBar · 快捷、小而美" }
        if scenario == "performance" {
          text =
            "{"
            + (0..<200).map { "\"key\($0)\":\"" + String(repeating: "a", count: 10475) + "\"" }
            .joined(separator: ",") + "}"
        }
        await send(
          "tools.import",
          [
            "page": .string(scenario == "qr" ? "qr" : "json"), "text": .string(text),
            "mode": .string("replace"),
          ])
        try? await Task.sleep(for: .milliseconds(600))
        var measurements: [String: Any] = [:]
        if scenario == "tree" || scenario == "qr" || scenario == "performance" {
          let script =
            scenario == "qr"
            ? "document.querySelector('#qr .pill').click(); while(document.querySelector('#qr .preview').hidden) await new Promise(requestAnimationFrame);return true"
            : "const t=performance.now();document.dispatchEvent(new KeyboardEvent('keydown',{key:'e',metaKey:true,bubbles:true}));while(document.querySelector('#tools .preview').hidden)await new Promise(requestAnimationFrame);return {milliseconds:performance.now()-t,rows:document.querySelectorAll('#tools .tree-row').length}"
          let result = try? await panel.webHost.webView.callAsyncJavaScript(
            script, arguments: [:], in: nil, contentWorld: .page)
          if let result { measurements["preview"] = result }
        }
        if scenario == "drop" { panel.model.dropActive = true }
        if scenario == "doc" { panel.model.page = .doc }
        if scenario.hasPrefix("settings") {
          panel.model.page = scenario == "settings" ? .clipboard : .json
          panel.model.enterSettings()
        }
        if scenario == "card" {
          let payload = ClipboardPayload(
            type: NSPasteboard.PasteboardType.string.rawValue, data: Data("在这里输入内容，再按 ⌘V 粘贴".utf8))
          for suffix in ["一", "二", "三"] {
            await panel.clipboard.record(
              ClipboardCapture(payloads: [
                ClipboardPayload(type: payload.type, data: payload.data + Data(suffix.utf8))
              ])!, source: nil)
          }
          panel.dismiss()
          let input = NSWindow(
            contentRect: panel.panel.frame, styleMask: [.titled], backing: .buffered, defer: false)
          input.title = "合成输入区域（仅用于验收截图）"
          let editor = NSTextView(frame: NSRect(origin: .zero, size: input.contentLayoutRect.size))
          editor.string = "这是合成的输入区域。\n\n切换卡片出现在鼠标上方；卡片不接管输入焦点。"
          editor.font = .systemFont(ofSize: 15)
          editor.textColor = NSColor(DesignTokens.textPrimary(panel.theme.effective))
          editor.backgroundColor = NSColor(DesignTokens.opaqueBackdrop(panel.theme.effective))
          input.contentView = editor
          input.makeKeyAndOrderFront(nil)
          NSApp.activate()
          try? await Task.sleep(for: .milliseconds(150))
          input.makeFirstResponder(editor)
          measurements["inputWasKeyBeforeCard"] = input.isKeyWindow
          measurements["frontmostBeforeCard"] =
            NSWorkspace.shared.frontmostApplication?.processIdentifier
          inputWindow = input
          let original = NSEvent.mouseLocation
          let point = NSPoint(x: input.frame.midX, y: input.frame.midY)
          let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0
          CGWarpMouseCursorPosition(CGPoint(x: point.x, y: desktopTop - point.y))
          try? await Task.sleep(for: .milliseconds(100))
          let board = NSPasteboard.withUniqueName()
          var timings: [Double] = []
          for index in 0..<15 {
            panel.clipboard.cycle(older: index % 2 == 0, board: board)
            timings.append(panel.clipboard.lastCycleMilliseconds)
          }
          board.releaseGlobally()
          CGWarpMouseCursorPosition(CGPoint(x: original.x, y: desktopTop - original.y))
          measurements["cycleToOrderFrontMilliseconds"] = timings
          measurements["mainPanelRemainsHidden"] = !panel.panel.isVisible
          measurements["inputRemainsKey"] = input.isKeyWindow
          measurements["frontmostAfterCard"] =
            NSWorkspace.shared.frontmostApplication?.processIdentifier
          measurements["temporaryKeysRegistered"] = panel.clipboard.card.temporaryKeys.isRegistered
        } else {
          try? await Task.sleep(for: .milliseconds(650))
        }
        let frame =
          scenario == "card" ? (inputWindow?.frame ?? panel.panel.frame) : panel.panel.frame
        measurements["processID"] = ProcessInfo.processInfo.processIdentifier
        measurements["frame"] = [frame.minX, frame.minY, frame.width, frame.height]
        measurements["scenario"] = scenario
        measurements["theme"] = dark ? "dark" : "light"
        measurements["sourceBytes"] = text.utf8.count
        measurements["windows"] = NSApp.windows.filter(\.isVisible).count
        if let data = try? JSONSerialization.data(
          withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
        {
          try? data.write(to: output)
        }
      }
    }
  }
#endif
