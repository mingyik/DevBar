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
  static let openTools = Self("openTools", default: .init(.j, modifiers: [.option, .command]))
  static let captureRegion = Self(
    "captureRegion", default: .init(.four, modifiers: [.option, .command]))
  static let captureScroll = Self(
    "captureScroll", default: .init(.five, modifiers: [.option, .command]))
  static let recordToggle = Self(
    "recordToggle", default: .init(.six, modifiers: [.option, .command]))
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
    KeyboardShortcuts.onKeyUp(for: .openTools) {
      Task { @MainActor in
        log("openTools")
        // Import/routing belongs to R8; R7 exposes the JSON placeholder.
        panel.model.page = .json
        panel.show(anchor: status.anchor)
      }
    }
    KeyboardShortcuts.onKeyUp(for: .captureRegion) {
      Task { @MainActor in log("captureRegion") }
    }
    KeyboardShortcuts.onKeyUp(for: .captureScroll) {
      Task { @MainActor in log("captureScroll") }
    }
    KeyboardShortcuts.onKeyUp(for: .recordToggle) {
      Task { @MainActor in log("recordToggle") }
    }
  }

  private static func log(_ name: String) {
    logger.notice("shortcut=\(name, privacy: .public)")
  }
}
