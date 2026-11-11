import AppKit
import DevBarCore
import SwiftUI

/// AppKit supplies one dragging item per file; a single SwiftUI provider would lose extra URLs.
struct ClipboardDragView: NSViewRepresentable {
  let payloads: [ClipboardPayload]
  let thumbnail: NSImage?
  let title: String
  let subtitle: String
  let fileCount: Int
  let swatch: NSColor?
  let scheme: ColorScheme
  let onClick: () -> Void
  let onDragging: (Bool) -> Void

  func makeNSView(context: Context) -> DragSource { DragSource() }
  func updateNSView(_ view: DragSource, context: Context) {
    view.payloads = payloads
    view.thumbnail = thumbnail
    view.title = title
    view.subtitle = subtitle
    view.fileCount = fileCount
    view.swatch = swatch
    view.scheme = scheme
    view.onClick = onClick
    view.onDragging = onDragging
  }

  final class DragSource: NSView, NSDraggingSource {
    var payloads: [ClipboardPayload] = []
    var thumbnail: NSImage?
    var title = ""
    var subtitle = ""
    var fileCount = 0
    var swatch: NSColor?
    var scheme: ColorScheme = .light
    var onClick: (() -> Void)?
    var onDragging: ((Bool) -> Void)?
    private var origin: NSPoint?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
      origin = event.locationInWindow
      dragging = false
    }

    override func mouseUp(with event: NSEvent) {
      if !dragging { onClick?() }
      origin = nil
    }

    override func mouseDragged(with event: NSEvent) {
      guard !dragging, let origin,
        hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4
      else { return }
      let entries = ClipboardController.pasteboardItems(payloads: payloads)
      guard !entries.isEmpty else { return }
      dragging = true
      onDragging?(true)
      let card = DragCardImage.make(
        title: title, subtitle: subtitle, fileCount: fileCount, thumbnail: thumbnail,
        swatch: swatch,
        scheme: scheme)
      let local = convert(event.locationInWindow, from: nil)
      let hotspot = NSPoint(x: card.hotspot.x, y: card.hotspot.y)
      let items = entries.enumerated().map { index, entry in
        let item = NSDraggingItem(pasteboardWriter: entry)
        if index == 0 {
          item.setDraggingFrame(
            NSRect(
              x: local.x - hotspot.x, y: local.y - hotspot.y, width: card.image.size.width,
              height: card.image.size.height), contents: card.image)
        } else {
          item.setDraggingFrame(.zero, contents: NSImage(size: .zero))
        }
        return item
      }
      beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }

    func draggingSession(
      _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
      dragging = false
      onDragging?(false)
    }
  }
}

enum DragCardImage {
  static func make(
    title: String, subtitle: String, fileCount: Int, thumbnail: NSImage?, swatch: NSColor?,
    scheme: ColorScheme, counter: String? = nil
  ) -> (image: NSImage, hotspot: NSPoint) {
    let hasThumb = thumbnail != nil || swatch != nil
    let width = DragCard.width(title: title, hasThumb: hasThumb)
    let card = NSSize(width: width, height: DragCard.height)
    let pad: CGFloat = 10
    let image = NSImage(size: NSSize(width: card.width + pad * 2, height: card.height + pad * 2))
    image.lockFocus()
    let bounds = NSRect(x: pad, y: pad, width: card.width, height: card.height)
    let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.shadowBlurRadius = 6
    shadow.shadowColor = NSColor(DesignTokens.textPrimary(scheme)).withAlphaComponent(0.18)
    shadow.set()
    NSColor(DesignTokens.opaqueBackdrop(scheme)).setFill()
    path.fill()
    NSColor(DesignTokens.panelRaised(scheme)).setFill()
    path.fill()
    NSShadow().set()
    path.lineWidth = 1.5
    NSColor(DesignTokens.textPrimary(scheme)).setStroke()
    path.stroke()
    var textX = bounds.minX + 12
    if let swatch {
      let chip = NSRect(x: textX, y: bounds.midY - 8, width: 16, height: 16)
      swatch.setFill()
      NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
      textX += 24
    } else if let thumbnail {
      let slot = NSRect(x: textX, y: bounds.midY - 20, width: 40, height: 40)
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(roundedRect: slot, xRadius: 6, yRadius: 6).addClip()
      thumbnail.draw(in: slot, from: .zero, operation: .sourceOver, fraction: 1)
      NSGraphicsContext.restoreGraphicsState()
      textX += 48
    }
    let primary = NSColor(DesignTokens.textPrimary(scheme))
    let tertiary = NSColor(DesignTokens.textTertiary(scheme))
    let counterWidth: CGFloat = counter == nil ? 0 : 50
    let titleRect = NSRect(
      x: textX, y: bounds.midY + 1, width: bounds.maxX - textX - 12 - counterWidth, height: 16)
    draw(
      title, in: titleRect, font: .systemFont(ofSize: 12), color: primary,
      lineBreak: .byTruncatingTail)
    let subtitleRect = NSRect(
      x: textX, y: bounds.midY - 16, width: bounds.maxX - textX - 12, height: 14)
    draw(
      subtitle, in: subtitleRect, font: .systemFont(ofSize: 11), color: tertiary,
      lineBreak: .byTruncatingTail)
    if let counter {
      draw(
        counter, in: NSRect(x: bounds.maxX - 58, y: bounds.maxY - 21, width: 48, height: 14),
        font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: tertiary,
        lineBreak: .byClipping, align: .right)
    } else if fileCount > 1 {
      let badge = NSRect(x: bounds.maxX - 22, y: bounds.maxY - 22, width: 18, height: 18)
      let circle = NSBezierPath(ovalIn: badge)
      primary.setFill()
      circle.fill()
      draw(
        "\(fileCount)", in: badge, font: .systemFont(ofSize: 10, weight: .semibold),
        color: NSColor(DesignTokens.selectionText(scheme)), lineBreak: .byClipping, align: .center)
    }
    image.unlockFocus()
    return (image, NSPoint(x: pad + card.width, y: pad))
  }

  private static func draw(
    _ text: String, in rect: NSRect, font: NSFont, color: NSColor, lineBreak: NSLineBreakMode,
    align: NSTextAlignment = .left
  ) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = lineBreak
    style.alignment = align
    (text as NSString).draw(
      in: rect,
      withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
  }
}
