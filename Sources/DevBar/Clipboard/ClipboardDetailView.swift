import AppKit
import DevBarCore
import SwiftUI

struct ClipboardDetailView: View {
  @Bindable var controller: ClipboardController
  let item: ClipItem
  let scheme: ColorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button(Strings.backToList) { controller.detailID = nil }
          .buttonStyle(DevBarCapsuleStyle(scheme: scheme))
        Spacer()
        Button {
          if let index = controller.items.firstIndex(where: { $0.id == item.id }) {
            controller.select(index)
          }
        } label: {
          Label(
            Strings.copy, systemImage: controller.copiedID == item.id ? "checkmark" : "doc.on.doc")
        }.buttonStyle(DevBarCapsuleStyle(scheme: scheme))
      }
      ReadOnlyScrollView(scheme: scheme) {
        VStack(alignment: .leading, spacing: 8) {
          if item.kind == .image,
            let payload = controller.originals[item.id]?.first(where: {
              NSImage(data: $0.data) != nil
            }),
            let image = NSImage(data: payload.data)
          {
            Image(nsImage: image).resizable().scaledToFit()
          } else {
            Text(contents).font(.system(size: 13, design: .monospaced))
              .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(
        DesignTokens.panelCard(scheme),
        in: RoundedRectangle(cornerRadius: DesignTokens.radiusMedium))
    }.foregroundStyle(DesignTokens.textPrimary(scheme))
  }

  private var contents: String {
    let payloads = controller.originals[item.id] ?? []
    let files = payloads.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
    if !files.isEmpty {
      return files.compactMap { String(data: $0.data, encoding: .utf8) }.joined(separator: "\n")
    }
    if let rich = payloads.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }),
      let text = try? NSAttributedString(
        data: rich.data, options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil)
    {
      return text.string
    }
    return payloads.first(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue })
      .flatMap { String(data: $0.data, encoding: .utf8) } ?? payloads.first(where: {
        $0.type == NSPasteboard.PasteboardType.html.rawValue
      }).flatMap { String(data: $0.data, encoding: .utf8) } ?? item.preview
  }
}
