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
  let onDelete: () -> Void
  let onHover: (Bool) -> Void
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
    view.onDelete = onDelete
    view.onHover = onHover
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
    var onDelete: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragging: ((Bool) -> Void)?
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
      let card = DragCardImage.make(
        title: title, subtitle: subtitle, fileCount: fileCount, thumbnail: thumbnail,
        swatch: swatch,
        scheme: scheme)
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
          title: self.title, subtitle: self.subtitle, fileCount: self.fileCount,
          thumbnail: self.thumbnail, swatch: self.swatch, scheme: self.scheme,
          deleteHover: hovered)
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
        let card = DragCardImage.make(
          title: title, subtitle: subtitle, fileCount: fileCount, thumbnail: thumbnail,
          swatch: swatch, scheme: scheme)
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
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.2
          context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          ghost.animator().setFrame(target, display: true)
          ghost.animator().alphaValue = 0
        } completionHandler: { [weak self] in
          Task { @MainActor in
            ghost.orderOut(nil)
            self?.onDragging?(false)
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
    title: String, subtitle: String, fileCount: Int, thumbnail: NSImage?, swatch: NSColor?,
    scheme: ColorScheme, counter: String? = nil, glass: Bool = false, deleteHover: Bool = false,
    footer: String? = nil, multilineContent: Bool = false
  ) -> (image: NSImage, hotspot: NSPoint) {
    let displayTitle = DragCard.firstLine(title)
    let displaySubtitle = DragCard.firstLine(subtitle)
    let hasThumb = thumbnail != nil || swatch != nil
    let counterWidth: CGFloat = counter != nil ? 50 : (deleteHover ? 28 : 0)
    let sizingText =
      multilineContent
      ? DragCard.firstLine(title)
      : (displayTitle.isEmpty ? displaySubtitle : displayTitle)
    let reservedWidth = multilineContent && counter != nil ? counterWidth : 0
    let width = DragCard.width(
      title: sizingText, hasThumb: hasThumb, trailingAccessoryWidth: reservedWidth)
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
      let slot = NSRect(x: textX, y: bounds.midY - 20, width: 40, height: 40)
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(roundedRect: slot, xRadius: 6, yRadius: 6).addClip()
      thumbnail.draw(in: slot, from: .zero, operation: .sourceOver, fraction: 1)
      NSGraphicsContext.restoreGraphicsState()
      textX += 48
    }
    let primary = NSColor(DesignTokens.textPrimary(scheme))
    let tertiary = NSColor(DesignTokens.textTertiary(scheme))
    var hasSecondContentLine = false
    let titleRect = NSRect(
      x: textX, y: bounds.midY + 1, width: bounds.maxX - textX - 12 - counterWidth, height: 16)
    if multilineContent {
      let textFont = NSFont.systemFont(ofSize: 12)
      let fullTextWidth = bounds.maxX - textX - 12
      let firstLineWidth = fullTextWidth - counterWidth
      let footerWidth = min(
        fullTextWidth, max(44, textWidth(footer ?? "", font: .systemFont(ofSize: 11)) + 6))
      let secondLineWidth = max(1, fullTextWidth - footerWidth - 8)
      let lines = previewLines(
        title, firstLineWidth: firstLineWidth, secondLineWidth: secondLineWidth, font: textFont)
      hasSecondContentLine = lines.second != nil
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
          in: NSRect(
            x: textX,
            y: hasSecondContentLine ? bounds.midY - 15 : bounds.minY + 3,
            width: bounds.maxX - textX - 12, height: 14),
          font: .systemFont(ofSize: 11), color: tertiary,
          lineBreak: .byTruncatingTail, align: .right)
      }
    } else {
      let subtitleWidth = bounds.maxX - textX - 12 - (displayTitle.isEmpty ? 0 : counterWidth)
      let subtitleRect = NSRect(
        x: textX, y: bounds.midY - 16, width: subtitleWidth, height: 14)
      draw(
        displaySubtitle, in: subtitleRect, font: .systemFont(ofSize: 11), color: tertiary,
        lineBreak: .byTruncatingTail)
    }
    if deleteHover {
      let iconRect = NSRect(x: bounds.maxX - 25, y: bounds.midY - 7, width: 14, height: 14)
      if let trash = NSImage(systemSymbolName: "trash", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])  // devbar:allow-color
        let redTrash = trash.withSymbolConfiguration(config) ?? trash
        redTrash.isTemplate = false
        redTrash.draw(in: iconRect)
      }
    } else if let counter {
      draw(
        counter, in: NSRect(x: bounds.maxX - 58, y: bounds.maxY - 21, width: 48, height: 14),
        font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        color: NSColor(DesignTokens.clipboardIndex(scheme)),
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
