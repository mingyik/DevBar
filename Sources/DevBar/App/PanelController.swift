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
      self?.dismiss()
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

  func show(anchor: CGRect?) {
    let interval = signposter.beginInterval("openPanel")
    let started = ContinuousClock.now
    if let anchor {
      lastAnchor = anchor
    }
    updateMaterial()
    reposition()
    panel.makeKeyAndOrderFront(nil)
    webHost.panelVisible = true
    NSApp.activate()
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
    panel.appearance = theme.appearance()
    webHost.panelVisible = panel.isVisible
    webHost.syncAppearance(panelSize: model.enlarged && model.showsEnlarge ? "large" : "normal")
    if model.page == .json || model.page == .qr {
      webHost.showScreen(model.page.rawValue)
    } else if model.page == .doc {
      webHost.showScreen("doc")
    }
  }

  private func watchSize() {
    withObservationTracking {
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
    let visible = screen(for: lastAnchor).visibleFrame
    let iconCenterX = lastAnchor?.midX ?? visible.midX
    let menuBottom = lastAnchor?.minY ?? visible.maxY
    let frame = PanelLayout.frame(
      iconCenterX: iconCenterX, menuBarBottomY: menuBottom,
      size: model.panelSize, visibleFrame: visible)
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = panel.isVisible ? 0.15 : 0
        panel.animator().setFrame(frame, display: true)
      }, completionHandler: nil)
  }

  private func screen(for anchor: CGRect?) -> NSScreen {
    if let anchor, let match = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
      return match
    }
    return NSScreen.main ?? NSScreen.screens[0]
  }

  private func handleOutsideClick() {
    guard panel.isVisible, !model.pinned else { return }
    if panel.frame.contains(NSEvent.mouseLocation) {
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
