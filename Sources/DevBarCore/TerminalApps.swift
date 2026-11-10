public enum TerminalApps: Sendable {
  public static let bundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable",
    "io.alacritty",
    "org.alacritty",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "co.zeit.hyper",
  ]

  public static func shouldYield(_ bundleID: String?) -> Bool {
    guard let bundleID else { return false }
    return bundleIDs.contains(bundleID)
  }
}
