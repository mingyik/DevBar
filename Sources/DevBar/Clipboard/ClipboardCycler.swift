import Foundation

struct ClipboardCycler {
  private(set) var currentIndex = 0
  mutating func reset() { currentIndex = 0 }
  mutating func select(_ index: Int, count: Int) {
    currentIndex = min(max(index, 0), max(count - 1, 0))
  }
  /// True means a boundary was reached; never wraps.
  mutating func move(older: Bool, count: Int) -> Bool {
    let next = currentIndex + (older ? 1 : -1)
    guard count > 0, (0..<count).contains(next) else { return true }
    currentIndex = next
    return false
  }
}
