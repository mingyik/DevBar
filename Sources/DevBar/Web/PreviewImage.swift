import AppKit
import WebKit
import os

/// Full-page preview PNG assembled from the isolated export WebView viewport.
/// The live panel is never resized or scrolled.
@MainActor final class PreviewImage: NSObject, WKNavigationDelegate {
  private let logger = Logger(subsystem: "local.devbar.app", category: "preview")
  private var savedPaths = Set<String>()
  private var busy = false
  private var releaseWhenIdle = false
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

  func releaseMemory() {
    guard !busy else {
      releaseWhenIdle = true
      return
    }
    releaseCanvas()
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
      html,body{margin:0;display:block;height:auto;overflow:visible}
      html body .snapshot-root{display:block;visibility:visible;position:static;left:auto;top:auto;height:auto;overflow:visible}
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
    defer {
      busy = false
      if releaseWhenIdle {
        releaseWhenIdle = false
        releaseCanvas()
      }
    }
    guard let host = host ?? NSApp?.keyWindow?.contentView else { return #"{"status":"failed"}"# }
    let view = ensureCanvas(width: width, height: min(height, 512), host: host)
    let loaded = await load(
      Self.snapshotDocument(html: html, css: css, theme: theme, background: background), in: view)
    guard loaded else { return #"{"status":"failed"}"# }
    try? await Task.sleep(for: .milliseconds(200))
    let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    guard let pixels = Self.dimensions(width: width, height: height) else {
      return #"{"status":"tooLarge"}"#
    }
    do {
      let bitmap = try await tiledSnapshot(
        view, width: width, height: height, pixels: pixels, scale: scale)
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        return #"{"status":"failed"}"#
      }
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

  private enum SnapshotError: Error { case invalidViewport, invalidTile, allocation }

  /// WebKit can omit composited/text content beyond its real viewport even when
  /// takeSnapshot's rect is taller. Scroll only the isolated export document and
  /// assemble viewport-sized tiles; never scroll or resize the user's panel.
  private func tiledSnapshot(
    _ view: WKWebView, width: Double, height: Double,
    pixels: (Int, Int), scale: CGFloat
  ) async throws -> NSBitmapImageRep {
    guard let viewport = try await view.evaluateJavaScript("window.innerHeight") as? Double,
      viewport > 0
    else { throw SnapshotError.invalidViewport }
    guard
      let context = CGContext(
        data: nil, width: pixels.0, height: pixels.1,
        bitsPerComponent: 8, bytesPerRow: pixels.0 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw SnapshotError.allocation }
    var top = 0.0
    while top < height {
      guard
        let scroll = try await view.evaluateJavaScript("window.scrollTo(0, \(top)); window.scrollY")
          as? Double
      else { throw SnapshotError.invalidTile }
      let localTop = max(0, top - scroll)
      let tileHeight = min(viewport - localTop, height - top)
      guard tileHeight > 0 else { throw SnapshotError.invalidTile }
      try await Task.sleep(for: .milliseconds(40))
      let config = WKSnapshotConfiguration()
      config.rect = CGRect(x: 0, y: localTop, width: width, height: tileHeight)
      config.snapshotWidth = NSNumber(
        value: Double(Self.snapshotPointWidth(pixels: pixels.0, scale: scale)))
      config.afterScreenUpdates = true
      let image = try await view.takeSnapshot(configuration: config)
      guard let tiff = image.tiffRepresentation, let tile = NSBitmapImageRep(data: tiff)?.cgImage
      else { throw SnapshotError.invalidTile }
      let startPixel = Int(ceil(top * 2))
      let endPixel = min(pixels.1, Int(ceil((top + tileHeight) * 2)))
      context.draw(
        tile,
        in: CGRect(x: 0, y: pixels.1 - endPixel, width: pixels.0, height: endPixel - startPixel))
      top += tileHeight
    }
    guard let image = context.makeImage() else { throw SnapshotError.allocation }
    return NSBitmapImageRep(cgImage: image)
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

  private func releaseCanvas() {
    loadGeneration += 1
    finishLoad(false)
    guard let canvas else { return }
    canvas.stopLoading()
    canvas.navigationDelegate = nil
    canvas.removeFromSuperview()
    self.canvas = nil
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
