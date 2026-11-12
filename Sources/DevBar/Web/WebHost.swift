import AppKit
import Observation
import Synchronization
import WebKit
import os

@MainActor
@Observable
final class WebHost: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
  private(set) var webView: WKWebView
  private(set) var generation = 0
  private(set) var panelVisible = false
  var autoImport = true
  var onClipboardWrite: ((Int) -> Void)?
  var onToast: ((String) -> Void)?
  var onMemoryFlush: (() -> Void)?
  var lastPreviewImagePath: String? { previewImage.lastSavedPath }
  var acceptsFiles: (() -> Bool)?
  var receivedFiles: (([URL]) -> Void)?

  private let previewImage = PreviewImage()
  private let theme: ThemeManager
  private let store = ScreenStateStore()
  private let handler: DevBarSchemeHandler
  private let logger = Logger(subsystem: "local.devbar.app", category: "web")
  private var ready = false
  private var pending: [String] = []
  private var memorySource: DispatchSourceMemoryPressure?
  private var hiddenFlushTask: Task<Void, Never>?
  private var memoryFlushInProgress = false
  private var webViewReleased = false
  private var ruleList: WKContentRuleList?
  private var loading = false

  init(theme: ThemeManager, webRoot: URL? = nil) {
    self.theme = theme
    #if DEBUG
      autoImport = !SelfCheckEnvironment.isActive
    #endif
    let root =
      webRoot ?? Bundle.main.resourceURL?.appending(path: "Web") ?? URL(fileURLWithPath: "/")
    handler = DevBarSchemeHandler(root: root)
    webView = WKWebView()
    super.init()
    installMemoryWatch()
    Task {
      await start()
      if !panelVisible { scheduleHiddenMemoryFlush() }
    }
  }

  func setPanelVisible(_ visible: Bool) {
    guard panelVisible != visible else { return }
    panelVisible = visible
    hiddenFlushTask?.cancel()
    hiddenFlushTask = nil
    if visible {
      if webViewReleased { rebuild() }
    } else {
      scheduleHiddenMemoryFlush()
    }
  }

  enum StateError: Error { case saveFailed }
  func relocateStorage(to destination: URL) async throws {
    try await store.relocate(to: destination)
  }

  func saveState() async throws {
    guard ready else {
      if webViewReleased { return }
      throw StateError.saveFailed
    }
    let envelope = BridgeEnvelope(v: 1, id: UUID().uuidString, type: "state.flush", payload: [:])
      .encoded()
    let saved = try await webView.callAsyncJavaScript(
      "return (await window.__devbar.receive(env)).ok === true", arguments: ["env": envelope],
      in: nil,
      contentWorld: .page)
    guard saved as? Bool == true else { throw StateError.saveFailed }
  }

  func importFile(text: String, name: String, docMode: String? = nil, document: Bool) {
    guard MemoryBudget.allows(bytes: text.utf8.count) else {
      onToast?(Strings.insufficientMemory)
      return
    }
    var payload: [String: BridgeJSON] = [
      "text": .string(text), "fileName": .string(name), "mode": .string("replace"),
    ]
    if let docMode { payload["docMode"] = .string(docMode) }
    send(type: document ? "doc.import" : "tools.import", payload: payload)
  }

  func hideScreen() { send(type: "screen.hide", payload: [:]) }

  func showScreen(_ screen: String) {
    send(type: "screen.show", payload: ["page": .string(screen)])
  }

  func syncAppearance(panelSize: String, autoImport: Bool = true) {
    self.autoImport = autoImport
    send(
      type: "theme.set", payload: ["theme": .string(theme.effective == .dark ? "dark" : "light")])
    send(type: "panel.size", payload: ["size": .string(panelSize)])
    send(
      type: "settings.set",
      payload: [
        "autoImport": .bool(autoImport)
      ]
    )
    applyContrast()
  }

  func applyContrast() {
    let value = theme.increaseContrast ? "high" : "normal"
    webView.evaluateJavaScript("document.documentElement.dataset.contrast = '\(value)'")
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) async -> (Any?, String?) {
    guard let raw = message.body as? String, let envelope = BridgeEnvelope.decode(raw) else {
      return (nil, "bad envelope")
    }
    logger.notice("bridgeIn type=\(envelope.type, privacy: .public)")
    return (await handle(envelope), nil)
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let url = navigationAction.request.url
    let mainFrame = navigationAction.targetFrame?.isMainFrame ?? false
    if mainFrame, let url, url.scheme == "devbar", url.host == "app" {
      decisionHandler(.allow)
      return
    }
    decisionHandler(.cancel)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    logger.error("webContentTerminated")
    rebuild()
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    nil
  }

  private func start() async {
    ruleList = await Self.compileRuleList()
    rebuild()
  }

  private func rebuild() {
    webViewReleased = false
    ready = false
    loading = true
    generation += 1
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(handler, forURLScheme: "devbar")
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    if let ruleList {
      configuration.userContentController.add(ruleList)
    }
    configuration.userContentController.addScriptMessageHandler(
      self,
      contentWorld: .page,
      name: "devbar"
    )
    let view = FileDropWebView(frame: webView.frame, configuration: configuration)
    view.acceptsFiles = { [weak self] in self?.acceptsFiles?() ?? false }
    view.receivedFiles = { [weak self] urls in self?.receivedFiles?(urls) }
    view.registerForDraggedTypes([.fileURL])
    view.navigationDelegate = self
    view.uiDelegate = self
    view.setValue(false, forKey: "drawsBackground")
    #if DEBUG
      view.isInspectable = true
    #else
      view.isInspectable = false
    #endif
    webView = view
    view.load(URLRequest(url: URL(string: "devbar://app/index.html")!))
    logger.notice("webViewLoad generation=\(self.generation, privacy: .public)")
  }

  private func handle(_ envelope: BridgeEnvelope) async -> String {
    let payload = envelope.payload
    switch envelope.type {
    case "app.ready":
      ready = true
      let reply = readyPayload()
      flushPending()
      applyContrast()
      return reply
    case "input.check":
      let bytes: Int
      if case .number(let value) = payload["bytes"], value.isFinite, value >= 0,
        value < Double(Int.max)
      {
        bytes = Int(value)
      } else {
        return #"{"allowed":false}"#
      }
      let allowed = MemoryBudget.allows(bytes: bytes)
      if !allowed { onToast?(Strings.insufficientMemory) }
      return allowed ? #"{"allowed":true}"# : #"{"allowed":false}"#
    case "clipboard.readText":
      guard MemoryBudget.allows(bytes: 0) else {
        onToast?(Strings.insufficientMemory)
        return #"{"status":"memory"}"#
      }
      return PasteboardBridge.readText()
    case "clipboard.writeText":
      PasteboardBridge.writeText(payload["text"]?.stringValue ?? "")
      onClipboardWrite?(NSPasteboard.general.changeCount)
      return #"{"ok":true}"#
    case "clipboard.writeImage":
      PasteboardBridge.writePNGBase64(payload["pngBase64"]?.stringValue ?? "")
      onClipboardWrite?(NSPasteboard.general.changeCount)
      return #"{"ok":true}"#
    case "preview.exportImage":
      guard case .number(let width) = payload["width"], case .number(let height) = payload["height"]
      else { return "{}" }
      #if DEBUG
        let exportDirectory = SelfCheckEnvironment.stateDirectory?.appending(path: "exports")
        if let exportDirectory {
          try? FileManager.default.createDirectory(
            at: exportDirectory, withIntermediateDirectories: true)
          previewImage.writesClipboard = false
        }
      #else
        let exportDirectory: URL? = nil
      #endif
      let result = await previewImage.export(
        page: payload["page"]?.stringValue ?? "",
        width: width,
        height: height,
        html: payload["html"]?.stringValue ?? "",
        css: payload["css"]?.stringValue ?? "",
        theme: payload["theme"]?.stringValue ?? "light",
        background: payload["background"]?.stringValue ?? "",
        directory: exportDirectory ?? DataLocations.captures,
        host: webView.window?.contentView)
      if result.contains("\"saved\"") { onClipboardWrite?(NSPasteboard.general.changeCount) }
      return result
    case "preview.reveal":
      previewImage.reveal(path: payload["path"]?.stringValue ?? "")
      return "{}"
    case "qr.show":
      return QRGenerator.reply(text: payload["text"]?.stringValue ?? "")
    case "state.save":
      if let screen = payload["screen"]?.stringValue, let state = payload["state"] {
        let saved = await store.save(screen: screen, json: state.canonical())
        return saved ? #"{"ok":true}"# : #"{"ok":false}"#
      }
      return #"{"ok":true}"#
    case "state.load":
      let screen = payload["screen"]?.stringValue ?? ""
      if let saved = await store.load(screen: screen) {
        return #"{"state":"# + saved + "}"
      }
      return #"{"state":null}"#
    case "link.open":
      let opened = Self.openLink(payload["url"]?.stringValue)
      return opened ? #"{"opened":true}"# : #"{"opened":false}"#
    case "ui.toast":
      let text = payload["text"]?.stringValue ?? ""
      logger.notice("toast bytes=\(text.utf8.count, privacy: .public)")
      onToast?(text)
      return "{}"
    case "memory.flush":
      return #"{"ok":true}"#
    default:
      return "{}"
    }
  }

  private func readyPayload() -> String {
    let themeName = theme.effective == .dark ? "dark" : "light"
    let mode = theme.mode.rawValue
    return """
      {"theme":"\(themeName)","mode":"\(mode)","panelSize":"normal","settings":{"autoImport":\(autoImport)}}
      """
  }

  private func send(type: String, payload: [String: BridgeJSON]) {
    let envelope = BridgeEnvelope(v: 1, id: UUID().uuidString, type: type, payload: payload)
      .encoded()
    guard ready else {
      pending.append(envelope)
      return
    }
    deliver(envelope)
  }

  private func flushPending() {
    let queued = pending
    pending.removeAll()
    for envelope in queued {
      deliver(envelope)
    }
  }

  private func deliver(_ envelope: String) {
    Task {
      do {
        _ = try await webView.callAsyncJavaScript(
          "return await window.__devbar.receive(env)",
          arguments: ["env": envelope],
          in: nil,
          contentWorld: .page
        )
      } catch { onToast?(Strings.stateSaveFailed) }
    }
    logger.notice("bridgeOut bytes=\(envelope.utf8.count, privacy: .public)")
  }

  private func installMemoryWatch() {
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        MemoryBudget.critical = self.memorySource?.data.contains(.critical) == true
        if self.memorySource?.data.contains(.normal) != true { self.handleMemoryPressure() }
      }
    }
    source.resume()
    memorySource = source
  }

  private func handleMemoryPressure() {
    guard !panelVisible else { return }
    hiddenFlushTask?.cancel()
    hiddenFlushTask = Task { @MainActor [weak self] in await self?.flushHiddenMemory() }
  }

  private func scheduleHiddenMemoryFlush() {
    hiddenFlushTask?.cancel()
    hiddenFlushTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(60))
      guard !Task.isCancelled else { return }
      await self?.flushHiddenMemory()
    }
  }

  private func flushHiddenMemory() async {
    guard !panelVisible, !memoryFlushInProgress, !webViewReleased else { return }
    memoryFlushInProgress = true
    defer { memoryFlushInProgress = false }
    logger.notice("memoryFlush")
    if ready {
      let envelope = BridgeEnvelope(
        v: 1, id: UUID().uuidString, type: "memory.flush", payload: [:]
      ).encoded()
      let replied = await requestMemoryFlush(envelope)
      logger.notice("memoryFlushReply=\(replied, privacy: .public)")
      guard replied else {
        onToast?(Strings.stateSaveFailed)
        scheduleHiddenMemoryFlush()
        return
      }
    }
    guard !panelVisible else { return }
    onMemoryFlush?()
    previewImage.releaseMemory()
    releaseHiddenWebView()
  }

  private func requestMemoryFlush(_ envelope: String) async -> Bool {
    let view = webView
    return await withCheckedContinuation { continuation in
      let gate = MemoryFlushGate()
      let request = Task { @MainActor in
        let success: Bool
        do {
          let reply = try await view.callAsyncJavaScript(
            "return (await window.__devbar.receive(env)).ok === true",
            arguments: ["env": envelope],
            in: nil,
            contentWorld: .page
          )
          success = reply as? Bool == true
        } catch {
          success = false
        }
        if gate.claim() { continuation.resume(returning: success) }
      }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        if gate.claim() {
          request.cancel()
          view.stopLoading()
          continuation.resume(returning: false)
        }
      }
    }
  }

  private func releaseHiddenWebView() {
    guard !panelVisible else { return }
    let old = webView
    old.stopLoading()
    old.navigationDelegate = nil
    old.uiDelegate = nil
    old.configuration.userContentController.removeScriptMessageHandler(
      forName: "devbar", contentWorld: .page)
    old.removeFromSuperview()
    webView = WKWebView(frame: old.frame, configuration: WKWebViewConfiguration())
    generation += 1
    ready = false
    loading = false
    webViewReleased = true
    logger.notice("webViewReleased")
  }

  private static func compileRuleList() async -> WKContentRuleList? {
    let source = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
    return await withCheckedContinuation { continuation in
      WKContentRuleListStore.default().compileContentRuleList(
        forIdentifier: "devbar-block-http",
        encodedContentRuleList: source
      ) { list, error in
        if error != nil {
          Logger(subsystem: "local.devbar.app", category: "web").error("contentRuleCompileFailed")
        }
        continuation.resume(returning: list)
      }
    }
  }

  private static func openLink(_ raw: String?) -> Bool {
    guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { return false }
    NSWorkspace.shared.open(url)
    return true
  }
}

private final class MemoryFlushGate: @unchecked Sendable {
  private let claimed = Mutex(false)

  func claim() -> Bool {
    claimed.withLock { value in
      guard !value else { return false }
      value = true
      return true
    }
  }
}
