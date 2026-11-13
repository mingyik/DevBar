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
          view.complete = { [weak self, weak view] result in
            self?.scrollingRequested = view?.scrollingRequested ?? false
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
  private var tool = "select"
  private var marks: [(String, NSBezierPath)] = []
  private var draft: NSBezierPath?
  private var moveOrigin: CGRect?
  private var resizeHandle: CGPoint?
  private var toolbar: NSVisualEffectView?
  private var mosaicFrame: CGImage?
  private var texts: [(String, CGPoint)] = []
  private var undoKinds: [String] = []

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

  private func drawMarks() {
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: selection).addClip()
    NSColor.labelColor.setStroke()
    for (kind, path) in marks {
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
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        path.fill()
      } else {
        path.lineWidth = 3
        path.stroke()
      }
    }
    for (text, point) in texts {
      text.draw(
        at: point,
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.labelColor,
        ])
    }
    draft?.lineWidth = 3
    draft?.stroke()
    NSGraphicsContext.restoreGraphicsState()
  }

  private func showToolbar() {
    toolbar?.removeFromSuperview()
    let bar = NSVisualEffectView()
    bar.material = .popover
    bar.state = .active
    bar.wantsLayer = true
    bar.layer?.cornerRadius = 10
    bar.layer?.borderWidth = 0.5
    bar.layer?.borderColor = NSColor.separatorColor.cgColor
    var tools = [
      ("cursorarrow", "select"), ("rectangle", "rect"), ("circle", "ellipse"),
      ("arrow.up.right", "arrow"), ("pencil.tip", "pen"), ("textformat", "text"),
      ("square.grid.3x3", "mosaic"), ("highlighter", "highlight"), ("arrow.uturn.backward", "undo"),
      ("rectangle.stack", "scroll"), ("arrow.down.to.line", "save"), ("xmark", "cancel"),
    ]
    if frozenFrame == nil { tools = [("play.fill", "scroll"), ("xmark", "cancel")] }
    let width = CGFloat(tools.count * 44 + 24)
    let x = min(max(selection.maxX - width, 8), bounds.maxX - width - 8)
    let y = selection.minY > 64 ? selection.minY - 60 : min(selection.maxY + 10, bounds.maxY - 54)
    bar.frame = NSRect(x: x, y: y, width: width, height: 50)
    for (index, entry) in tools.enumerated() {
      let button = NSButton(
        image: NSImage(systemSymbolName: entry.0, accessibilityDescription: entry.1)!, target: self,
        action: #selector(toolClicked(_:)))
      button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
      button.contentTintColor = .labelColor
      button.identifier = NSUserInterfaceItemIdentifier(entry.1)
      button.isBordered = false
      button.frame = NSRect(x: 12 + index * 44, y: 5, width: 42, height: 40)
      bar.addSubview(button)
    }
    addSubview(bar)
    toolbar = bar
  }

  @objc private func toolClicked(_ sender: NSButton) {
    for field in subviews.compactMap({ $0 as? NSTextField }) { commitText(field) }
    switch sender.identifier?.rawValue {
    case "save": confirm()
    case "cancel": complete?(.failure(CaptureError.cancelled))
    case "scroll":
      scrollingRequested = true
      confirm()
    case "undo":
      if let kind = undoKinds.popLast() {
        if kind == "text" { texts.removeLast() } else { marks.removeLast() }
      }
      needsDisplay = true
    case let value?: tool = value
    default: break
    }
  }
  override var acceptsFirstResponder: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    if let frame = frozenFrame {
      NSImage(cgImage: frame, size: bounds.size).draw(in: bounds)
    }
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
    anchor = point
    if tool == "text" && selection.contains(point) {
      let field = NSTextField(string: "")
      field.frame = NSRect(
        x: point.x, y: point.y, width: min(200, selection.maxX - point.x), height: 26)
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
    if !field.stringValue.isEmpty { texts.append((field.stringValue, field.frame.origin)) }
    field.removeFromSuperview()
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let anchor else { return }
    let point = convert(event.locationInWindow, from: nil)
    if draft != nil {
      if tool == "pen" {
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
          draft = NSBezierPath()
          draft?.move(to: anchor)
          draft?.line(to: point)
          let angle = atan2(point.y - anchor.y, point.x - anchor.x)
          for delta in [-0.5, 0.5] {
            draft?.move(to: point)
            draft?.line(
              to: CGPoint(
                x: point.x - 14 * cos(angle + delta), y: point.y - 14 * sin(angle + delta)))
          }
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
    mouseDragged(with: event)
    if let draft {
      marks.append((tool, draft))
      undoKinds.append("mark")
      self.draft = nil
    }
    anchor = nil
    moveOrigin = nil
    resizeHandle = nil
    if !selection.isEmpty { showToolbar() }
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
