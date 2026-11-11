import KeyboardShortcuts
import Testing

@testable import DevBar

@MainActor @Test func terminalKeepsCommandShiftVButYieldsControlV() {
  let terminal = "com.apple.Terminal"
  #expect(!TerminalYield.shouldYield(terminal, shortcut: .init(.v, modifiers: [.command, .shift])))
  #expect(TerminalYield.shouldYield(terminal, shortcut: .init(.v, modifiers: [.control])))
  #expect(TerminalYield.shouldYield(terminal, shortcut: .init(.v, modifiers: [.control, .shift])))
  let browser = "com.apple.Safari"
  #expect(!TerminalYield.shouldYield(browser, shortcut: .init(.v, modifiers: [.control])))
  #expect(!TerminalYield.shouldYield(terminal, shortcut: nil))
}
