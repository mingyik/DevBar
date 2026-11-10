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
  private let host: NSHostingView<PanelView>
  private var outsideMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var dismissing = false
  private var lastAnchor: CGRect?
  private let logger = Logger(subsystem: "local.devbar.app", category: "panel")
  private let signposter = OSSignposter(subsystem: "local.devbar.app", category: "panel")

  init(theme: ThemeManager) {
    let model = PanelModel()
    let webHost = WebHost(theme: theme)
    self.model = model
    self.theme = theme
    self.webHost = webHost
    panel = DevBarPanel()
    host = NSHostingView(rootView: PanelView(model: model, theme: theme, webHost: webHost))
    webHost.onToast = { text in
      model.toast = text
    }
    installChrome()
    panel.onEscape = { [weak self] in
      self?.dismiss()
    }
    panel.onSelectPage = { [weak self] index in
      guard let page = PanelModel.Page(rawValue: index) else { return }
      self?.model.page = page
      self?.reposition()
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
      show(anchor: anchor)
    }
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
    NSApp.activate()
    let elapsed = started.duration(to: .now)
    let milliseconds = milliseconds(elapsed)
    signposter.endInterval("openPanel", interval)
    logger.notice("panelOpenMs=\(milliseconds, privacy: .public)")
  }

  func dismiss() {
    guard panel.isVisible, !dismissing else { return }
    dismissing = true
    panel.orderOut(nil)
    dismissing = false
  }

  func showSettings(anchor: CGRect?) {
    model.page = .settings
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
    if model.page == .tools {
      webHost.showScreen("tools")
    } else if model.page == .document {
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
    let enlarged = model.enlarged && model.showsEnlarge
    panel.setFrame(
      PanelLayout.frame(
        iconCenterX: iconCenterX,
        menuBarBottomY: menuBottom,
        enlarged: enlarged,
        visibleFrame: visible
      ),
      display: true
    )
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
