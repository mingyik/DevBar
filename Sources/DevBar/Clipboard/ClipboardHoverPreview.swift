import AVKit
import AppKit
import DevBarCore
import ImageIO
import Observation
import PDFKit
@preconcurrency import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum ClipboardPreviewMedia: Equatable, Sendable {
  case pdf(URL)
  case audiovisual(URL)
  case imageFile(URL)
  case webImage(Data, mime: String)
}

@MainActor
final class ClipboardHoverPreviewScheduler {
  private let initialDelay: Duration
  private let switchDelay: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private var task: Task<Void, Never>?
  private(set) var pendingID: UUID?

  init(
    initialDelay: Duration = .milliseconds(180),
    switchDelay: Duration = .milliseconds(90),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.initialDelay = initialDelay
    self.switchDelay = switchDelay
    self.sleep = sleep
  }

  func schedule(
    id: UUID,
    isPreviewVisible: Bool,
    onFire: @escaping @MainActor (UUID) -> Void
  ) {
    task?.cancel()
    pendingID = id
    let delay = isPreviewVisible ? switchDelay : initialDelay
    let sleep = self.sleep
    task = Task { @MainActor [weak self] in
      do { try await sleep(delay) } catch { return }
      guard !Task.isCancelled, let self, self.pendingID == id else { return }
      self.pendingID = nil
      self.task = nil
      onFire(id)
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
    pendingID = nil
  }
}

@MainActor @Observable
final class ClipboardHoverPreviewState {
  private(set) var item: ClipItem?
  private(set) var tag = ""
  private(set) var content = ""
  private(set) var image: NSImage?
  private(set) var media: ClipboardPreviewMedia?
  private(set) var isLoading = true
  private(set) var isSizing = true

  func begin(
    item: ClipItem, tag: String = "", cachedContent: String? = nil, sizingComplete: Bool = false
  ) {
    self.item = item
    self.tag = tag
    content = item.kind == .image ? "" : cachedContent ?? item.preview
    image = nil
    media = nil
    isLoading = item.kind == .image
    isSizing = !sizingComplete
  }

  func finishSizing(itemID: UUID) {
    guard item?.id == itemID else { return }
    isSizing = false
  }

  func finish(itemID: UUID, content: String, image: CGImage?, media: ClipboardPreviewMedia?) {
    guard item?.id == itemID else { return }
    self.content = content
    self.media = media
    self.image = image.map {
      NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
    }
    isLoading = false
  }

  func releaseMemory() {
    item = nil
    content = ""
    image = nil
    media = nil
    isLoading = false
    isSizing = false
  }
}

/// Immutable image data can cross from the background decoder to the main actor.
struct PreparedClipboardHover: @unchecked Sendable {
  let itemID: UUID
  let content: String
  let image: CGImage?
  let imageHeight: CGFloat?
  let media: ClipboardPreviewMedia?
}

enum ClipboardHoverContentLoader {
  static func prepare(
    item: ClipItem, payloads: [ClipboardPayload], width: CGFloat, maximum: CGFloat,
    systemThumbnail: CGImage? = nil
  ) -> PreparedClipboardHover {
    let media = systemThumbnail == nil ? previewMedia(item: item, payloads: payloads) : nil
    let image = systemThumbnail ?? (item.kind == .image ? decodeImage(payloads) : nil)
    let content = textContent(item: item, payloads: payloads)
    let imageHeight: CGFloat?
    if let image, image.width > 0, image.height > 0 {
      imageHeight = min(
        maximum, max(width, (width - 28) * CGFloat(image.height) / CGFloat(image.width) + 60))
    } else {
      imageHeight = media == nil ? nil : min(maximum, width * 1.25)
    }
    return PreparedClipboardHover(
      itemID: item.id, content: content, image: image, imageHeight: imageHeight, media: media)
  }

