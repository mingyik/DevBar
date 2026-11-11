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
  for key in ["v", "c", "x"] {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: key,
      charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
    #expect(panel.performKeyEquivalent(with: event))
  }
  #expect(responder.actions == ["paste", "copy", "cut"])
}
