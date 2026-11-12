import AppKit

@MainActor
final class DevBarPanel: NSPanel {
  var onEscape: (() -> Void)?
  var onDocumentMode: (() -> Bool)?
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
    isMovableByWindowBackground = false
    animationBehavior = .none
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  @objc func _hasActiveAppearance() -> Bool { true }
  @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
  @objc func hasKeyAppearance() -> Bool { true }

  override func sendEvent(_ event: NSEvent) {
    // Explicit dismissal takes precedence over text/preview responders.
    if event.type == .keyDown, event.keyCode == 53 {
      onEscape?()
      return
    }
    // Scroll views can consume arrows before keyDown reaches the window.
    // Clipboard navigation owns unmodified arrows/return on that page only.
    let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
    if event.type == .keyDown, modifiers.isEmpty,
      [UInt16(125), 126, 36, 51].contains(event.keyCode), onClipboardKey?(event.keyCode) == true
    {
      return
    }
    super.sendEvent(event)
  }

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
    let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
    if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "p" {
      return onDocumentMode?() ?? false
    }
    if flags == .command,
      event.charactersIgnoringModifiers?.lowercased() == "p"
    {
      onCyclePage?(false)
      return true
    }
    if flags.isEmpty, onClipboardKey?(event.keyCode) == true { return true }
    guard flags == .command, let characters = event.charactersIgnoringModifiers?.lowercased() else {
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

/// Keeps Liquid Glass in its active appearance without stealing key focus from the main panel.
@MainActor
final class ClipboardPreviewPanel: NSPanel {
  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    hidesOnDeactivate = false
    ignoresMouseEvents = false
    animationBehavior = .none
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  @objc func _hasActiveAppearance() -> Bool { true }
  @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
  @objc func hasKeyAppearance() -> Bool { true }
}
