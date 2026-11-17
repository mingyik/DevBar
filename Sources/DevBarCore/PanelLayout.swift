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
  public static let sidebarWidth: CGFloat = 240
  public static let minSidebarWidth: CGFloat = 180
  public static let menuGap: CGFloat = 6

  /// Determine fixed card widths from the screen before choosing a 1, 2, or 3 pane layout.
  /// All modes use the same card widths; transitions only change their visible positions.
  public static func documentPanelSize(
    enlarged: Bool,
    split: Bool,
    sidebar: Bool,
    visibleFrame: CGRect
  ) -> (panelSize: CGSize, sidebarWidth: CGFloat) {
    let fullWidth = max(0, visibleFrame.width)
    let fixedSidebar = min(sidebarWidth, fullWidth / 4)
    let pane = min(
      (enlarged ? large.width : normal.width) - 20,
      max(0, (fullWidth - fixedSidebar - 0.7 - 22) / 2))
    let content = split ? pane * 2 + 22 : pane + 20
    let total = content + (sidebar ? fixedSidebar + 0.7 : 0)
    let height = min(
      enlarged ? floor(visibleFrame.height * 4 / 5) : normal.height,
      max(0, visibleFrame.height))
    return (CGSize(width: min(fullWidth, total), height: height), sidebar ? fixedSidebar : 0)
  }

  public static func documentPaneWidth(enlarged: Bool, visibleFrame: CGRect) -> CGFloat {
    documentPanelSize(
      enlarged: enlarged, split: false, sidebar: false,
      visibleFrame: visibleFrame
    ).panelSize.width - 20
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
    anchor: CGRect?, screens: [DisplaySlice], fallbackVisible: CGRect
  ) -> (centerX: CGFloat, menuBottom: CGFloat, visible: CGRect) {
    if let anchor, let screen = menuBarScreen(anchor, screens: screens) {
      return (anchor.midX, anchor.minY, screen.visibleFrame)
    }
    return (fallbackVisible.midX, fallbackVisible.maxY, fallbackVisible)
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
    return result
  }
}
