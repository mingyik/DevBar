import AppKit
import DevBarCore
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

@MainActor
final class PanelController {
  lazy var capture = CaptureCoordinator(panel: self)
  let model: PanelModel
  let theme: ThemeManager
  let panel: DevBarPanel
  let webHost: WebHost
  let storage = StorageSettings()
  let clipboard: ClipboardController
  let documents: DocumentSession
  private var documentMode = "source"
  private var openGeneration = 0
  private var documentAlertVisible = false
  private let host: NSHostingView<PanelView>
  private var outsideMonitor: Any?
  private var activationObserver: NSObjectProtocol?
  private var resignObserver: NSObjectProtocol?
  private var dismissing = false
  private var lastAnchor: CGRect?
  private var previousPage: PanelModel.Page?
  private var clipboardPreview: NSPanel?
  private var clipboardPreviewItemID: UUID?
  private var clipboardPreviewState: ClipboardHoverPreviewState?
  private var clipboardPreviewHost: NSHostingView<ClipboardHoverPreview>?
  private var clipboardPreviewScheme: ColorScheme?
  private var previewHeights: [UUID: (width: CGFloat, maximum: CGFloat, height: CGFloat)] = [:]
  private var previewContents: [UUID: String] = [:]
  private var previewLoadTask: Task<Void, Never>?
  private var previewGeneration = UUID()
  private var previewPointerInside = false
  private var previewHideTask: Task<Void, Never>?
  private let logger = Logger(subsystem: "local.devbar.app", category: "panel")
  private let signposter = OSSignposter(subsystem: "local.devbar.app", category: "panel")

