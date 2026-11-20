import AppKit
import Testing

@testable import DevBar

@MainActor private final class EditingResponder: NSResponder {
  var actions: [String] = []
  override var acceptsFirstResponder: Bool { true }
  @objc func paste(_ sender: Any?) { actions.append("paste") }
  @objc func copy(_ sender: Any?) { actions.append("copy") }
  @objc func cut(_ sender: Any?) { actions.append("cut") }
}

@MainActor @Test func editingCommandsReachPanelResponderWithoutMainMenu() {
  _ = NSApplication.shared
  let panel = DevBarPanel()
  let responder = EditingResponder()
  panel.makeFirstResponder(responder)
  for (key, flags) in [
    ("v", NSEvent.ModifierFlags.command), ("c", .command), ("x", .command),
    ("V", [.command, .capsLock]),
  ] {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: key,
      charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
    #expect(panel.performKeyEquivalent(with: event))
  }
  #expect(responder.actions == ["paste", "copy", "cut", "paste"])
}

@MainActor @Test func commandWClosesPanelLocally() {
  _ = NSApplication.shared
  let panel = DevBarPanel()
  var closed = 0
  panel.onClosePanel = { closed += 1 }
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
    windowNumber: panel.windowNumber, context: nil, characters: "w",
    charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
  #expect(panel.performKeyEquivalent(with: event))
  #expect(closed == 1)
}

@MainActor private final class ArrowConsumingResponder: NSResponder {
  var consumed = 0
  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) { consumed += 1 }
}

@MainActor @Test func clipboardNavigationPrecedesScrollViewAndIgnoresSystemArrowFlags() {
  _ = NSApplication.shared
  let panel = DevBarPanel()
  let responder = ArrowConsumingResponder()
  panel.makeFirstResponder(responder)
  var received: [UInt16] = []
  panel.onClipboardKey = {
    received.append($0)
    return [125, 126, 36].contains($0)
  }
  for (code, text) in [(UInt16(125), "\u{f701}"), (126, "\u{f700}"), (36, "\r")] {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero,
      modifierFlags: [.function, .numericPad], timestamp: 0, windowNumber: panel.windowNumber,
      context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false,
      keyCode: code)!
    panel.sendEvent(event)
  }
  #expect(received == [125, 126, 36])
  #expect(responder.consumed == 0)
}

@MainActor @Test func escapeReachesTheInputResponder() {
  _ = NSApplication.shared
  let panel = DevBarPanel()
  panel.makeKeyAndOrderFront(nil)
  defer { panel.orderOut(nil) }
  let responder = ArrowConsumingResponder()
  panel.makeFirstResponder(responder)
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
  panel.sendEvent(event)
  #expect(panel.isVisible)
  #expect(responder.consumed == 1)
}
