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
  private var renderedFrame: CGImage?
  private var preparing = false
  private var continuation: CheckedContinuation<CaptureRegion, any Error>?
  private var timeoutTask: Task<Void, Never>?

  private let appearanceName: NSAppearance.Name?
  private let iconColor: NSColor
  private let disabledIconColor: NSColor
  private let toolbarTintColor: NSColor
  private let toolbarBorderColor: NSColor
  public init(
    appearanceName: NSAppearance.Name? = nil,
    iconColor: NSColor = .labelColor, disabledIconColor: NSColor = .disabledControlTextColor,
    toolbarTintColor: NSColor = .clear, toolbarBorderColor: NSColor = .separatorColor
  ) {
    self.appearanceName = appearanceName
    self.iconColor = iconColor
    self.disabledIconColor = disabledIconColor
    self.toolbarTintColor = toolbarTintColor
    self.toolbarBorderColor = toolbarBorderColor
  }

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
          panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary,
          ]
          let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
          view.iconColor = iconColor
          view.disabledIconColor = disabledIconColor
          view.toolbarTintColor = toolbarTintColor
          view.toolbarBorderColor = toolbarBorderColor
          view.frozenFrame = frozenFrames[number.uint32Value]
          view.scrollingRequested = !freeze
          view.screenFrame = screen.frame
          view.displayID = number.uint32Value
          view.scale = screen.backingScaleFactor
          view.onInteraction = { [weak self] in self?.timeoutTask?.cancel() }
          view.complete = { [weak self, weak view] result in
            self?.scrollingRequested = view?.scrollingRequested ?? false
            self?.saveRequested = view?.saveRequested ?? false
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
    if case .success = result, scrollingRequested {
      for panel in panels {
        (panel.contentView as? SelectionView)?.beginScrollingProgress()
        panel.ignoresMouseEvents = true
        if panel.isKeyWindow { panel.resignKey() }
      }
    } else {
      dismissScrollingOverlay()
    }
    reply.resume(with: result)
  }
  public func dismissScrollingOverlay() {
    for panel in panels { panel.orderOut(nil) }
    panels.removeAll()
  }

}

