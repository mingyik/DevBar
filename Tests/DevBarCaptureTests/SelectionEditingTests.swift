import AppKit
import Testing

@testable import DevBarCapture

@MainActor @Test func scrollingSelectionConfirmsManualCaptureWithoutPlayButton() throws {
  _ = NSApplication.shared
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless,
    backing: .buffered, defer: false)
  let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
  window.contentView = view
  view.screenFrame = view.bounds
  var completed = false
  view.complete = { result in
    if case .success = result { completed = true }
  }
  func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    )
  }
  view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 150)))
  view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 600, y: 450)))
  let bar = try #require(view.subviews.first as? NSVisualEffectView)
  #expect(bar.frame.height == 40)
  let buttons = bar.subviews.compactMap { $0 as? NSButton }
  #expect(buttons.compactMap { $0.identifier?.rawValue } == ["save", "cancel", "confirm"])
  #expect(!bar.subviews.contains { $0 is NSBox })
  #expect(!completed)
  let confirm = try #require(buttons.first { $0.identifier?.rawValue == "confirm" })
  confirm.performClick(nil)
  #expect(completed)
  #expect(view.scrollingRequested)
  #expect(!view.saveRequested)
}

@MainActor @Test func screenshotToolbarUsesConsistentColorsInBothAppearances() throws {
  _ = NSApplication.shared
  for name in [NSAppearance.Name.aqua, .darkAqua] {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: name)
    let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = view
    view.screenFrame = view.bounds
    view.iconColor = .textColor
    view.disabledIconColor = .tertiaryLabelColor
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    view.frozenFrame = bitmap.cgImage
    func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
    }
    view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 150)))
    view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 600, y: 450)))
    let bar = try #require(view.subviews.first as? NSVisualEffectView)
    #expect(bar.frame.height == 40)
    #expect(bar.layer?.borderWidth == 1)
    let buttons = bar.subviews.compactMap { $0 as? NSButton }
    for button in buttons {
      #expect(button.frame.height == 30)
      #expect(!button.allowsVibrancy)
      #expect(bar.bounds.contains(button.frame))
      #expect(button.image?.size == NSSize(width: 18, height: 18))
      #expect(button.image?.isTemplate == true)
      #expect(button.image?.representations.contains { $0 is NSCustomImageRep } == true)
      if button.identifier?.rawValue == "select" {
        #expect(button.contentTintColor == .systemBlue)  // devbar:allow-color
      } else if button.identifier?.rawValue == "undo" {
        #expect(!button.isEnabled)
        #expect(button.contentTintColor == view.disabledIconColor)
      } else {
        #expect(button.contentTintColor == view.iconColor)
      }
    }
    let arrow = try #require(buttons.first { $0.identifier?.rawValue == "arrow" })
    if let directory = ProcessInfo.processInfo.environment["DEVBAR_TOOLBAR_REVIEW_DIR"],
      let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)
    {
      bar.cacheDisplay(in: bar.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(
        to: URL(fileURLWithPath: directory).appending(path: "toolbar-\(name.rawValue).png"))
    }
    arrow.performClick(nil)
    let bars = view.subviews.compactMap { $0 as? NSVisualEffectView }
    let options = try #require(bars.last)
    let modeButtons = options.subviews.compactMap { $0 as? NSButton }.prefix(2)
    #expect(modeButtons.count == 2)
    for button in modeButtons {
      #expect(button.image?.size == NSSize(width: 18, height: 18))
      #expect(button.image?.representations.contains { $0 is NSCustomImageRep } == true)
      #expect(NSStringFromClass(type(of: button)) == NSStringFromClass(type(of: arrow)))
    }
  }
}

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

@MainActor @Test func liveSelectionRedrawDoesNotAccumulateMask() throws {
  let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
  NSGraphicsContext.saveGraphicsState()
  defer { NSGraphicsContext.restoreGraphicsState() }
  NSGraphicsContext.current = context
  view.draw(view.bounds)
  let first = Data(
    bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
  view.draw(view.bounds)
  let second = Data(
    bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
  #expect(first == second)
}

@MainActor @Test func annotationClickRequiresDragAndOutsideClickPreservesSelection() throws {
  let window = NSWindow(
    contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless,
    backing: .buffered, defer: false)
  let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
  window.contentView = view
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  view.frozenFrame = bitmap.cgImage
  view.screenFrame = view.bounds
  view.scale = 1
  func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    )
  }
  func button(_ name: String) throws -> NSButton {
    try #require(
      view.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }.first {
        $0.identifier?.rawValue == name
      })
  }
  view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 150)))
  view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 600, y: 450)))
  try button("arrow").performClick(nil)
  view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 200, y: 200)))
  view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 200, y: 200)))
  #expect(try !button("undo").isEnabled)
  view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 200, y: 200)))
  view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 300, y: 300)))
  #expect(try button("undo").isEnabled)
  let beforeStyleChange = try CaptureFileWriter.encode(#require(view.exportFrame()))
  let slider = try #require(view.subviews.flatMap(\.subviews).compactMap { $0 as? NSSlider }.first)
  slider.doubleValue = 9
  NSApp.sendAction(try #require(slider.action), to: slider.target, from: slider)
  #expect(try CaptureFileWriter.encode(#require(view.exportFrame())) == beforeStyleChange)
  try button("rect").performClick(nil)
  let rectangleSlider = try #require(
    view.subviews.flatMap(\.subviews).compactMap { $0 as? NSSlider }.first)
  #expect(rectangleSlider.doubleValue == 3)
  try button("arrow").performClick(nil)
  let arrowSlider = try #require(
    view.subviews.flatMap(\.subviews).compactMap { $0 as? NSSlider }.first)
  #expect(arrowSlider.doubleValue == 9)
  view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 20, y: 20)))
  view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 20, y: 20)))
  var region: CaptureRegion?
  view.complete = { region = try? $0.get() }
  try button("save").performClick(nil)
  #expect(region?.pixelRect.width == 500)
  #expect(region?.pixelRect.height == 300)
}
