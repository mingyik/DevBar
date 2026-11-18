// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Adapted for DevBar.

import AppKit
import CoreImage

/// One selection overlay per display, optionally using a frozen frame.
@MainActor
public final class SelectionOverlay {
  private var panels: [NSPanel] = []
  private var insetHandles: [InsetHandlePanel] = []
  private weak var activeScrollingView: SelectionView?
  private var activeScrollingRegion: CaptureRegion?
  private var isDraggingInset = false
  private var dragStartPixels = 0
  private var frozenFrames: [CGDirectDisplayID: CGImage] = [:]
  public private(set) var scrollingRequested = false
  public private(set) var saveRequested = false
  public var insetControl: ScrollingInsetControl?
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
          panel.sharingType = .none
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
    if case .success(let region) = result, scrollingRequested {
      for panel in panels {
        guard let view = panel.contentView as? SelectionView else { continue }
        if view.displayID == region.displayID {
          view.beginScrollingProgress(region: region, initialInsets: insetControl?.current)
          activeScrollingView = view
          activeScrollingRegion = region
          setupInsetHandles(for: view, region: region)
        } else {
          view.beginScrollingProgress()
        }
        panel.ignoresMouseEvents = true
        if panel.isKeyWindow { panel.resignKey() }
      }
    } else {
      dismissScrollingOverlay()
    }
    reply.resume(with: result)
  }

  public func setScrollingInsets(top: Int, bottom: Int, right: Int) {
    guard !isDraggingInset, let view = activeScrollingView, let region = activeScrollingRegion
    else {
      return
    }
    view.topInsetPixels = top
    view.bottomInsetPixels = bottom
    view.rightInsetPixels = right
    view.needsDisplay = true
    layoutInsetHandles(for: view, region: region)
  }

  public func dismissScrollingOverlay() {
    for handle in insetHandles { handle.orderOut(nil) }
    insetHandles.removeAll()
    activeScrollingView = nil
    activeScrollingRegion = nil
    isDraggingInset = false
    for panel in panels { panel.orderOut(nil) }
    panels.removeAll()
  }

  private func setupInsetHandles(for view: SelectionView, region: CaptureRegion) {
    for handle in insetHandles { handle.orderOut(nil) }
    insetHandles.removeAll()
    let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    for edge in InsetEdge.allCases {
      let handleView = InsetHandleView(edge: edge)
      handleView.onDragStart = { [weak self, weak view] in
        guard let self, let view else { return }
        self.isDraggingInset = true
        switch edge {
        case .top: self.dragStartPixels = view.topInsetPixels
        case .bottom: self.dragStartPixels = view.bottomInsetPixels
        case .right: self.dragStartPixels = view.rightInsetPixels
        }
      }
      handleView.onDrag = { [weak self, weak view] startPoint, currentPoint in
        guard let self, let view else { return }
        let frameWidth = max(1, Int(region.pixelRect.width))
        let frameHeight = max(1, Int(region.pixelRect.height))
        let minContentHeight = ScreenshotScrollingCapture.minimumContentHeight(
          frameHeight: frameHeight)
        let minContentWidth = ScreenshotScrollingCapture.minimumContentWidth(
          frameWidth: frameWidth)
        switch edge {
        case .top:
          let delta = Int(((startPoint.y - currentPoint.y) * region.scale).rounded())
          let maxTop = max(0, frameHeight - minContentHeight - view.bottomInsetPixels)
          let nextTop = min(max(0, self.dragStartPixels + delta), maxTop)
          view.topInsetPixels = nextTop
          self.insetControl?.update { $0.top = nextTop }
        case .bottom:
          let delta = Int(((currentPoint.y - startPoint.y) * region.scale).rounded())
          let maxBottom = max(0, frameHeight - minContentHeight - view.topInsetPixels)
          let nextBottom = min(max(0, self.dragStartPixels + delta), maxBottom)
          view.bottomInsetPixels = nextBottom
          self.insetControl?.update { $0.bottom = nextBottom }
        case .right:
          let delta = Int(((startPoint.x - currentPoint.x) * region.scale).rounded())
          let maxRight = max(0, frameWidth - minContentWidth)
          let nextRight = min(max(0, self.dragStartPixels + delta), maxRight)
          view.rightInsetPixels = nextRight
          self.insetControl?.update { $0.right = nextRight }
        }
        view.needsDisplay = true
        self.layoutInsetHandles(for: view, region: region)
      }
      handleView.onDragEnd = { [weak self] in
        self?.isDraggingInset = false
      }
      let panel = InsetHandlePanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.sharingType = .none
      panel.level = level
      panel.collectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary,
      ]
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.ignoresMouseEvents = false
      panel.animationBehavior = .none
      panel.contentView = handleView
      insetHandles.append(panel)
      panel.orderFrontRegardless()
    }
    layoutInsetHandles(for: view, region: region)
  }

  private func layoutInsetHandles(for view: SelectionView, region: CaptureRegion) {
    let global = view.selection.offsetBy(dx: view.screenFrame.minX, dy: view.screenFrame.minY)
    let topPts = CGFloat(view.topInsetPixels) / region.scale
    let bottomPts = CGFloat(view.bottomInsetPixels) / region.scale
    let rightPts = CGFloat(view.rightInsetPixels) / region.scale
    let thickness: CGFloat = 14
    let horizontalSpan = max(36, global.width - rightPts - 24)
    let verticalSpan = max(36, global.height - topPts - bottomPts - 24)
    for panel in insetHandles {
      guard let handleView = panel.contentView as? InsetHandleView else { continue }
      let frame: CGRect
      switch handleView.edge {
      case .top:
        let y = global.maxY - topPts - thickness / 2
        let x = global.minX + max(0, (global.width - rightPts - horizontalSpan) / 2)
        frame = CGRect(x: x, y: y, width: horizontalSpan, height: thickness)
      case .bottom:
        let y = global.minY + bottomPts - thickness / 2
        let x = global.minX + max(0, (global.width - rightPts - horizontalSpan) / 2)
        frame = CGRect(x: x, y: y, width: horizontalSpan, height: thickness)
      case .right:
        let x = global.maxX - rightPts - thickness / 2
        let y =
          global.minY + bottomPts + max(0, (global.height - topPts - bottomPts - verticalSpan) / 2)
        frame = CGRect(x: x, y: y, width: thickness, height: verticalSpan)
      }
      panel.setFrame(frame, display: true)
    }
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
final class SelectionView: NSView, NSTextFieldDelegate {
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
  private var hoveredWindowFrame: CGRect?
  private var windowCandidate: (start: CGPoint, frame: CGRect)?
  var scrollingRequested = false
  var saveRequested = false
  var topInsetPixels = 0
  var bottomInsetPixels = 0
  var rightInsetPixels = 0
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
  private var resizingMark: (index: Int, origin: CGRect, edge: ResizeEdge)?
  private var mosaicBrush = true
  private var optionsBar: NSVisualEffectView?
  private var marks: [(String, NSBezierPath, NSColor, CGFloat)] = []
  private var draft: NSBezierPath?
  private var moveOrigin: CGRect?
  private var resizeHandle: CGPoint?
  private var toolbar: NSVisualEffectView?
  private struct TextAnnotation {
    var text: String
    var origin: CGPoint
    var wrapWidth: CGFloat
    var maxHeight: CGFloat
    var color: NSColor
    var fontSize: CGFloat
  }

  private var mosaicFrame: CGImage?
  private var texts: [TextAnnotation] = []
  private var undoKinds: [String] = []
  private var selectedMark: Int?
  private var selectedText: Int?
  private var hoverTrackingArea: NSTrackingArea?
  private var draggingTextIndex: Int?
  private var draggingMarkIndex: Int?
  private var dragStartPoint: CGPoint?
  private var dragTextOrigin: CGPoint?
  private var dragMarkLastPoint: CGPoint?

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
    for item in texts {
      let rect = textRect(
        text: item.text, origin: item.origin, wrapWidth: item.wrapWidth,
        maxHeight: item.maxHeight, fontSize: item.fontSize)
      let drawRect = CGRect(x: rect.minX, y: rect.minY, width: item.wrapWidth, height: rect.height)
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: drawRect).addClip()
      (item.text as NSString).draw(
        with: drawRect,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [
          .font: NSFont.systemFont(ofSize: item.fontSize), .foregroundColor: item.color,
        ])
      NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  private func drawObjectSelection() {
    var points: [CGPoint] = []
    var box: CGRect?
    if let draft, isResizableBoxKind(drawingKind) {
      points = objectHandles(draft.bounds)
    } else if let index = selectedMark, marks.indices.contains(index) {
      let (kind, path, _, _) = marks[index]
      if kind.hasPrefix("arrow"), path.elementCount >= 2 {
        var first = [NSPoint](repeating: .zero, count: 3)
        var last = first
        _ = path.element(at: 0, associatedPoints: &first)
        _ = path.element(at: 1, associatedPoints: &last)
        points = [first[0], last[0]]
      } else if isResizableBoxKind(kind) {
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

  private func isResizableBoxKind(_ kind: String) -> Bool {
    kind == "rect" || kind == "ellipse" || kind == "mosaicRect"
  }

  private func markResizeEdge(for rect: CGRect, at point: CGPoint) -> ResizeEdge? {
    let edges: [ResizeEdge] = [
      ResizeEdge(left: true, right: false, bottom: true, top: false),
      ResizeEdge(left: false, right: false, bottom: true, top: false),
      ResizeEdge(left: false, right: true, bottom: true, top: false),
      ResizeEdge(left: false, right: true, bottom: false, top: false),
      ResizeEdge(left: false, right: true, bottom: false, top: true),
      ResizeEdge(left: false, right: false, bottom: false, top: true),
      ResizeEdge(left: true, right: false, bottom: false, top: true),
      ResizeEdge(left: true, right: false, bottom: false, top: false),
    ]
    for (handle, edge) in zip(objectHandles(rect), edges) {
      if hypot(point.x - handle.x, point.y - handle.y) < 9 {
        return edge
      }
    }
    return nil
  }

  private func isArrowHandleHovered(for path: NSBezierPath, at point: CGPoint) -> Bool {
    guard path.elementCount >= 2 else { return false }
    var start = [NSPoint](repeating: .zero, count: 3)
    var end = start
    _ = path.element(at: 0, associatedPoints: &start)
    _ = path.element(at: 1, associatedPoints: &end)
    return hypot(point.x - start[0].x, point.y - start[0].y) < 9
      || hypot(point.x - end[0].x, point.y - end[0].y) < 9
  }

  private func textRect(
    text: String, origin: CGPoint, wrapWidth: CGFloat, maxHeight: CGFloat, fontSize: CGFloat
  ) -> CGRect {
    let bounding = (text as NSString).boundingRect(
      with: CGSize(width: max(1, wrapWidth), height: max(1, maxHeight)),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
    return CGRect(
      x: origin.x, y: origin.y,
      width: min(wrapWidth, ceil(bounding.width)),
      height: min(maxHeight, ceil(bounding.height)))
  }

  private func textBounds(_ index: Int) -> CGRect {
    let item = texts[index]
    return textRect(
      text: item.text, origin: item.origin, wrapWidth: item.wrapWidth,
      maxHeight: item.maxHeight, fontSize: item.fontSize)
  }

  var markBoundsForTesting: [CGRect] { marks.map(\.1.bounds) }
  var textBoundsForTesting: [CGRect] { texts.indices.map { textBounds($0) } }

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
      layoutTextField(field)
    }
    needsDisplay = true
  }

  private func layoutTextField(_ field: NSTextField) {
    guard !selection.isEmpty else { return }
    let font = field.font ?? .systemFont(ofSize: fontSize)
    let text = field.currentEditor()?.string ?? field.stringValue
    let availableWidth = max(1, selection.width)
    let minWidth = min(availableWidth, max(60, ceil(fontSize * 3.2)))
    let originX = max(selection.minX, min(field.frame.minX, selection.maxX - minWidth))
    let maxWidth = max(minWidth, selection.maxX - originX)
    let contentWidth = (text as NSString).size(withAttributes: [.font: font]).width
    let width = min(maxWidth, max(minWidth, ceil(contentWidth) + 16))
    let sample = text.isEmpty ? " " : text
    let bounding = (sample as NSString).boundingRect(
      with: CGSize(width: max(1, width - 12), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font])
    let availableHeight = max(1, selection.height)
    let minHeight = min(availableHeight, ceil(fontSize * 1.4 + 8))
    let height = min(availableHeight, max(minHeight, ceil(bounding.height) + 8))
    let topY = min(field.frame.maxY, selection.maxY)
    let originY = max(selection.minY, topY - height)
    field.frame = NSRect(x: originX, y: originY, width: width, height: height)
  }

  func controlTextDidChange(_ obj: Notification) {
    guard let field = obj.object as? NSTextField else { return }
    layoutTextField(field)
  }

  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
  ) -> Bool {
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      if let flags = NSApp.currentEvent?.modifierFlags,
        flags.contains(.shift) || flags.contains(.option)
      {
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
      }
      if let field = control as? NSTextField {
        commitText(field)
        return true
      }
    } else if commandSelector == #selector(NSResponder.cancelOperation(_:)),
      let field = control as? NSTextField
    {
      field.removeFromSuperview()
      window?.makeFirstResponder(self)
      needsDisplay = true
      showToolbar()
      return true
    }
    return false
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
  func beginScrollingProgress(
    region: CaptureRegion? = nil, initialInsets: ScrollingInsetControl.Values? = nil
  ) {
    captureInProgress = true
    frozenFrame = nil
    if let region {
      selection = CGRect(
        x: region.rectInPoints.minX,
        y: screenFrame.height - region.rectInPoints.maxY,
        width: region.rectInPoints.width,
        height: region.rectInPoints.height)
    }
    topInsetPixels = initialInsets?.top ?? 0
    bottomInsetPixels = initialInsets?.bottom ?? 0
    rightInsetPixels = initialInsets?.right ?? 0
    toolbar?.removeFromSuperview()
    optionsBar?.removeFromSuperview()
    toolbar = nil
    optionsBar = nil
    marks.removeAll()
    texts.removeAll()
    selectedMark = nil
    selectedText = nil
    resizingMark = nil
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
    } else if !selection.isEmpty {
      // Keep the frozen selection readable while the page below scrolls.
      let mask = NSBezierPath(rect: bounds)
      mask.append(NSBezierPath(rect: selection))
      mask.windingRule = .evenOdd
      NSColor.black.withAlphaComponent(0.4).setFill()  // devbar:allow-color
      mask.fill()
    }
    if selection.isEmpty, anchor == nil, !captureInProgress, !scrollingRequested,
      let hoveredWindowFrame
    {
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: hoveredWindowFrame).addClip()
      if let frame = frozenFrame {
        NSImage(cgImage: frame, size: bounds.size).draw(in: bounds)
      } else {
        NSGraphicsContext.current?.cgContext.clear(hoveredWindowFrame)
      }
      NSGraphicsContext.restoreGraphicsState()
      NSColor.systemBlue.setStroke()  // devbar:allow-color
      let outline = NSBezierPath(rect: hoveredWindowFrame)
      outline.lineWidth = 3
      outline.stroke()
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
      if captureInProgress {
        drawScrollingInsets()
      } else {
        for point in handles {
          let dot = NSBezierPath(
            ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
          NSColor.systemBlue.setFill()  // devbar:allow-color
          dot.fill()
          NSColor.white.setStroke()  // devbar:allow-color
          dot.lineWidth = 1
          dot.stroke()
        }
      }
      let effectiveWidth = max(
        1, Int(selection.width * scale) - (captureInProgress ? rightInsetPixels : 0))
      let label = "\(effectiveWidth) × \(Int(selection.height * scale))"
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

  private func drawScrollingInsets() {
    let topPts = min(selection.height, CGFloat(max(0, topInsetPixels)) / scale)
    let bottomPts = min(selection.height - topPts, CGFloat(max(0, bottomInsetPixels)) / scale)
    let rightPts = min(selection.width, CGFloat(max(0, rightInsetPixels)) / scale)
    let excludedFill = NSColor.black.withAlphaComponent(0.22)  // devbar:allow-color
    excludedFill.setFill()
    if topPts > 0 {
      CGRect(x: selection.minX, y: selection.maxY - topPts, width: selection.width, height: topPts)
        .fill()
    }
    if bottomPts > 0 {
      CGRect(x: selection.minX, y: selection.minY, width: selection.width, height: bottomPts)
        .fill()
    }
    if rightPts > 0 {
      CGRect(
        x: selection.maxX - rightPts, y: selection.minY + bottomPts,
        width: rightPts, height: max(0, selection.height - topPts - bottomPts)
      ).fill()
    }
    let contentMaxX = selection.maxX - rightPts
    let topY = selection.maxY - topPts
    let bottomY = selection.minY + bottomPts
    NSColor.white.withAlphaComponent(0.75).setStroke()  // devbar:allow-color
    let dash: [CGFloat] = [4, 4]
    if topPts > 0 {
      let line = NSBezierPath()
      line.lineWidth = 1
      line.setLineDash(dash, count: dash.count, phase: 0)
      line.move(to: CGPoint(x: selection.minX, y: topY))
      line.line(to: CGPoint(x: contentMaxX, y: topY))
      line.stroke()
    }
    if bottomPts > 0 {
      let line = NSBezierPath()
      line.lineWidth = 1
      line.setLineDash(dash, count: dash.count, phase: 0)
      line.move(to: CGPoint(x: selection.minX, y: bottomY))
      line.line(to: CGPoint(x: contentMaxX, y: bottomY))
      line.stroke()
    }
    if rightPts > 0 {
      let line = NSBezierPath()
      line.lineWidth = 1
      line.setLineDash(dash, count: dash.count, phase: 0)
      line.move(to: CGPoint(x: contentMaxX, y: bottomY))
      line.line(to: CGPoint(x: contentMaxX, y: topY))
      line.stroke()
    }
    func drawPill(_ rect: CGRect) {
      let pill = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
      NSColor.white.withAlphaComponent(0.92).setFill()  // devbar:allow-color
      pill.fill()
      NSColor.black.withAlphaComponent(0.45).setStroke()  // devbar:allow-color
      pill.lineWidth = 1
      pill.stroke()
    }
    let horizontalMidX = (selection.minX + contentMaxX) / 2
    let verticalMidY = (bottomY + topY) / 2
    drawPill(CGRect(x: horizontalMidX - 16, y: topY - 2.5, width: 32, height: 5))
    drawPill(CGRect(x: horizontalMidX - 16, y: bottomY - 2.5, width: 32, height: 5))
    drawPill(CGRect(x: contentMaxX - 2.5, y: verticalMidY - 16, width: 5, height: 32))
  }

  private var handles: [CGPoint] {
    [
      CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.midX, y: selection.minY),
      CGPoint(x: selection.maxX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.midY),
      CGPoint(x: selection.maxX, y: selection.maxY), CGPoint(x: selection.midX, y: selection.maxY),
      CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.minX, y: selection.midY),
    ]
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseExited(with event: NSEvent) {
    hoveredWindowFrame = nil
    needsDisplay = true
    NSCursor.arrow.set()
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if selection.isEmpty, anchor == nil, !captureInProgress, !scrollingRequested {
      hoveredWindowFrame = Self.targetWindow(
        for: CGRect(
          x: point.x + screenFrame.minX, y: point.y + screenFrame.minY,
          width: 1, height: 1))?.frame.offsetBy(
          dx: -screenFrame.minX, dy: -screenFrame.minY
        ).intersection(bounds)
      needsDisplay = true
    }
    updateCursor(at: point)
  }

  private struct ResizeEdge {
    let left: Bool
    let right: Bool
    let bottom: Bool
    let top: Bool
  }

  private func selectionResizeEdge(at point: CGPoint) -> ResizeEdge? {
    guard !selection.isEmpty, selection.insetBy(dx: -8, dy: -8).contains(point) else { return nil }
    let left = abs(point.x - selection.minX) <= 8
    let right = abs(point.x - selection.maxX) <= 8
    let bottom = abs(point.y - selection.minY) <= 8
    let top = abs(point.y - selection.maxY) <= 8
    guard left || right || bottom || top else { return nil }
    return ResizeEdge(left: left, right: right, bottom: bottom, top: top)
  }

  private func resizeCursor(for edge: ResizeEdge) -> NSCursor {
    if (edge.left && edge.top) || (edge.right && edge.bottom) {
      return NSCursor.frameResize(
        position: edge.left ? .topLeft : .bottomRight, directions: .all)
    }
    if (edge.right && edge.top) || (edge.left && edge.bottom) {
      return NSCursor.frameResize(
        position: edge.right ? .topRight : .bottomLeft, directions: .all)
    }
    if edge.left || edge.right { return .resizeLeftRight }
    return .resizeUpDown
  }

  private func updateCursor(at point: CGPoint) {
    guard !captureInProgress else {
      NSCursor.arrow.set()
      return
    }
    if let edit = resizingMark {
      resizeCursor(for: edit.edge).set()
      return
    }
    if editingArrow != nil || draggingTextIndex != nil || draggingMarkIndex != nil {
      NSCursor.closedHand.set()
      return
    }
    if moveOrigin != nil {
      if let handle = resizeHandle {
        let edge = ResizeEdge(
          left: handle.x == selection.minX, right: handle.x == selection.maxX,
          bottom: handle.y == selection.minY, top: handle.y == selection.maxY)
        resizeCursor(for: edge).set()
      } else {
        NSCursor.closedHand.set()
      }
      return
    }
    if selection.isEmpty {
      NSCursor.crosshair.set()
      return
    }
    if let index = selectedMark, marks.indices.contains(index) {
      let (kind, path, _, _) = marks[index]
      if kind.hasPrefix("arrow"), isArrowHandleHovered(for: path, at: point) {
        NSCursor.pointingHand.set()
        return
      }
      if isResizableBoxKind(kind), let edge = markResizeEdge(for: path.bounds, at: point) {
        resizeCursor(for: edge).set()
        return
      }
    }
    if let edge = selectionResizeEdge(at: point), tool == "select" || !selection.contains(point) {
      resizeCursor(for: edge).set()
      return
    }
    if tool == "select", selection.contains(point) {
      NSCursor.openHand.set()
      return
    }
    if tool == "text", selection.contains(point) {
      NSCursor.iBeam.set()
      return
    }
    NSCursor.crosshair.set()
  }

  override func mouseDown(with event: NSEvent) {
    guard !captureInProgress else { return }
    window?.makeKey()
    window?.makeFirstResponder(self)
    let point = convert(event.locationInWindow, from: nil)
    onInteraction?()
    if selection.isEmpty,
      let target = Self.targetWindow(
        for: CGRect(
          x: point.x + screenFrame.minX, y: point.y + screenFrame.minY,
          width: 1, height: 1))
    {
      let local = target.frame.offsetBy(
        dx: -screenFrame.minX, dy: -screenFrame.minY
      ).intersection(bounds)
      if local.width > 1, local.height > 1 {
        windowCandidate = (point, local)
        anchor = point
        if scrollingRequested {
          // Lock the window immediately so moving the mouse cannot switch it.
          selection = local
          hoveredWindowFrame = nil
          needsDisplay = true
        }
        return
      }
    }
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
          updateCursor(at: point)
          return
        }
        if hypot(point.x - end[0].x, point.y - end[0].y) < 9 {
          editingArrow = (index, false, start[0])
          anchor = point
          updateCursor(at: point)
          return
        }
      }
    }
    if let index = selectedMark, marks.indices.contains(index),
      isResizableBoxKind(marks[index].0),
      let edge = markResizeEdge(for: marks[index].1.bounds, at: point)
    {
      resizingMark = (index, marks[index].1.bounds, edge)
      anchor = point
      updateCursor(at: point)
      return
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
        draggingTextIndex = index
        dragStartPoint = point
        dragTextOrigin = texts[index].origin
        showToolbar()
        anchor = nil
        needsDisplay = true
        updateCursor(at: point)
        return
      }
      if let index = marks.indices.reversed().first(where: {
        marks[$0].1.bounds.insetBy(dx: -6, dy: -6).contains(point)
      }) {
        selectedMark = index
        draggingMarkIndex = index
        dragStartPoint = point
        dragMarkLastPoint = point
        showToolbar()
        anchor = nil
        needsDisplay = true
        updateCursor(at: point)
        return
      }
    }
    if tool == "text" && selection.contains(point) {
      for existing in subviews.compactMap({ $0 as? NSTextField }) { commitText(existing) }
      let field = NSTextField(string: "")
      field.usesSingleLineMode = false
      field.lineBreakMode = .byWordWrapping
      field.cell?.wraps = true
      field.cell?.isScrollable = false
      field.delegate = self
      field.isBordered = false
      field.drawsBackground = false
      field.font = .systemFont(ofSize: fontSize)
      field.textColor = ink
      field.wantsLayer = true
      field.layer?.cornerRadius = 4
      field.layer?.borderWidth = 2
      field.layer?.masksToBounds = true
      field.layer?.borderColor = NSColor.systemBlue.cgColor  // devbar:allow-color
      field.target = self
      field.action = #selector(commitText(_:))
      let availableWidth = max(1, selection.width)
      let minWidth = min(availableWidth, max(60, ceil(fontSize * 3.2)))
      let startX = max(selection.minX, min(point.x, selection.maxX - minWidth))
      let availableHeight = max(1, selection.height)
      let minHeight = min(availableHeight, ceil(fontSize * 1.4 + 8))
      let startY = max(selection.minY, min(point.y, selection.maxY - minHeight))
      field.frame = NSRect(x: startX, y: startY, width: minWidth, height: minHeight)
      layoutTextField(field)
      addSubview(field)
      window?.makeFirstResponder(field)
      anchor = nil
      return
    }
    if !selection.isEmpty && tool != "select" && selection.contains(point) {
      draft = NSBezierPath()
      draft?.move(to: point)
    } else if !selection.isEmpty {
      if let handle = handles.first(where: { hypot($0.x - point.x, $0.y - point.y) < 9 }) {
        resizeHandle = handle
      } else if let edge = selectionResizeEdge(at: point) {
        resizeHandle = CGPoint(
          x: edge.left ? selection.minX : edge.right ? selection.maxX : selection.midX,
          y: edge.bottom ? selection.minY : edge.top ? selection.maxY : selection.midY)
      } else {
        resizeHandle = nil
      }
      moveOrigin = selection.contains(point) || resizeHandle != nil ? selection : nil
      updateCursor(at: point)
    }
  }

  @objc private func commitText(_ field: NSTextField) {
    if !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let wrapWidth = max(1, field.frame.width - 12)
      let maxHeight = max(1, field.frame.height - 8)
      let origin = CGPoint(x: field.frame.minX + 6, y: field.frame.minY + 4)
      texts.append(
        TextAnnotation(
          text: field.stringValue, origin: origin, wrapWidth: wrapWidth,
          maxHeight: maxHeight, color: ink, fontSize: fontSize))
      undoKinds.append("text")
      selectedText = texts.count - 1
    }
    field.removeFromSuperview()
    window?.makeFirstResponder(self)
    needsDisplay = true
    showToolbar()
  }

  override func mouseDragged(with event: NSEvent) {
    guard !captureInProgress else { return }
    let point = convert(event.locationInWindow, from: nil)
    if let index = draggingTextIndex, let start = dragStartPoint, let origin = dragTextOrigin {
      let bounds = textBounds(index)
      let maxX = max(selection.minX, selection.maxX - bounds.width)
      let maxY = max(selection.minY, selection.maxY - bounds.height)
      texts[index].origin = CGPoint(
        x: min(max(origin.x + point.x - start.x, selection.minX), maxX),
        y: min(max(origin.y + point.y - start.y, selection.minY), maxY))
      needsDisplay = true
      updateCursor(at: point)
      return
    }
    if let index = draggingMarkIndex, let last = dragMarkLastPoint {
      let markBounds = marks[index].1.bounds
      let dx = min(
        max(point.x - last.x, selection.minX - markBounds.minX),
        selection.maxX - markBounds.maxX)
      let dy = min(
        max(point.y - last.y, selection.minY - markBounds.minY),
        selection.maxY - markBounds.maxY)
      marks[index].1.transform(using: AffineTransform(translationByX: dx, byY: dy))
      dragMarkLastPoint = CGPoint(x: last.x + dx, y: last.y + dy)
      needsDisplay = true
      updateCursor(at: point)
      return
    }
    guard let anchor else { return }
    if let edit = resizingMark {
      let clamped = CGPoint(
        x: min(max(point.x, selection.minX), selection.maxX),
        y: min(max(point.y, selection.minY), selection.maxY))
      var left = edit.origin.minX
      var right = edit.origin.maxX
      var bottom = edit.origin.minY
      var top = edit.origin.maxY
      if edit.edge.left { left = max(selection.minX, min(clamped.x, right - 4)) }
      if edit.edge.right { right = min(selection.maxX, max(clamped.x, left + 4)) }
      if edit.edge.bottom { bottom = max(selection.minY, min(clamped.y, top - 4)) }
      if edit.edge.top { top = min(selection.maxY, max(clamped.y, bottom + 4)) }
      let rect = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
      let kind = marks[edit.index].0
      marks[edit.index].1 =
        kind == "ellipse" ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
      needsDisplay = true
      updateCursor(at: point)
      return
    }
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
    if let candidate = windowCandidate {
      windowCandidate = nil
      if hypot(end.x - candidate.start.x, end.y - candidate.start.y) < 12,
        candidate.frame.contains(end)
      {
        anchor = nil
        selection = candidate.frame
        needsDisplay = true
        if !selection.isEmpty {
          if scrollingRequested { confirm() } else { showToolbar() }
        }
        return
      }
    }
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
    resizingMark = nil
    draggingTextIndex = nil
    draggingMarkIndex = nil
    dragStartPoint = nil
    dragTextOrigin = nil
    dragMarkLastPoint = nil
    moveOrigin = nil
    resizeHandle = nil
    if !selection.isEmpty {
      if scrollingRequested && frozenFrame == nil { confirm() } else { showToolbar() }
    }
    needsDisplay = true
    updateCursor(at: end)
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
    var global = selection.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
    var windowID: CGWindowID?
    var touchesTop = false
    var touchesBottom = false
    var touchesRight = false
    if scrollingRequested, let target = Self.targetWindow(for: global) {
      global = global.intersection(target.frame)
      windowID = target.id
      touchesTop = abs(global.maxY - target.frame.maxY) <= 2
      touchesBottom = abs(global.minY - target.frame.minY) <= 2
      touchesRight = abs(global.maxX - target.frame.maxX) <= 2
    }
    complete?(
      Result {
        try CaptureRegion(
          displayID: displayID, globalRect: global, screenFrame: screenFrame, scale: scale,
          windowID: windowID,
          touchesWindowTop: touchesTop,
          touchesWindowBottom: touchesBottom,
          touchesWindowRight: touchesRight)
      })
  }

  /// A scrolling capture only makes sense on one scrollable surface. Prefer
  /// the frontmost normal window under the selection center; a larger window
  /// behind it must not win on area alone. Fall back to the largest overlap
  /// only when the center is not inside any window.
  private static func targetWindow(
    for rect: CGRect
  ) -> (frame: CGRect, id: CGWindowID)? {
    guard rect.width > 0, rect.height > 0,
      let mainTop = NSScreen.screens.first?.frame.maxY,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    var frames: [CGRect] = []
    var ids: [CGWindowID] = []
    for window in windows {
      guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
        (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
        let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
        let raw = window[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
      else { continue }
      frames.append(
        CGRect(
          x: bounds.minX, y: mainTop - bounds.maxY,
          width: bounds.width, height: bounds.height))
      ids.append(CGWindowID(number))
    }
    guard let index = windowChoice(frames: frames, selection: rect) else { return nil }
    return (frames[index], ids[index])
  }

  /// Window frames arrive front to back. A larger window behind the visible one
  /// can cover more of the selection; the window the person sees at the
  /// selection's center must win, with the largest overlap only as a fallback.
  nonisolated static func windowChoice(frames: [CGRect], selection: CGRect) -> Int? {
    let center = CGPoint(x: selection.midX, y: selection.midY)
    if let frontmost = frames.firstIndex(where: { $0.contains(center) }) {
      return frontmost
    }
    var best: (index: Int, area: CGFloat)?
    for (index, frame) in frames.enumerated() {
      let overlap = frame.intersection(selection)
      guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
      let area = overlap.width * overlap.height
      if area > (best?.area ?? 0) { best = (index, area) }
    }
    return best?.index
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

private enum InsetEdge: CaseIterable {
  case top
  case bottom
  case right
}

@MainActor
private final class InsetHandlePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
private final class InsetHandleView: NSView {
  let edge: InsetEdge
  var onDragStart: (() -> Void)?
  var onDrag: ((CGPoint, CGPoint) -> Void)?
  var onDragEnd: (() -> Void)?
  private var dragStartPoint = CGPoint.zero

  init(edge: InsetEdge) {
    self.edge = edge
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

  private var cursor: NSCursor {
    edge == .right ? .resizeLeftRight : .resizeUpDown
  }

  override func draw(_ dirtyRect: NSRect) {
    // WindowServer passes clicks through fully transparent (alpha == 0) pixels
    // on non-opaque windows; a minimal alpha keeps the handle strip clickable.
    NSColor.black.withAlphaComponent(0.01).setFill()  // devbar:allow-color
    bounds.fill()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: cursor)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self))
  }

  override func cursorUpdate(with event: NSEvent) {
    cursor.set()
  }

  override func mouseEntered(with event: NSEvent) {
    cursor.set()
  }

  override func mouseMoved(with event: NSEvent) {
    cursor.set()
  }

  override func mouseDown(with event: NSEvent) {
    dragStartPoint = NSEvent.mouseLocation
    cursor.set()
    onDragStart?()
  }

  override func mouseDragged(with event: NSEvent) {
    cursor.set()
    onDrag?(dragStartPoint, NSEvent.mouseLocation)
  }

  override func mouseUp(with event: NSEvent) {
    onDragEnd?()
  }
}
