import Testing

@testable import DevBarCore

@Test func onlyListedTerminalsYieldShortcuts() {
  #expect(TerminalApps.shouldYield("com.apple.Terminal"))
  #expect(TerminalApps.shouldYield("com.googlecode.iterm2"))
  #expect(TerminalApps.shouldYield("com.mitchellh.ghostty"))
  #expect(TerminalApps.shouldYield("dev.warp.Warp-Stable"))
  #expect(TerminalApps.shouldYield("io.alacritty"))
  #expect(TerminalApps.shouldYield("org.alacritty"))
  #expect(TerminalApps.shouldYield("net.kovidgoyal.kitty"))
  #expect(TerminalApps.shouldYield("com.github.wez.wezterm"))
  #expect(TerminalApps.shouldYield("co.zeit.hyper"))
  #expect(!TerminalApps.shouldYield("com.microsoft.VSCode"))
  #expect(!TerminalApps.shouldYield("com.jetbrains.intellij"))
  #expect(!TerminalApps.shouldYield(nil))
}
