import AppKit

@MainActor
final class DevBarPanel: NSPanel {
  var onEscape: (() -> Void)?
  var onSelectPage: ((Int) -> Void)?

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
    guard flags == .command, let characters = event.charactersIgnoringModifiers,
      characters.count == 1
    else {
      return false
    }
    switch characters {
    case "1":
      onSelectPage?(0)
    case "2":
      onSelectPage?(1)
    case "3":
      onSelectPage?(2)
    case "4":
      onSelectPage?(3)
    default:
      return false
    }
    return true
  }
}
