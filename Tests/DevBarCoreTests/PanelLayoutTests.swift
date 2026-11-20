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
  let fallbackScreen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
  let valid = CGRect(x: 200, y: 874, width: 22, height: 24)
  let placed = PanelLayout.placement(
    anchor: valid, screens: [connected], fallbackScreenFrame: fallbackScreen,
    fallbackVisible: fallback)
  #expect(placed.centerX == valid.midX)
  #expect(placed.menuBottom == valid.minY)
  #expect(placed.screenFrame == connected.frame)
  #expect(placed.visible == connected.visibleFrame)

  let offscreen = CGRect(x: -20, y: -40, width: 18, height: 18)
  let below = CGRect(x: 200, y: 400, width: 22, height: 22)
  let unplugged = CGRect(x: 1800, y: 874, width: 22, height: 24)
  for anchor in [offscreen, below, unplugged] {
    let fallbackPlacement = PanelLayout.placement(
      anchor: anchor, screens: [connected], fallbackScreenFrame: fallbackScreen,
      fallbackVisible: fallback)
    #expect(fallbackPlacement.centerX == fallback.midX)
    #expect(fallbackPlacement.menuBottom == fallback.maxY)
    #expect(fallbackPlacement.screenFrame == fallbackScreen)
    #expect(fallbackPlacement.visible == fallback)
  }
}

@Test func documentPanelSizeExpandsForSplitAndSidebarAndClampsToNarrowScreens() {
  let wide = CGRect(x: 0, y: 0, width: 1600, height: 1000)
  let single = PanelLayout.documentPanelSize(
    enlarged: false, split: false, sidebar: false, screenFrame: wide, visibleFrame: wide)
  #expect(single.panelSize == CGSize(width: 480, height: 600))
  #expect(single.sidebarWidth == 0)

  let enlargedSingle = PanelLayout.documentPanelSize(
    enlarged: true, split: false, sidebar: false,
    screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
    visibleFrame: CGRect(x: 0, y: 25, width: 1600, height: 900))
  #expect(enlargedSingle.panelSize == CGSize(width: 710, height: 800))

  let twoWithSidebar = PanelLayout.documentPanelSize(
    enlarged: false, split: false, sidebar: true, screenFrame: wide, visibleFrame: wide)
  #expect(twoWithSidebar.sidebarWidth == PanelLayout.sidebarWidth)
  #expect(twoWithSidebar.panelSize.width == 480 + PanelLayout.sidebarWidth)

  let twoSplit = PanelLayout.documentPanelSize(
    enlarged: false, split: true, sidebar: false, screenFrame: wide, visibleFrame: wide)
  #expect(twoSplit.sidebarWidth == 0)
  #expect(twoSplit.panelSize.width == 960)

  let threePanes = PanelLayout.documentPanelSize(
    enlarged: false, split: true, sidebar: true, screenFrame: wide, visibleFrame: wide)
  #expect(threePanes.sidebarWidth == PanelLayout.sidebarWidth)
  #expect(threePanes.panelSize.width == 960 + PanelLayout.sidebarWidth)

  for narrowWidth in [CGFloat(1024), 760, 560] {
    let narrow = CGRect(x: 0, y: 0, width: narrowWidth, height: 700)
    let layout = PanelLayout.documentPanelSize(
      enlarged: true, split: true, sidebar: true, screenFrame: narrow, visibleFrame: narrow)
    #expect(layout.panelSize.width <= narrow.width)
    #expect(layout.panelSize.height <= narrow.height)
    #expect(
      layout.sidebarWidth >= PanelLayout.minSidebarWidth
        || layout.sidebarWidth < narrow.width)
    #expect(layout.panelSize.width - layout.sidebarWidth >= 300)
    let frame = PanelLayout.frame(
      iconCenterX: narrow.maxX - 30, menuBarBottomY: narrow.maxY,
      size: layout.panelSize, visibleFrame: narrow)
    #expect(narrow.contains(frame))
  }
}

@Test func enlargedDocumentSplitAndSidebarUseTheWiderColumn() {
  let screen = CGRect(x: 0, y: 0, width: 2400, height: 1000)
  let visible = CGRect(x: 0, y: 25, width: 2400, height: 900)
  let layout = PanelLayout.documentPanelSize(
    enlarged: true, split: true, sidebar: true,
    screenFrame: screen, visibleFrame: visible)
  #expect(layout.panelSize.width == PanelLayout.documentWidth * 2 + PanelLayout.sidebarWidth)
  #expect(layout.panelSize.height == 800)
  #expect(layout.sidebarWidth == PanelLayout.sidebarWidth)
}

@Test func windowFramesUseIntegralPoints() {
  let visible = CGRect(x: 0, y: 0, width: 1600, height: 900)
  let frame = PanelLayout.frame(
    iconCenterX: 801.5, menuBarBottomY: 900, enlarged: false, visibleFrame: visible)
  #expect(frame.minX == frame.minX.rounded())
  #expect(frame.minY == frame.minY.rounded())
  #expect(frame.width == frame.width.rounded())
  #expect(frame.height == frame.height.rounded())
}
