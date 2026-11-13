import AppKit
@preconcurrency import ApplicationServices
import DevBarCore

struct DirectPasteAuthorizationWait {
  enum Step { case wait, finished, fallback }
  var gracePeriod: Double
  private var sawSystemPrompt = false

  init(gracePeriod: Double) { self.gracePeriod = gracePeriod }

  mutating func next(trusted: Bool, systemPrompt: Bool, settingsActive: Bool, elapsed: Double)
    -> Step
  {
    if trusted { return .finished }
    if systemPrompt { sawSystemPrompt = true }
    if systemPrompt || settingsActive { return .wait }
    return sawSystemPrompt || elapsed >= gracePeriod ? .fallback : .wait
  }
}

/// AX permission requests have no presentation or dismissal callback. Observe only the
/// system permission agent's visible-window metadata; never read its UI or window titles.
@MainActor final class DirectPasteAuthorizationPrompt {
  private static let requestKey = "directPasteAccessibilityPromptRequested"
  private let defaults: UserDefaults
  private let beforeFallback: () -> Void
  private let didAuthorize: () -> Void
  private let openSettings: () -> Void
  private var task: Task<Void, Never>?
  private var isPresenting = false

  init(
    defaults: UserDefaults, beforeFallback: @escaping () -> Void,
    didAuthorize: @escaping () -> Void, openSettings: @escaping () -> Void
  ) {
    self.defaults = defaults
    self.beforeFallback = beforeFallback
    self.didAuthorize = didAuthorize
    self.openSettings = openSettings
  }

  func request() {
    guard !isPresenting else { return }
    if AXIsProcessTrusted() {
      didAuthorize()
      return
    }
    isPresenting = true
    let requestSystem = DirectPastePromptPolicy.shouldRequest(
      isTrusted: false, wasRequested: defaults.bool(forKey: Self.requestKey))
    if requestSystem {
      defaults.set(true, forKey: Self.requestKey)
      let options =
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
    }
    task = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isPresenting = false
        self.task = nil
      }
      let started = ContinuousClock.now
      var flow = DirectPasteAuthorizationWait(gracePeriod: requestSystem ? 2 : 0)
      while !Task.isCancelled {
        let duration = started.duration(to: .now).components
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        let step = flow.next(
          trusted: AXIsProcessTrusted(), systemPrompt: Self.systemPromptIsVisible(),
          settingsActive: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == "com.apple.systempreferences", elapsed: elapsed)
        switch step {
        case .finished:
          didAuthorize()
          return
        case .fallback:
          // Never paste automatically after a permission change: the user retries explicitly.
          beforeFallback()
          let alert = NSAlert()
          alert.messageText = Strings.directPastePermissionTitle
          alert.informativeText = Strings.directPastePermissionBody
          alert.addButton(withTitle: Strings.capturePermissionSettings)
          alert.addButton(withTitle: Strings.directPastePermissionLater).keyEquivalent = "\u{1b}"
          alert.window.level = .modalPanel
          alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
          let previousApplication = NSWorkspace.shared.frontmostApplication
          NSApp.activate()
          if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
          } else if NSApp.isActive {
            previousApplication?.activate()
          }
          return
        case .wait:
          do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
      }
    }
  }

  private static func systemPromptIsVisible() -> Bool {
    let agents = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.apple.accessibility.universalAccessAuthWarn")
    let pids = Set(agents.map(\.processIdentifier))
    guard !pids.isEmpty else { return false }
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return true }
    return windows.contains { window in
      guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
        let rectangle = window[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: rectangle as CFDictionary),
        bounds.width > 0, bounds.height > 0
      else {
        return false
      }
      return (window[kCGWindowAlpha as String] as? Double ?? 1) > 0
    }
  }
}
