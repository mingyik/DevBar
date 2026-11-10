import AppKit
import DevBarCore
import os
import SwiftUI

@MainActor
final class PanelController {
  let model: PanelModel
  let theme: ThemeManager
  let panel: DevBarPanel
  private let host: NSHostingView<PanelView>
  private var outsideMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var dismissing = false
  private var lastAnchor: CGRect?
  private let logger = Logger(subsystem: "local.devbar.app", category: "panel")
  private let signposter = OSSignposter(subsystem: "local.devbar.app", category: "panel")

  init(theme: ThemeManager) {
    let model = PanelModel()
    self.model = model
    self.theme = theme
    panel = DevBarPanel()
    host = NSHostingView(rootView: PanelView(model: model, theme: theme))
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
    outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
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
    panel.appearance = theme.appearance()
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
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = DesignTokens.radiusLarge
    effect.layer?.masksToBounds = true
    host.translatesAutoresizingMaskIntoConstraints = false
    effect.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.addSubview(effect)
    container.addSubview(host)
    panel.contentView = container
    NSLayoutConstraint.activate([
      effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      effect.topAnchor.constraint(equalTo: container.topAnchor),
      effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      host.topAnchor.constraint(equalTo: container.topAnchor),
      host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
  }

  private func watchSize() {
    withObservationTracking {
      _ = model.enlarged
      _ = model.page
      _ = theme.mode
      _ = theme.systemScheme
      _ = theme.increaseContrast
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.panel.appearance = self?.theme.appearance()
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
