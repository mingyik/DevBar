import KeyboardShortcuts

@MainActor enum ClipboardShortcutMigration {
  static let current = KeyboardShortcuts.Shortcut(.v, modifiers: [.command, .shift])
  static func migrated(_ shortcut: KeyboardShortcuts.Shortcut?) -> KeyboardShortcuts.Shortcut {
    guard let shortcut else { return current }
    let retired = [
      KeyboardShortcuts.Shortcut(.v, modifiers: [.control]),
      .init(.v, modifiers: [.control, .shift]),
    ]
    return retired.contains(shortcut) ? current : shortcut
  }
  static func apply() {
    let existing = KeyboardShortcuts.getShortcut(for: .cycleOlder)
    KeyboardShortcuts.setShortcut(migrated(existing), for: .cycleOlder)
  }
}
