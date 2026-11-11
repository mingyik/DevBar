import CoreGraphics
import Testing

@testable import DevBarCore

@Test func scrollThumbFitsClampsAndTracksContentRatio() {
  #expect(ScrollThumb.geometry(viewport: 100, content: 100, offset: 0) == nil)
  #expect(ScrollThumb.geometry(viewport: 0, content: 100, offset: 0) == nil)
  #expect(ScrollThumb.geometry(viewport: 100, content: 200, offset: -10)?.position == 0)
  #expect(ScrollThumb.geometry(viewport: 100, content: 200, offset: 50)?.position == 25)
  #expect(ScrollThumb.geometry(viewport: 100, content: 200, offset: 999)?.position == 50)
  #expect(ScrollThumb.geometry(viewport: 100, content: 10000, offset: 0)?.length == 20)
}

@Test func panelResizeKeepsTopWhenScreenIsShort() {
  let visible = CGRect(x: 0, y: 0, width: 1000, height: 650)
  let normal = PanelLayout.frame(
    iconCenterX: 500, menuBarBottomY: 650, size: CGSize(width: 480, height: 600),
    visibleFrame: visible)
  let large = PanelLayout.frame(
    iconCenterX: 500, menuBarBottomY: 650, size: CGSize(width: 640, height: 720),
    visibleFrame: visible)
  #expect(normal.maxY == 644)
  #expect(large.maxY == normal.maxY)
  #expect(large.height == 644)
}
