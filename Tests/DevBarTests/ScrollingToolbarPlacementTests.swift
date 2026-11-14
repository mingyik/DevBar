import AppKit
import DevBarCapture
import Testing

@testable import DevBar

@MainActor @Test func scrollingControlsStayBesideRegionRatherThanScreenTop() throws {
  let screen = CGRect(x: -1200, y: 0, width: 1200, height: 900)
  let visible = CGRect(x: -1200, y: 0, width: 1200, height: 875)
  let rect = CGRect(x: -1000, y: 300, width: 500, height: 300)
  let region = try CaptureRegion(displayID: 1, globalRect: rect, screenFrame: screen, scale: 2)
  let size = CGSize(width: 380, height: 43)
  let frame = CaptureCoordinator.progressFrame(
    region: region, screen: screen, visible: visible, size: size)
  #expect(frame.maxX == rect.maxX)
  #expect(frame.maxY == rect.minY - 8)
  #expect(visible.contains(frame))

  let bottomRect = CGRect(x: -1000, y: 5, width: 500, height: 300)
  let bottom = try CaptureRegion(
    displayID: 1, globalRect: bottomRect, screenFrame: screen, scale: 2)
  let above = CaptureCoordinator.progressFrame(
    region: bottom, screen: screen, visible: visible, size: size)
  #expect(above.minY == bottomRect.maxY + 8)
  #expect(visible.contains(above))
}
