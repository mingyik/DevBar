import AppKit
import DevBarCore
import KeyboardShortcuts
import Testing

@testable import DevBar

@Suite(.serialized)
struct ClipboardCardTests {
  @Test @MainActor func clipboardCardClosesWhenFocusMovesToAnotherApplication() async {
    _ = NSApplication.shared
    var process: pid_t? = 1001
    let card = ClipboardCard(
      theme: ThemeManager(), focusedProcess: { process }, caretBounds: { _ in nil })
    card.show(
      index: 0, count: 2, title: "测试", subtitle: "", thumbnail: nil, swatch: nil,
      fileCount: 0, boundary: false, target: 1001)
    process = 1002
    await card.refreshLocation()
    #expect(!card.panel.isVisible)
    #expect(!card.temporaryKeys.isRegistered)
  }

  @Test @MainActor func clipboardCardFollowsChangedCaretWhileAlreadyVisible() async {
    _ = NSApplication.shared
    guard let screen = NSScreen.screens.first else { return }
    var bounds = CGRect(x: screen.frame.midX, y: 200, width: 1, height: 20)
    let card = ClipboardCard(
      theme: ThemeManager(), focusedProcess: { 1001 }, caretBounds: { _ in bounds })
    card.show(
      index: 0, count: 2, title: "测试", subtitle: "", thumbnail: nil, swatch: nil,
      fileCount: 0, boundary: false, target: 1001)
    await card.refreshLocation()
    let oldFrame = card.panel.frame
    bounds.origin.y += 160
    await card.refreshLocation()
    #expect(abs(card.panel.frame.minY - oldFrame.minY) > 100)
    card.dismiss()
    let closedFrame = card.panel.frame
    bounds.origin.y += 80
    await card.refreshLocation()
    #expect(card.panel.frame == closedFrame)
    #expect(!card.panel.isVisible)
  }

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
      index: 2, count: 10, title: "合成测试", subtitle: "4 字符", thumbnail: nil, swatch: nil,
      fileCount: 0,
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

  @Test @MainActor func clipboardCardPanelStaysVisibleAcrossInactiveFullScreenSpaces() {
    _ = NSApplication.shared
    let card = ClipboardCard(theme: ThemeManager())
    #expect(card.panel.level == .popUpMenu)
    #expect(!card.panel.hidesOnDeactivate)
    #expect(
      card.panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .transient]))
    #expect(!card.panel.collectionBehavior.contains(.stationary))
  }

  @Test @MainActor func clipboardCardAnchoredFrameGrowsAwayFromLockedEdge() {
    let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let bottomAnchor = ClipboardCard.LockedAnchor(
      centerX: 500, edgeY: 320, edge: .bottom, visible: screen)
    let shortAbove = ClipboardCard.anchoredFrame(
      anchor: bottomAnchor, size: NSSize(width: 220, height: 76))
    let tallAbove = ClipboardCard.anchoredFrame(
      anchor: bottomAnchor, size: NSSize(width: 280, height: 140))
    #expect(shortAbove.minY == 320)
    #expect(tallAbove.minY == 320)
    #expect(tallAbove.maxY > shortAbove.maxY)

    let topAnchor = ClipboardCard.LockedAnchor(
      centerX: 500, edgeY: 720, edge: .top, visible: screen)
    let shortBelow = ClipboardCard.anchoredFrame(
      anchor: topAnchor, size: NSSize(width: 220, height: 76))
    let tallBelow = ClipboardCard.anchoredFrame(
      anchor: topAnchor, size: NSSize(width: 280, height: 140))
    #expect(shortBelow.maxY == 720)
    #expect(tallBelow.maxY == 720)
    #expect(tallBelow.minY < shortBelow.minY)
  }

  @Test @MainActor func clipboardCardKeepsLockedEdgeAcrossItemSwitchesAndRespectsReduceMotion()
    async
  {
    _ = NSApplication.shared
    guard let screen = NSScreen.screens.first else { return }
    let bounds = CGRect(x: screen.frame.midX, y: 260, width: 1, height: 20)
    let card = ClipboardCard(
      theme: ThemeManager(), focusedProcess: { 1001 }, caretBounds: { _ in bounds },
      reduceMotion: { true })
    card.show(
      index: 0, count: 2, title: "短文本", subtitle: "3 字符", thumbnail: nil, swatch: nil,
      fileCount: 0, boundary: false, target: 1001)
    await card.refreshLocation()
    let lockedMinY = card.panel.frame.minY

    card.show(
      index: 1, count: 2, title: "第一行很长很长\n第二行也很长很长", subtitle: "16 字符",
      thumbnail: NSImage(size: NSSize(width: 60, height: 60)), swatch: nil,
      fileCount: 0, boundary: true, multilineContent: true, target: 1001)
    let originAfterBoundary = card.panel.frame.origin
    #expect(abs(card.panel.frame.minY - lockedMinY) < 0.5)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(card.panel.frame.origin == originAfterBoundary)
    card.dismiss()
  }
}
