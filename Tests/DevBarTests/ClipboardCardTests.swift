import AppKit
import DevBarCore
import KeyboardShortcuts
import Testing

@testable import DevBar

@Test @MainActor func clipboardCardEnterConfirmsOnceAfterClosing() {
  _ = NSApplication.shared
  let card = ClipboardCard(theme: ThemeManager())
  var confirmations = 0
  card.onConfirm = {
    #expect(!card.panel.isVisible)
    #expect(!card.temporaryKeys.isRegistered)
    confirmations += 1
  }
  card.show(
    index: 0, count: 1, title: "测试", subtitle: "", thumbnail: nil, swatch: nil, fileCount: 0,
    boundary: false)
  card.temporaryKeys.onKey?(36)
  #expect(confirmations == 1)
}

@Test @MainActor func clipboardCardConfirmationNotifiesDismissAfterCallback() {
  _ = NSApplication.shared
  let card = ClipboardCard(theme: ThemeManager())
  var events: [String] = []
  card.onConfirm = { events.append("confirm") }
  card.onDismiss = { events.append("dismiss") }
  card.show(
    index: 0, count: 1, title: "测试", subtitle: "", thumbnail: nil, swatch: nil,
    fileCount: 0, boundary: false)

  card.temporaryKeys.onKey?(36)

  #expect(events == ["confirm", "dismiss"])
}

@Test @MainActor func clipboardCardAuthorizationNoticeReusesTheSamePosition() {
  _ = NSApplication.shared
  let card = ClipboardCard(theme: ThemeManager())
  card.show(
    index: 0, count: 1, title: "测试", subtitle: "", thumbnail: nil, swatch: nil,
    fileCount: 0, boundary: false)
  let oldCenter = NSPoint(x: card.panel.frame.midX, y: card.panel.frame.midY)

  card.showAuthorizationNotice(
    title: "已复制，可按 ⌘V 粘贴", subtitle: "授权辅助功能后可直接粘贴")

  #expect(card.panel.isVisible)
  #expect(card.isAuthorizationNoticeVisible)
  #expect(!card.temporaryKeys.isRegistered)
  #expect(abs(card.panel.frame.midX - oldCenter.x) < 0.5)
  #expect(abs(card.panel.frame.midY - oldCenter.y) < 0.5)
  card.dismiss()
}

@Test @MainActor func imageClipboardCardShowsDimensionsInFullWidthBottomLine() {
  let card = DragCardImage.make(
    title: "", subtitle: "474 × 474", fileCount: 0,
    thumbnail: NSImage(size: NSSize(width: 40, height: 40)),
    swatch: nil, scheme: .light, glass: true)
  #expect(card.image.size.width == DragCard.minWidth + 20)
  #expect(card.image.size.width <= DragCard.maxWidth + 20)
}

@Test @MainActor func floatingTextPreviewUsesAtMostTwoLines() {
  let font = NSFont.systemFont(ofSize: 12)
  let oneLine = DragCardImage.previewLines(
    "短文本", firstLineWidth: 120, secondLineWidth: 70, font: font)
  #expect(oneLine.first == "短文本")
  #expect(oneLine.second == nil)

  let twoLines = DragCardImage.previewLines(
    "这是一段需要换行的长文本", firstLineWidth: 72, secondLineWidth: 62, font: font)
  #expect(!twoLines.first.isEmpty)
  #expect(twoLines.second?.isEmpty == false)
  #expect(twoLines.second?.hasSuffix("…") == true)
}

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

@Test @MainActor func clipboardCardEscapeHidesWithoutActivatingAndReleasesKeys() {
  _ = NSApplication.shared
  let card = ClipboardCard(theme: ThemeManager())
  card.show(
    index: 0, count: 2, title: "合成测试", subtitle: "文本", thumbnail: nil, swatch: nil,
    fileCount: 0, boundary: false)
  #expect(card.panel.isVisible)
  #expect(card.panel.contentView?.subviews.contains { $0 is NSVisualEffectView } == true)
  card.temporaryKeys.onKey?(53)
  #expect(!card.panel.isVisible)
  #expect(!card.temporaryKeys.isRegistered)
}

@Test @MainActor func clipboardCardCaretPlacementPrefersAboveAndFallsBelow() {
  let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
  let size = NSSize(width: 240, height: 80)
  let middle = ClipboardCard.caretFrame(
    caret: NSRect(x: 400, y: 300, width: 1, height: 20), size: size, visible: screen)
  #expect(middle.minY >= 320)
  let top = ClipboardCard.caretFrame(
    caret: NSRect(x: 790, y: 570, width: 1, height: 20), size: size, visible: screen)
  #expect(top.maxY <= 570)
  #expect(screen.contains(top))
}

@Test @MainActor func clipboardCardFallbackCentersWhenPointerIsOutsideScreens() {
  let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
  let frame = ClipboardCard.fallbackFrame(
    pointer: NSPoint(x: 5000, y: 5000), size: NSSize(width: 200, height: 80), visible: screen)
  #expect(frame.midX == screen.midX)
  #expect(frame.midY == screen.midY)
}
