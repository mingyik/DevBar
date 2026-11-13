import AppKit
import DevBarCore
import SwiftUI

/// AppKit supplies one dragging item per file; a single SwiftUI provider would lose extra URLs.
struct ClipboardDragView: NSViewRepresentable {
  let payloads: [ClipboardPayload]
  let cardContent: ClipCardContent
  let scheme: ColorScheme
  let onClick: () -> Void
  let onDelete: () -> Void
  let onHover: (Bool) -> Void
  let onDragging: @MainActor @Sendable (Bool) -> Void

  func makeNSView(context: Context) -> DragSource { DragSource() }
  func updateNSView(_ view: DragSource, context: Context) {
    view.payloads = payloads
    view.cardContent = cardContent
    view.scheme = scheme
    view.onClick = onClick
    view.onDelete = onDelete
    view.onHover = onHover
    view.onDragging = onDragging
  }

  final class DragSource: NSView, NSDraggingSource {
    var payloads: [ClipboardPayload] = []
    var cardContent = ClipCardContent()
    var scheme: ColorScheme = .light
    var onClick: (() -> Void)?
    var onDelete: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragging: (@MainActor @Sendable (Bool) -> Void)?
    private var origin: NSPoint?
    private var dragging = false
    private var deleteZones: [NSPanel] = []
    private var menuFrames: [NSRect] = []
    private var deleteHover = false
    private var deletionPerformed = false
    private var dragImageSize = NSSize.zero
    private var dragHotspot = NSPoint.zero
    // Keep the provider alive after drag end while Finder receives its promised file.
    private var promisedFile: ClipboardDragFile?

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      for area in trackingAreas { removeTrackingArea(area) }
      addTrackingArea(
        NSTrackingArea(
          rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
          owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

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
      let promise = ClipboardDragFile(payloads: payloads)
      let entries: [any NSPasteboardWriting] =
        promise.map { [$0] } ?? ClipboardController.pasteboardItems(payloads: payloads)
      guard !entries.isEmpty else { return }
      promisedFile = promise
      dragging = true
      onDragging?(true)
      let card = DragCardImage.make(cardContent, scheme: scheme)
      dragImageSize = card.image.size
      dragHotspot = card.hotspot
      deleteHover = false
      deletionPerformed = false
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
      showDeleteZones()
      let session = beginDraggingSession(with: items, event: event, source: self)
      session.animatesToStartingPositionsOnCancelOrFail = false
    }

    private func showDeleteZones() {
      let thickness = NSStatusBar.system.thickness
      menuFrames = NSScreen.screens.map { screen in
        NSRect(
          x: screen.frame.minX, y: screen.frame.maxY - thickness,
          width: screen.frame.width, height: thickness)
      }
      deleteZones = menuFrames.map { menuFrame in
        let frame = NSRect(
          x: menuFrame.minX, y: menuFrame.minY - DragCard.height,
          width: menuFrame.width, height: menuFrame.height + DragCard.height)
        let panel = NSPanel(
          contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
          backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = ClipboardDeleteDropView(frame: NSRect(origin: .zero, size: frame.size))
        view.canDelete = { [weak self] in self?.deleteHover ?? false }
        view.onDelete = { [weak self] in
          guard let self else { return }
          self.deletionPerformed = true
          self.onDelete?()
        }
        panel.contentView = view
        panel.orderFrontRegardless()
        return panel
      }
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
      let hovered = isDeleteTarget(at: screenPoint)
      guard hovered != deleteHover else { return }
      deleteHover = hovered
      session.enumerateDraggingItems(
        options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]
      ) { item, index, _ in
        guard index == 0 else { return }
        let card = DragCardImage.make(
          self.cardContent, scheme: self.scheme, deleteHover: hovered)
        item.setDraggingFrame(item.draggingFrame, contents: card.image)
      }
    }

    func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }

