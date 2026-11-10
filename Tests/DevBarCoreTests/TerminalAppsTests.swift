import Testing
@testable import DevBarCore

@Test func onlyTerminalAndITermYieldShortcuts() {
  #expect(TerminalApps.shouldYield("com.apple.Terminal"))
  #expect(TerminalApps.shouldYield("com.googlecode.iterm2"))
  #expect(!TerminalApps.shouldYield("com.microsoft.VSCode"))
  #expect(!TerminalApps.shouldYield("com.jetbrains.intellij"))
  #expect(!TerminalApps.shouldYield(nil))
}
