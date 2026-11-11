import Foundation

public struct ScrollThumb: Equatable, Sendable {
  public let length: Double
  public let position: Double

  public static func geometry(viewport: Double, content: Double, offset: Double) -> Self? {
    guard viewport.isFinite, content.isFinite, offset.isFinite,
      viewport > 0, content > viewport
    else { return nil }
    let length = min(viewport, max(20, viewport * viewport / content))
    let fraction = min(1, max(0, offset / (content - viewport)))
    return Self(length: length, position: fraction * (viewport - length))
  }
}
