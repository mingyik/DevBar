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
  private var caret: NSRect?
  private var locationTask: Task<Void, Never>?
  private var locationGeneration = 0
  private var locationTarget: pid_t?
  private var clickMonitor: Any?
  private let focusedProcess: () -> pid_t?
  private let caretBounds: (pid_t) async -> CGRect?
  private var dismissal: Task<Void, Never>?
  private var shakeTask: Task<Void, Never>?
  private(set) var isAuthorizationNoticeVisible = false
  private(set) var lastShowMilliseconds = 0.0
  init(
    theme: ThemeManager,
    focusedProcess: @escaping () -> pid_t? = {
      NSWorkspace.shared.frontmostApplication?.processIdentifier
    },
    caretBounds: @escaping (pid_t) async -> CGRect? = { target in
      await Task.detached(priority: .userInitiated) {
        ClipboardCaretLocator.bounds(for: target)
      }.value
    }
  ) {
    self.theme = theme
    self.focusedProcess = focusedProcess
    self.caretBounds = caretBounds
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    temporaryKeys.onKey = { [weak self] key in
      if key == 36 || key == 76 {
        self?.dismiss(notifying: false)
        self?.onConfirm?()
        self?.onDismiss?()
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
  static func caretFrame(caret: NSRect, size: NSSize, visible: NSRect) -> NSRect {
    let gap: CGFloat = 32
    let x = min(max(caret.midX - size.width / 2, visible.minX), visible.maxX - size.width)
    let above = caret.maxY + gap
    let below = caret.minY - gap - size.height
    let y = above + size.height <= visible.maxY ? above : below
    return NSRect(
      x: x, y: min(max(y, visible.minY), visible.maxY - size.height),
      width: size.width, height: size.height)
  }
  static func fallbackFrame(pointer: NSPoint, size: NSSize, visible: NSRect) -> NSRect {
    guard visible.contains(pointer) else {
      return centeredFrame(
        center: NSPoint(x: visible.midX, y: visible.midY), size: size, visible: visible)
    }
    return frame(pointer: pointer, size: size, visible: visible)
  }
  func show(index: Int, count: Int, content: ClipCardContent, boundary: Bool, target: pid_t? = nil)
  {
    show(
      index: index, count: count, title: content.title, subtitle: content.subtitle,
      thumbnail: content.icon, swatch: content.swatch, fileCount: content.stack,
      boundary: boundary, footer: content.note, multilineContent: content.multiline,
      tag: content.tag, target: target)
  }
  func show(
    index: Int, count: Int, title: String, subtitle: String, thumbnail: NSImage?, swatch: NSColor?,
    fileCount: Int, boundary: Bool, footer: String? = nil, multilineContent: Bool = false,
    tag: String? = nil, target: pid_t? = nil
  ) {
    let started = ContinuousClock.now
    dismissal?.cancel()
    shakeTask?.cancel()
    isAuthorizationNoticeVisible = false
    let first = !panel.isVisible
    if first {
      pointer = NSEvent.mouseLocation
      caret = nil
    }
    let image = DragCardImage.make(
      title: title, subtitle: subtitle, fileCount: fileCount, thumbnail: thumbnail, swatch: swatch,
      scheme: theme.effective, glass: true, footer: footer,
      multilineContent: multilineContent, tag: tag
    ).image
    install(image)
    positionCard(size: image.size)
    if first && !temporaryKeys.register() {
      dismiss()
      return
    }
    panel.alphaValue = 1
    panel.orderFrontRegardless()
    if first { trackLocation(target: target) }
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

  private func positionCard(size requestedSize: NSSize? = nil) {
    let anchor = pointer ?? NSEvent.mouseLocation
    let size = requestedSize ?? panel.frame.size
    if let caret,
      let screen = NSScreen.screens.first(where: {
        $0.frame.contains(NSPoint(x: caret.midX, y: caret.midY))
      })
    {
      panel.setFrame(
        Self.caretFrame(caret: caret, size: size, visible: screen.visibleFrame), display: true
      )
    } else if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) {
      panel.setFrame(
        Self.frame(pointer: anchor, size: size, visible: screen.visibleFrame), display: true)
    } else if let screen = NSScreen.main ?? NSScreen.screens.first {
      panel.setFrame(
        Self.fallbackFrame(pointer: anchor, size: size, visible: screen.visibleFrame),
        display: true)
    }
  }

  private func trackLocation(target: pid_t?) {
    locationTask?.cancel()
    locationGeneration += 1
    locationTarget = target
    guard let target, target != ProcessInfo.processInfo.processIdentifier else { return }
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) {
      [weak self] _ in
      Task { @MainActor in
        guard let self, self.panel.isVisible, !self.isAuthorizationNoticeVisible else { return }
        self.pointer = NSEvent.mouseLocation
      }
    }
    locationTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.panel.isVisible, !self.isAuthorizationNoticeVisible else { return }
        await self.refreshLocation()
        do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
      }
    }
  }

  func refreshLocation() async {
    guard panel.isVisible, !isAuthorizationNoticeVisible,
      let target = locationTarget
    else { return }
    guard focusedProcess() == target else {
      dismiss()
      return
    }
    let generation = locationGeneration
    let bounds = await caretBounds(target)
    guard !Task.isCancelled, locationGeneration == generation,
      panel.isVisible, !isAuthorizationNoticeVisible, focusedProcess() == target
    else { return }
    if let bounds, let primary = NSScreen.screens.first {
      let converted = NSRect(
        x: bounds.minX, y: primary.frame.maxY - bounds.maxY,
        width: bounds.width, height: bounds.height)
      guard
        NSScreen.screens.contains(where: {
          $0.frame.contains(NSPoint(x: converted.midX, y: converted.midY))
        })
      else {
        caret = nil
        shakeTask?.cancel()
        positionCard()
        return
      }
      guard caret != converted else { return }
      caret = converted
      shakeTask?.cancel()
      positionCard()
    } else {
      caret = nil
      shakeTask?.cancel()
      positionCard()
    }
  }

  func showAuthorizationNotice(title: String, subtitle: String) {
    dismissal?.cancel()
    shakeTask?.cancel()
    temporaryKeys.unregister()
    isAuthorizationNoticeVisible = true
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    clickMonitor = nil
    locationTask?.cancel()
    locationGeneration += 1
    let image = DragCardImage.make(
      title: title, subtitle: subtitle, fileCount: 0, thumbnail: nil, swatch: nil,
      scheme: theme.effective, glass: true
    ).image
    let oldFrame = panel.frame
    install(image)
    let screen = NSScreen.screens.first(where: { $0.frame.intersects(oldFrame) }) ?? NSScreen.main
    let visible = screen?.visibleFrame ?? oldFrame
    let frame = Self.centeredFrame(
      center: NSPoint(x: oldFrame.midX, y: oldFrame.midY), size: image.size, visible: visible)
    panel.setFrame(frame, display: true)
    panel.alphaValue = 1
    panel.orderFrontRegardless()
    dismissal = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(2300))
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
    dismiss(notifying: true)
  }

  private func dismiss(notifying: Bool) {
    dismissal?.cancel()
    shakeTask?.cancel()
    temporaryKeys.unregister()
    panel.orderOut(nil)
    pointer = nil
    caret = nil
    locationGeneration += 1
    locationTask?.cancel()
    locationTask = nil
    locationTarget = nil
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    clickMonitor = nil
    isAuthorizationNoticeVisible = false
    if notifying { onDismiss?() }
  }

  private func install(_ image: NSImage) {
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
  }

  private static func centeredFrame(center: NSPoint, size: NSSize, visible: NSRect) -> NSRect {
    let x = min(max(center.x - size.width / 2, visible.minX), visible.maxX - size.width)
    let y = min(max(center.y - size.height / 2, visible.minY), visible.maxY - size.height)
    return NSRect(x: x, y: y, width: size.width, height: size.height)
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