    func draggingSession(
      _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
      let shouldDelete = deletionPerformed || isDeleteTarget(at: screenPoint)
      for panel in deleteZones { panel.orderOut(nil) }
      deleteZones.removeAll()
      menuFrames.removeAll()
      deleteHover = false
      dragging = false
      if shouldDelete {
        if !deletionPerformed { onDelete?() }
        deletionPerformed = false
        onDragging?(false)
        return
      }
      deletionPerformed = false
      // Finder can request the promised file after the drag session has ended.
      if operation.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        let window
      {
        let target = window.convertToScreen(convert(bounds, to: nil))
        let card = DragCardImage.make(cardContent, scheme: scheme)
        let pointer = NSEvent.mouseLocation
        let start = NSRect(
          x: pointer.x - card.hotspot.x, y: pointer.y - card.hotspot.y,
          width: card.image.size.width, height: card.image.size.height)
        let ghost = NSPanel(
          contentRect: start, styleMask: [.borderless, .nonactivatingPanel],
          backing: .buffered, defer: false)
        ghost.level = .popUpMenu
        ghost.backgroundColor = .clear
        ghost.isOpaque = false
        ghost.hasShadow = false
        ghost.ignoresMouseEvents = true
        ghost.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let image = NSImageView(frame: NSRect(origin: .zero, size: start.size))
        image.image = card.image
        image.imageScaling = .scaleAxesIndependently
        image.autoresizingMask = [.width, .height]
        ghost.contentView = image
        ghost.orderFrontRegardless()
        // Capture the callback strongly: SwiftUI may tear this view down mid-animation, and a
        // weak self would leave the row hidden (opacity 0) forever.
        let finish = onDragging
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.2
          context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          ghost.animator().setFrame(target, display: true)
          ghost.animator().alphaValue = 0
        } completionHandler: {
          MainActor.assumeIsolated {
            ghost.orderOut(nil)
            finish?(false)
          }
        }
      } else {
        onDragging?(false)
      }
    }

    private func isDeleteTarget(at screenPoint: NSPoint) -> Bool {
      guard !menuFrames.isEmpty, dragImageSize.width > 0, dragImageSize.height > 0 else {
        return false
      }
      let imageFrame = NSRect(
        x: screenPoint.x - dragHotspot.x, y: screenPoint.y - dragHotspot.y,
        width: dragImageSize.width, height: dragImageSize.height)
      let cardBounds = imageFrame.insetBy(dx: 10, dy: 10)
      return menuFrames.contains { $0.intersects(cardBounds) }
    }
  }
}

/// Exists only during a clipboard drag, so dropping in the menu bar is explicit and cancellable.
@MainActor final class ClipboardDeleteDropView: NSView {
  var onDelete: (() -> Void)?
  var canDelete: (() -> Bool)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([
      .fileURL, .string, .png, .tiff, .rtf, .html,
      NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ])
  }
  required init?(coder: NSCoder) { nil }
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    canDelete?() == true
  }
  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard canDelete?() == true else { return false }
    onDelete?()
    return true
  }
}

