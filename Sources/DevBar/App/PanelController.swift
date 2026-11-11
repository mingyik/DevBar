import AppKit
import DevBarCore
import SwiftUI
import os

@MainActor
final class PanelController {
  let model: PanelModel
  let theme: ThemeManager
  let panel: DevBarPanel
  let webHost: WebHost
  let clipboard: ClipboardController
  private let host: NSHostingView<PanelView>
  private var outsideMonitor: Any?
  private var activationObserver: NSObjectProtocol?
  private var resignObserver: NSObjectProtocol?
  private var dismissing = false
  private var lastAnchor: CGRect?
  private var clipboardPreview: NSPanel?
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
        startMonitoring: !SelfCheckEnvironment.isActive)
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
      rootView: PanelView(model: model, theme: theme, webHost: webHost, clipboard: clipboard))
    clipboard.onHoverPreview = { [weak self] id in
      self?.showClipboardPreview(id)
    }
    webHost.onToast = { text in
      model.toast = text
    }
    webHost.onClipboardWrite = { [weak clipboard] count in clipboard?.monitor.markSelfWrite(count) }
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
    model.page = page
    show(anchor: anchor)
  }

  func show(anchor: CGRect?, activateApplication: Bool = true) {
    let interval = signposter.beginInterval("openPanel")
    let started = ContinuousClock.now
    if let anchor {
      lastAnchor = anchor
    }
    updateMaterial()
    reposition()
    if activateApplication {
      panel.makeKeyAndOrderFront(nil)
      NSApp.activate()
    } else {
      panel.orderFrontRegardless()
    }
    webHost.panelVisible = true
    Task { await clipboard.monitor.poll() }
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
    previewPointerInside = false
    clipboardPreview?.orderOut(nil)
    webHost.panelVisible = false
    dismissing = false
  }

  func showSettings(anchor: CGRect?) {
    model.enterSettings()
    if panel.isVisible {
      if let anchor {
        lastAnchor = anchor
      }
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
          self.clipboardPreview?.orderOut(nil)
          return
        }
        try? await Task.sleep(for: .milliseconds(120))
      }
    }
  }

  private func showClipboardPreview(_ id: UUID?) {
    guard panel.isVisible, model.page == .clipboard else {
      previewHideTask?.cancel()
      previewPointerInside = false
      clipboardPreview?.orderOut(nil)
      return
    }
    guard let id else {
      schedulePreviewHide()
      return
    }
    guard let item = clipboard.items.first(where: { $0.id == id }),
      let screen = panel.screen ?? NSScreen.main
    else {
      clipboardPreview?.orderOut(nil)
      return
    }
    previewHideTask?.cancel()
    previewPointerInside = false
    let visible = screen.visibleFrame
    let width = min(300, panel.frame.width - 20, visible.width)
    let previewContent = ClipboardHoverPreview(
      item: item, payloads: clipboard.originals[id] ?? [], scheme: theme.effective, theme: theme,
      onHoverChange: { [weak self] inside in
        guard let self else { return }
        self.previewPointerInside = inside
        if inside {
          self.previewHideTask?.cancel()
        } else {
          self.schedulePreviewHide()
        }
      })
    let height = previewContent.preferredHeight(width: width, maximum: visible.height * 2 / 3)
    let left = panel.frame.minX - width - 6
    let right = panel.frame.maxX + 6
    let x = left >= visible.minX ? left : min(right, visible.maxX - width)
    let y = min(max(panel.frame.maxY - height, visible.minY), visible.maxY - height)
    let frame = NSRect(x: x, y: y, width: width, height: height)
    let preview =
      clipboardPreview
      ?? NSPanel(
        contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
    preview.level = .popUpMenu
    preview.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    preview.backgroundColor = .clear
    preview.isOpaque = false
    preview.hasShadow = true
    preview.hidesOnDeactivate = false
    preview.ignoresMouseEvents = false
    preview.appearance = theme.appearance()
    preview.contentView = NSHostingView(rootView: previewContent)
    preview.setFrame(frame, display: true)
    clipboardPreview = preview
    preview.orderFrontRegardless()
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
      previewPointerInside = false
      clipboardPreview?.orderOut(nil)
    }
    panel.appearance = theme.appearance()
    webHost.panelVisible = panel.isVisible
    webHost.syncAppearance(
      panelSize: model.enlarged && model.showsEnlarge ? "large" : "normal",
      autoImport: model.autoImport)
    if model.page == .json || model.page == .qr {
      webHost.showScreen(model.page.rawValue)
    } else if model.page == .doc {
      webHost.showScreen("doc")
    }
  }

  private func watchSize() {
    withObservationTracking {
      _ = model.dropActive
      _ = model.autoImport
      _ = model.enlarged
      _ = model.page
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

  private func reposition() {
    let screens = NSScreen.screens.map {
      PanelLayout.DisplaySlice(frame: $0.frame, visibleFrame: $0.visibleFrame)
    }
    let mouse = NSEvent.mouseLocation
    let mouseScreen =
      NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    let placed = PanelLayout.placement(
      anchor: lastAnchor, screens: screens, fallbackVisible: mouseScreen.visibleFrame)
    let frame = PanelLayout.frame(
      iconCenterX: placed.centerX, menuBarBottomY: placed.menuBottom,
      size: model.panelSize, visibleFrame: placed.visible)
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
