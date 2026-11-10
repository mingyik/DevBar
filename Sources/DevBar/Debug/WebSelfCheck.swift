// T1.4 运行时安全自检（R6 验证用）。只在 Debug 构建编译，Release 里不存在。
// 触发：DevBar.app/Contents/MacOS/DevBar --devbar-selfcheck <结果 JSON 路径>
// 自检前备份、结束后恢复 ~/Library/Application Support/DevBar/state，不改动用户已保存的内容。
// 结果只记录检查项、状态和长度，不记录编辑器内容（自检只写入自己的标记文本）。
#if DEBUG
  import AppKit
  import Network
  import WebKit

  @MainActor
  enum WebSelfCheck {
    static func runIfRequested(panel: PanelController) {
      let args = CommandLine.arguments
      guard let index = args.firstIndex(of: "--devbar-selfcheck"), index + 1 < args.count else {
        return
      }
      let output = URL(fileURLWithPath: args[index + 1])
      Task { @MainActor in
        let runner = Runner(panel: panel)
        let results = await runner.run()
        let data = try? JSONSerialization.data(
          withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: output)
        NSApp.terminate(nil)
      }
    }
  }

  @MainActor
  private final class Runner {
    let panel: PanelController
    var results: [[String: Any]] = []
    let stateDir = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "DevBar/state")
    var backup: [String: Data] = [:]

    init(panel: PanelController) { self.panel = panel }

    func run() async -> [String: Any] {
      backupState()
      defer { restoreState() }
      let started = Date()
      panel.model.page = .tools
      panel.show(anchor: nil)
      _ = await waitFor("页面就绪", seconds: 15) {
        await self.js("return !!window.__devbar") as? Bool == true
      }

      await checkCSPHeader()
      await checkFetchBlocked()
      await checkEvalBlocked()
      await checkInlineScriptBlocked()
      await checkRuleListEffective()
      await checkTabSwitchKeepsContentAndUndo()
      await checkWebContentCrashRecovery()

      return [
        "system": ProcessInfo.processInfo.operatingSystemVersionString,
        "seconds": Int(Date().timeIntervalSince(started)),
        "passed": results.allSatisfy { $0["pass"] as? Bool == true },
        "checks": results,
      ]
    }

    // MARK: - 检查项

    func checkCSPHeader() async {
      let value =
        await js(
          """
          const r = await fetch('devbar://app/index.html');
          const meta = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
          return { header: r.headers.get('content-security-policy'), meta: meta ? meta.content : null };
          """) as? [String: Any]
      let header = value?["header"] as? String
      let meta = value?["meta"] as? String
      record(
        "CSP 响应头", pass: header == DevBarCSP.header && meta == DevBarCSP.header,
        ["header": header ?? "nil", "metaMatches": meta == DevBarCSP.header])
    }

    func checkFetchBlocked() async {
      let value =
        await js(
          """
          const v = [];
          document.addEventListener('securitypolicyviolation', e => v.push(e.violatedDirective));
          let outcome;
          try { await fetch('https://example.com'); outcome = 'loaded'; }
          catch (e) { outcome = 'blocked:' + e.name; }
          await new Promise(r => setTimeout(r, 200));
          return { outcome, violations: v };
          """) as? [String: Any]
      let outcome = value?["outcome"] as? String ?? "nil"
      record(
        "fetch https 被拒", pass: outcome.hasPrefix("blocked"),
        ["outcome": outcome, "violations": value?["violations"] ?? []])
    }

    func checkEvalBlocked() async {
      let value =
        await js(
          """
          let a, b;
          try { a = 'ran:' + eval('1'); } catch (e) { a = 'blocked:' + e.name; }
          try { b = 'ran:' + (new Function('return 1'))(); } catch (e) { b = 'blocked:' + e.name; }
          return { eval: a, fn: b };
          """) as? [String: Any]
      let evalResult = value?["eval"] as? String ?? "nil"
      let fnResult = value?["fn"] as? String ?? "nil"
      record(
        "eval 与 new Function 被拒",
        pass: evalResult.hasPrefix("blocked") && fnResult.hasPrefix("blocked"),
        ["eval": evalResult, "newFunction": fnResult])
    }

    func checkInlineScriptBlocked() async {
      let value =
        await js(
          """
          window.__inlineRan = false;
          const s = document.createElement('script');
          s.textContent = 'window.__inlineRan = true';
          document.head.appendChild(s);
          await new Promise(r => setTimeout(r, 100));
          return window.__inlineRan;
          """) as? Bool
      record("内联脚本被拒", pass: value == false, ["inlineRan": value.map { "\($0)" } ?? "nil"])
    }

    /// 内容拦截规则单独验证：CSP 也会拦外部请求，所以在 App 的 WebView 里分不出是哪一层拦的。
    /// 这里取 App 编译进系统规则库的同一份规则（标识 devbar-block-http），
    /// 用一个本机 HTTP 服务对比「无规则 / 有规则」两个不带 CSP 的 WebView，看服务端是否收到请求。
    func checkRuleListEffective() async {
      let server = LocalImageServer()
      guard let port = await server.start() else {
        record("内容拦截规则生效", pass: false, ["error": "本机服务启动失败"])
        return
      }
      defer { server.stop() }
      let list = await withCheckedContinuation {
        (c: CheckedContinuation<WKContentRuleList?, Never>) in
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: "devbar-block-http") {
          list, _ in c.resume(returning: list)
        }
      }
      guard let list else {
        record("内容拦截规则生效", pass: false, ["error": "规则库里没有 devbar-block-http"])
        return
      }
      let url = "http://127.0.0.1:\(port)/probe.png"
      let control = await loadImage(url: url, ruleList: nil)
      let hitsAfterControl = server.hits
      let blocked = await loadImage(url: url, ruleList: list)
      let hitsAfterBlocked = server.hits
      record(
        "内容拦截规则生效",
        pass: control == "load" && blocked == "error" && hitsAfterBlocked == hitsAfterControl,
        [
          "withoutRule": control, "withRule": blocked,
          "serverHitsWithoutRule": hitsAfterControl,
          "serverHitsAddedWithRule": hitsAfterBlocked - hitsAfterControl,
        ])
    }

    func checkTabSwitchKeepsContentAndUndo() async {
      let marker = "devbar-selfcheck-\(UUID().uuidString.prefix(8))"
      let viewBefore = ObjectIdentifier(panel.webHost.webView)
      _ = await js(
        editorScript("tools", "v.focus(); v.dispatch(v.state.replaceSelection(m)); return true"),
        ["m": marker])
      let length1 = await js(editorScript("tools", "return v.state.doc.length")) as? Int ?? -1
      for screen in ["doc", "tools", "doc", "tools"] {
        panel.webHost.showScreen(screen)
        try? await Task.sleep(for: .milliseconds(150))
      }
      let afterSwitch =
        await js(editorScript("tools", "return v.state.doc.toString().includes(m)"), ["m": marker])
        as? Bool
      let undone =
        await js(
          editorScript(
            "tools",
            """
            v.contentDOM.dispatchEvent(new InputEvent('beforeinput', { inputType: 'historyUndo', bubbles: true, cancelable: true }));
            return v.state.doc.toString().includes(m)
            """), ["m": marker]) as? Bool
      let sameView = ObjectIdentifier(panel.webHost.webView) == viewBefore
      record(
        "切换页签后内容与撤销历史保留",
        pass: afterSwitch == true && undone == false && sameView,
        [
          "lengthAfterInsert": length1, "keptAfterSwitch": afterSwitch.map { "\($0)" } ?? "nil",
          "removedByUndo": undone.map { "\(!$0)" } ?? "nil", "sameWebView": sameView,
        ])
    }

    func checkWebContentCrashRecovery() async {
      let marker = "devbar-crash-\(UUID().uuidString.prefix(8))"
      _ = await js(
        editorScript(
          "tools",
          """
          v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: m } });
          v.contentDOM.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
          return true
          """), ["m": marker])
      try? await Task.sleep(for: .milliseconds(1600))  // 前端停止输入 1 秒后保存
      let oldView = panel.webHost.webView
      let mountedBefore = isMounted(oldView)
      let oldGeneration = panel.webHost.generation
      let pid = (oldView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
      guard pid > 0 else {
        record("WebContent 崩溃后重建并恢复", pass: false, ["error": "取不到 WebContent 进程号"])
        return
      }
      kill(pid, SIGKILL)
      let rebuilt = await waitFor("重建", seconds: 15) {
        guard self.panel.webHost.generation > oldGeneration else { return false }
        return await self.js("return !!window.__devbar") as? Bool == true
      }
      let restored = await waitFor("恢复内容", seconds: 10) {
        await self.js(
          self.editorScript("tools", "return v.state.doc.toString() === m"), ["m": marker]) as? Bool
          == true
      }
      // 面板里实际挂着的是不是新的 WebView（宿主重建后界面是否跟上）
      try? await Task.sleep(for: .milliseconds(500))
      let showsNew = isMounted(panel.webHost.webView)
      let showsOld = isMounted(oldView)
      // 再关开一次面板，看界面是否会换成新 WebView
      panel.dismiss()
      try? await Task.sleep(for: .milliseconds(300))
      panel.show(anchor: nil)
      try? await Task.sleep(for: .milliseconds(500))
      let showsNewAfterReopen = isMounted(panel.webHost.webView)
      record(
        "WebContent 崩溃后重建并恢复",
        pass: rebuilt && restored && showsNew && !showsOld,
        [
          "panelShowsWebViewBeforeCrash": mountedBefore, "killedPid": Int(pid), "rebuilt": rebuilt,
          "contentRestored": restored,
          "panelShowsNewWebView": showsNew, "panelStillShowsOldWebView": showsOld,
          "panelShowsNewAfterReopen": showsNewAfterReopen,
          "generation": "\(oldGeneration)→\(panel.webHost.generation)",
        ])
    }

    // MARK: - 工具

    func editorScript(_ screen: String, _ body: String) -> String {
      "const v = document.querySelector('#\(screen) .cm-content').cmTile.root.view;\n\(body)"
    }

    func js(_ body: String, _ args: [String: Any] = [:]) async -> Any? {
      do {
        return try await panel.webHost.webView.callAsyncJavaScript(
          body, arguments: args, in: nil, contentWorld: .page)
      } catch {
        return nil
      }
    }

    func waitFor(_ name: String, seconds: Double, _ condition: @MainActor () async -> Bool) async
      -> Bool
    {
      let deadline = Date().addingTimeInterval(seconds)
      while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(200))
      }
      return false
    }

    func loadImage(url: String, ruleList: WKContentRuleList?) async -> String {
      let config = WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      if let ruleList { config.userContentController.add(ruleList) }
      let view = WKWebView(frame: .init(x: 0, y: 0, width: 10, height: 10), configuration: config)
      view.loadHTMLString("<html><body></body></html>", baseURL: nil)
      try? await Task.sleep(for: .milliseconds(500))
      let result = try? await view.callAsyncJavaScript(
        """
        return await new Promise(r => {
          const i = new Image();
          i.onload = () => r('load'); i.onerror = () => r('error');
          i.src = u + '?' + Math.random();
          setTimeout(() => r('timeout'), 5000);
        });
        """, arguments: ["u": url], in: nil, contentWorld: .page)
      return result as? String ?? "nil"
    }

    /// WebView 是否真的挂在面板窗口里（有父视图且所在窗口就是面板）。
    func isMounted(_ view: WKWebView) -> Bool {
      view.superview != nil && view.window === panel.panel
    }

    func record(_ name: String, pass: Bool, _ detail: [String: Any]) {
      results.append(["name": name, "pass": pass, "detail": detail])
    }

    func backupState() {
      for file in (try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? [] {
        backup[file] = try? Data(contentsOf: stateDir.appending(path: file))
      }
    }

    func restoreState() {
      let existing = (try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? []
      for file in existing where backup[file] == nil {
        try? FileManager.default.removeItem(at: stateDir.appending(path: file))
      }
      for (file, data) in backup {
        try? data.write(to: stateDir.appending(path: file), options: .atomic)
      }
    }
  }

  /// 只监听 127.0.0.1 的最小 HTTP 服务，回一张 1×1 PNG，并计数收到的请求。
  @MainActor
  private final class LocalImageServer {
    private var listener: NWListener?
    private(set) var hits = 0
    private static let png = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    )!

    func start() async -> UInt16? {
      let params = NWParameters.tcp
      params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
      guard let listener = try? NWListener(using: params) else { return nil }
      self.listener = listener
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.serve(connection) }
      }
      listener.start(queue: .main)
      // 轮询端口，避免在回调里跨隔离域传状态。
      for _ in 0..<40 {
        if case .ready = listener.state, let port = listener.port?.rawValue { return port }
        try? await Task.sleep(for: .milliseconds(50))
      }
      return nil
    }

    func stop() { listener?.cancel() }

    private func serve(_ connection: NWConnection) {
      hits += 1
      connection.start(queue: .main)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
        var response = Data(
          "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(Self.png.count)\r\nConnection: close\r\n\r\n"
            .utf8)
        response.append(Self.png)
        connection.send(
          content: response, completion: .contentProcessed { _ in connection.cancel() })
      }
    }
  }
#endif
