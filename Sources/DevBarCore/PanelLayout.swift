import CoreGraphics

public enum PanelLayout: Sendable {
  public static let normal = CGSize(width: 480, height: 600)
  public static let large = CGSize(width: 640, height: 720)
  public static let menuGap: CGFloat = 6

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
