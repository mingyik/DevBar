import AppKit
import DevBarCore
import SwiftUI

@MainActor
@Observable
final class ThemeManager {
  var mode: ThemeMode {
    didSet { defaults.set(mode.rawValue, forKey: key) }
  }

  private(set) var systemScheme: ColorScheme
  private(set) var increaseContrast: Bool
  private let defaults: UserDefaults
  private let key = "themeMode"
  private var observers: [NSObjectProtocol] = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let raw = defaults.string(forKey: key), let stored = ThemeMode(rawValue: raw) {
      mode = stored
    } else {
      mode = .system
    }
    systemScheme = .light
    increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    refreshSystem()
    observe()
  }

  var effective: ColorScheme {
    switch mode.effective(system: systemScheme == .dark ? .dark : .light) {
    case .light:
      .light
    case .dark:
      .dark
    }
  }

  func toggleManual() {
    mode = mode.toggled(from: effective == .dark ? .dark : .light)
  }

  func appearance() -> NSAppearance? {
    switch mode {
    case .system:
      nil
    case .light:
      NSAppearance(named: .aqua)
    case .dark:
      NSAppearance(named: .darkAqua)
    }
  }

  func refresh() {
    refreshSystem()
    increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
  }

  private func observe() {
    let center = DistributedNotificationCenter.default()
    observers.append(
      center.addObserver(
        forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.refreshSystem()
        }
      }
    )
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
      }
    )
  }

  private func refreshSystem() {
    let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    systemScheme = match == .darkAqua ? .dark : .light
  }
}
