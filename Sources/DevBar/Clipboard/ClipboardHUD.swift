import AppKit
import SwiftUI

@MainActor
final class ClipboardHUD {
  let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 420, height: 36),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  private var dismissal: Task<Void, Never>?
  private var shakeTask: Task<Void, Never>?
  private let theme: ThemeManager
  private(set) var lastShowMilliseconds = 0.0

  init(theme: ThemeManager) {
    self.theme = theme
    panel.level = .statusBar
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
  }

  func show(index: Int, count: Int, preview: String, thumbnail: NSImage?, boundary: Bool) {
    let started = ContinuousClock.now
    dismissal?.cancel()
    shakeTask?.cancel()
    panel.appearance = theme.appearance()
    panel.contentView = NSHostingView(
      rootView: HUDContent(
        theme: theme, index: index,
        count: count, preview: preview.components(separatedBy: .newlines).first ?? "",
        thumbnail: thumbnail))
    let screen =
      NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    if let frame = screen?.visibleFrame {
      panel.setFrame(
        NSRect(x: frame.midX - 210, y: frame.maxY - 48 - 36, width: 420, height: 36), display: true)
    }
    panel.alphaValue = 1
    panel.orderFrontRegardless()
    let elapsed = started.duration(to: .now).components
    lastShowMilliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    if boundary { shake() }
    dismissal = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1200))
      guard !Task.isCancelled, let self else { return }
      NSAnimationContext.runAnimationGroup(
        { context in
          context.duration = 0.2
          self.panel.animator().alphaValue = 0
        }, completionHandler: nil)
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled else { return }
      self.panel.orderOut(nil)
    }
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

private struct HUDContent: View {
  var theme: ThemeManager
  let index: Int
  let count: Int
  let preview: String
  let thumbnail: NSImage?
  var body: some View {
    let scheme = theme.effective
    HStack(spacing: 8) {
      Text("\(index + 1) / \(count)").monospacedDigit()
        .foregroundStyle(DesignTokens.textSecondary(scheme))
      if let thumbnail {
        Image(nsImage: thumbnail).resizable().scaledToFit().frame(width: 20, height: 20)
      }
      Text(preview).foregroundStyle(DesignTokens.textPrimary(scheme))
      Spacer(minLength: 0)
    }
    .font(.system(size: 13)).lineLimit(1).padding(.horizontal, 14)
    .frame(height: 36)
    .background {
      if theme.reduceTransparency {
        Capsule().fill(DesignTokens.opaqueBackdrop(scheme))
          .overlay(Capsule().fill(DesignTokens.panelBase(scheme)))
      } else {
        Capsule().fill(Color.clear).glassEffect(.regular, in: Capsule())
          .overlay(Capsule().fill(DesignTokens.panelGlassTint(scheme)))
      }
    }
    .overlay(Capsule().strokeBorder(DesignTokens.lineBorder(scheme), lineWidth: 0.7))
    .environment(\.colorScheme, scheme)
  }
}
