import AppKit
import DevBarCore
import ImageIO
import Observation
import SwiftUI

@MainActor @Observable
final class ClipboardHoverPreviewState {
  private(set) var item: ClipItem?
  private(set) var content = ""
  private(set) var image: NSImage?
  private(set) var isLoading = true
  private(set) var isSizing = true

  func begin(item: ClipItem, cachedContent: String? = nil, sizingComplete: Bool = false) {
    self.item = item
    content = item.kind == .image ? "" : cachedContent ?? item.preview
    image = nil
    isLoading = item.kind == .image
    isSizing = !sizingComplete
  }

  func finishSizing(itemID: UUID) {
    guard item?.id == itemID else { return }
    isSizing = false
  }

  func finish(itemID: UUID, content: String, image: CGImage?) {
    guard item?.id == itemID else { return }
    self.content = content
    self.image = image.map {
      NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
    }
    isLoading = false
  }
}

/// Immutable image data can cross from the background decoder to the main actor.
struct PreparedClipboardHover: @unchecked Sendable {
  let itemID: UUID
  let content: String
  let image: CGImage?
  let imageHeight: CGFloat?
}

enum ClipboardHoverContentLoader {
  static func prepare(
    item: ClipItem, payloads: [ClipboardPayload], width: CGFloat, maximum: CGFloat
  ) -> PreparedClipboardHover {
    let image = item.kind == .image ? decodeImage(payloads) : nil
    let content = textContent(item: item, payloads: payloads)
    let imageHeight: CGFloat?
    if let image, image.width > 0, image.height > 0 {
      imageHeight = min(
        maximum, max(width, (width - 28) * CGFloat(image.height) / CGFloat(image.width) + 60))
    } else {
      imageHeight = nil
    }
    return PreparedClipboardHover(
      itemID: item.id, content: content, image: image, imageHeight: imageHeight)
  }

  private static func textContent(item: ClipItem, payloads: [ClipboardPayload]) -> String {
    if item.kind == .files {
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
      if let item = state.item {
        Text(
          item.kind == .files
            ? Strings.clipboardFileType
            : item.kind == .image ? Strings.clipboardImageType : Strings.clipboardTextType
        )
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(DesignTokens.textSecondary(scheme))
      }
      if state.isLoading && state.item?.kind == .image {
        Spacer(minLength: 0)
        if showsProgress {
          ProgressView().controlSize(.small)
            .tint(DesignTokens.textTertiary(scheme))
            .frame(maxWidth: .infinity)
        }
        Spacer(minLength: 0)
      } else if let image = state.image {
        Image(nsImage: image).resizable().scaledToFit()
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
