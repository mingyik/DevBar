public enum TerminalApps: Sendable {
  public static let bundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
  ]

  public static func shouldYield(_ bundleID: String?) -> Bool {
    guard let bundleID else { return false }
    return bundleIDs.contains(bundleID)
  }
}
