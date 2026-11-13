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
    "togglePanel", default: .init(.d, modifiers: [.control, .option]))
  static let cycleOlder = Self("cycleOlder", default: .init(.v, modifiers: [.command, .shift]))
  static let captureRegion = Self(
    "captureRegion", default: .init(.four, modifiers: [.option, .command]))
  static let captureScroll = Self(
    "captureScroll", default: .init(.five, modifiers: [.option, .command]))
}

@MainActor
enum ShortcutActions {
  private static let logger = Logger(subsystem: "local.devbar.app", category: "shortcut")

  static func register(panel: PanelController, status: StatusItemController) {
    ClipboardShortcutMigration.apply()
    KeyboardShortcuts.reset(KeyboardShortcuts.Name("page.encode"))
    for page in PanelModel.Page.contentPages {
      KeyboardShortcuts.onKeyUp(for: page.shortcutName) {
        Task { @MainActor in panel.open(page: page, anchor: status.anchor) }
      }
    }
    let retired = KeyboardShortcuts.Shortcut(.space, modifiers: [.option, .command])
    if KeyboardShortcuts.getShortcut(for: .togglePanel) == retired {
      KeyboardShortcuts.reset(.togglePanel)
      logger.notice("shortcut=togglePanel reset retired default")
    }
    KeyboardShortcuts.onKeyUp(for: .togglePanel) {
      Task { @MainActor in
        log("togglePanel")
        panel.toggle(anchor: status.anchor)
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
