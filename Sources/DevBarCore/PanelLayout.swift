import CoreGraphics

public enum PanelLayout: Sendable {
  public static let normal = CGSize(width: 420, height: 560)
  public static let large = CGSize(width: 600, height: 700)
  public static let menuGap: CGFloat = 6

  /// 普通尺寸以图标中心对齐；放大时保持顶边，宽度向左扩展。超出可见区域再向内收。
  public static func frame(
    iconCenterX: CGFloat,
    menuBarBottomY: CGFloat,
    enlarged: Bool,
    visibleFrame: CGRect
  ) -> CGRect {
    let size = enlarged ? large : normal
    let top = menuBarBottomY - menuGap
    let right = iconCenterX + normal.width / 2
    let originX = enlarged ? right - size.width : iconCenterX - size.width / 2
    let proposed = CGRect(x: originX, y: top - size.height, width: size.width, height: size.height)
    return clamp(proposed, in: visibleFrame)
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
