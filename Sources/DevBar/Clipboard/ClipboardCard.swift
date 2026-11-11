import AppKit
import SwiftUI

@MainActor final class ClipboardCard {
  let panel = NSPanel(
    contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
    defer: false)
  let temporaryKeys = ClipboardTemporaryKeys()
  var onMove: ((Bool) -> Void)?
  var onDismiss: (() -> Void)?
  var onConfirm: (() -> Void)?
  private let theme: ThemeManager
  private var pointer: NSPoint?
  private var dismissal: Task<Void, Never>?
  private var shakeTask: Task<Void, Never>?
  private(set) var lastShowMilliseconds = 0.0
  init(theme: ThemeManager) {
    self.theme = theme
    panel.level = .statusBar
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    temporaryKeys.onKey = { [weak self] key in
      if key == 36 || key == 76 {
        self?.dismiss()
        self?.onConfirm?()
      } else if key == 53 {
        self?.dismiss()
      } else {
        self?.onMove?(key == 123 || key == 126)
      }
    }
  }
  static func frame(pointer: NSPoint, size: NSSize, visible: NSRect) -> NSRect {
    let x = min(max(pointer.x - size.width / 2, visible.minX), visible.maxX - size.width)
    let y = min(max(pointer.y + 36 - 10, visible.minY), visible.maxY - size.height)
    return NSRect(x: x, y: y, width: size.width, height: size.height)
  }
  func show(
    index: Int, count: Int, title: String, subtitle: String, thumbnail: NSImage?, swatch: NSColor?,
    fileCount: Int, boundary: Bool
  ) {
    let started = ContinuousClock.now
    dismissal?.cancel()
    shakeTask?.cancel()
    let first = !panel.isVisible
    if first { pointer = NSEvent.mouseLocation }
    let image = DragCardImage.make(
      title: title, subtitle: subtitle, fileCount: fileCount, thumbnail: thumbnail, swatch: swatch,
      scheme: theme.effective, counter: "\(index+1) / \(count)", glass: true
    ).image
    let view = NSImageView(frame: NSRect(origin: .zero, size: image.size))
    view.image = image
    let container = NSView(frame: view.frame)
    let glass = NSVisualEffectView(frame: view.frame.insetBy(dx: 10, dy: 10))
    glass.material = .popover
    glass.blendingMode = .behindWindow
    glass.state = .active
    glass.wantsLayer = true
    glass.layer?.cornerRadius = 10
    glass.layer?.masksToBounds = true
    container.addSubview(glass)
    container.addSubview(view)
    panel.contentView = container
    panel.appearance = theme.appearance()
    let anchor = pointer ?? NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
      panel.setFrame(
        Self.frame(pointer: anchor, size: image.size, visible: screen.visibleFrame), display: true)
    }
    if first && !temporaryKeys.register() {
      dismiss()
      return
    }
    panel.alphaValue = 1
    panel.orderFrontRegardless()
    let elapsed = started.duration(to: .now).components
    lastShowMilliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    if boundary { shake() }
    dismissal = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1500))
      guard !Task.isCancelled, let self else { return }
      NSAnimationContext.runAnimationGroup(
        { context in
          context.duration = 0.2
          self.panel.animator().alphaValue = 0
        }, completionHandler: nil)
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled else { return }
      self.dismiss()
    }
  }
  func dismiss() {
    dismissal?.cancel()
    shakeTask?.cancel()
    temporaryKeys.unregister()
    panel.orderOut(nil)
    pointer = nil
    onDismiss?()
  }
  private func shake() {
    let origin = panel.frame.origin
    shakeTask = Task { [weak self] in
      for offset in [4.0, -4, 4, -4, 4, -4, 0] {
        guard !Task.isCancelled, let self else { return }
        self.panel.setFrameOrigin(NSPoint(x: origin.x + offset, y: origin.y))
        try? await Task.sleep(for: .nanoseconds(250_000_000 / 7))
      }
    }
  }
}
