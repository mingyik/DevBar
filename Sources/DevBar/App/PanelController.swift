import AppKit
import DevBarCore
import QuartzCore
import SwiftUI
import os

@MainActor
final class PanelController {
  let model: PanelModel
  let theme: ThemeManager
  let panel: DevBarPanel
  let webHost: WebHost
  let storage = StorageSettings()
  let clipboard: ClipboardController
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

  init(theme: ThemeManager) {
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
    let webHost = WebHost(theme: theme)
    self.clipboard = clipboard
    self.model = model
    self.theme = theme
    self.webHost = webHost
    panel = DevBarPanel()
    host = NSHostingView(
      rootView: PanelView(
        model: model, theme: theme, webHost: webHost, clipboard: clipboard, storage: storage))
    storage.clipboard = clipboard
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
    webHost.onClipboardWrite = { [weak clipboard] count in clipboard?.monitor.markSelfWrite(count) }
    webHost.onMemoryFlush = { [weak self] in self?.releaseHiddenVisualCaches() }
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
      guard let self, self.model.page == .doc else { return false }
      self.webHost.toggleDocumentMode()
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
        self?.handleOutsideClick()
      }
    }
    model.onPageChange = { [weak self] in
      guard let self else { return }
      if self.previousPage == .clipboard, self.model.page != .clipboard {
        self.releaseClipboardVisualCaches()
      }
      self.previousPage = self.model.page
      if self.model.page == .clipboard, self.clipboard.needsVisualCacheReload {
        Task { await self.clipboard.restoreVisualCaches() }
      }
      self.updateMaterial()
      self.reposition(animated: false)
    }
    previousPage = model.page
    clipboard.releaseVisualCaches()
    watchSize()
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
    model.page = page
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
    state.begin(item: item, cachedContent: cachedContent, sizingComplete: cachedHeight != nil)
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
    if model.showsEnlarge, model.enlarged, !model.dropActive {
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
        context.duration = panel.isVisible ? 0.15 : 0
        panel.animator().setFrame(frame, display: true)
      }, completionHandler: nil)
  }

  private func handleOutsideClick() {
    guard panel.isVisible, !model.pinned else { return }
    let location = NSEvent.mouseLocation
    if panel.frame.contains(location)
      || (clipboardPreview?.isVisible == true && clipboardPreview?.frame.contains(location) == true)
    {
      return
    }
    dismiss()
  }

  private func handleResignKey() {
    guard panel.isVisible, !model.pinned, !dismissing, !NSApp.isActive else { return }
    dismiss()
  }

  private func milliseconds(_ elapsed: Duration) -> Double {
    let parts = elapsed.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1_000_000_000_000_000
  }
}