@MainActor enum DragCardImage {
  static func make(
    _ content: ClipCardContent, scheme: ColorScheme, glass: Bool = false,
    deleteHover: Bool = false
  ) -> (image: NSImage, hotspot: NSPoint) {
    make(
      title: content.title, subtitle: content.subtitle, fileCount: content.stack,
      thumbnail: content.icon, swatch: content.swatch, scheme: scheme, glass: glass,
      deleteHover: deleteHover, footer: content.note, multilineContent: content.multiline,
      tag: content.tag)
  }
  static func make(
    title: String, subtitle: String, fileCount: Int, thumbnail: NSImage?, swatch: NSColor?,
    scheme: ColorScheme, glass: Bool = false, deleteHover: Bool = false,
    footer: String? = nil, multilineContent: Bool = false, tag: String? = nil
  ) -> (image: NSImage, hotspot: NSPoint) {
    let displayTitle = DragCard.firstLine(title)
    let displaySubtitle = DragCard.firstLine(subtitle)
    let hasThumb = thumbnail != nil || swatch != nil
    let tagWidth = deleteHover ? 0 : tag.map { tagSize($0) } ?? 0
    let tagReserve = tagWidth > 0 ? tagWidth + 6 : 0
    let topRightReserve: CGFloat = deleteHover ? 28 : tagReserve
    let width =
      multilineContent
      ? DragCard.width(
        title: DragCard.firstLine(title), hasThumb: hasThumb,
        trailingAccessoryWidth: topRightReserve)
      : max(
        DragCard.width(
          title: displayTitle, hasThumb: hasThumb, trailingAccessoryWidth: topRightReserve),
        DragCard.width(title: displaySubtitle, hasThumb: hasThumb, trailingAccessoryWidth: 0))
    let card = NSSize(width: width, height: DragCard.height)
    let pad: CGFloat = 10
    let image = NSImage(size: NSSize(width: card.width + pad * 2, height: card.height + pad * 2))
    image.lockFocus()
    let bounds = NSRect(x: pad, y: pad, width: card.width, height: card.height)
    let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.shadowBlurRadius = 6
    shadow.shadowColor =
      deleteHover
      ? NSColor.systemRed.withAlphaComponent(0.65)  // devbar:allow-color
      : NSColor(DesignTokens.textPrimary(scheme)).withAlphaComponent(0.18)
    if deleteHover { shadow.shadowBlurRadius = 12 }
    shadow.set()
    if !glass {
      NSColor(DesignTokens.opaqueBackdrop(scheme)).setFill()
      path.fill()
      NSColor(DesignTokens.panelRaised(scheme)).setFill()
      path.fill()
    }
    NSShadow().set()
    path.lineWidth = 0.5
    if glass {
      NSColor(DesignTokens.lineBorder(scheme)).setStroke()
    } else if deleteHover {
      NSColor.systemRed.setStroke()  // devbar:allow-color
    } else {
      NSColor(Color.blue).setStroke()  // devbar:allow-color
    }
    path.stroke()
    var textX = bounds.minX + 12
    if let swatch {
      let chip = NSRect(x: textX, y: bounds.midY - 8, width: 16, height: 16)
      swatch.setFill()
      NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
      textX += 24
    } else if let thumbnail {
      // Multiple files: up to three stacked copies of the first icon, front one fully opaque.
      let layers = min(max(fileCount, 1), 3)
      let side: CGFloat = layers > 1 ? 34 : 40
      for layer in (0..<layers).reversed() {
        let shift = CGFloat(layer) * 3
        let slot = NSRect(
          x: textX + shift, y: bounds.midY - 20 + (40 - side) - shift, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: slot, xRadius: 6, yRadius: 6).addClip()
        thumbnail.draw(
          in: slot, from: .zero, operation: .sourceOver, fraction: layer == 0 ? 1 : 0.45)
        NSGraphicsContext.restoreGraphicsState()
      }
      textX += 48
    }
    let primary = NSColor(DesignTokens.textPrimary(scheme))
    let tertiary = NSColor(DesignTokens.textTertiary(scheme))
    let fullTextWidth = bounds.maxX - textX - 12
    let titleRect = NSRect(
      x: textX, y: bounds.midY + 1, width: max(0, fullTextWidth - topRightReserve), height: 16)
    if multilineContent {
      let textFont = NSFont.systemFont(ofSize: 12)
      let firstLineWidth = max(1, fullTextWidth - topRightReserve)
      let footerWidth =
        (footer?.isEmpty == false)
        ? min(fullTextWidth, max(44, textWidth(footer ?? "", font: .systemFont(ofSize: 11)) + 6))
        : 0
      let secondLineWidth =
        footerWidth > 0 ? max(1, fullTextWidth - footerWidth - 8) : fullTextWidth
      let lines = previewLines(
        title, firstLineWidth: firstLineWidth, secondLineWidth: secondLineWidth, font: textFont)
      draw(
        lines.first,
        in: NSRect(x: textX, y: bounds.midY + 1, width: firstLineWidth, height: 16),
        font: textFont, color: primary, lineBreak: .byClipping)
      if let second = lines.second {
        draw(
          second, in: NSRect(x: textX, y: bounds.midY - 15, width: secondLineWidth, height: 14),
          font: textFont, color: primary, lineBreak: .byClipping)
      }
    } else if !displayTitle.isEmpty {
      draw(
        displayTitle, in: titleRect, font: .systemFont(ofSize: 12), color: primary,
        lineBreak: .byTruncatingTail)
    }
    if multilineContent {
      if let footer {
        draw(
          footer,
          in: NSRect(x: textX, y: bounds.midY - 15, width: fullTextWidth, height: 14),
          font: .systemFont(ofSize: 11), color: tertiary,
          lineBreak: .byTruncatingTail, align: .right)
      }
    } else {
      draw(
        displaySubtitle,
        in: NSRect(x: textX, y: bounds.midY - 16, width: max(0, fullTextWidth), height: 14),
        font: .systemFont(ofSize: 11), color: tertiary, lineBreak: .byTruncatingTail)
    }
    if deleteHover {
      let iconRect = NSRect(x: bounds.maxX - 25, y: bounds.midY - 7, width: 14, height: 14)
      if let trash = NSImage(systemSymbolName: "trash", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])  // devbar:allow-color
        let redTrash = trash.withSymbolConfiguration(config) ?? trash
        redTrash.isTemplate = false
        redTrash.draw(in: iconRect)
      }
    } else if let tag, tagWidth > 0 {
      drawTag(tag, x: bounds.maxX - 12 - tagWidth, midY: bounds.midY + 9, scheme: scheme)
    }
    image.unlockFocus()
    return (image, NSPoint(x: pad + card.width, y: pad))
  }
  private static let tagFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

  private static func tagSize(_ tag: String) -> CGFloat {
    tag.isEmpty ? 0 : ceil(textWidth(tag, font: tagFont)) + 10
  }

  /// Filled monochrome chip: a hairline outline washed out on glass.
  private static func drawTag(_ tag: String, x: CGFloat, midY: CGFloat, scheme: ColorScheme) {
    let primary = NSColor(DesignTokens.textPrimary(scheme))
    let rect = NSRect(x: x, y: midY - 8, width: tagSize(tag), height: 16)
    primary.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
    draw(
      tag, in: rect.offsetBy(dx: 0, dy: -1.5), font: tagFont,
      color: primary.withAlphaComponent(0.85), lineBreak: .byClipping, align: .center)
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

  private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
  }

  static func previewLines(
    _ text: String, firstLineWidth: CGFloat, secondLineWidth: CGFloat, font: NSFont
  ) -> (first: String, second: String?) {
    let characters = Array(text.prefix(320))
    var lines = ["", ""]
    var lineIndex = 0
    var truncated = false
    for (index, character) in characters.enumerated() {
      if character == "\n" || character == "\r" || character == "\r\n" {
        if lineIndex == 0 {
          lineIndex = 1
          continue
        }
        truncated = index + 1 < characters.count
        break
      }
      let piece = String(character)
      let candidate = lines[lineIndex] + piece
      let width = lineIndex == 0 ? firstLineWidth : secondLineWidth
      if !lines[lineIndex].isEmpty && textWidth(candidate, font: font) > width {
        guard lineIndex == 0 else {
          truncated = true
          break
        }
        lineIndex = 1
        lines[lineIndex] = piece
      } else {
        lines[lineIndex] = candidate
      }
    }
    if lineIndex == 0 { return (lines[0], nil) }
    if truncated {
      while !lines[1].isEmpty && textWidth(lines[1] + "…", font: font) > secondLineWidth {
        lines[1].removeLast()
      }
      lines[1] += "…"
    }
    return (lines[0], lines[1])
  }
}
