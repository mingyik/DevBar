import AppKit
import WebKit
import os

/// Full-page preview PNG. A rect taller than the live WKWebView does not paint
/// content outside that view, so export loads the measured markup into an
/// offscreen web view sized to the content. R9's document page uses the same path.
@MainActor final class PreviewImage: NSObject, WKNavigationDelegate {
  private let logger = Logger(subsystem: "local.devbar.app", category: "preview")
  private var savedPaths = Set<String>()
  private var busy = false
  private var canvas: WKWebView?
  private var loadContinuation: CheckedContinuation<Bool, Never>?
  private var loadGeneration = 0
  var writesClipboard = true
  private(set) var lastSavedPath: String?

  static func dimensions(width: Double, height: Double) -> (Int, Int)? {
    guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 8192, height <= 8192
    else { return nil }
    let w = Int(ceil(width * 2))
    let h = Int(ceil(height * 2))
    guard w <= 16384, h <= 16384, w * h <= 64_000_000 else { return nil }
    return (w, h)
  }

  /// `snapshotWidth` is in points. Divide the wanted pixel width by the screen
  /// scale so the bitmap is 2× the CSS size on both 1× and 2× displays.
  static func snapshotPointWidth(pixels: Int, scale: CGFloat) -> CGFloat {
    CGFloat(pixels) / (scale > 0 ? scale : 2)
  }

  static func destination(directory: URL, now: Date, exists: (String) -> Bool) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let base = "DevBar 截图 \(formatter.string(from: now))"
    var url = directory.appending(path: "\(base).png")
    var index = 2
    while exists(url.path) {
      url = directory.appending(path: "\(base) (\(index)).png")
      index += 1
    }
    return url
  }

  static func snapshotDocument(html: String, css: String, theme: String, background: String)
    -> String
  {
    let safeTheme = theme == "dark" ? "dark" : "light"
    let safeCSS = css.replacingOccurrences(
      of: "</style", with: "<\\/style", options: .caseInsensitive)
    let backdrop =
      sanitizedHex(background).map { "html,body{background:\($0)}" }
      ?? "html,body{background:var(--snapshot-background)}"
    return """
      <!doctype html><html data-theme="\(safeTheme)"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; script-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><style>
      \(safeCSS)
      \(backdrop)
      html,body{margin:0}
      html body .snapshot-root{display:block;visibility:visible;position:static;left:auto;top:auto}
      </style></head><body>\(html)</body></html>
      """
  }

  func export(
    page: String,
    width: Double,
    height: Double,
    html: String,
    css: String,
    theme: String,
    background: String,
    directory: URL? = nil, host: NSView? = nil
  ) async -> String {
    guard page == "json" || page == "doc", !busy, !html.isEmpty else {
      return #"{"status":"failed"}"#
    }
    guard Self.dimensions(width: width, height: height) != nil else {
      return #"{"status":"tooLarge"}"#
    }
    busy = true
    defer { busy = false }
    guard let host = host ?? NSApp?.keyWindow?.contentView else { return #"{"status":"failed"}"# }
    let view = ensureCanvas(width: width, height: height, host: host)
    let loaded = await load(
      Self.snapshotDocument(html: html, css: css, theme: theme, background: background), in: view)
    guard loaded else { return #"{"status":"failed"}"# }
    try? await Task.sleep(for: .milliseconds(200))
    let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    guard let pixels = Self.dimensions(width: width, height: height) else {
      return #"{"status":"tooLarge"}"#
    }
    let config = WKSnapshotConfiguration()
    config.rect = CGRect(x: 0, y: 0, width: width, height: height)
    config.snapshotWidth = NSNumber(
      value: Double(Self.snapshotPointWidth(pixels: pixels.0, scale: scale)))
    config.afterScreenUpdates = true
    do {
      let image = try await view.takeSnapshot(configuration: config)
      guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        bitmap.pixelsWide <= 16384, bitmap.pixelsHigh <= 16384,
        bitmap.pixelsWide * bitmap.pixelsHigh <= 64_000_000,
        let data = bitmap.representation(using: .png, properties: [:])
      else { return #"{"status":"failed"}"# }
      let folder =
        directory ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
      let file = Self.destination(directory: folder, now: Date()) {
        FileManager.default.fileExists(atPath: $0)
      }
      try data.write(to: file, options: .atomic)
      if writesClipboard { PasteboardBridge.writePNG(data, file: file) }
      savedPaths.insert(file.path)
      lastSavedPath = file.path
      logger.notice(
        "previewImage px=\(bitmap.pixelsWide, privacy: .public)x\(bitmap.pixelsHigh, privacy: .public) bytes=\(data.count, privacy: .public)"
      )
      return BridgeJSON.object(["status": .string("saved"), "path": .string(file.path)]).canonical()
    } catch {
      logger.error("previewImageFailed")
      return #"{"status":"failed"}"#
    }
  }

  func reveal(path: String) {
    guard savedPaths.contains(path) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  private func ensureCanvas(width: Double, height: Double, host: NSView) -> WKWebView {
    let size = NSSize(width: width, height: height)
    if let canvas {
      canvas.setFrameSize(size)
      if canvas.superview !== host {
        canvas.removeFromSuperview()
        host.addSubview(canvas, positioned: .below, relativeTo: nil)
      }
      return canvas
    }
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
    view.navigationDelegate = self
    view.setFrameOrigin(NSPoint(x: -20000, y: 0))
    host.addSubview(view, positioned: .below, relativeTo: nil)
    canvas = view
    return view
  }

  private func load(_ html: String, in view: WKWebView) async -> Bool {
    loadGeneration += 1
    let generation = loadGeneration
    return await withCheckedContinuation { continuation in
      finishLoad(false)
      loadContinuation = continuation
      view.loadHTMLString(html, baseURL: nil)
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(30))
        guard generation == self.loadGeneration else { return }
        self.finishLoad(false)
      }
    }
  }

  private func finishLoad(_ ok: Bool) {
    loadContinuation?.resume(returning: ok)
    loadContinuation = nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    finishLoad(true)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finishLoad(false)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    finishLoad(false)
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let scheme = navigationAction.request.url?.scheme?.lowercased()
    decisionHandler(scheme == "http" || scheme == "https" ? .cancel : .allow)
  }

  private static func sanitizedHex(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
      return nil
    }
    return trimmed
  }
}
