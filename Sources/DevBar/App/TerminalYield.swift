import AppKit
import DevBarCore
import KeyboardShortcuts
import os

@MainActor
final class TerminalYield {
  private let logger = Logger(subsystem: "local.devbar.app", category: "shortcut")
  private var observer: NSObjectProtocol?
  private var yielding = false

  func start() {
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let bundleID =
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
        .bundleIdentifier
      MainActor.assumeIsolated {
        self?.update(bundleID)
      }
    }
    update(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
  }

  static func shouldYield(_ bundleID: String?, shortcut: KeyboardShortcuts.Shortcut?) -> Bool {
    guard TerminalApps.shouldYield(bundleID), let shortcut else { return false }
    return shortcut == .init(.v, modifiers: [.control])
      || shortcut == .init(.v, modifiers: [.control, .shift])
  }

  private func update(_ bundleID: String?) {
    let next = Self.shouldYield(bundleID, shortcut: KeyboardShortcuts.getShortcut(for: .cycleOlder))
    guard next != yielding else { return }
    yielding = next
    if next {
      KeyboardShortcuts.disable(.cycleOlder)
      logger.notice("terminalYield=on")
    } else {
      KeyboardShortcuts.enable(.cycleOlder)
      logger.notice("terminalYield=off")
    }
  }
}
