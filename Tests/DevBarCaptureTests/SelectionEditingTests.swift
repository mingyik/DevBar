import AppKit
import Testing

@testable import DevBarCapture

@MainActor @Test func selectionStaysOpenUntilSaveAndExportsNativePixels() throws {
  _ = NSApplication.shared
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless,
    backing: .buffered, defer: false)
  let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
  window.contentView = view
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1200,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  view.frozenFrame = bitmap.cgImage
  view.screenFrame = view.bounds
  view.scale = 2
  var completed = false
  view.complete = { _ in completed = true }
  func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    )
  }
  view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 150)))
  view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 600, y: 450)))
  #expect(!completed)
  let bar = try #require(view.subviews.first as? NSVisualEffectView)
  let save = try #require(
    bar.subviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "save" })
  let exported = try #require(view.exportFrame())
  #expect(exported.width == 1600)
  #expect(exported.height == 1200)
  save.performClick(nil)
  #expect(completed)
}