  static func singleFileURL(_ payloads: [ClipboardPayload]) -> URL? {
    let files = payloads.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
    guard files.count == 1, let data = files.first?.data,
      let raw = String(data: data, encoding: .utf8),
      let url = URL(string: raw), url.isFileURL,
      (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    else { return nil }
    return url
  }

  static func systemThumbnail(url: URL, width: CGFloat, scale: CGFloat) async -> CGImage? {
    guard !Task.isCancelled else { return nil }
    let generator = QLThumbnailGenerator.shared
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: width, height: width * 1.4),
      scale: scale, representationTypes: [.thumbnail, .lowQualityThumbnail])
    return await withTaskCancellationHandler {
      guard !Task.isCancelled else { return nil }
      return try? await generator.generateBestRepresentation(for: request).cgImage
    } onCancel: {
      generator.cancel(request)
    }
  }

  private static func previewMedia(
    item: ClipItem, payloads: [ClipboardPayload]
  ) -> ClipboardPreviewMedia? {
    if item.kind == .files {
      let files = payloads.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
      guard files.count == 1, let data = files.first?.data,
        let raw = String(data: data, encoding: .utf8),
        let url = URL(string: raw), url.isFileURL,
        let values = try? url.resourceValues(forKeys: [
          .isRegularFileKey, .contentTypeKey, .fileSizeKey,
        ]),
        values.isRegularFile == true, let type = values.contentType,
        type.conforms(to: .pdf) || [.png, .jpeg, .gif, .tiff, .bmp, .svg].contains(type)
          || type.identifier == "org.webmproject.webp"
          || type.conforms(to: .movie) || type.conforms(to: .audio),
        FileManager.default.isReadableFile(atPath: url.path)
      else { return nil }
      if type == .svg {
        guard let size = values.fileSize, size <= 10 * 1024 * 1024,
          let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 10 * 1024 * 1024 + 1),
          data.count <= 10 * 1024 * 1024
        else { return nil }
        return .webImage(data, mime: "image/svg+xml")
      }
      if type.conforms(to: .pdf) { return .pdf(url) }
      if type.conforms(to: .image) { return .imageFile(url) }
      return .audiovisual(url)
    }
    guard item.kind == .image else { return nil }
    for payload in payloads {
      if payload.type == UTType.svg.identifier, payload.data.count <= 10 * 1024 * 1024 {
        return .webImage(payload.data, mime: "image/svg+xml")
      }
      guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil),
        CGImageSourceGetCount(source) > 1,
        let identifier = CGImageSourceGetType(source),
        let type = UTType(identifier as String),
        type == .gif || type.identifier == "org.webmproject.webp"
      else { continue }
      return .webImage(payload.data, mime: type == .gif ? "image/gif" : "image/webp")
    }
    return nil
  }

  private static func textContent(item: ClipItem, payloads: [ClipboardPayload]) -> String {
    if item.kind == .files {
      if let url = singleFileURL(payloads),
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
        type.conforms(to: .text)
          || ["md", "markdown", "json"].contains(url.pathExtension.lowercased()),
        let handle = try? FileHandle(forReadingFrom: url)
      {
        defer { try? handle.close() }
        if let data = try? handle.read(upToCount: 4096), !data.isEmpty {
          return String(decoding: data, as: UTF8.self)
        }
      }
      return ClipboardController.filePaths(payloads: payloads) ?? item.preview
    }
    if let payload = payloads.first(where: {
      $0.type == NSPasteboard.PasteboardType.string.rawValue
    }), let text = String(data: payload.data, encoding: .utf8) {
      return text
    }
    if let rich = payloads.first(where: {
      $0.type == NSPasteboard.PasteboardType.rtf.rawValue
    }),
      let text = try? NSAttributedString(
        data: rich.data, options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil)
    {
      return text.string
    }
    return item.preview
  }

  private static func decodeImage(_ payloads: [ClipboardPayload]) -> CGImage? {
    let options: CFDictionary =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 1_200,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary
    for payload in payloads {
      guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
      else { continue }
      return image
    }
    return nil
  }

}

