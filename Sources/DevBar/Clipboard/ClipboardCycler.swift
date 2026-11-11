import Foundation

struct ClipboardCycler {
  private(set) var currentIndex = 0
  mutating func reset() { currentIndex = 0 }
  mutating func select(_ index: Int, count: Int) {
    currentIndex = min(max(index, 0), max(count - 1, 0))
  }
  /// True only when there are no items to select.
  mutating func move(older: Bool, count: Int) -> Bool {
    guard count > 0 else { return true }
    currentIndex = (currentIndex + (older ? 1 : -1) + count) % count
    return false
  }
}
