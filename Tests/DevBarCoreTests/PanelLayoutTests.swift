import CoreGraphics
import Testing
@testable import DevBarCore

@Test func enlargedPanelStaysInsideTopRightOf13InchScreen() {
  let visible = CGRect(x: 0, y: 80, width: 1280, height: 800)
  let frame = PanelLayout.frame(
    iconCenterX: 1256,
    menuBarBottomY: visible.maxY,
    enlarged: true,
    visibleFrame: visible
  )
  #expect(visible.contains(frame))
  #expect(frame.width == PanelLayout.large.width)
  #expect(frame.height == PanelLayout.large.height)
  #expect(frame.maxX <= visible.maxX)
  #expect(frame.maxY <= visible.maxY - PanelLayout.menuGap || frame.maxY <= visible.maxY)
}

@Test func normalPanelCentersOnIcon() {
  let visible = CGRect(x: 0, y: 0, width: 1600, height: 900)
  let frame = PanelLayout.frame(
    iconCenterX: 800,
    menuBarBottomY: 900,
    enlarged: false,
    visibleFrame: visible
  )
  #expect(abs(frame.midX - 800) < 0.1)
  #expect(frame.maxY == 900 - PanelLayout.menuGap)
}
