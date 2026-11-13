import AppKit
@preconcurrency import ApplicationServices

/// Queries only the selected range's geometry, never the text itself.
enum ClipboardCaretLocator {
  nonisolated static func bounds(for pid: pid_t) -> CGRect? {
    guard AXIsProcessTrusted() else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.05)
    var focused: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return nil }
    let element = focused as! AXUIElement
    AXUIElementSetMessagingTimeout(element, 0.05)
    var range: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range)
        == .success, let range, CFGetTypeID(range) == AXValueGetTypeID()
    else { return nil }
    let rangeValue = range as! AXValue
    guard AXValueGetType(rangeValue) == .cfRange else { return nil }
    var selected = CFRange()
    guard AXValueGetValue(rangeValue, .cfRange, &selected), selected.length == 0 else { return nil }
    var value: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &value)
        == .success, let value, CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    let boundsValue = value as! AXValue
    var bounds = CGRect.zero
    guard AXValueGetType(boundsValue) == .cgRect,
      AXValueGetValue(boundsValue, .cgRect, &bounds),
      bounds.origin != .zero, bounds.height > 0, bounds.height <= 80,
      bounds.width >= 0, bounds.width <= 80,
      bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite
    else { return nil }
    return bounds
  }
}
