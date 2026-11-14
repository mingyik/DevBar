import AppKit
import SwiftUI

@MainActor
final class DocumentSidebarPanel: NSPanel {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 460),
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    hidesOnDeactivate = false
    animationBehavior = .none
  }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  @objc func _hasActiveAppearance() -> Bool { true }
  @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
}

@MainActor
final class DocumentPreviewPanel: NSPanel {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    hidesOnDeactivate = false
    animationBehavior = .none
  }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  @objc func _hasActiveAppearance() -> Bool { true }
  @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
}

struct DocumentPreviewSurface: View {
  let theme: ThemeManager
  let host: WebHost
  var body: some View {
    DocumentWebViewBox(host: host)
      .background { PanelChrome(theme: theme, scheme: theme.effective) }
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous))
      .environment(\.colorScheme, theme.effective)
  }
}

struct DocumentSidebarSurface: View {
  let theme: ThemeManager
  let session: DocumentSession
  let browser: DocumentBrowser
  let onOpen: (URL) -> Void
  let onPick: () -> Void
  var body: some View {
    DocumentSidebarView(
      theme: theme, session: session, browser: browser, onOpen: onOpen, onPick: onPick
    )
    .background { PanelChrome(theme: theme, scheme: theme.effective) }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous))
  }
}

private struct DocumentWebViewBox: NSViewRepresentable {
  let host: WebHost
  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    mount(host.webView, in: container)
    return container
  }
  func updateNSView(_ container: NSView, context: Context) {
    if container.subviews.first !== host.webView {
      for subview in container.subviews { subview.removeFromSuperview() }
      mount(host.webView, in: container)
    }
  }
  private func mount(_ view: NSView, in container: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      view.topAnchor.constraint(equalTo: container.topAnchor),
      view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
  }
}

/// Owns the two auxiliary Markdown windows and keeps them aligned with the
/// main panel without ever placing them off the visible frame.
@MainActor
final class DocumentWindows {
  let previewHost: WebHost
  private let theme: ThemeManager
  private let session: DocumentSession
  private let browser: DocumentBrowser
  private let previewPanel = DocumentPreviewPanel()
  private let sidebarPanel = DocumentSidebarPanel()
  private let sidebarWidth: CGFloat = 260
  private let sidebarHeight: CGFloat = 460
  private let gap: CGFloat = 8
  private(set) var sidebarVisible = false
  var splitActive = false
  var isPreviewVisible: Bool { previewPanel.isVisible }

  init(
    theme: ThemeManager, session: DocumentSession, browser: DocumentBrowser,
    previewHost: WebHost
  ) {
    self.theme = theme
    self.session = session
    self.browser = browser
    self.previewHost = previewHost
    previewPanel.contentView = NSHostingView(
      rootView: DocumentPreviewSurface(theme: theme, host: previewHost))
    sidebarPanel.contentView = NSHostingView(
      rootView: DocumentSidebarSurface(
        theme: theme, session: session, browser: browser,
        onOpen: { [weak self] url in self?.onOpen?(url) },
        onPick: { [weak self] in self?.onPick?() }))
  }

  var onOpen: ((URL) -> Void)?
  var onPick: (() -> Void)?

  func adjustedMainFrame(_ frame: NSRect, visible: NSRect) -> NSRect {
    var result = frame
    if sidebarVisible {
      let left = result.minX - gap - sidebarWidth
      if left < visible.minX {
        let shift = visible.minX - left
        result.origin.x = min(result.minX + shift, visible.maxX - result.width)
      }
    }
    if splitActive {
      let minimumPreview: CGFloat = 320
      let needed = result.width + gap + minimumPreview
      if result.minX + needed > visible.maxX {
        result.origin.x = max(visible.minX, visible.maxX - needed)
      }
    }
    result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
    result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
    return result
  }

  func position(mainFrame: NSRect, visible: NSRect) {
    if sidebarVisible {
      let x = min(
        max(mainFrame.minX - gap - sidebarWidth, visible.minX),
        visible.maxX - sidebarWidth)
      let height = min(max(sidebarHeight, mainFrame.height), visible.height)
      let y = min(max(mainFrame.maxY - height, visible.minY), visible.maxY - height)
      let frame = NSRect(x: x, y: y, width: sidebarWidth, height: height)
      if sidebarPanel.frame != frame { sidebarPanel.setFrame(frame, display: true) }
      sidebarPanel.appearance = theme.appearance()
    }
    guard previewPanel.isVisible else { return }
    let x = min(mainFrame.maxX + gap, visible.maxX - 240)
    let available = visible.maxX - x
    let width = min(max(320, mainFrame.width), max(240, available))
    let height = min(mainFrame.height, visible.height)
    let y = min(max(mainFrame.maxY - height, visible.minY), visible.maxY - height)
    let frame = NSRect(x: x, y: y, width: width, height: height)
    if previewPanel.frame != frame { previewPanel.setFrame(frame, display: true) }
  }

  func showPreview(text: String, mode: String) {
    previewPanel.appearance = theme.appearance()
    previewHost.setPanelVisible(true)
    previewHost.syncAppearance(panelSize: "normal")
    previewHost.sendDocumentPreview(text: text, mode: mode)
    previewPanel.orderFrontRegardless()
  }

  func hidePreview() {
    guard previewPanel.isVisible else { return }
    previewPanel.orderOut(nil)
    previewHost.setPanelVisible(false)
  }

  func toggleSidebar() {
    sidebarVisible.toggle()
    if sidebarVisible {
      sidebarPanel.appearance = theme.appearance()
      sidebarPanel.orderFrontRegardless()
    } else {
      sidebarPanel.orderOut(nil)
    }
  }

  func closeSidebar() {
    guard sidebarVisible else { return }
    sidebarVisible = false
    sidebarPanel.orderOut(nil)
  }

  func hideAll() {
    hidePreview()
    closeSidebar()
  }
}
