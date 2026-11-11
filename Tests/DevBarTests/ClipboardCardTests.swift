import AppKit
import KeyboardShortcuts
import Testing

@testable import DevBar

@Test @MainActor func clipboardShortcutMigratesRetiredDefaultsButKeepsCustomBindings() {
  let expected = KeyboardShortcuts.Shortcut(.v, modifiers: [.command, .shift])
  #expect(ClipboardShortcutMigration.migrated(nil) == expected)
  #expect(ClipboardShortcutMigration.migrated(.init(.v, modifiers: [.control])) == expected)
  #expect(
    ClipboardShortcutMigration.migrated(.init(.v, modifiers: [.control, .shift])) == expected)
  let custom = KeyboardShortcuts.Shortcut(.b, modifiers: [.control, .option])
  #expect(ClipboardShortcutMigration.migrated(custom) == custom)
}
@Test @MainActor func clipboardCardAnchorsAbovePointerAndClampsVisibleScreen() {
  let screen = NSRect(x: 100, y: 100, width: 900, height: 700)
  let middle = ClipboardCard.frame(
    pointer: NSPoint(x: 550, y: 400), size: NSSize(width: 240, height: 76), visible: screen)
  #expect(middle.minX == 430)
  #expect(middle.minY + 10 == 436)
  let edge = ClipboardCard.frame(
    pointer: NSPoint(x: 998, y: 799), size: NSSize(width: 280, height: 76), visible: screen)
  #expect(screen.contains(edge))
}
@Test @MainActor func clipboardCardDismissesAndReleasesTemporaryKeysTogether() {
  _ = NSApplication.shared
  let card = ClipboardCard(theme: ThemeManager())
  var dismissed = 0
  card.onDismiss = { dismissed += 1 }
  card.show(
    index: 2, count: 10, title: "合成测试", subtitle: "4 字符", thumbnail: nil, swatch: nil, fileCount: 0,
    boundary: false)
  #expect(card.panel.isVisible)
  card.dismiss()
  #expect(!card.panel.isVisible)
  #expect(dismissed == 1)
  #expect(!card.temporaryKeys.isRegistered)
}
