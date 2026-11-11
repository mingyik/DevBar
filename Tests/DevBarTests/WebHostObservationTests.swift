import AppKit
import Observation
import Synchronization
import Testing

@testable import DevBar

@MainActor @Test func webViewReplacementNotifiesObservation() async {
  _ = NSApplication.shared
  let theme = ThemeManager(defaults: UserDefaults(suiteName: "local.devbar.test.observation")!)
  let host = WebHost(theme: theme)
  let changed = Mutex(false)
  withObservationTracking {
    _ = host.webView
    _ = host.generation
  } onChange: {
    changed.withLock { $0 = true }
  }
  for _ in 0..<100 {
    if changed.withLock({ $0 }) { break }
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(host.generation > 0)
  #expect(changed.withLock { $0 })
}
