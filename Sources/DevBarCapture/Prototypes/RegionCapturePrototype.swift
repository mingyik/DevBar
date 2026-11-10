// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Adapted for DevBar.

import AppKit
import ScreenCaptureKit

/// V4-only acquisition subset of ScreenshotCaptureEngine. No clipboard or file side effects.
@MainActor
public enum RegionCapturePrototype {
  public static func image(for region: CaptureRegion) async throws -> CGImage {
    guard CGPreflightScreenCaptureAccess() else {
      throw CapturePrototypeError.screenPermissionDenied
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == region.displayID })
    else { throw CapturePrototypeError.displayUnavailable }
    let own = content.windows.filter {
      $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
    }
    let filter = SCContentFilter(display: display, excludingWindows: own)
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = region.rectInPoints
    configuration.width = Int(region.pixelRect.width)
    configuration.height = Int(region.pixelRect.height)
    configuration.showsCursor = false
    configuration.colorSpaceName = CGColorSpace.sRGB
    return try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
  }
}
