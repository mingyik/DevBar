import Foundation

/// Edge bands the person sets while a long capture runs. The top and bottom
/// bands are kept once as a fixed header and footer; the right band (overlay
/// scroller, window edge) is left out of the result. Values are pixels of the
/// selected region. `nil` keeps the automatically detected band.
public final class ScrollingInsetControl: @unchecked Sendable {
  public struct Values: Equatable, Sendable {
    public var top: Int?
    public var bottom: Int?
    public var right: Int

    public init(top: Int? = nil, bottom: Int? = nil, right: Int = 0) {
      self.top = top
      self.bottom = bottom
      self.right = right
    }
  }

  private let lock = NSLock()
  private var values: Values
  private var version = 0
  private var observer: (@Sendable () -> Void)?

  public init(_ values: Values = .init()) {
    self.values = values
  }

  public var current: Values {
    lock.lock()
    defer { lock.unlock() }
    return values
  }

  public func update(_ change: (inout Values) -> Void) {
    var notify: (@Sendable () -> Void)?
    lock.lock()
    let before = values
    change(&values)
    if values != before {
      version += 1
      notify = observer
    }
    lock.unlock()
    notify?()
  }

  func onChange(_ handler: (@Sendable () -> Void)?) {
    lock.lock()
    observer = handler
    lock.unlock()
  }

  /// Values changed since `seen`; nil when nothing changed.
  func changes(since seen: inout Int) -> Values? {
    lock.lock()
    defer { lock.unlock() }
    guard version != seen else { return nil }
    seen = version
    return values
  }
}