/// A passive preview: it never becomes key or reads the system clipboard.
struct ClipboardHoverPreview: View {
  @Bindable var state: ClipboardHoverPreviewState
  let scheme: ColorScheme
  var theme: ThemeManager
  var onHoverChange: (Bool) -> Void
  var onContentHeightChange: (CGFloat) -> Void
  @State private var showsProgress = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if state.item != nil {
        ClipTagChip(tag: state.tag, scheme: scheme)
      }
      if state.isLoading && state.item?.kind == .image {
        Spacer(minLength: 0)
        if showsProgress {
          ProgressView().controlSize(.small)
            .tint(DesignTokens.textTertiary(scheme))
            .frame(maxWidth: .infinity)
        }
        Spacer(minLength: 0)
      } else if let media = state.media {
        ClipboardMediaPreviewContainer(media: media, scheme: scheme)
          .id(state.item?.id)
          .padding(.trailing, 14)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let image = state.image {
        let imageShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Image(nsImage: image).resizable().scaledToFit()
          .clipShape(imageShape)
          .overlay {
            imageShape.strokeBorder(DesignTokens.lineBorder(scheme), lineWidth: 0.5)
          }
          .padding(.trailing, 14)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ClipboardPreviewText(
          content: state.content, scheme: scheme, onContentHeightChange: onContentHeightChange
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(.leading, 14)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background { PanelChrome(theme: theme, scheme: scheme) }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous))
    .environment(\.colorScheme, scheme)
    .overlay(alignment: .topTrailing) {
      if showsProgress && (state.isLoading || state.isSizing) && state.item?.kind != .image {
        ProgressView().controlSize(.mini)
          .tint(DesignTokens.textTertiary(scheme))
          .padding(14)
          .allowsHitTesting(false)
      }
    }
    .onHover(perform: onHoverChange)
    .task(id: state.isLoading || state.isSizing ? state.item?.id : nil) {
      showsProgress = false
      guard state.isLoading || state.isSizing else { return }
      do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
      showsProgress = true
    }
  }
}

private struct ClipboardMediaPreviewContainer: View {
  let media: ClipboardPreviewMedia
  let scheme: ColorScheme

  private var imageFileAspectRatio: CGFloat? {
    guard case .imageFile(let url) = media,
      let image = NSImage(contentsOf: url),
      image.size.width > 0, image.size.height > 0
    else { return nil }
    return image.size.width / image.size.height
  }

  var body: some View {
    let imageShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    switch media {
    case .imageFile:
      Group {
        if let ratio = imageFileAspectRatio {
          ClipboardNativeMediaPreview(media: media, scheme: scheme)
            .aspectRatio(ratio, contentMode: .fit)
        } else {
          ClipboardNativeMediaPreview(media: media, scheme: scheme)
        }
      }
      .clipShape(imageShape)
      .overlay {
        imageShape.strokeBorder(DesignTokens.lineBorder(scheme), lineWidth: 0.5)
      }
    case .webImage:
      ClipboardNativeMediaPreview(media: media, scheme: scheme)
    case .pdf, .audiovisual:
      ClipboardNativeMediaPreview(media: media, scheme: scheme)
        .clipShape(imageShape)
    }
  }
}

private struct ClipboardNativeMediaPreview: NSViewRepresentable {
  let media: ClipboardPreviewMedia
  let scheme: ColorScheme

  private func borderCSS() -> String {
    let resolved = NSColor(DesignTokens.lineBorder(scheme)).usingColorSpace(.sRGB)
    let r = Int(((resolved?.redComponent ?? 0) * 255).rounded())
    let g = Int(((resolved?.greenComponent ?? 0) * 255).rounded())
    let b = Int(((resolved?.blueComponent ?? 0) * 255).rounded())
    let a = String(format: "%.3f", resolved?.alphaComponent ?? 0.1)
    return "rgba(\(r),\(g),\(b),\(a))"  // devbar:allow-color
  }

