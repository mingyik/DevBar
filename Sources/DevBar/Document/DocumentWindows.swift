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
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  @objc func _hasActiveAppearance() -> Bool { true }
  @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
}

@MainActor
final class DocumentEditorPanel: NSPanel {
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
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  @objc func _hasActiveAppearance() -> Bool { true }
  @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
}

struct DocumentEditorSurface: View {
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
  let editorHost: WebHost
  private let theme: ThemeManager
  private let session: DocumentSession
  private let browser: DocumentBrowser
  private let editorPanel = DocumentEditorPanel()
  private let sidebarPanel = DocumentSidebarPanel()
  private let sidebarWidth: CGFloat = 260
  private let sidebarHeight: CGFloat = 460
  private let editorWidth: CGFloat = 480
  private let editorHeight: CGFloat = 600
  private let gap: CGFloat = 8
  private(set) var sidebarVisible = false
  var isEditorVisible: Bool { editorPanel.isVisible }

  func owns(_ window: NSWindow?) -> Bool {
    guard let window else { return false }
    return window === editorPanel || window === sidebarPanel
  }

  func contains(_ point: NSPoint) -> Bool {
    if editorPanel.isVisible, editorPanel.frame.contains(point) { return true }
    if sidebarVisible, sidebarPanel.frame.contains(point) { return true }
    return false
  }

  init(
    theme: ThemeManager, session: DocumentSession, browser: DocumentBrowser,
    editorHost: WebHost
  ) {
    self.theme = theme
    self.session = session
    self.browser = browser
    self.editorHost = editorHost
    editorPanel.contentView = NSHostingView(
      rootView: DocumentEditorSurface(theme: theme, host: editorHost))
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
    result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
    result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
    return result
  }

  func position(mainFrame: NSRect, visible: NSRect, animated: Bool = false) {
    if sidebarVisible {
      let x = min(
        max(mainFrame.minX - gap - sidebarWidth, visible.minX),
        visible.maxX - sidebarWidth)
      let height = min(max(sidebarHeight, mainFrame.height), visible.height)
      let y = min(max(mainFrame.maxY - height, visible.minY), visible.maxY - height)
      let frame = NSRect(x: x, y: y, width: sidebarWidth, height: height)
      if sidebarPanel.frame != frame {
        setFrame(sidebarPanel, frame, animated: animated)
      }
      sidebarPanel.appearance = theme.appearance()
    }
    guard editorPanel.isVisible else { return }
    let available = mainFrame.minX - gap - visible.minX
    let width = min(editorWidth, max(240, available))
    let x = max(visible.minX, mainFrame.minX - gap - width)
    let height = min(editorHeight, visible.height)
    let y = min(max(mainFrame.maxY - height, visible.minY), visible.maxY - height)
    let frame = NSRect(x: x, y: y, width: width, height: height)
    if editorPanel.frame != frame {
      setFrame(editorPanel, frame, animated: animated)
    }
  }

  private func setFrame(_ panel: NSPanel, _ frame: NSRect, animated: Bool) {
    guard animated else {
      panel.setFrame(frame, display: true)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      panel.animator().setFrame(frame, display: true)
    }
  }

  func showEditor(text: String, mode: String) {
    editorPanel.appearance = theme.appearance()
    editorHost.setPanelVisible(true)
    editorHost.syncAppearance(panelSize: "normal")
    editorHost.sendEditorInit(text: text, mode: mode)
    editorPanel.makeKeyAndOrderFront(nil)
  }

  func hideEditor() {
    guard editorPanel.isVisible else { return }
    editorPanel.orderOut(nil)
    editorHost.setPanelVisible(false)
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

  func showSidebar() {
    guard !sidebarVisible else { return }
    sidebarVisible = true
    sidebarPanel.appearance = theme.appearance()
    sidebarPanel.orderFrontRegardless()
  }

  func closeSidebar() {
    guard sidebarVisible else { return }
    sidebarVisible = false
    sidebarPanel.orderOut(nil)
  }

  func hideAll() {
    hideEditor()
    closeSidebar()
  }
}
