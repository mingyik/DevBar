// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Adapted for DevBar.

import AppKit
import CoreImage

/// One selection overlay per display, optionally using a frozen frame.
@MainActor
public final class SelectionOverlay {
  private var panels: [NSPanel] = []
  private var frozenFrames: [CGDirectDisplayID: CGImage] = [:]
  public private(set) var scrollingRequested = false
  public private(set) var saveRequested = false
  public private(set) var completionRequested = false
  private var renderedFrame: CGImage?
  private var preparing = false
  private var continuation: CheckedContinuation<CaptureRegion, any Error>?
  private var timeoutTask: Task<Void, Never>?

  private let appearanceName: NSAppearance.Name?
  public init(appearanceName: NSAppearance.Name? = nil) { self.appearanceName = appearanceName }

  public func selectImage(timeout: Duration = .seconds(60)) async throws -> (CaptureRegion, CGImage)
  {
    guard continuation == nil, !preparing else { throw CaptureError.alreadyRunning }
    defer { frozenFrames.removeAll() }
    let region = try await select(timeout: timeout)
    guard let frame = renderedFrame ?? frozenFrames[region.displayID],
      let image = frame.cropping(to: region.pixelRect)
    else { throw CaptureError.noImage }
    return (region, image)
  }

  public func select(freeze: Bool = true, timeout: Duration = .seconds(60)) async throws
    -> CaptureRegion
  {
    guard continuation == nil, !preparing else { throw CaptureError.alreadyRunning }
    preparing = true
    defer { preparing = false }
    frozenFrames.removeAll()
    renderedFrame = nil
    scrollingRequested = false
    // Freeze before showing any overlays; each image is captured at native pixels.
    if freeze {
      for screen in NSScreen.screens {
        guard
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        else { continue }
        let region = try CaptureRegion(
          displayID: number.uint32Value, globalRect: screen.frame,
          screenFrame: screen.frame, scale: screen.backingScaleFactor)
        guard let image = await ScreenshotCaptureEngine.captureDisplayRegion(region: region)
        else { throw CaptureError.noImage }
        frozenFrames[number.uint32Value] = image
      }
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { reply in
        continuation = reply
        if Task.isCancelled {
          finish(.failure(CaptureError.cancelled))
          return
        }
        for screen in NSScreen.screens {
          guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
              as? NSNumber
          else { continue }
          let panel = SelectionPanel(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
          panel.isReleasedWhenClosed = false
          if let appearanceName { panel.appearance = NSAppearance(named: appearanceName) }
          panel.level = .screenSaver
          panel.isOpaque = false
          panel.backgroundColor = .clear
          panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
          let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
          view.frozenFrame = frozenFrames[number.uint32Value]
          view.screenFrame = screen.frame
          view.displayID = number.uint32Value
          view.scale = screen.backingScaleFactor
          view.onInteraction = { [weak self] in self?.timeoutTask?.cancel() }
          view.complete = { [weak self, weak view] result in
            self?.scrollingRequested = view?.scrollingRequested ?? false
            self?.saveRequested = view?.saveRequested ?? false
            self?.completionRequested = view?.completionRequested ?? false
            self?.renderedFrame = view?.exportFrame()
            self?.finish(result)
          }
          panel.contentView = view
          panels.append(panel)
          panel.orderFrontRegardless()
          if screen.frame.contains(NSEvent.mouseLocation) {
            panel.makeKey()
            panel.makeFirstResponder(view)
          }
        }
        guard !panels.isEmpty else {
          finish(.failure(CaptureError.displayUnavailable))
          return
        }
        timeoutTask = Task { [weak self] in
          do { try await Task.sleep(for: timeout) } catch { return }
          self?.finish(.failure(CaptureError.timedOut))
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(.failure(CaptureError.cancelled)) }
    }
  }

  private func finish(_ result: Result<CaptureRegion, any Error>) {
    guard let reply = continuation else { return }
    continuation = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    for panel in panels { panel.orderOut(nil) }
    panels.removeAll()
    reply.resume(with: result)
  }
}

@MainActor
private final class SelectionPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

@MainActor
final class SelectionView: NSView {
  var frozenFrame: CGImage?
  var screenFrame = CGRect.zero
  var displayID: CGDirectDisplayID = 0
  var scale: CGFloat = 1
  var complete: ((Result<CaptureRegion, any Error>) -> Void)?
  private var anchor: CGPoint?
  private var selection = CGRect.zero
  var scrollingRequested = false
  var saveRequested = false
  var completionRequested = false
  var onInteraction: (() -> Void)?
  private var tool = "select"
  private struct ToolStyle {
    var color = NSColor.systemRed  // devbar:allow-color
    var width: CGFloat = 3
    var size: CGFloat = 18
  }
  private var styles: [String: ToolStyle] = [:]
  private var ink: NSColor {
    get { styles[tool, default: ToolStyle()].color }
    set { styles[tool, default: ToolStyle()].color = newValue }
  }
  private var stroke: CGFloat {
    get { styles[tool, default: ToolStyle()].width }
    set { styles[tool, default: ToolStyle()].width = newValue }
  }
  private var fontSize: CGFloat {
    get { styles[tool, default: ToolStyle()].size }
    set { styles[tool, default: ToolStyle()].size = newValue }
  }
  private var largeArrow = false
  private var editingArrow: (index: Int, start: Bool, fixed: CGPoint)?
  private var mosaicBrush = true
  private var optionsBar: NSVisualEffectView?
  private var marks: [(String, NSBezierPath, NSColor, CGFloat)] = []
  private var draft: NSBezierPath?
  private var moveOrigin: CGRect?
  private var resizeHandle: CGPoint?
  private var toolbar: NSVisualEffectView?
  private var mosaicFrame: CGImage?
  private var texts: [(String, CGPoint, NSColor, CGFloat)] = []
  private var undoKinds: [String] = []
  private var selectedMark: Int?
  private var selectedText: Int?

  func exportFrame() -> CGImage? {
    guard let frozenFrame else { return nil }
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: frozenFrame.width,
        pixelsHigh: frozenFrame.height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(
      x: CGFloat(frozenFrame.width) / bounds.width, y: CGFloat(frozenFrame.height) / bounds.height)
    NSImage(cgImage: frozenFrame, size: bounds.size).draw(in: bounds)
    drawMarks()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.cgImage
  }

  private func drawMarks(clipped: Bool = true) {
    NSGraphicsContext.saveGraphicsState()
    if clipped { NSBezierPath(rect: selection).addClip() }
    NSColor.labelColor.setStroke()
    let displayed =
      marks
      + (draft.map { [(tool == "arrow" && largeArrow ? "arrowFilled" : tool, $0, ink, stroke)] }
        ?? [])
    for (kind, path, color, weight) in displayed {
      color.setStroke()
      if kind == "mosaic", let frozenFrame {
        if mosaicFrame == nil {
          let source = CIImage(cgImage: frozenFrame)
          let filtered = source.applyingFilter(
            "CIPixellate", parameters: [kCIInputScaleKey: 14 * scale])
          mosaicFrame = CIContext().createCGImage(filtered, from: source.extent)
        }
        if let mosaicFrame {
          NSGraphicsContext.saveGraphicsState()
          path.addClip()
          NSImage(cgImage: mosaicFrame, size: bounds.size).draw(in: bounds)
          NSGraphicsContext.restoreGraphicsState()
        }
      } else if kind == "highlight" {
        color.withAlphaComponent(0.2).setFill()
        path.fill()
      } else {
        path.lineWidth = weight
        if kind == "arrowFilled" {
          color.setFill()
          path.fill()
        } else {
          path.stroke()
        }
      }
    }
    for (text, point, color, size) in texts {
      text.draw(
        at: point,
        withAttributes: [
          .font: NSFont.systemFont(ofSize: size), .foregroundColor: color,
        ])
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  private func drawObjectSelection() {
    var points: [CGPoint] = []
    var box: CGRect?
    if let draft, tool == "rect" || tool == "ellipse" {
      points = objectHandles(draft.bounds)
    } else if let index = selectedMark, marks.indices.contains(index) {
      let (kind, path, _, _) = marks[index]
      if kind.hasPrefix("arrow"), path.elementCount >= 2 {
        var first = [NSPoint](repeating: .zero, count: 3)
        var last = first
        _ = path.element(at: 0, associatedPoints: &first)
        _ = path.element(at: 1, associatedPoints: &last)
        points = [first[0], last[0]]
      } else if kind == "rect" || kind == "ellipse" {
        points = objectHandles(path.bounds)
      } else {
        box = path.bounds.insetBy(dx: -5, dy: -5)
      }
    } else if let index = selectedText, texts.indices.contains(index) {
      box = textBounds(index).insetBy(dx: -6, dy: -4)
    }
    NSColor.systemBlue.setStroke()  // devbar:allow-color
    if let box {
      let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
      path.lineWidth = 2
      path.stroke()
    }
    for point in points {
      let dot = NSBezierPath(
        ovalIn: NSRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
      NSColor.systemBlue.setFill()  // devbar:allow-color
      dot.fill()
      NSColor.white.setStroke()  // devbar:allow-color
      dot.lineWidth = 1
      dot.stroke()
    }
  }

  static func arrowPath(start: CGPoint, end: CGPoint, width: CGFloat, large: Bool) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    let angle = atan2(end.y - start.y, end.x - start.x)
    let length = hypot(end.x - start.x, end.y - start.y)
    if large {
      let head = min(length * 0.45, max(18, width * 6))
      let ux = cos(angle)
      let uy = sin(angle)
      let nx = -uy
      let ny = ux
      let base = CGPoint(x: end.x - head * ux, y: end.y - head * uy)
      let outer = head * 0.48
      let inner = max(width * 0.45, head * 0.13)
      path.move(to: start)
      path.line(to: CGPoint(x: base.x + inner * nx, y: base.y + inner * ny))
      path.line(to: CGPoint(x: base.x + outer * nx, y: base.y + outer * ny))
      path.line(to: end)
      path.line(to: CGPoint(x: base.x - outer * nx, y: base.y - outer * ny))
      path.line(to: CGPoint(x: base.x - inner * nx, y: base.y - inner * ny))
      path.close()
    } else {
      let head = min(length * 0.6, max(12, width * 3))
      let left = CGPoint(x: end.x - head * cos(angle - 0.5), y: end.y - head * sin(angle - 0.5))
      let right = CGPoint(x: end.x - head * cos(angle + 0.5), y: end.y - head * sin(angle + 0.5))
      path.move(to: left)
      path.line(to: end)
      path.line(to: right)
    }
    return path
  }

  private func objectHandles(_ rect: CGRect) -> [CGPoint] {
    [
      CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
      CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
    ]
  }

  private func textBounds(_ index: Int) -> CGRect {
    CGRect(
      origin: texts[index].1,
      size: texts[index].0.size(withAttributes: [.font: NSFont.systemFont(ofSize: texts[index].3)]))
  }

  private func showToolbar() {
    toolbar?.removeFromSuperview()
    optionsBar?.removeFromSuperview()
    let bar = NSVisualEffectView()
    bar.material = .hudWindow
    bar.blendingMode = .withinWindow
    bar.state = .active
    bar.wantsLayer = true
    bar.layer?.cornerRadius = 10
    bar.layer?.borderWidth = 0.5
    bar.layer?.borderColor = NSColor.separatorColor.cgColor
    var tools = [
      ("hand.draw", "select"), ("rectangle", "rect"), ("circle", "ellipse"),
      ("arrow.up.right", "arrow"), ("pencil.tip", "pen"), ("textformat", "text"),
      ("aqi.medium", "mosaic"), ("highlighter", "highlight"), ("arrow.uturn.backward", "undo"),
      ("rectangle.stack", "scroll"), ("arrow.down.to.line", "save"), ("xmark", "cancel"),
    ]
    if frozenFrame == nil {
      tools = [
        ("play.fill", "scroll"), ("arrow.down.to.line", "save"), ("xmark", "cancel"),
        ("checkmark", "confirm"),
      ]
    }
    let breaks: Set<Int> = frozenFrame == nil ? [1] : [1, 8, 10]
    let width = CGFloat(tools.count * 44 + 24 + breaks.count * 12)
    let x = min(max(selection.maxX - width, 8), bounds.maxX - width - 8)
    let y = selection.minY > 64 ? selection.minY - 60 : min(selection.maxY + 10, bounds.maxY - 54)
    bar.frame = NSRect(x: x, y: y, width: width, height: 50)
    var offset: CGFloat = 12
    for (index, entry) in tools.enumerated() {
      if breaks.contains(index) {
        let separator = NSBox(frame: NSRect(x: offset + 5, y: 13, width: 1, height: 24))
        separator.boxType = .separator
        bar.addSubview(separator)
        offset += 12
      }
      let button = CaptureToolbarButton(
        image: toolbarImage(symbol: entry.0, tool: entry.1), target: self,
        action: #selector(toolClicked(_:)))
      button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
      let action = ["save", "cancel", "confirm", "undo", "scroll"].contains(entry.1)
      let selected = !action && entry.1 == tool
      button.toolSelected = selected
      button.isEnabled = entry.1 != "undo" || !undoKinds.isEmpty
      if !button.isEnabled {
        button.contentTintColor = .disabledControlTextColor
      } else if selected {
        button.contentTintColor = .systemBlue
      }  // devbar:allow-color
      else {
        button.contentTintColor = .labelColor
      }
      button.wantsLayer = true
      button.layer?.cornerRadius = 7
      button.layer?.backgroundColor =
        selected ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : nil
      button.setAccessibilityValue(selected ? "1" : "0")
      button.identifier = NSUserInterfaceItemIdentifier(entry.1)
      button.isBordered = false
      button.frame = NSRect(x: offset, y: 5, width: 42, height: 40)
      offset += 44
      bar.addSubview(button)
    }
    addSubview(bar)
    toolbar = bar
    showOptions(below: bar.frame)
  }

  private func toolbarImage(symbol: String, tool: String) -> NSImage {
    if tool == "text" {
      let image = NSImage(size: NSSize(width: 24, height: 24))
      image.lockFocus()
      ("T" as NSString).draw(
        at: NSPoint(x: 5, y: 0),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 23, weight: .medium),
          .foregroundColor: NSColor.labelColor,
        ])
      image.unlockFocus()
      image.isTemplate = true
      return image
    }
    return NSImage(systemSymbolName: symbol, accessibilityDescription: tool)
      ?? NSImage(size: NSSize(width: 24, height: 24))
  }

  private var palette: [NSColor] {
    [
      .systemRed, .systemYellow, .systemBlue, .systemGreen,  // devbar:allow-color
      .black, .gray, .white,  // devbar:allow-color
    ]
  }

  private func showOptions(below frame: CGRect) {
    guard frozenFrame != nil,
      ["rect", "ellipse", "arrow", "pen", "text", "highlight", "mosaic"].contains(tool)
    else { return }
    let bar = NSVisualEffectView()
    bar.material = .hudWindow
    bar.blendingMode = .withinWindow
    bar.state = .active
    bar.wantsLayer = true
    bar.layer?.cornerRadius = 9
    bar.layer?.borderWidth = 0.5
    bar.layer?.borderColor = NSColor.separatorColor.cgColor
    let offset: CGFloat = tool == "arrow" || tool == "mosaic" ? 100 : 0
    let width: CGFloat = (tool == "mosaic" ? 180 : 430) + offset
    let y = frame.minY >= 56 ? frame.minY - 54 : min(frame.maxY + 6, bounds.maxY - 48)
    bar.frame = CGRect(
      x: min(max(frame.minX, 8), bounds.maxX - width - 8), y: y, width: width, height: 46)
    let slider = NSSlider(
      value: Double(tool == "text" ? fontSize : stroke), minValue: tool == "text" ? 10 : 1,
      maxValue: tool == "text" ? 48 : 12, target: self, action: #selector(styleChanged(_:)))
    if offset > 0 {
      for index in 0..<2 {
        let title = tool == "arrow" ? (index == 0 ? "大头" : "普通") : (index == 0 ? "涂抹" : "框选")
        let button = NSButton(
          image: modeImage(index: index), target: self, action: #selector(modeChanged(_:)))
        button.toolTip = title
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.tag = index
        button.isBordered = false
        button.wantsLayer = true
        let active = tool == "arrow" ? (largeArrow == (index == 0)) : (mosaicBrush == (index == 0))
        button.contentTintColor = active ? .systemBlue : .labelColor  // devbar:allow-color
        button.layer?.cornerRadius = 5
        button.layer?.backgroundColor =
          active ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : nil
        button.frame = CGRect(x: 6 + index * 46, y: 7, width: 44, height: 32)
        bar.addSubview(button)
      }
    }
    slider.frame = CGRect(x: 12 + offset, y: 10, width: 140, height: 26)
    bar.addSubview(slider)
    if tool != "mosaic" {
      for (index, color) in palette.enumerated() {
        let button = NSButton(
          title: color == ink ? "✓" : "", target: self, action: #selector(colorChanged(_:)))
        button.tag = index
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = color.cgColor
        button.contentTintColor = index == 1 || index == 6 ? .black : .white  // devbar:allow-color
        button.frame = CGRect(x: 165 + index * 36 + Int(offset), y: 9, width: 28, height: 28)
        bar.addSubview(button)
      }
    }
    addSubview(bar)
    optionsBar = bar
  }

  private func modeImage(index: Int) -> NSImage {
    if tool == "mosaic", index == 0 {
      return NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: nil)
        ?? NSImage(size: NSSize(width: 24, height: 24))
    }
    let image = NSImage(size: NSSize(width: 24, height: 24))
    image.lockFocus()
    NSColor.labelColor.setFill()
    NSColor.labelColor.setStroke()
    if tool == "arrow" {
      let path = Self.arrowPath(
        start: CGPoint(x: 3, y: 3), end: CGPoint(x: 22, y: 22), width: 2, large: index == 0)
      if index == 0 {
        path.fill()
      } else {
        path.lineWidth = 2
        path.stroke()
      }
    } else {
      let rect = CGRect(x: 4, y: 4, width: 16, height: 16)
      let path = NSBezierPath(rect: rect)
      path.lineWidth = 1.5
      path.stroke()
      for point in [
        CGPoint(x: 4, y: 4), CGPoint(x: 20, y: 4), CGPoint(x: 4, y: 20), CGPoint(x: 20, y: 20),
      ] {
        NSBezierPath(ovalIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
      }
    }
    image.unlockFocus()
    image.isTemplate = true
    return image
  }

  @objc private func modeChanged(_ sender: NSButton) {
    if tool == "arrow" { largeArrow = sender.tag == 0 } else { mosaicBrush = sender.tag == 0 }
    showToolbar()
  }

  @objc private func styleChanged(_ slider: NSSlider) {
    if tool == "text" {
      fontSize = CGFloat(slider.doubleValue)
    } else {
      stroke = CGFloat(slider.doubleValue)
    }
    applyStyle()
  }
  @objc private func colorChanged(_ button: NSButton) {
    ink = palette[button.tag]
    applyStyle()
    showToolbar()
  }
  private func applyStyle() {
    for field in subviews.compactMap({ $0 as? NSTextField }) {
      field.font = .systemFont(ofSize: fontSize)
      field.textColor = ink
      field.frame.size.height = ceil(fontSize * 1.5 + 8)
      field.frame.size.width = min(
        max(80, CGFloat(field.stringValue.count + 2) * fontSize), selection.maxX - field.frame.minX)
    }
    needsDisplay = true
  }

  @objc private func toolClicked(_ sender: NSButton) {
    for field in subviews.compactMap({ $0 as? NSTextField }) { commitText(field) }
    switch sender.identifier?.rawValue {
    case "save":
      saveRequested = true
      confirm()
    case "confirm":
      completionRequested = true
      scrollingRequested = true
      confirm()
    case "cancel": complete?(.failure(CaptureError.cancelled))
    case "scroll":
      scrollingRequested = true
      confirm()
    case "undo":
      selectedMark = nil
      selectedText = nil
      if let kind = undoKinds.popLast() {
        if kind == "text" { texts.removeLast() } else { marks.removeLast() }
      }
      needsDisplay = true
      showToolbar()
    case let value?:
      tool = value
      showToolbar()
    default: break
    }
  }
  override var acceptsFirstResponder: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.current?.cgContext.clear(bounds)
    if let frame = frozenFrame {
      NSImage(cgImage: frame, size: bounds.size).draw(in: bounds)
    }
    drawMarks(clipped: false)
    NSColor.black.withAlphaComponent(0.4).setFill()  // devbar:allow-color
    bounds.fill()
    if !selection.isEmpty {
      if let frame = frozenFrame {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        NSImage(cgImage: frame, size: bounds.size).draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
      } else {
        NSGraphicsContext.current?.cgContext.clear(selection)
      }
      NSColor.systemBlue.setStroke()  // devbar:allow-color
      let outline = NSBezierPath(rect: selection)
      outline.lineWidth = 3
      outline.stroke()
      drawMarks()
      drawObjectSelection()
      for point in handles {
        let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        NSColor.systemBlue.setFill()  // devbar:allow-color
        dot.fill()
        NSColor.white.setStroke()  // devbar:allow-color
        dot.lineWidth = 1
        dot.stroke()
      }
      let label = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))"
      let attributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.white,
        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),  // devbar:allow-color
      ]
      let size = label.size(withAttributes: attributes)
      let badge = NSRect(
        x: min(selection.minX, bounds.maxX - size.width - 20),
        y: min(selection.maxY + 8, bounds.maxY - 30), width: size.width + 20, height: 26)
      NSColor.black.withAlphaComponent(0.65).setFill()  // devbar:allow-color
      NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
      label.draw(at: CGPoint(x: badge.minX + 10, y: badge.minY + 5), withAttributes: attributes)
    }
  }

  private var handles: [CGPoint] {
    [
      CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.midX, y: selection.minY),
      CGPoint(x: selection.maxX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.midY),
      CGPoint(x: selection.maxX, y: selection.maxY), CGPoint(x: selection.midX, y: selection.maxY),
      CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.minX, y: selection.midY),
    ]
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeKey()
    window?.makeFirstResponder(self)
    let point = convert(event.locationInWindow, from: nil)
    onInteraction?()
    if let index = selectedMark, marks.indices.contains(index), marks[index].0.hasPrefix("arrow") {
      let path = marks[index].1
      if path.elementCount >= 2 {
        var start = [NSPoint](repeating: .zero, count: 3)
        var end = start
        _ = path.element(at: 0, associatedPoints: &start)
        _ = path.element(at: 1, associatedPoints: &end)
        if hypot(point.x - start[0].x, point.y - start[0].y) < 9 {
          editingArrow = (index, true, end[0])
          anchor = point
          return
        }
        if hypot(point.x - end[0].x, point.y - end[0].y) < 9 {
          editingArrow = (index, false, start[0])
          anchor = point
          return
        }
      }
    }
    anchor = point
    if !selection.isEmpty && !selection.insetBy(dx: -9, dy: -9).contains(point) {
      for field in subviews.compactMap({ $0 as? NSTextField }) { commitText(field) }
      selectedMark = nil
      selectedText = nil
      anchor = nil
      needsDisplay = true
      return
    }
    selectedMark = nil
    selectedText = nil
    if tool == "select" && selection.contains(point) {
      if let index = texts.indices.reversed().first(where: {
        textBounds($0).insetBy(dx: -6, dy: -4).contains(point)
      }) {
        selectedText = index
        tool = "text"
        showToolbar()
        anchor = nil
        needsDisplay = true
        return
      }
      if let index = marks.indices.reversed().first(where: {
        marks[$0].1.bounds.insetBy(dx: -6, dy: -6).contains(point)
      }) {
        selectedMark = index
        tool = marks[index].0.hasPrefix("arrow") ? "arrow" : marks[index].0
        showToolbar()
        anchor = nil
        needsDisplay = true
        return
      }
    }
    if tool == "text" && selection.contains(point) {
      let field = NSTextField(string: "")
      field.frame = NSRect(
        x: point.x, y: point.y, width: min(200, selection.maxX - point.x),
        height: ceil(fontSize * 1.5 + 8))
      field.isBordered = false
      field.drawsBackground = false
      field.font = .systemFont(ofSize: fontSize)
      field.textColor = ink
      field.wantsLayer = true
      field.layer?.cornerRadius = 4
      field.layer?.borderWidth = 2
      field.layer?.borderColor = NSColor.systemBlue.cgColor  // devbar:allow-color
      field.target = self
      field.action = #selector(commitText(_:))
      addSubview(field)
      window?.makeFirstResponder(field)
      anchor = nil
      return
    }
    if !selection.isEmpty && tool != "select" && selection.contains(point) {
      draft = NSBezierPath()
      draft?.move(to: point)
    } else if !selection.isEmpty {
      resizeHandle = handles.first { hypot($0.x - point.x, $0.y - point.y) < 9 }
      moveOrigin = selection.contains(point) || resizeHandle != nil ? selection : nil
    }
  }

  @objc private func commitText(_ field: NSTextField) {
    if !field.stringValue.isEmpty {
      texts.append((field.stringValue, field.frame.origin, ink, fontSize))
      undoKinds.append("text")
      selectedText = texts.count - 1
    }
    field.removeFromSuperview()
    needsDisplay = true
    showToolbar()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let anchor else { return }
    let point = convert(event.locationInWindow, from: nil)
    if let edit = editingArrow {
      let clamped = CGPoint(
        x: min(max(point.x, selection.minX), selection.maxX),
        y: min(max(point.y, selection.minY), selection.maxY))
      marks[edit.index].1 = Self.arrowPath(
        start: edit.start ? clamped : edit.fixed,
        end: edit.start ? edit.fixed : clamped, width: marks[edit.index].3,
        large: marks[edit.index].0 == "arrowFilled")
      needsDisplay = true
      return
    }
    if draft != nil {
      if tool == "mosaic" && mosaicBrush {
        let last = draft?.currentPoint ?? anchor
        let distance = hypot(point.x - last.x, point.y - last.y)
        let steps = max(1, Int(distance / 3))
        let diameter = max(16, stroke * 6)
        for step in 0...steps {
          let t = CGFloat(step) / CGFloat(steps)
          let center = CGPoint(
            x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t)
          draft?.appendOval(
            in: CGRect(
              x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter,
              height: diameter))
        }
        draft?.move(to: point)
      } else if tool == "pen" {
        draft?.line(to: point)
      } else {
        let rect = CGRect(
          x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x),
          height: abs(point.y - anchor.y))
        if tool == "rect" || tool == "mosaic" || tool == "highlight" {
          draft = NSBezierPath(rect: rect)
        } else if tool == "ellipse" {
          draft = NSBezierPath(ovalIn: rect)
        } else {
          draft = Self.arrowPath(start: anchor, end: point, width: stroke, large: largeArrow)
        }
      }
    } else if let original = moveOrigin {
      if let handle = resizeHandle {
        var left = original.minX
        var right = original.maxX
        var bottom = original.minY
        var top = original.maxY
        if handle.x == original.minX { left = min(point.x, right - 4) }
        if handle.x == original.maxX { right = max(point.x, left + 4) }
        if handle.y == original.minY { bottom = min(point.y, top - 4) }
        if handle.y == original.maxY { top = max(point.y, bottom + 4) }
        selection = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
          .intersection(bounds)
      } else {
        selection.origin = CGPoint(
          x: min(max(original.minX + point.x - anchor.x, 0), bounds.width - original.width),
          y: min(max(original.minY + point.y - anchor.y, 0), bounds.height - original.height))

      }
    } else {
      selection = CGRect(
        x: min(anchor.x, point.x), y: min(anchor.y, point.y),
        width: abs(anchor.x - point.x), height: abs(anchor.y - point.y)
      ).intersection(bounds)
    }
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    let end = convert(event.locationInWindow, from: nil)
    if let anchor, draft != nil, hypot(end.x - anchor.x, end.y - anchor.y) < 3 {
      draft = nil
    } else {
      mouseDragged(with: event)
    }
    if let draft {
      marks.append((tool == "arrow" && largeArrow ? "arrowFilled" : tool, draft, ink, stroke))
      undoKinds.append("mark")
      selectedMark = marks.count - 1
      self.draft = nil
    }
    anchor = nil
    editingArrow = nil
    moveOrigin = nil
    resizeHandle = nil
    if !selection.isEmpty { showToolbar() }
    needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      complete?(.failure(CaptureError.cancelled))
    } else if event.keyCode == 36 {
      confirm()
    } else {
      super.keyDown(with: event)
    }
  }

  private func confirm() {
    guard selection.width > 0, selection.height > 0 else { return }
    let global = selection.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
    complete?(
      Result {
        try CaptureRegion(
          displayID: displayID, globalRect: global, screenFrame: screenFrame, scale: scale)
      })
  }
}

@MainActor private final class CaptureToolbarButton: NSButton {
  var toolSelected = false
  private var hovered = false
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) {
    hovered = true
    refreshBackground()
  }
  override func mouseExited(with event: NSEvent) {
    hovered = false
    refreshBackground()
  }
  private func refreshBackground() {
    layer?.backgroundColor =
      isEnabled && (toolSelected || hovered)
      ? NSColor.labelColor.withAlphaComponent(toolSelected ? 0.12 : 0.08).cgColor : nil
  }
}
