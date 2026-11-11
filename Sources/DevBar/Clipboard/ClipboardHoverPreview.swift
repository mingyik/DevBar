import AppKit
import DevBarCore
import SwiftUI

/// A passive preview: it never becomes key or reads the system clipboard.
struct ClipboardHoverPreview: View {
  let item: ClipItem
  let payloads: [ClipboardPayload]
  let scheme: ColorScheme
  var theme: ThemeManager
  var onHoverChange: (Bool) -> Void = { _ in }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        item.kind == .files
          ? Strings.clipboardFileType
          : item.kind == .image ? Strings.clipboardImageType : Strings.clipboardTextType
      )
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(DesignTokens.textSecondary(scheme))
      if item.kind == .image,
        let data = payloads.first(where: { NSImage(data: $0.data) != nil })?.data,
        let image = NSImage(data: data)
      {
        Image(nsImage: image).resizable().scaledToFit()
          .padding(.trailing, 14)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ReadOnlyScrollView(
          scheme: scheme, contentTrailingInset: 16, indicatorTrailingInset: 7,
          indicatorWidth: 2, indicatorOpacity: 0.65, flashOnAppear: true
        ) {
          Text(content)
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

  func preferredHeight(width: CGFloat, maximum: CGFloat) -> CGFloat {
    let contentWidth = max(1, width - 28)
    let contentHeight: CGFloat
    if item.kind == .image,
      let image = payloads.lazy.compactMap({ NSImage(data: $0.data) }).first,
      image.size.width > 0, image.size.height > 0
    {
      contentHeight = contentWidth * image.size.height / image.size.width
    } else {
      let text = String(content.prefix(32_000)) as NSString
      contentHeight = text.boundingRect(
        with: NSSize(width: max(1, width - 30), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
      ).height.rounded(.up)
    }
    return min(maximum, max(width, contentHeight + 60))
  }

  var content: String {
    if item.kind == .files {
      return ClipboardController.filePaths(payloads: payloads) ?? item.preview
    }
    if let payload = payloads.first(where: {
      $0.type == NSPasteboard.PasteboardType.string.rawValue
    }),
      let text = String(data: payload.data, encoding: .utf8)
    {
      return text
    }
    if let rich = payloads.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }),
      let text = try? NSAttributedString(
        data: rich.data, options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil)
    {
      return text.string
    }
    return item.preview
  }
}
