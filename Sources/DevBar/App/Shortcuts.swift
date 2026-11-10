import AppKit
import KeyboardShortcuts
import os

@MainActor
extension KeyboardShortcuts.Name {
  static let togglePanel = Self("togglePanel", default: .init(.space, modifiers: [.option, .command]))
  static let cycleOlder = Self("cycleOlder", default: .init(.v, modifiers: [.control]))
  static let cycleNewer = Self("cycleNewer", default: .init(.v, modifiers: [.control, .shift]))
  static let openTools = Self("openTools", default: .init(.j, modifiers: [.option, .command]))
  static let captureRegion = Self("captureRegion", default: .init(.four, modifiers: [.option, .command, .shift]))
  static let captureLong = Self("captureLong", default: .init(.five, modifiers: [.option, .command, .shift]))
  static let record = Self("record", default: .init(.six, modifiers: [.option, .command, .shift]))
}

@MainActor
enum ShortcutActions {
  private static let logger = Logger(subsystem: "local.devbar.app", category: "shortcut")

  static func register(panel: PanelController, status: StatusItemController) {
    KeyboardShortcuts.onKeyUp(for: .togglePanel) {
      Task { @MainActor in
        log("togglePanel")
        panel.toggle(anchor: status.anchor)
      }
    }
    KeyboardShortcuts.onKeyUp(for: .cycleOlder) {
      Task { @MainActor in log("cycleOlder") }
    }
    KeyboardShortcuts.onKeyUp(for: .cycleNewer) {
      Task { @MainActor in log("cycleNewer") }
    }
    KeyboardShortcuts.onKeyUp(for: .openTools) {
      Task { @MainActor in log("openTools") }
    }
    KeyboardShortcuts.onKeyUp(for: .captureRegion) {
      Task { @MainActor in log("captureRegion") }
    }
    KeyboardShortcuts.onKeyUp(for: .captureLong) {
      Task { @MainActor in log("captureLong") }
    }
    KeyboardShortcuts.onKeyUp(for: .record) {
      Task { @MainActor in log("record") }
    }
  }

  private static func log(_ name: String) {
    logger.notice("shortcut=\(name, privacy: .public)")
  }
}
