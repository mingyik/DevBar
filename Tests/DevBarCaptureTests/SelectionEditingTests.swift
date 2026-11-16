import AppKit
import Testing

@testable import DevBarCapture

@MainActor @Test func scrollingSelectionStartsWhenRegionIsReleased() throws {
  _ = NSApplication.shared
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless,
    backing: .buffered, defer: false)
  let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
  window.contentView = view
  view.screenFrame = view.bounds
  view.scrollingRequested = true
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
  #expect(completed)
  #expect(view.scrollingRequested)
  #expect(!view.saveRequested)

}

@MainActor @Test func scrollingSelectionIgnoresFurtherDraggingAfterCaptureBegins() throws {
  _ = NSApplication.shared
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless,
    backing: .buffered, defer: false)
  let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
  window.contentView = view
  view.screenFrame = view.bounds
  view.scrollingRequested = true
  var completions = 0
  view.complete = { _ in completions += 1 }
  func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    )
  }
  view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 150)))
  view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 600, y: 450)))
  let original = view.selection
  view.beginScrollingProgress()
  for point in [
    CGPoint(x: original.midX, y: original.midY),
    CGPoint(x: original.minX, y: original.minY), CGPoint(x: original.midX, y: original.minY),
    CGPoint(x: original.maxX, y: original.minY), CGPoint(x: original.maxX, y: original.midY),
    CGPoint(x: original.maxX, y: original.maxY), CGPoint(x: original.midX, y: original.maxY),
    CGPoint(x: original.minX, y: original.maxY), CGPoint(x: original.minX, y: original.midY),
  ] {
    view.mouseDown(with: try event(.leftMouseDown, point))
    view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 700, y: 500)))
    view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 700, y: 500)))
  }
  for code: UInt16 in [36, 53, 123, 124, 125, 126] {
    view.keyDown(
      with: try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: "",
          charactersIgnoringModifiers: "",
          isARepeat: false, keyCode: code)))
  }
  #expect(view.selection == original)
  #expect(completions == 1)
  #expect(view.subviews.isEmpty)
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
    var completed = false
    view.complete = { _ in completed = true }
    let currentBar = try #require(view.subviews.compactMap { $0 as? NSVisualEffectView }.first)
    let scroll = try #require(
      currentBar.subviews.compactMap { $0 as? NSButton }.first {
        $0.identifier?.rawValue == "scroll"
      })
    scroll.performClick(nil)
    #expect(completed)
    #expect(view.scrollingRequested)
    view.beginScrollingProgress()
    #expect(view.subviews.compactMap { $0 as? NSVisualEffectView }.isEmpty)
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

@Test func scrollingSelectionPrefersTheFrontmostWindowAtItsCenter() {
  // The window behind overlaps more of the selection, but the center is on
  // the front window. The old largest-area rule would pick the one behind.
  let front = CGRect(x: 100, y: 100, width: 200, height: 200)
  let behind = CGRect(x: 0, y: 0, width: 1000, height: 1000)
  let selection = CGRect(x: 80, y: 80, width: 400, height: 400)
  #expect(SelectionView.windowChoice(frames: [front, behind], selection: selection) == 0)
  // Center outside every window: fall back to the largest overlap.
  let left = CGRect(x: 0, y: 0, width: 100, height: 100)
  let right = CGRect(x: 300, y: 0, width: 200, height: 200)
  let outside = CGRect(x: 50, y: 0, width: 400, height: 80)
  #expect(SelectionView.windowChoice(frames: [left, right], selection: outside) == 1)
}
