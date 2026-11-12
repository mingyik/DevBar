// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Adapted for DevBar.

import CoreGraphics

/// V4 prototype: extracted coordinate math, without selection UI dependencies.
public struct CaptureRegion: Equatable, Sendable {
  public let displayID: CGDirectDisplayID
  /// Display-local points, top-left origin (not Cocoa global coordinates).
  public let rectInPoints: CGRect
  public let scale: CGFloat

  public var pixelRect: CGRect {
    CGRect(
      x: rectInPoints.minX * scale, y: rectInPoints.minY * scale,
      width: rectInPoints.width * scale, height: rectInPoints.height * scale)
  }

  public init(
    displayID: CGDirectDisplayID, globalRect: CGRect, screenFrame: CGRect, scale: CGFloat
  ) throws {
    guard scale.isFinite, scale > 0,
      [
        globalRect.minX, globalRect.minY, globalRect.width, globalRect.height,
        screenFrame.minX, screenFrame.minY, screenFrame.width, screenFrame.height,
      ]
      .allSatisfy(\.isFinite)
    else { throw CapturePrototypeError.invalidRegion }
    let clipped = globalRect.standardized.intersection(screenFrame)
    guard !clipped.isNull, !clipped.isEmpty else {
      throw CapturePrototypeError.invalidRegion
    }
    let raw = CGRect(
      x: (clipped.minX - screenFrame.minX) * scale,
      y: (screenFrame.maxY - clipped.maxY) * scale,
      width: clipped.width * scale, height: clipped.height * scale)
    // Reject tiny selections rather than expanding beyond the user's gesture.
    let width = floor(raw.width / 2) * 2
    let height = floor(raw.height / 2) * 2
    guard width >= 2, height >= 2 else { throw CapturePrototypeError.invalidRegion }
    self.displayID = displayID
    self.scale = scale
    rectInPoints = CGRect(
      x: floor(raw.minX) / scale, y: floor(raw.minY) / scale,
      width: width / scale, height: height / scale)
  }
}

public enum CapturePrototypeError: Error {
  case invalidRegion
  case cancelled
  case screenPermissionDenied
  case displayUnavailable
  case noImage
  case timedOut
  case alreadyRunning
}
