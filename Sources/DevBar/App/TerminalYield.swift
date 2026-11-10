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
      let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
      MainActor.assumeIsolated {
        self?.update(bundleID)
      }
    }
    update(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
  }

  private func update(_ bundleID: String?) {
    let next = TerminalApps.shouldYield(bundleID)
    guard next != yielding else { return }
    yielding = next
    if next {
      KeyboardShortcuts.disable(.cycleOlder)
      KeyboardShortcuts.disable(.cycleNewer)
      logger.notice("terminalYield=on")
    } else {
      KeyboardShortcuts.enable(.cycleOlder)
      KeyboardShortcuts.enable(.cycleNewer)
      logger.notice("terminalYield=off")
    }
  }
}
