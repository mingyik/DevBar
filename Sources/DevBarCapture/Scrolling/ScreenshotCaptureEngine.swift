// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Adapted for DevBar.

import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

enum ScreenshotCaptureEngine {
  final class RegionCapture: @unchecked Sendable {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private var stream: SCStream?
    private var sink: FrameSink?

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, streaming: Bool = false) {
      self.filter = filter
      self.configuration = configuration
      guard streaming else { return }
      let sink = FrameSink()
      guard
        let stream = try? SCStream(
          filter: filter, configuration: configuration, delegate: nil)
      else { return }
      do {
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
      } catch { return }
      self.stream = stream
      self.sink = sink
    }

    func start() async {
      guard let stream else { return }
      try? await stream.startCapture()
    }

    func image() async -> CGImage? {
      try? await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: configuration)
    }

    /// Next frame from the live stream. `wait` false returns nil immediately
    /// when the queue is empty, so a finish can drain what was already captured.
    func nextFrame(wait: Bool = true) async -> CGImage? {
      guard let sink else { return wait ? await image() : nil }
      return await sink.nextImage(wait: wait)
    }

    var queuedFrameCount: Int { sink?.queuedCount ?? 0 }

    func stop() {
      stream?.stopCapture { _ in }
      sink?.stop()
      stream = nil
      sink = nil
    }
  }

  private final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    /// A few seconds of 20 fps frames. Matching has to be able to drain this
    /// before a scroll-back is discarded.
    static let maximumQueuedFrames = 48
    let queue = DispatchQueue(label: "local.devbar.scrolling.frames")
    private let lock = NSLock()
    private struct Frame: @unchecked Sendable {
      let buffer: CVPixelBuffer
    }
    private var frames: [Frame] = []
    private var waiters: [CheckedContinuation<Frame?, Never>] = []
    private var stopped = false
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    var queuedCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return frames.count
    }

    func stream(
      _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
      of outputType: SCStreamOutputType
    ) {
      guard outputType == .screen, sampleBuffer.isValid,
        let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
      else { return }
      lock.lock()
      if !waiters.isEmpty {
        let waiter = waiters.removeFirst()
        lock.unlock()
        waiter.resume(returning: Frame(buffer: buffer))
        return
      }
      // Keep the oldest unprocessed frames. Dropping them skips the path the
      // stitcher has not reached yet, so a later scroll-back cannot fill the gap.
      guard frames.count < Self.maximumQueuedFrames else {
        lock.unlock()
        return
      }
      frames.append(Frame(buffer: buffer))
      lock.unlock()
    }

    func nextImage(wait: Bool) async -> CGImage? {
      let frame: Frame? = await withCheckedContinuation { continuation in
        lock.lock()
        if !frames.isEmpty {
          let frame = frames.removeFirst()
          lock.unlock()
          continuation.resume(returning: frame)
        } else if stopped || !wait {
          lock.unlock()
          continuation.resume(returning: nil)
        } else {
          waiters.append(continuation)
          lock.unlock()
        }
      }
      guard let frame else { return nil }
      let image = CIImage(cvPixelBuffer: frame.buffer)
      return context.createCGImage(image, from: image.extent)
    }

    func stop() {
      lock.lock()
      stopped = true
      let pending = waiters
      waiters.removeAll()
      frames.removeAll()
      lock.unlock()
      for waiter in pending { waiter.resume(returning: nil) }
    }
  }

  static func captureDisplayRegion(region: CaptureRegion) async -> CGImage? {
    guard let source = await prepareDisplayRegion(region: region) else { return nil }
    return await source.image()
  }

  static func prepareDisplayRegion(
    region: CaptureRegion, streaming: Bool = false
  ) async -> RegionCapture? {
    guard
      let content = try? await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true),
      let display = content.displays.first(where: { $0.displayID == region.displayID })
    else { return nil }
    let bounds = CGRect(
      x: 0, y: 0, width: CGFloat(display.width) * region.scale,
      height: CGFloat(display.height) * region.scale)
    let clamped = region.pixelRect.intersection(bounds).integral
    guard !clamped.isNull, !clamped.isEmpty else { return nil }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let windows: [SCWindow]
    if let target = region.windowID,
      content.windows.contains(where: { $0.windowID == target })
    {
      // Long capture: show only the target window. Other applications and
      // transient panels covering the selection must not enter the image.
      windows = content.windows.filter { $0.windowID != target }
    } else {
      windows = content.windows.filter { $0.owningApplication?.processID == ownPID }
    }
    let filter = SCContentFilter(display: display, excludingWindows: windows)
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = CGRect(
      x: clamped.minX / region.scale, y: clamped.minY / region.scale,
      width: clamped.width / region.scale, height: clamped.height / region.scale)
    configuration.width = max(1, Int(clamped.width))
    configuration.height = max(1, Int(clamped.height))
    configuration.showsCursor = false
    configuration.colorSpaceName = CGColorSpace.sRGB
    if streaming {
      configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
      configuration.queueDepth = 8
      configuration.pixelFormat = kCVPixelFormatType_32BGRA
    }
    let capture = RegionCapture(
      filter: filter, configuration: configuration, streaming: streaming)
    if streaming { await capture.start() }
    return capture
  }
}
