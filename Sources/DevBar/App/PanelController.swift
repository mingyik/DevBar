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
  private var layoutAnimationTask: Task<Void, Never>?
  private var activationObserver: NSObjectProtocol?
  private var dismissing = false
  private var lastAnchor: CGRect?
  private var documentWindowUserMoved = false
  private var applyingLayout = false
  private var previousPage: PanelModel.Page?
  private var windowMoveObserver: NSObjectProtocol?
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
    webHost.onDocumentLink = { [weak self] href in
      await self?.openDocumentLink(href) ?? false
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
    model.onClosePanel = { [weak self] in
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
    windowMoveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification, object: panel, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.model.page == .doc, !self.applyingLayout else { return }
        self.documentWindowUserMoved = true
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
    panel.isMovableByWindowBackground = next == .doc
    if next != .doc { documentWindowUserMoved = false }
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

  func openFromMenuBar(anchor: CGRect?) {
    if !panel.isVisible { model.prepareToOpen() }
    show(anchor: anchor)
  }

  func open(page: PanelModel.Page, anchor: CGRect?) {
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
    layoutAnimationTask?.cancel()
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
    let scale = min(2, preview.backingScaleFactor)
    previewLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
      let thumbnail: CGImage?
      if item.kind == .files, let url = ClipboardHoverContentLoader.singleFileURL(payloads) {
        thumbnail = await ClipboardHoverContentLoader.systemThumbnail(
          url: url, width: max(1, width - 28), scale: scale)
      } else {
        thumbnail = nil
      }
      guard !Task.isCancelled else { return }
      let prepared = ClipboardHoverContentLoader.prepare(
        item: item, payloads: payloads, width: width, maximum: maximum,
        systemThumbnail: thumbnail)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self,
          self.previewGeneration == generation,
          self.clipboardPreviewItemID == id,
          self.clipboardPreview?.isVisible == true
        else { return }
        self.clipboardPreviewState?.finish(
          itemID: id, content: prepared.content, image: prepared.image, media: prepared.media)
        if item.kind == .text, prepared.media == nil, prepared.content.utf8.count <= 128_000 {
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
    let container = NSView()
    panel.contentView = container
    panel.isMovableByWindowBackground = model.page == .doc
    host.sizingOptions = []
    host.translatesAutoresizingMaskIntoConstraints = true
    host.autoresizingMask = [.width, .height]
    host.frame = container.bounds
    container.addSubview(host)
    panel.appearance = theme.appearance()
  }

  private func updateMaterial() {
    if model.page != .clipboard {
      previewHideTask?.cancel()
      hideClipboardPreview()
    }
    panel.appearance = theme.appearance()
    webHost.syncAppearance(
      panelSize: model.page == .doc ? "large" : "normal",
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

  private func reposition(
    animated: Bool = true, avoidDocumentContentReflow: Bool = false
  ) {
    let screens = NSScreen.screens.map {
      PanelLayout.DisplaySlice(frame: $0.frame, visibleFrame: $0.visibleFrame)
    }
    let mouse = NSEvent.mouseLocation
    let mouseScreen =
      NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    let placed = PanelLayout.placement(
      anchor: lastAnchor, screens: screens, fallbackVisible: mouseScreen.visibleFrame)
    let layoutVisible =
      model.page == .doc && documentWindowUserMoved && panel.isVisible
      ? panel.screen?.visibleFrame ?? placed.visible : placed.visible
    var size = model.panelSize
    var sidebar: CGFloat = 0
    var documentContentWidthChanged = false
    if model.page == .doc, !model.dropActive {
      let layout = PanelLayout.documentPanelSize(
        enlarged: model.enlarged, split: model.documentSplit,
        sidebar: model.documentSidebarVisible, visibleFrame: layoutVisible)
      size = layout.panelSize
      if model.documentSidebarWidth != layout.sidebarWidth {
        model.documentSidebarWidth = layout.sidebarWidth
      }
      sidebar = model.documentSidebarVisible ? model.documentSidebarWidth + 0.7 : 0
      let contentWidth = max(0, layout.panelSize.width - sidebar)
      documentContentWidthChanged = abs(model.documentContentWidth - contentWidth) >= 0.5
      if documentContentWidthChanged { model.documentContentWidth = contentWidth }
    } else if model.showsEnlarge, model.enlarged, !model.dropActive {
      size.height = floor(layoutVisible.height * 4 / 5)
    }
    let frame: CGRect
    if model.page == .doc, documentWindowUserMoved, panel.isVisible {
      frame = PanelLayout.clamp(
        CGRect(
          x: panel.frame.maxX - size.width,
          y: panel.frame.maxY - size.height,
          width: size.width,
          height: size.height),
        in: layoutVisible)
    } else {
      frame = PanelLayout.frame(
        iconCenterX: placed.centerX, menuBarBottomY: placed.menuBottom,
        size: size, visibleFrame: layoutVisible)
    }
    layoutAnimationTask?.cancel()
    let shouldAnimate = animated && !(avoidDocumentContentReflow && documentContentWidthChanged)
    guard shouldAnimate, panel.isVisible,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      panel.frame != frame || model.documentSidebarPresentationWidth != sidebar
    else {
      applyLayout(frame: frame, sidebar: sidebar)
      return
    }
    let startFrame = panel.frame
    let startSidebar = model.documentSidebarPresentationWidth
    layoutAnimationTask = Task { @MainActor [weak self] in
      let started = CACurrentMediaTime()
      while !Task.isCancelled {
        guard let self else { return }
        let t = min(1, (CACurrentMediaTime() - started) / 0.22)
        let progress = t * t * (3 - 2 * t)
        func interpolate(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        self.applyLayout(
          frame: CGRect(
            x: interpolate(startFrame.minX, frame.minX),
            y: interpolate(startFrame.minY, frame.minY),
            width: interpolate(startFrame.width, frame.width),
            height: interpolate(startFrame.height, frame.height)),
          sidebar: interpolate(startSidebar, sidebar))
        if t >= 1 { return }
        try? await Task.sleep(for: .milliseconds(16))
      }
    }
  }

  private func applyLayout(frame: CGRect, sidebar: CGFloat) {
    applyingLayout = true
    defer { applyingLayout = false }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      model.documentSidebarPresentationWidth = sidebar
      panel.setFrame(frame, display: false)
      if let content = panel.contentView {
        host.frame = content.bounds
        content.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
      }
      panel.displayIfNeeded()
    }
  }

  // MARK: - Markdown document

  private func handleDocumentMode(
    _ mode: String, text _: String, docMode _: String, documentID: String?
  ) async {
    let resolved = ["source", "preview", "split"].contains(mode) ? mode : "source"
    guard documentID == documents.documentID else { return }
    let changed = documentMode != resolved
    documentMode = resolved
    model.documentDisplay = resolved
    model.documentSplit = resolved == "split"
    if changed { reposition(animated: true) }
  }

  private func toggleDocumentSidebar() {
    guard panel.isVisible, model.page == .doc else { return }
    documents.pruneMissingRecent()
    model.documentSidebarVisible.toggle()
    reposition(animated: true, avoidDocumentContentReflow: true)
  }

  private func openDocumentLink(_ href: String) async -> Bool {
    guard model.page == .doc else { return false }
    if let url = URL(string: href), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty
    {
      guard !documentAlertVisible else { return false }
      documentAlertVisible = true
      defer { documentAlertVisible = false }
      let alert = NSAlert()
      alert.messageText = Strings.documentOpenBrowserTitle
      alert.informativeText = url.absoluteString
      alert.addButton(withTitle: Strings.documentOpenBrowser)
      alert.addButton(withTitle: Strings.documentCancel)
      alert.window.level = .modalPanel
      guard alert.runModal() == .alertFirstButtonReturn else { return false }
      return NSWorkspace.shared.open(url)
    }
    guard let target = documents.resolveDocumentLink(href) else { return false }
    if ["md", "markdown"].contains(target.pathExtension.lowercased()) {
      await openDocument(target, previewMarkdown: true, revealSidebar: true)
      return documents.url == target
    }
    let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
    guard values?.isRegularFile == true, values?.isExecutable == false,
      NSWorkspace.shared.open(target)
    else {
      model.toast = Strings.documentLinkOpenFailed
      return false
    }
    return true
  }

  func openDocument(
    _ url: URL, previewMarkdown: Bool = false, revealSidebar: Bool = false
  ) async {
    openGeneration += 1
    let generation = openGeneration
    logger.notice("documentOpen start")
    let keepsDraftSilently =
      previewMarkdown && ["md", "markdown"].contains(url.pathExtension.lowercased())
    if !keepsDraftSilently {
      guard await confirmReplaceIfNeeded(generation: generation) else { return }
    }
    guard generation == openGeneration else { return }
    let result = await documents.read(url)
    guard generation == openGeneration else { return }
    logger.notice("documentOpen read done")
    switch result {
    case .failure(let error):
      documents.pruneMissingRecent()
      model.toast = Strings.fileDropError(Self.dropReason(error))
    case .success(let opened):
      guard await stashCurrentDocumentDraft(), generation == openGeneration else { return }
      documents.adopt(opened)
      model.toast = ""
      model.page = .doc
      let opensInPreview = previewMarkdown && opened.mode == .markdown
      if opensInPreview {
        documentMode = "preview"
      } else if opened.mode == nil {
        documentMode = "source"
      }
      if revealSidebar { model.documentSidebarVisible = true }
      webHost.importDocument(opened, display: opensInPreview ? "preview" : nil)
      model.documentDisplay = documentMode
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
    model.documentDisplay = draft.display
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
