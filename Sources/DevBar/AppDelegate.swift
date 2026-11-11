import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  #if DEBUG
    private let theme = ThemeManager(defaults: SelfCheckEnvironment.defaults)
  #else
    private let theme = ThemeManager()
  #endif
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
    #if DEBUG
      WebSelfCheck.runIfRequested(panel: panel)
      if CommandLine.arguments.contains("--devbar-manual-editor") {
        panel.model.page = .json
        panel.show(anchor: statusItem.anchor)
      }
    #endif
  }
}
