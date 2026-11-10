import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let theme = ThemeManager()
  private let statusItem = StatusItemController()
  private let panel: PanelController
  private let terminalYield = TerminalYield()

  override init() {
    panel = PanelController(theme: theme)
    super.init()
  }

  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
      app.run()
    }
  }

  func applicationDidFinishLaunching(_: Notification) {
    theme.refresh()
    statusItem.onPrimaryClick = { [weak self] in
      self?.panel.toggle(anchor: self?.statusItem.anchor)
    }
    statusItem.onSettings = { [weak self] in
      self?.panel.showSettings(anchor: self?.statusItem.anchor)
    }
    statusItem.onAbout = { [weak self] in
      self?.panel.model.page = .settings
      self?.panel.show(anchor: self?.statusItem.anchor)
    }
    ShortcutActions.register(panel: panel, status: statusItem)
    terminalYield.start()
  }
}