  func makeNSView(context: Context) -> NSView {
    switch media {
    case .pdf(let url):
      let view = PDFView()
      view.document = PDFDocument(url: url)
      view.autoScales = true
      return view
    case .audiovisual(let url):
      let view = AVPlayerView()
      view.controlsStyle = .inline
      view.player = AVPlayer(url: url)
      return view
    case .imageFile(let url):
      let view = NSImageView()
      view.imageScaling = .scaleProportionallyUpOrDown
      view.image = NSImage(contentsOf: url)
      view.animates = true
      return view
    case .webImage(let data, let mime):
      let view = imageWebView()
      let border = borderCSS()
      let html = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;background:transparent;display:grid;place-items:center;height:100vh}
        img{display:block;max-width:100vw;max-height:100vh;object-fit:contain;border-radius:8px;border:0.5px solid \(border);box-sizing:border-box}</style>
        <img src="data:\(mime);base64,\(data.base64EncodedString())">
        """
      view.loadHTMLString(html, baseURL: nil)
      return view
    }
  }

  private func imageWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.setValue(false, forKey: "drawsBackground")
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}

  static func dismantleNSView(_ view: NSView, coordinator: ()) {
    if let playerView = view as? AVPlayerView {
      playerView.player?.pause()
      playerView.player = nil
    }
    if let pdfView = view as? PDFView { pdfView.document = nil }
    if let webView = view as? WKWebView { webView.stopLoading() }
  }
}

/// Keeps long text out of SwiftUI's intrinsic-size measurement path.
private struct ClipboardPreviewText: NSViewRepresentable {
  let content: String
  let scheme: ColorScheme
  var onContentHeightChange: (CGFloat) -> Void

  @MainActor final class Coordinator {
    var content: String?
    var revision = 0
    var onHeight: ((CGFloat) -> Void)?

    func contentHeightChanged(_ height: CGFloat) {
      let currentRevision = revision
      Task { @MainActor [weak self] in
        guard let self, self.revision == currentRevision else { return }
        self.onHeight?(height)
      }
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.verticalScrollElasticity = .none
    scroll.horizontalScrollElasticity = .none
    scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 16)
    scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 7)
    scroll.verticalScroller = ClipboardPreviewScroller()

    let text = ClipboardPreviewNativeTextView(usingTextLayoutManager: true)
    text.onContentHeightChange = { [weak coordinator = context.coordinator] height in
      coordinator?.contentHeightChanged(height)
    }
    text.isEditable = false
    text.isSelectable = false
    text.isRichText = false
    text.drawsBackground = false
    text.allowsUndo = false
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.textContainerInset = .zero
    text.textContainer?.lineFragmentPadding = 0
    text.textContainer?.widthTracksTextView = true
    text.minSize = .zero
    text.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    scroll.documentView = text
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.onHeight = onContentHeightChange
    guard let text = scroll.documentView as? ClipboardPreviewNativeTextView else { return }
    text.textColor = NSColor(DesignTokens.textPrimary(scheme))
    if let scroller = scroll.verticalScroller as? ClipboardPreviewScroller {
      scroller.thumbColor = NSColor(DesignTokens.scrollThumb(scheme)).withAlphaComponent(0.65)
    }
    guard context.coordinator.content != content else { return }
    context.coordinator.revision += 1
    context.coordinator.content = content
    text.string = content
    text.contentDidChange()
    text.scrollToBeginningOfDocument(nil)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize?
  {
    CGSize(width: proposal.width ?? 270, height: proposal.height ?? 240)
  }
}

private final class ClipboardPreviewScroller: NSScroller {
  var thumbColor = NSColor.clear

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

  override func drawKnob() {
    let knob = rect(for: .knob)
    let rect = NSRect(x: knob.midX - 1, y: knob.minY, width: 2, height: knob.height)
    thumbColor.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
  }
}

private final class ClipboardPreviewNativeTextView: NSTextView {
  var onContentHeightChange: ((CGFloat) -> Void)?
  private var lastContentHeight: CGFloat = -1

  func contentDidChange() {
    lastContentHeight = -1
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let height = textLayoutManager?.usageBoundsForTextContainer.height,
      height.isFinite, height > 0, abs(lastContentHeight - height) > 0.5
    else { return }
    lastContentHeight = height
    onContentHeightChange?(height)
  }
}
