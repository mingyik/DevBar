import AppKit
import DevBarCore
import SwiftUI

/// AppKit supplies one dragging item per file; a single SwiftUI provider would lose extra URLs.
struct ClipboardDragView: NSViewRepresentable {
  let payloads: [ClipboardPayload]
  let thumbnail: NSImage?
  let onClick: () -> Void
  func makeNSView(context: Context) -> DragSource { DragSource() }
  func updateNSView(_ view: DragSource, context: Context) {
    view.payloads = payloads
    view.preview = thumbnail
    view.onClick = onClick
  }

  final class DragSource: NSView, NSDraggingSource {
    var payloads: [ClipboardPayload] = []
    var preview: NSImage?
    var onClick: (() -> Void)?
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
        hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 3
      else { return }
      let entries = ClipboardController.pasteboardItems(payloads: payloads)
      guard !entries.isEmpty else { return }
      dragging = true
      let image =
        preview ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        ?? NSImage(size: NSSize(width: 24, height: 24))
      let local = convert(event.locationInWindow, from: nil)
      let items = entries.enumerated().map { index, entry in
        let item = NSDraggingItem(pasteboardWriter: entry)
        item.setDraggingFrame(
          NSRect(
            x: local.x + Double(index * 4), y: local.y,
            width: 32, height: 32), contents: image)
        return item
      }
      beginDraggingSession(with: items, event: event, source: self)
    }
    func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }
  }
}
