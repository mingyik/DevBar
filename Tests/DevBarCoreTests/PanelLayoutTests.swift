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

@Test func panelAnchorMustSitOnAConnectedMenuBar() {
  let connected = PanelLayout.DisplaySlice(
    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
  let fallback = CGRect(x: 100, y: 40, width: 800, height: 500)
  let valid = CGRect(x: 200, y: 874, width: 22, height: 24)
  let placed = PanelLayout.placement(anchor: valid, screens: [connected], fallbackVisible: fallback)
  #expect(placed.centerX == valid.midX)
  #expect(placed.menuBottom == valid.minY)
  #expect(placed.visible == connected.visibleFrame)

  let offscreen = CGRect(x: -20, y: -40, width: 18, height: 18)
  let below = CGRect(x: 200, y: 400, width: 22, height: 22)
  let unplugged = CGRect(x: 1800, y: 874, width: 22, height: 24)
  for anchor in [offscreen, below, unplugged] {
    let fallbackPlacement = PanelLayout.placement(
      anchor: anchor, screens: [connected], fallbackVisible: fallback)
    #expect(fallbackPlacement.centerX == fallback.midX)
    #expect(fallbackPlacement.menuBottom == fallback.maxY)
    #expect(fallbackPlacement.visible == fallback)
  }
}
