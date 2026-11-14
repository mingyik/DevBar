import AppKit
import WebKit

/// File URLs go to the native reader instead of WebKit navigation or editor insertion.
@MainActor final class FileDropWebView: WKWebView {
  var acceptsFiles: (() -> Bool)?
  var receivedFiles: (([URL]) -> Void)?
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  private func files(_ sender: any NSDraggingInfo) -> [URL] {
    sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
  }
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard sender.draggingPasteboard.types?.contains(.fileURL) == true else {
      return super.draggingEntered(sender)
    }
    return acceptsFiles?() == true ? .copy : []
  }
  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard sender.draggingPasteboard.types?.contains(.fileURL) == true else {
      return super.draggingUpdated(sender)
    }
    return acceptsFiles?() == true ? .copy : []
  }
  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard sender.draggingPasteboard.types?.contains(.fileURL) == true else {
      return super.prepareForDragOperation(sender)
    }
    return acceptsFiles?() == true
  }
  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard sender.draggingPasteboard.types?.contains(.fileURL) == true else {
      return super.performDragOperation(sender)
    }
    guard acceptsFiles?() == true else { return false }
    let urls = files(sender)
    guard !urls.isEmpty else { return false }
    receivedFiles?(urls)
    return true
  }
}
