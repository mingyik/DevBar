import AppKit
import WebKit

@MainActor
final class PreviewExportPanel: NSPanel, WKNavigationDelegate {
  enum Selection {
    case cancelled
    case confirmed(CGFloat)
    case failed
  }

  private let preview: WKWebView
  private let document: String
  private var loadContinuation: CheckedContinuation<Bool, Never>?
  private var selectionContinuation: CheckedContinuation<Selection, Never>?

  init(
    document: String, width: CGFloat, maximumWidth: CGFloat, height: CGFloat,
    visibleFrame: NSRect, theme: String
  ) {
    let windowFrame = NSRect(
      x: visibleFrame.midX - width / 2,
      y: visibleFrame.midY - height / 2,
      width: width,
      height: height)
    let contentFrame = NSRect(origin: .zero, size: windowFrame.size)
    self.document = document
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    preview = WKWebView(frame: contentFrame, configuration: configuration)

    super.init(
      contentRect: windowFrame,
      styleMask: [.borderless, .resizable],
      backing: .buffered,
      defer: false)

    appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isMovableByWindowBackground = false
    minSize = NSSize(width: min(420, maximumWidth), height: height)
    maxSize = NSSize(width: maximumWidth, height: height)
    resizeIncrements = NSSize(width: 1, height: 0)

    let root = NSView(frame: contentFrame)
    root.autoresizingMask = [.width, .height]
    preview.translatesAutoresizingMaskIntoConstraints = false
    preview.navigationDelegate = self

    let toolbar = makeToolbar()
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(preview)
    root.addSubview(toolbar)
    NSLayoutConstraint.activate([
      preview.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      preview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      preview.topAnchor.constraint(equalTo: root.topAnchor),
      preview.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      toolbar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
      toolbar.widthAnchor.constraint(equalToConstant: 116),
      toolbar.heightAnchor.constraint(equalToConstant: 48),
    ])
    contentView = root
  }

  func chooseWidth() async -> Selection {
    let loaded = await withCheckedContinuation { continuation in
      loadContinuation = continuation
      preview.loadHTMLString(document, baseURL: nil)
    }
    guard loaded else { return .failed }

    return await withCheckedContinuation { continuation in
      selectionContinuation = continuation
      makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      finish(.cancelled)
      return
    }
    super.keyDown(with: event)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    loadContinuation?.resume(returning: true)
    loadContinuation = nil
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    loadContinuation?.resume(returning: false)
    loadContinuation = nil
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    loadContinuation?.resume(returning: false)
    loadContinuation = nil
  }

  @objc private func cancelExport() { finish(.cancelled) }

  @objc private func confirmExport() {
    finish(.confirmed(contentView?.bounds.width ?? frame.width))
  }

  private func finish(_ selection: Selection) {
    guard let continuation = selectionContinuation else { return }
    selectionContinuation = nil
    orderOut(nil)
    continuation.resume(returning: selection)
  }

  private func makeToolbar() -> NSVisualEffectView {
    let toolbar = NSVisualEffectView()
    toolbar.material = .hudWindow
    toolbar.blendingMode = .withinWindow
    toolbar.state = .active
    toolbar.wantsLayer = true
    toolbar.layer?.cornerRadius = 14
    toolbar.layer?.borderWidth = 0.7
    toolbar.layer?.borderColor = NSColor.separatorColor.cgColor

    let stack = NSStackView(views: [
      makeButton(symbol: "xmark", label: "取消", action: #selector(cancelExport)),
      makeButton(symbol: "checkmark", label: "保存图片", action: #selector(confirmExport)),
    ])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .fillEqually
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    toolbar.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
      stack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 4),
      stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -4),
    ])
    return toolbar
  }

  private func makeButton(symbol: String, label: String, action: Selector) -> NSButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
    let button = NSButton(image: image, target: self, action: action)
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.contentTintColor = .labelColor
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.image = button.image?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
    return button
  }
}
