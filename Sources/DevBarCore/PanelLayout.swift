import CoreGraphics

public enum PanelLayout: Sendable {
  public struct DisplaySlice: Sendable, Equatable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public init(frame: CGRect, visibleFrame: CGRect) {
      self.frame = frame
      self.visibleFrame = visibleFrame
    }
  }

  public static let normal = CGSize(width: 480, height: 600)
  public static let large = CGSize(width: 640, height: 720)
  /// Markdown 内容列，比旧的 640pt 宽 70pt。
  public static let documentWidth: CGFloat = large.width + 70
  public static let sidebarWidth: CGFloat = 240
  public static let minSidebarWidth: CGFloat = 180
  public static let menuGap: CGFloat = 6

  /// Computes the single-window Markdown panel size and sidebar width for 1, 2, or 3 panes,
  /// expanding when space permits and shrinking proportionally on narrow screens.
  public static func documentPanelSize(
    enlarged: Bool,
    split: Bool,
    sidebar: Bool,
    screenFrame: CGRect,
    visibleFrame: CGRect
  ) -> (panelSize: CGSize, sidebarWidth: CGFloat) {
    let paneWidth = enlarged ? documentWidth : normal.width
    let desiredContentWidth = split ? paneWidth * 2 : paneWidth
    let desiredSidebarWidth: CGFloat = sidebar ? sidebarWidth : 0
    // 4/5 以整块屏幕为基准，不扣菜单栏；高度仍受可用区域限制。
    let desiredHeight = enlarged ? floor(screenFrame.height * 4 / 5) : normal.height
    let clampedHeight = min(desiredHeight, max(0, visibleFrame.height.rounded(.down)))
    let totalDesiredWidth = desiredSidebarWidth + desiredContentWidth
    let clampedWidth = min(totalDesiredWidth, max(0, visibleFrame.width.rounded(.down)))
    guard sidebar else {
      return (CGSize(width: clampedWidth, height: clampedHeight), 0)
    }
    let minContentForPreferredSidebar: CGFloat = split ? 420 : 320
    let actualSidebarWidth: CGFloat
    if clampedWidth - sidebarWidth >= minContentForPreferredSidebar {
      actualSidebarWidth = sidebarWidth
    } else {
      let scaled = floor(clampedWidth * 0.28)
      actualSidebarWidth = min(clampedWidth, max(min(minSidebarWidth, clampedWidth), scaled))
    }
    return (
      CGSize(width: clampedWidth, height: clampedHeight),
      actualSidebarWidth.rounded(.down)
    )
  }

  /// Usable only when the anchor center is on a connected display and its bottom
  /// edge is inside that display's menu bar. Off-screen status items fail this.
  public static func menuBarScreen(_ anchor: CGRect, screens: [DisplaySlice]) -> DisplaySlice? {
    let center = CGPoint(x: anchor.midX, y: anchor.midY)
    guard let screen = screens.first(where: { $0.frame.contains(center) }) else { return nil }
    guard anchor.minY >= screen.visibleFrame.maxY - 2 else { return nil }
    return screen
  }

  public static func placement(
    anchor: CGRect?, screens: [DisplaySlice], fallbackScreenFrame: CGRect,
    fallbackVisible: CGRect
  ) -> (centerX: CGFloat, menuBottom: CGFloat, screenFrame: CGRect, visible: CGRect) {
    if let anchor, let screen = menuBarScreen(anchor, screens: screens) {
      return (anchor.midX, anchor.minY, screen.frame, screen.visibleFrame)
    }
    return (
      fallbackVisible.midX, fallbackVisible.maxY, fallbackScreenFrame, fallbackVisible
    )
  }

  /// 以图标中心对齐，改变尺寸时保持顶边；超出可见区域再向内收。
  public static func frame(
    iconCenterX: CGFloat,
    menuBarBottomY: CGFloat,
    enlarged: Bool,
    visibleFrame: CGRect
  ) -> CGRect {
    frame(
      iconCenterX: iconCenterX, menuBarBottomY: menuBarBottomY,
      size: enlarged ? large : normal, visibleFrame: visibleFrame)
  }

  public static func frame(
    iconCenterX: CGFloat, menuBarBottomY: CGFloat,
    size: CGSize, visibleFrame: CGRect
  ) -> CGRect {
    let top = min(menuBarBottomY - menuGap, visibleFrame.maxY)
    let height = min(size.height, max(0, top - visibleFrame.minY))
    return clamp(
      CGRect(
        x: iconCenterX - size.width / 2, y: top - height,
        width: size.width, height: height), in: visibleFrame)
  }

  public static func clamp(_ rect: CGRect, in visible: CGRect) -> CGRect {
    var result = rect
    if result.width > visible.width {
      result.size.width = visible.width
    }
    if result.height > visible.height {
      result.size.height = visible.height
    }
    if result.minX < visible.minX {
      result.origin.x = visible.minX
    }
    if result.maxX > visible.maxX {
      result.origin.x = visible.maxX - result.width
    }
    if result.minY < visible.minY {
      result.origin.y = visible.minY
    }
    if result.maxY > visible.maxY {
      result.origin.y = visible.maxY - result.height
    }
    return integral(result, in: visible)
  }

  /// 最终窗口落在整数点上，避免半像素边缘。
  private static func integral(_ rect: CGRect, in visible: CGRect) -> CGRect {
    var result = CGRect(
      x: rect.minX.rounded(), y: rect.minY.rounded(),
      width: max(0, rect.width.rounded(.down)),
      height: max(0, rect.height.rounded(.down)))
    if result.width > visible.width { result.size.width = visible.width.rounded(.down) }
    if result.height > visible.height { result.size.height = visible.height.rounded(.down) }
    if result.minX < visible.minX { result.origin.x = visible.minX.rounded(.up) }
    if result.maxX > visible.maxX {
      result.origin.x = (visible.maxX - result.width).rounded(.down)
    }
    if result.minY < visible.minY { result.origin.y = visible.minY.rounded(.up) }
    if result.maxY > visible.maxY {
      result.origin.y = (visible.maxY - result.height).rounded(.down)
    }
    return result
  }
}
