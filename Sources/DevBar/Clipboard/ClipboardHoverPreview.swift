import AppKit
import CoreText
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

  func begin(item: ClipItem) {
    self.item = item
    content = ""
    image = nil
    isLoading = true
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
  let height: CGFloat
}

enum ClipboardHoverContentLoader {
  static func prepare(
    item: ClipItem, payloads: [ClipboardPayload], width: CGFloat, maximum: CGFloat
  ) -> PreparedClipboardHover {
    let image = item.kind == .image ? decodeImage(payloads) : nil
    let content = textContent(item: item, payloads: payloads)
    let contentWidth = max(1, width - 28)
    let contentHeight: CGFloat
    if let image, image.width > 0, image.height > 0 {
      contentHeight = contentWidth * CGFloat(image.height) / CGFloat(image.width)
    } else {
      contentHeight = measuredTextHeight(content, width: max(1, width - 30))
    }
    let height = min(maximum, max(width, contentHeight + 60))
    return PreparedClipboardHover(
      itemID: item.id, content: content, image: image, height: height)
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

  private static func measuredTextHeight(_ content: String, width: CGFloat) -> CGFloat {
    let text = String(content.prefix(32_000))
    let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let size = CTFramesetterSuggestFrameSizeWithConstraints(
      framesetter,
      CFRange(location: 0, length: attributed.length),
      nil,
      CGSize(width: width, height: .greatestFiniteMagnitude),
      nil
    )
    return ceil(size.height)
  }
}

/// A passive preview: it never becomes key or reads the system clipboard.
struct ClipboardHoverPreview: View {
  @Bindable var state: ClipboardHoverPreviewState
  let scheme: ColorScheme
  var theme: ThemeManager
  var onHoverChange: (Bool) -> Void

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
      if state.isLoading {
        Spacer(minLength: 0)
        ProgressView().controlSize(.small)
          .tint(DesignTokens.textTertiary(scheme))
          .frame(maxWidth: .infinity)
        Spacer(minLength: 0)
      } else if let image = state.image {
        Image(nsImage: image).resizable().scaledToFit()
          .padding(.trailing, 14)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ReadOnlyScrollView(
          scheme: scheme, contentTrailingInset: 16, indicatorTrailingInset: 7,
          indicatorWidth: 2, indicatorOpacity: 0.65, flashOnAppear: true
        ) {
          Text(state.content)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(DesignTokens.textPrimary(scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.disabled)
        }
      }
    }
    .padding(.leading, 14)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background { PanelChrome(theme: theme, scheme: scheme) }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous))
    .environment(\.colorScheme, scheme)
    .onHover(perform: onHoverChange)
  }
}
