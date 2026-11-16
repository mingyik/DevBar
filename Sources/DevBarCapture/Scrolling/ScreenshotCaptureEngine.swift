// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Adapted for DevBar.

import AppKit
import ScreenCaptureKit

enum ScreenshotCaptureEngine {
  final class RegionCapture: @unchecked Sendable {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
      self.filter = filter
      self.configuration = configuration
    }
    func image() async -> CGImage? {
      try? await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: configuration)
    }
  }

  static func captureDisplayRegion(region: CaptureRegion) async -> CGImage? {
    guard let source = await prepareDisplayRegion(region: region) else { return nil }
    return await source.image()
  }

  static func prepareDisplayRegion(region: CaptureRegion) async -> RegionCapture? {
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
    return RegionCapture(filter: filter, configuration: configuration)
  }
}
