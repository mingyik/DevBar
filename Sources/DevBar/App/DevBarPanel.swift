import AppKit

@MainActor
final class DevBarPanel: NSPanel {
  var onEscape: (() -> Void)?
  var onCyclePage: ((Bool) -> Void)?
  var onClipboardKey: ((UInt16) -> Bool)?

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    hasShadow = true
    isOpaque = false
    backgroundColor = .clear
    hidesOnDeactivate = false
    animationBehavior = .none
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if handle(event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if handle(event) {
      return
    }
    super.keyDown(with: event)
  }

  private func handle(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 {
      onEscape?()
      return true
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command || flags == [.command, .shift],
      event.charactersIgnoringModifiers?.lowercased() == "p"
    {
      onCyclePage?(flags.contains(.shift))
      return true
    }
    if flags.isEmpty, onClipboardKey?(event.keyCode) == true { return true }
    guard flags == .command, let characters = event.charactersIgnoringModifiers else {
      return false
    }
    // Menu-less agent apps have no Edit menu to dispatch these AppKit actions.
    // Leave select-all and history shortcuts to WKWebView / CodeMirror.
    let actions = ["v": "paste:", "c": "copy:", "x": "cut:"]
    if let action = actions[characters] {
      return firstResponder?.tryToPerform(NSSelectorFromString(action), with: self) ?? false
    }
    return false
  }
}