@MainActor
private final class SelectionPanel: NSPanel {
  override init(
    contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType,
    defer flag: Bool
  ) {
    super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
    animationBehavior = .none
    isMovable = false
    isMovableByWindowBackground = false
    hasShadow = false
  }
  required init?(coder: NSCoder) { nil }
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class SelectionView: NSView {
  var iconColor: NSColor = .labelColor
  var disabledIconColor: NSColor = .disabledControlTextColor
  var toolbarTintColor: NSColor = .clear
  var toolbarBorderColor: NSColor = .separatorColor
  var frozenFrame: CGImage?
  var screenFrame = CGRect.zero
  var displayID: CGDirectDisplayID = 0
  var scale: CGFloat = 1
  var complete: ((Result<CaptureRegion, any Error>) -> Void)?
  private var anchor: CGPoint?
  private(set) var selection = CGRect.zero
  var scrollingRequested = false
  var saveRequested = false
  var onInteraction: (() -> Void)?
  private var captureInProgress = false
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

  private var drawingKind: String {
    if tool == "arrow" && largeArrow { return "arrowFilled" }
    if tool == "mosaic" && !mosaicBrush { return "mosaicRect" }
    return tool
  }

  private func drawMarks(clipped: Bool = true) {
    NSGraphicsContext.saveGraphicsState()
    if clipped { NSBezierPath(rect: selection).addClip() }
    NSColor.labelColor.setStroke()
    let displayed =
      marks
      + (draft.map { [(drawingKind, $0, ink, stroke)] }
        ?? [])
    for (kind, path, color, weight) in displayed {
      color.setStroke()
      if kind.hasPrefix("mosaic"), let frozenFrame {
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
    if let draft, tool == "rect" || tool == "ellipse" || (tool == "mosaic" && !mosaicBrush) {
      points = objectHandles(draft.bounds)
    } else if let index = selectedMark, marks.indices.contains(index) {
      let (kind, path, _, _) = marks[index]
      if kind.hasPrefix("arrow"), path.elementCount >= 2 {
        var first = [NSPoint](repeating: .zero, count: 3)
        var last = first
        _ = path.element(at: 0, associatedPoints: &first)
        _ = path.element(at: 1, associatedPoints: &last)
        points = [first[0], last[0]]
      } else if kind == "rect" || kind == "ellipse" || kind == "mosaicRect" {
        points = objectHandles(path.bounds)
      } else if kind != "mosaic" {
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

  private func makeToolbar(cornerRadius: CGFloat) -> NSVisualEffectView {
    let bar = NSVisualEffectView()
    bar.material = .hudWindow
    bar.blendingMode = .withinWindow
    bar.state = .active
    bar.wantsLayer = true
    bar.layer?.cornerRadius = cornerRadius
    bar.layer?.masksToBounds = true
    bar.layer?.borderWidth = 1
    bar.layer?.borderColor = toolbarBorderColor.cgColor
    let tint = CaptureToolbarTintView(frame: bar.bounds)
    tint.autoresizingMask = [.width, .height]
    tint.wantsLayer = true
    tint.layer?.backgroundColor = toolbarTintColor.cgColor
    bar.addSubview(tint)
    return bar
  }

  private func showToolbar() {
    toolbar?.removeFromSuperview()
    optionsBar?.removeFromSuperview()
    let bar = makeToolbar(cornerRadius: 10)
    var tools = [
      ("hand.draw", "select"), ("rectangle", "rect"), ("circle", "ellipse"),
      ("arrow.up.right", "arrow"), ("pencil", "pen"), ("textformat", "text"),
      ("square.on.square", "mosaic"), ("arrow.uturn.backward", "undo"),
      ("rectangle.stack", "scroll"), ("arrow.down.to.line", "save"), ("xmark", "cancel"),
    ]
    if frozenFrame == nil {
      tools = [
        ("arrow.down.to.line", "save"), ("xmark", "cancel"),
        ("checkmark", "confirm"),
      ]
    }
    let breaks: Set<Int> = frozenFrame == nil ? [] : [1, 7, 9]
    let width = CGFloat(tools.count * 44 + 24 + breaks.count * 12)
    let x = min(max(selection.maxX - width, 8), bounds.maxX - width - 8)
    let y = selection.minY > 54 ? selection.minY - 50 : min(selection.maxY + 10, bounds.maxY - 44)
    bar.frame = NSRect(x: x, y: y, width: width, height: 40)
    var offset: CGFloat = 12
    for (index, entry) in tools.enumerated() {
      if breaks.contains(index) {
        let separator = NSBox(frame: NSRect(x: offset + 5, y: 10, width: 1, height: 20))
        separator.boxType = .separator
        bar.addSubview(separator)
        offset += 12
      }
      let button = CaptureToolbarButton(
        image: toolbarImage(symbol: entry.0, tool: entry.1), target: self,
        action: #selector(toolClicked(_:)))
      button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
      let action = ["save", "cancel", "confirm", "undo", "scroll"].contains(entry.1)
      let selected = !action && entry.1 == tool
      button.toolSelected = selected
      button.highlightColor = iconColor
      button.isEnabled = entry.1 != "undo" || !undoKinds.isEmpty
      if !button.isEnabled {
        button.contentTintColor = disabledIconColor
      } else if selected {
        button.contentTintColor = .systemBlue
      }  // devbar:allow-color
      else {
        button.contentTintColor = iconColor
      }
      button.wantsLayer = true
      button.layer?.cornerRadius = 7
      button.layer?.backgroundColor =
        selected ? iconColor.withAlphaComponent(0.12).cgColor : nil
      button.setAccessibilityValue(selected ? "1" : "0")
      button.identifier = NSUserInterfaceItemIdentifier(entry.1)
      button.isBordered = false
      button.frame = NSRect(x: offset, y: 5, width: 42, height: 30)
      offset += 44
      bar.addSubview(button)
    }
    addSubview(bar)
    toolbar = bar
    showOptions(below: bar.frame)
  }

  private func toolbarImage(symbol: String, tool: String) -> NSImage {
    if [
      "select", "rect", "ellipse", "text", "arrow", "pen", "mosaic", "undo", "scroll", "save",
      "cancel", "confirm",
    ].contains(tool) {
      let path = NSBezierPath()
      path.lineWidth = 1.35
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      switch tool {
      case "select":
        path.move(to: CGPoint(x: 6, y: 7))
        path.line(to: CGPoint(x: 6, y: 15))
        path.curve(
          to: CGPoint(x: 8.5, y: 15), controlPoint1: CGPoint(x: 6, y: 17),
          controlPoint2: CGPoint(x: 8.5, y: 17))
        path.line(to: CGPoint(x: 8.5, y: 10))
        path.move(to: CGPoint(x: 8.5, y: 12))
        path.curve(
          to: CGPoint(x: 11, y: 12), controlPoint1: CGPoint(x: 8.5, y: 14),
          controlPoint2: CGPoint(x: 11, y: 14))
        path.line(to: CGPoint(x: 11, y: 9.5))
        path.move(to: CGPoint(x: 11, y: 11))
        path.curve(
          to: CGPoint(x: 13.5, y: 11), controlPoint1: CGPoint(x: 11, y: 13),
          controlPoint2: CGPoint(x: 13.5, y: 13))
        path.line(to: CGPoint(x: 13.5, y: 8.5))
        path.move(to: CGPoint(x: 13.5, y: 9.5))
        path.curve(
          to: CGPoint(x: 16, y: 9.5), controlPoint1: CGPoint(x: 13.5, y: 11.5),
          controlPoint2: CGPoint(x: 16, y: 11.5))
        path.line(to: CGPoint(x: 16, y: 6))
        path.curve(
          to: CGPoint(x: 11, y: 2), controlPoint1: CGPoint(x: 16, y: 3),
          controlPoint2: CGPoint(x: 14, y: 2))
        path.line(to: CGPoint(x: 9, y: 2))
        path.curve(
          to: CGPoint(x: 6.5, y: 3.5), controlPoint1: CGPoint(x: 8, y: 2),
          controlPoint2: CGPoint(x: 7, y: 2.5))
        path.line(to: CGPoint(x: 2, y: 9))
        path.curve(
          to: CGPoint(x: 4.5, y: 11), controlPoint1: CGPoint(x: 0.5, y: 11),
          controlPoint2: CGPoint(x: 3, y: 12.5))
        path.line(to: CGPoint(x: 6, y: 9))
      case "rect":
        path.append(
          NSBezierPath(
            roundedRect: CGRect(x: 2, y: 3, width: 14, height: 12), xRadius: 1.5, yRadius: 1.5))
      case "ellipse":
        path.appendOval(in: CGRect(x: 2, y: 2, width: 14, height: 14))
      case "mosaic":
        path.append(
          NSBezierPath(
            roundedRect: CGRect(x: 2, y: 6, width: 10, height: 10), xRadius: 1.5, yRadius: 1.5))
        path.append(
          NSBezierPath(
            roundedRect: CGRect(x: 6, y: 2, width: 10, height: 10), xRadius: 1.5, yRadius: 1.5))
      case "undo":
        path.move(to: CGPoint(x: 3, y: 11))
        path.line(to: CGPoint(x: 11, y: 11))
        path.curve(
          to: CGPoint(x: 11, y: 3), controlPoint1: CGPoint(x: 18, y: 11),
          controlPoint2: CGPoint(x: 18, y: 3))
        path.line(to: CGPoint(x: 7, y: 3))
        path.move(to: CGPoint(x: 7, y: 15))
        path.line(to: CGPoint(x: 3, y: 11))
        path.line(to: CGPoint(x: 7, y: 7))
      case "scroll":
        path.append(
          NSBezierPath(
            roundedRect: CGRect(x: 2, y: 2, width: 14, height: 10), xRadius: 1.5, yRadius: 1.5))
        path.move(to: CGPoint(x: 3, y: 14))
        path.line(to: CGPoint(x: 15, y: 14))
        path.move(to: CGPoint(x: 5, y: 16))
        path.line(to: CGPoint(x: 13, y: 16))
      case "save":
        path.move(to: CGPoint(x: 9, y: 16))
        path.line(to: CGPoint(x: 9, y: 5))
        path.move(to: CGPoint(x: 4.5, y: 9.5))
        path.line(to: CGPoint(x: 9, y: 5))
        path.line(to: CGPoint(x: 13.5, y: 9.5))
        path.move(to: CGPoint(x: 2, y: 6))
        path.line(to: CGPoint(x: 2, y: 2))
        path.line(to: CGPoint(x: 16, y: 2))
        path.line(to: CGPoint(x: 16, y: 6))
      case "cancel":
        path.move(to: CGPoint(x: 3, y: 3))
        path.line(to: CGPoint(x: 15, y: 15))
        path.move(to: CGPoint(x: 3, y: 15))
        path.line(to: CGPoint(x: 15, y: 3))
      case "confirm":
        path.move(to: CGPoint(x: 2, y: 9))
        path.line(to: CGPoint(x: 7, y: 4))
        path.line(to: CGPoint(x: 16, y: 15))
      case "arrow":
        path.move(to: CGPoint(x: 3, y: 3))
        path.line(to: CGPoint(x: 15, y: 15))
        path.move(to: CGPoint(x: 5, y: 15))
        path.line(to: CGPoint(x: 15, y: 15))
        path.line(to: CGPoint(x: 15, y: 5))
      case "pen":
        path.move(to: CGPoint(x: 3, y: 3))
        path.line(to: CGPoint(x: 4, y: 7))
        path.line(to: CGPoint(x: 13, y: 16))
        path.line(to: CGPoint(x: 16, y: 13))
        path.line(to: CGPoint(x: 7, y: 4))
        path.close()
        path.move(to: CGPoint(x: 11, y: 14))
        path.line(to: CGPoint(x: 14, y: 11))
        path.move(to: CGPoint(x: 3, y: 1))
        path.line(to: CGPoint(x: 15, y: 1))
      default:
        path.move(to: CGPoint(x: 3, y: 15))
        path.line(to: CGPoint(x: 15, y: 15))
        path.move(to: CGPoint(x: 9, y: 15))
        path.line(to: CGPoint(x: 9, y: 3))
        path.move(to: CGPoint(x: 6, y: 3))
        path.line(to: CGPoint(x: 12, y: 3))
      }
      let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.labelColor.setStroke()
        path.stroke()
        return true
      }
      image.isTemplate = true
      image.cacheMode = .never
      return image
    }
    let symbolImage =
      NSImage(systemSymbolName: symbol, accessibilityDescription: tool)
      ?? NSImage(size: NSSize(width: 18, height: 18))
    return normalizedToolbarImage(
      symbolImage.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)) ?? symbolImage)
  }

  private func normalizedToolbarImage(_ source: NSImage) -> NSImage {
    guard source.size.width > 0, source.size.height > 0 else {
      return NSImage(size: NSSize(width: 18, height: 18))
    }
    let scale = min(18 / source.size.width, 18 / source.size.height)
    let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      source.draw(
        in: NSRect(
          x: (18 - size.width) / 2, y: (18 - size.height) / 2,
          width: size.width, height: size.height))
      return true
    }
    image.isTemplate = true
    image.cacheMode = .never
    return image
  }

  private var palette: [NSColor] {
    [
      .systemRed, .systemYellow, .systemBlue, .systemGreen,  // devbar:allow-color
      .black, .gray, .white,  // devbar:allow-color
    ]
  }

  private func showOptions(below frame: CGRect) {
    guard frozenFrame != nil,
      ["rect", "ellipse", "arrow", "pen", "text", "mosaic"].contains(tool)
    else { return }
    let bar = makeToolbar(cornerRadius: 9)
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
        let button = CaptureToolbarButton(
          image: modeImage(index: index), target: self, action: #selector(modeChanged(_:)))
        button.toolTip = title
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        button.tag = index
        button.isBordered = false
        button.wantsLayer = true
        let active = tool == "arrow" ? (largeArrow == (index == 0)) : (mosaicBrush == (index == 0))
        button.toolSelected = active
        button.highlightColor = iconColor
        button.contentTintColor = active ? .systemBlue : iconColor  // devbar:allow-color
        button.layer?.cornerRadius = 5
        button.layer?.backgroundColor =
          active ? iconColor.withAlphaComponent(0.12).cgColor : nil
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
      return toolbarImage(symbol: "hand.point.up.left", tool: "mosaicBrush")
    }
    let isArrow = tool == "arrow"
    let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
      NSColor.labelColor.setFill()
      NSColor.labelColor.setStroke()
      if isArrow {
        let path = Self.arrowPath(
          start: CGPoint(x: 3, y: 3), end: CGPoint(x: 22, y: 22), width: 2, large: index == 0)
        if index == 0 {
          path.fill()
        } else {
          path.lineWidth = 1.5
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
      return true
    }
    image.isTemplate = true
    image.cacheMode = .never
    return normalizedToolbarImage(image)
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
  func beginScrollingProgress() {
    captureInProgress = true
    frozenFrame = nil
    toolbar?.removeFromSuperview()
    optionsBar?.removeFromSuperview()
    toolbar = nil
    optionsBar = nil
    marks.removeAll()
    texts.removeAll()
    selectedMark = nil
    selectedText = nil
    needsDisplay = true
  }
  override var acceptsFirstResponder: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.current?.cgContext.clear(bounds)
    if let frame = frozenFrame {
      NSImage(cgImage: frame, size: bounds.size).draw(in: bounds)
    }
    drawMarks(clipped: false)
    if !captureInProgress {
      NSColor.black.withAlphaComponent(0.4).setFill()  // devbar:allow-color
      bounds.fill()
    }
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
    guard !captureInProgress else { return }
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
        tool =
          marks[index].0.hasPrefix("arrow")
          ? "arrow" : marks[index].0.hasPrefix("mosaic") ? "mosaic" : marks[index].0
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
    guard !captureInProgress else { return }
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
        if tool == "rect" || tool == "mosaic" {
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
    guard !captureInProgress else { return }
    let end = convert(event.locationInWindow, from: nil)
    if let anchor, draft != nil, hypot(end.x - anchor.x, end.y - anchor.y) < 3 {
      draft = nil
    } else {
      mouseDragged(with: event)
    }
    if let draft {
      marks.append((drawingKind, draft, ink, stroke))
      undoKinds.append("mark")
      selectedMark = marks.count - 1
      self.draft = nil
    }
    anchor = nil
    editingArrow = nil
    moveOrigin = nil
    resizeHandle = nil
    if !selection.isEmpty {
      if scrollingRequested && frozenFrame == nil { confirm() } else { showToolbar() }
    }
    needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    guard !captureInProgress else { return }
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
  override var allowsVibrancy: Bool { false }
  var toolSelected = false
  var highlightColor: NSColor = .labelColor
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
      ? highlightColor.withAlphaComponent(toolSelected ? 0.12 : 0.08).cgColor : nil
  }
}

@MainActor private final class CaptureToolbarTintView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
