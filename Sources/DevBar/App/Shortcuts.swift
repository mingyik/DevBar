import AppKit
import KeyboardShortcuts
import os

@MainActor
extension KeyboardShortcuts.Name {
  static let pageClipboard = Self("page.clipboard")
  static let pageJSON = Self("page.json")
  static let pageQR = Self("page.qr")
  static let pageDoc = Self("page.doc")
  static let togglePanel = Self(
    "togglePanel", default: .init(.r, modifiers: [.command]))
  static let cycleOlder = Self("cycleOlder", default: .init(.v, modifiers: [.command, .shift]))
  static let captureRegion = Self(
    "captureRegion", default: .init(.a, modifiers: [.command, .shift]))
  static let captureScroll = Self(
    "captureScroll", default: .init(.l, modifiers: [.command, .shift]))
  /// Temporary global hot key while a long capture is active.
  static let captureExit = Self("captureExit", default: .init(.escape))
}

@MainActor
enum ShortcutActions {
  private static let logger = Logger(subsystem: "local.devbar.app", category: "shortcut")

  static func register(panel: PanelController, status: StatusItemController) {
    panel.panel.globalCycleOwnsR = {
      KeyboardShortcuts.getShortcut(for: .togglePanel)
        == KeyboardShortcuts.Shortcut(.r, modifiers: [.command])
    }
    for (name, old) in [
      (
        KeyboardShortcuts.Name.captureRegion,
        KeyboardShortcuts.Shortcut(.four, modifiers: [.option, .command])
      ),
      (
        KeyboardShortcuts.Name.captureScroll,
        KeyboardShortcuts.Shortcut(.five, modifiers: [.option, .command])
      ),
    ] {
      if KeyboardShortcuts.getShortcut(for: name) == old { KeyboardShortcuts.reset(name) }
    }
    ClipboardShortcutMigration.apply()
    KeyboardShortcuts.reset(KeyboardShortcuts.Name("page.encode"))
    for page in PanelModel.Page.contentPages {
      KeyboardShortcuts.onKeyUp(for: page.shortcutName) {
        Task { @MainActor in panel.open(page: page, anchor: status.anchor) }
      }
    }
    let retired = [
      KeyboardShortcuts.Shortcut(.space, modifiers: [.option, .command]),
      KeyboardShortcuts.Shortcut(.d, modifiers: [.control, .option]),
      KeyboardShortcuts.Shortcut(.w, modifiers: [.command]),
    ]
    if let current = KeyboardShortcuts.getShortcut(for: .togglePanel), retired.contains(current) {
      KeyboardShortcuts.reset(.togglePanel)
      logger.notice("shortcut=togglePanel reset retired default")
    }
    KeyboardShortcuts.onKeyUp(for: .togglePanel) {
      Task { @MainActor in
        log("togglePanel")
        if panel.panel.isVisible {
          panel.model.cyclePage()
        } else {
          panel.toggle(anchor: status.anchor)
        }
      }
    }
    KeyboardShortcuts.onKeyDown(for: .cycleOlder) {
      Task { @MainActor in
        log("cycleOlder")
        panel.clipboard.cycle(older: true)
      }
    }
    KeyboardShortcuts.onKeyUp(for: .captureRegion) {
      Task { @MainActor in
        log("captureRegion")
        panel.capture.start(scrolling: false)
      }
    }
    KeyboardShortcuts.onKeyUp(for: .captureScroll) {
      Task { @MainActor in
        log("captureScroll")
        panel.capture.start(scrolling: true)
      }
    }
  }

  private static func log(_ name: String) {
    logger.notice("shortcut=\(name, privacy: .public)")
  }
}