  init(theme: ThemeManager, webRoot: URL? = nil) {
    #if DEBUG
      let model = PanelModel(defaults: SelfCheckEnvironment.defaults)
      let clipboard = ClipboardController(
        theme: theme,
        directory: SelfCheckEnvironment.stateDirectory?.deletingLastPathComponent().appending(
          path: "clipboard"),
        reader: SelfCheckEnvironment.isActive
          ? SelfCheckPasteboardReader() as any PasteboardReading : SystemPasteboardReader(),
        startMonitoring: !SelfCheckEnvironment.isActive, defaults: SelfCheckEnvironment.defaults)
    #else
      let model = PanelModel()
      let clipboard = ClipboardController(theme: theme)
    #endif
    let webHost = WebHost(theme: theme, webRoot: webRoot)
    self.clipboard = clipboard
    self.model = model
    self.theme = theme
    self.webHost = webHost
    #if DEBUG
      documents = DocumentSession(defaults: SelfCheckEnvironment.defaults)
    #else
      documents = DocumentSession()
    #endif
    panel = DevBarPanel()
    host = NSHostingView(
      rootView: PanelView(
        model: model, theme: theme, webHost: webHost, clipboard: clipboard, storage: storage,
        documents: documents))
    storage.clipboard = clipboard
    model.onToggleDocumentSidebar = { [weak self] in self?.toggleDocumentSidebar() }
    model.onOpenDocument = { [weak self] url in
      Task { await self?.openDocument(url) }
    }
    model.onOpenDocumentDraft = { [weak self] id in
      Task { await self?.openDocumentDraft(id: id) }
    }
    model.onPickDocument = { [weak self] in self?.pickDocument() }
    storage.saveState = { [weak webHost] in
      guard let webHost else { throw WebHost.StateError.saveFailed }
      try await webHost.saveState()
    }
    storage.relocate = { [weak webHost] destination in
      guard let webHost else { throw WebHost.StateError.saveFailed }
      try await webHost.relocateStorage(to: destination)
    }
    clipboard.onHoverPreview = { [weak self] id in
      self?.showClipboardPreview(id)
    }
    webHost.onToast = { text in
      model.toast = text
    }
    webHost.onPreviewExportSaved = { [weak self] path in
      self?.capture.showSavedNotice(Strings.captureSaved, path: URL(fileURLWithPath: path))
    }
    webHost.onClipboardWrite = { [weak clipboard] count in clipboard?.monitor.markSelfWrite(count) }
    webHost.onMemoryFlush = { [weak self] in self?.releaseHiddenVisualCaches() }
    webHost.saveDocument = { [weak self] text, id in
      await self?.saveDocument(text: text, documentID: id) ?? #"{"status":"failed"}"#
    }
    webHost.onDocumentMode = { [weak self] mode, text, docMode, documentID in
      await self?.handleDocumentMode(
        mode, text: text, docMode: docMode, documentID: documentID)
    }
    panel.onClipboardKey = { [weak self] code in
      guard self?.model.page == .clipboard else { return false }
      return self?.clipboard.handleKey(code) ?? false
    }
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak clipboard] _ in
      Task { @MainActor in await clipboard?.monitor.poll() }
    }
    installChrome()
    panel.onEscape = { [weak self] in
      guard let self else { return }
      if model.dropActive {
        model.fileDrop?.cancel()
        model.dropActive = false
      }
      dismiss()
    }
    panel.onDocumentMode = { [weak self] in
      guard let self, Self.supportsModeToggle(self.model.page) else { return false }
      if self.model.page == .doc {
        self.webHost.cycleDocumentMode()
      } else {
        self.webHost.toggleDocumentMode()
      }
      return true
    }
    panel.onCyclePage = { [weak self] backwards in
      self?.model.cyclePage(backwards: backwards)
    }
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: panel,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleResignKey()
      }
    }
    outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])
    { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let location = NSEvent.mouseLocation
        if self.panel.isVisible, self.panel.frame.contains(location),
          !self.panel.isKeyWindow
        {
          self.panel.makeKeyAndOrderFront(nil)
        }
        self.handleOutsideClick()
      }
    }
    model.onPageChange = { [weak self] in
      guard let self else { return }
      let previous = self.previousPage
      let next = self.model.page
      self.previousPage = next
      self.finishPageChange(from: previous, to: next)
    }
    previousPage = model.page
    clipboard.releaseVisualCaches()
    watchSize()
  }

  private func finishPageChange(from previous: PanelModel.Page?, to next: PanelModel.Page) {
    if previous == .clipboard, next != .clipboard { releaseClipboardVisualCaches() }
    if next == .clipboard, clipboard.needsVisualCacheReload {
      Task { await clipboard.restoreVisualCaches() }
    }
    updateMaterial()
    reposition(animated: false)
  }

  static func supportsModeToggle(_ page: PanelModel.Page) -> Bool {
    page == .doc || page == .qr
  }

  func toggle(anchor: CGRect?) {
    if panel.isVisible {
      dismiss()
    } else {
      model.prepareToOpen()
      show(anchor: anchor)
    }
  }

  func open(page: PanelModel.Page, anchor: CGRect?) {
    if panel.isVisible, model.page == page {
      dismiss()
      return
    }
    if let anchor {
      lastAnchor = anchor
    }
    model.prepareToOpen(page: page)
    show(anchor: anchor)
  }

  func show(anchor: CGRect?, activateApplication: Bool = true) {
    let interval = signposter.beginInterval("openPanel")
    let started = ContinuousClock.now
    if let anchor {
      lastAnchor = anchor
    }
    webHost.setPanelVisible(true)
    updateMaterial()
    reposition()
    if activateApplication {
      panel.makeKeyAndOrderFront(nil)
      NSApp.activate()
    } else {
      panel.orderFrontRegardless()
    }
    Task {
      if model.page == .clipboard, clipboard.needsVisualCacheReload {
        await clipboard.restoreVisualCaches()
      }
      await clipboard.monitor.poll()
    }
    let elapsed = started.duration(to: .now)
    let milliseconds = milliseconds(elapsed)
    signposter.endInterval("openPanel", interval)
    logger.notice("panelOpenMs=\(milliseconds, privacy: .public)")
  }

  func dismiss() {
    guard panel.isVisible, !dismissing else { return }
    dismissing = true
    finishDismiss()
  }

  /// Complete panel dismissal before freezing the display.
  func prepareForCapture() async -> Bool {
    guard !dismissing else { return false }
    if panel.isVisible {
      dismissing = true
      finishDismiss()
    }
    await Task.yield()
    return true
  }

  private func finishDismiss() {
    panel.orderOut(nil)
    previewHideTask?.cancel()
    hideClipboardPreview()
    webHost.setPanelVisible(false)
    dismissing = false
  }

  func showSettings(anchor: CGRect?) {
    if let anchor {
      lastAnchor = anchor
    }
    model.enterSettings()
    if panel.isVisible {
      reposition()
    } else {
      show(anchor: anchor)
    }
  }

  private var isMouseInPreview: Bool {
    guard let preview = clipboardPreview, preview.isVisible else { return false }
    return preview.frame.insetBy(dx: -16, dy: -8).contains(NSEvent.mouseLocation)
  }

  private func schedulePreviewHide() {
    previewHideTask?.cancel()
    previewHideTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      while !Task.isCancelled {
        guard let self else { return }
        if self.clipboard.hoverID != nil { return }
        if !self.previewPointerInside && !self.isMouseInPreview {
          self.hideClipboardPreview()
          return
        }
        try? await Task.sleep(for: .milliseconds(120))
      }
    }
  }

  private func showClipboardPreview(_ id: UUID?) {
    guard panel.isVisible, model.page == .clipboard, !clipboard.isDragging else {
      previewHideTask?.cancel()
      hideClipboardPreview()
      return
    }
    guard let id else {
      schedulePreviewHide()
      return
    }
    guard let item = clipboard.items.first(where: { $0.id == id }),
      let screen = panel.screen ?? NSScreen.main
    else {
      hideClipboardPreview()
      return
    }
    previewHideTask?.cancel()
    previewPointerInside = false
    if clipboardPreviewItemID == id, clipboardPreview?.isVisible == true { return }
    clipboardPreviewItemID = id
    let visible = screen.visibleFrame
    let width = min(300, panel.frame.width - 20, visible.width)
    let maximum = visible.height * 2 / 3
    let cachedContent =
      item.kind == .image ? nil : previewContents[id] ?? clipboard.previewTexts[id]
    previewLoadTask?.cancel()
    let generation = UUID()
    previewGeneration = generation
    let cachedHeight = previewHeights[id].flatMap {
      $0.width == width && $0.maximum == maximum ? $0.height : nil
    }
    let height = cachedHeight ?? min(width, maximum)
    let frame = clipboardPreviewFrame(width: width, height: height, visible: visible)
    let state = clipboardPreviewState ?? ClipboardHoverPreviewState()
    clipboardPreviewState = state
    state.begin(
      item: item, tag: clipboard.tag(for: item), cachedContent: cachedContent,
      sizingComplete: cachedHeight != nil)
    let previewContent = ClipboardHoverPreview(
      state: state, scheme: theme.effective, theme: theme,
      onHoverChange: { [weak self] inside in
        guard let self else { return }
        self.previewPointerInside = inside
        if inside {
          self.previewHideTask?.cancel()
        } else {
          self.schedulePreviewHide()
        }
      },
      onContentHeightChange: { [weak self] contentHeight in
        guard let self, let id = self.clipboardPreviewItemID,
          let preview = self.clipboardPreview, preview.isVisible,
          self.clipboardPreviewState?.item?.id == id,
          let screen = self.panel.screen ?? NSScreen.main
        else { return }
        self.updateClipboardPreviewHeight(
          contentHeight + 60, id: id,
          width: preview.frame.width, maximum: screen.visibleFrame.height * 2 / 3,
          visible: screen.visibleFrame)
      })
    let preview = clipboardPreview ?? ClipboardPreviewPanel(contentRect: frame)
    preview.appearance = theme.appearance()
    if let host = clipboardPreviewHost {
      if clipboardPreviewScheme != theme.effective { host.rootView = previewContent }
    } else {
      let host = NSHostingView(rootView: previewContent)
      clipboardPreviewHost = host
      preview.contentView = host
    }
    clipboardPreviewScheme = theme.effective
    preview.setFrame(frame, display: true)
    clipboardPreview = preview
    preview.orderFrontRegardless()
    if cachedContent != nil { return }

    let payloads = clipboard.originals[id] ?? []
    previewLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
      let prepared = ClipboardHoverContentLoader.prepare(
        item: item, payloads: payloads, width: width, maximum: maximum)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self,
          self.previewGeneration == generation,
          self.clipboardPreviewItemID == id,
          self.clipboardPreview?.isVisible == true
        else { return }
        self.clipboardPreviewState?.finish(
          itemID: id, content: prepared.content, image: prepared.image)
        if item.kind != .image, prepared.content.utf8.count <= 128_000 {
          if self.previewContents.count >= 20 { self.previewContents.removeAll() }
          self.previewContents[id] = prepared.content
        }
        if let imageHeight = prepared.imageHeight {
          self.updateClipboardPreviewHeight(
            imageHeight, id: id, width: width,
            maximum: maximum, visible: visible)
        }
      }
    }
  }

  private func updateClipboardPreviewHeight(
    _ proposedHeight: CGFloat, id: UUID,
    width: CGFloat, maximum: CGFloat, visible: NSRect
  ) {
    let height = min(maximum, max(width, proposedHeight))
    if let cached = previewHeights[id], cached.width == width,
      cached.maximum == maximum, abs(cached.height - height) <= 0.5
    {
      return
    }
    if previewHeights.count >= 20 { previewHeights.removeAll() }
    previewHeights[id] = (width, maximum, height)
    guard let preview = clipboardPreview, preview.isVisible else { return }
    guard abs(preview.frame.height - height) > 0.5 else {
      clipboardPreviewState?.finishSizing(itemID: id)
      return
    }
    let generation = previewGeneration
    let frame = clipboardPreviewFrame(width: width, height: height, visible: visible)
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.16
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        preview.animator().setFrame(frame, display: true)
      },
      completionHandler: { [weak self] in
        Task { @MainActor in
          guard let self, self.previewGeneration == generation else { return }
          self.clipboardPreviewState?.finishSizing(itemID: id)
        }
      })
  }

  private func clipboardPreviewFrame(width: CGFloat, height: CGFloat, visible: NSRect) -> NSRect {
    let left = panel.frame.minX - width - 6
    let right = panel.frame.maxX + 6
    let x = left >= visible.minX ? left : min(right, visible.maxX - width)
    let y = min(max(panel.frame.maxY - height, visible.minY), visible.maxY - height)
    return NSRect(x: x, y: y, width: width, height: height)
  }

  private func hideClipboardPreview() {
    previewLoadTask?.cancel()
    previewLoadTask = nil
    previewGeneration = UUID()
    clipboardPreviewItemID = nil
    previewPointerInside = false
    clipboardPreview?.orderOut(nil)
  }

  private func releaseHiddenVisualCaches() {
    guard !panel.isVisible else { return }
    releaseClipboardVisualCaches()
  }

  private func releaseClipboardVisualCaches() {
    previewHideTask?.cancel()
    hideClipboardPreview()
    clipboardPreviewState?.releaseMemory()
    clipboardPreview?.contentView = nil
    clipboardPreview = nil
    clipboardPreviewHost = nil
    clipboardPreviewState = nil
    clipboardPreviewScheme = nil
    previewContents.removeAll(keepingCapacity: false)
    previewHeights.removeAll(keepingCapacity: false)
    clipboard.releaseVisualCaches()
  }

  private func installChrome() {
    host.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.addSubview(host)
    panel.contentView = container
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      host.topAnchor.constraint(equalTo: container.topAnchor),
      host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    panel.appearance = theme.appearance()
  }

  private func updateMaterial() {
    if model.page != .clipboard {
      previewHideTask?.cancel()
      hideClipboardPreview()
    }
    panel.appearance = theme.appearance()
    webHost.syncAppearance(
      panelSize: model.enlarged && model.showsEnlarge ? "large" : "normal",
      autoImport: model.autoImport)
    if model.page == .json || model.page == .qr {
      webHost.showScreen(model.page.rawValue)
    } else if model.page == .doc {
      webHost.showScreen("doc")
    } else {
      webHost.hideScreen()
    }
  }

  private func watchSize() {
    withObservationTracking {
      _ = model.dropActive
      _ = model.autoImport
      _ = model.sizePreferences
      _ = theme.mode
      _ = theme.systemScheme
      _ = theme.increaseContrast
      _ = theme.reduceTransparency
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.updateMaterial()
        self?.reposition()
        self?.watchSize()
      }
    }
  }

  private func reposition(animated: Bool = true) {
    let screens = NSScreen.screens.map {
      PanelLayout.DisplaySlice(frame: $0.frame, visibleFrame: $0.visibleFrame)
    }
    let mouse = NSEvent.mouseLocation
    let mouseScreen =
      NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    let placed = PanelLayout.placement(
      anchor: lastAnchor, screens: screens, fallbackVisible: mouseScreen.visibleFrame)
    var size = model.panelSize
    if model.page == .doc, !model.dropActive {
      let layout = PanelLayout.documentPanelSize(
        enlarged: model.enlarged, split: model.documentSplit,
        sidebar: model.documentSidebarVisible, visibleFrame: placed.visible)
      size = layout.panelSize
      model.documentSidebarWidth = layout.sidebarWidth
    } else if model.showsEnlarge, model.enlarged, !model.dropActive {
      size.height = floor(placed.visible.height * 4 / 5)
    }
    let frame = PanelLayout.frame(
      iconCenterX: placed.centerX, menuBarBottomY: placed.menuBottom,
      size: size, visibleFrame: placed.visible)
    guard animated, panel.isVisible else {
      panel.setFrame(frame, display: true)
      return
    }
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.15
        panel.animator().setFrame(frame, display: true)
      }, completionHandler: nil)
  }

  private func handleOutsideClick() {
    guard panel.isVisible, !model.pinned else { return }
    let location = NSEvent.mouseLocation
    if panel.frame.contains(location)
      || (clipboardPreview?.isVisible == true && clipboardPreview?.frame.contains(location) == true)
      || (NSApp.modalWindow?.frame.contains(location) == true)
    {
      return
    }
    dismiss()
  }

  private func handleResignKey() {
    guard panel.isVisible, !model.pinned, !dismissing, !NSApp.isActive else { return }
    dismiss()
  }

  // MARK: - Markdown document

  private func handleDocumentMode(
    _ mode: String, text _: String, docMode _: String, documentID: String?
  ) async {
    let resolved = ["source", "preview", "split"].contains(mode) ? mode : "source"
    guard documentID == documents.documentID else { return }
    let changed = documentMode != resolved
    documentMode = resolved
    model.documentSplit = resolved == "split"
    if changed { reposition(animated: false) }
  }

  private func toggleDocumentSidebar() {
    guard panel.isVisible, model.page == .doc else { return }
    documents.pruneMissingRecent()
    model.documentSidebarVisible.toggle()
    reposition(animated: false)
  }

  func openDocument(_ url: URL) async {
    openGeneration += 1
    let generation = openGeneration
    logger.notice("documentOpen start")
    guard await confirmReplaceIfNeeded(generation: generation) else { return }
    guard generation == openGeneration else { return }
    let result = await documents.read(url)
    guard generation == openGeneration else { return }
    logger.notice("documentOpen read done")
    switch result {
    case .failure(let error):
      documents.pruneMissingRecent()
      model.toast = Strings.fileDropError(Self.dropReason(error))
    case .success(let opened):
      guard await stashCurrentDocumentDraft() else { return }
      documents.adopt(opened)
      model.toast = ""
      model.page = .doc
      webHost.importDocument(opened)
      if opened.mode == nil {
        documentMode = "source"
      }
      model.documentSplit = documentMode == "split"
      reposition(animated: false)
    }
  }

  private func openDocumentDraft(id: String) async {
    openGeneration += 1
    let generation = openGeneration
    guard await confirmReplaceIfNeeded(generation: generation), generation == openGeneration,
      await stashCurrentDocumentDraft(), generation == openGeneration,
      let candidate = documents.draft(id: id),
      webHost.importDocumentDraft(candidate),
      let draft = documents.activateDraft(id: id)
    else { return }

    model.page = .doc
    model.toast = ""
    documentMode = draft.display
    model.documentSplit = draft.display == "split"
    reposition(animated: false)
  }

  private func stashCurrentDocumentDraft() async -> Bool {
    guard model.page == .doc else { return true }
    guard let snapshot = await webHost.documentSnapshot() else { return false }
    guard documents.requiresDraft(snapshot) else { return true }
    guard documents.stashDraft(snapshot) != nil else {
      model.toast = Strings.insufficientMemory
      return false
    }
    return true
  }

  private func confirmReplaceIfNeeded(generation: Int) async -> Bool {
    let status = await webHost.documentStatus()
    guard generation == openGeneration else { return false }
    switch DocumentFile.replacementReadiness(
      requiresEditorSnapshot: false, hasEditorSnapshot: false,
      dirty: status?["dirty"] as? Bool)
    {
    case .unavailable: return false
    case .clean: return true
    case .modified: break
    }
    let alert = NSAlert()
    alert.messageText = Strings.documentUnsavedTitle
    alert.informativeText = Strings.documentUnsavedBody
    alert.addButton(withTitle: Strings.documentSave)
    alert.addButton(withTitle: Strings.documentKeepDraft)
    alert.addButton(withTitle: Strings.documentCancel)
    alert.window.level = .modalPanel
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      guard let text = await webHost.documentText() else { return false }
      guard generation == openGeneration else { return false }
      let outcome = await documents.save(text, saveAs: false)
      switch outcome {
      case .saved(let saved):
        let id = documents.ensureID(saved.id)
        await webHost.markDocumentSaved(
          text: text, fileName: saved.fileName, documentId: id)
        capture.showSavedNotice(Strings.captureSaved, path: saved.url)
        let currentText = await webHost.documentText() ?? text
        guard currentText == text else { return false }
        return generation == openGeneration
      case .canceled, .failed:
        return false
      case .externalChanged:
        showDocumentAlert(
          title: Strings.documentExternalTitle, body: Strings.documentExternalBody)
        return false
      case .missing:
        showDocumentAlert(
          title: Strings.documentMissingTitle, body: Strings.documentMissingBody)
        return false
      }
    case .alertSecondButtonReturn:
      return true
    default:
      return false
    }
  }

  private func saveDocument(text: String, documentID: String?) async -> String {
    if let documentID, documentID != documents.documentID {
      return #"{"status":"failed"}"#
    }
    let outcome = await documents.save(text, saveAs: false)
    switch outcome {
    case .saved(let saved):
      let id = documents.ensureID(saved.id)
      capture.showSavedNotice(Strings.captureSaved, path: saved.url)
      return BridgeJSON.object([
        "status": .string("saved"), "fileName": .string(saved.fileName),
        "documentId": .string(id), "text": .string(text),
      ]).canonical()
    case .canceled: return #"{"status":"canceled"}"#
    case .failed: return #"{"status":"failed"}"#
    case .externalChanged: return #"{"status":"externalChanged"}"#
    case .missing: return #"{"status":"missing"}"#
    }
  }

  private func pickDocument() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = FileRoute.documentExtensions.compactMap {
      UTType(filenameExtension: $0)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await openDocument(url) }
  }

  private func showDocumentAlert(title: String, body: String) {
    guard !documentAlertVisible else { return }
    documentAlertVisible = true
    defer { documentAlertVisible = false }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = body
    alert.addButton(withTitle: Strings.captureCancel)
    alert.window.level = .modalPanel
    _ = alert.runModal()
  }

  private static func dropReason(_ error: DocumentOpenError) -> FileDropReason {
    switch error {
    case .tooLarge: .tooLarge
    case .notUTF8: .notUTF8
    case .unsupported: .unsupportedType
    case .unreadable: .unreadable
    }
  }

  private func milliseconds(_ elapsed: Duration) -> Double {
    let parts = elapsed.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1_000_000_000_000_000
  }
}
