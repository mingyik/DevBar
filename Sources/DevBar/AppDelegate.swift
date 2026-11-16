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
  private var fileDrop: FileDropCoordinator?
  private var pendingOpenFiles: [URL] = []

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
    statusItem.onCaptureRegion = { [weak self] in self?.panel.capture.start(scrolling: false) }
    statusItem.onCaptureScroll = { [weak self] in self?.panel.capture.start(scrolling: true) }
    statusItem.onSettings = { [weak self] in
      self?.panel.showSettings(anchor: self?.statusItem.anchor)
    }
    statusItem.onAbout = { [weak self] in
      self?.panel.model.page = .settings
      self?.panel.show(anchor: self?.statusItem.anchor)
    }
    let fileDrop = FileDropCoordinator(panel: panel, status: statusItem)
    self.fileDrop = fileDrop
    if !pendingOpenFiles.isEmpty {
      let urls = pendingOpenFiles
      pendingOpenFiles.removeAll()
      panel.show(anchor: statusItem.anchor)
      fileDrop.receive(urls)
    }
    panel.model.fileDrop = fileDrop
    panel.webHost.acceptsFiles = { [weak self] in
      self?.panel.model.page == .json || self?.panel.model.page == .doc
    }
    panel.webHost.receivedFiles = { [weak fileDrop] urls in fileDrop?.receive(urls) }
    statusItem.installFileDrop(fileDrop)
    ShortcutActions.register(panel: panel, status: statusItem)
    terminalYield.start()
    #if DEBUG
      WebSelfCheck.runIfRequested(panel: panel)
      R7UICheck.runIfRequested(panel: panel)
      R8UICheck.runIfRequested(panel: panel)
      R9UICheck.runIfRequested(panel: panel)
      if CommandLine.arguments.contains("--devbar-manual-editor") {
        panel.model.page = .json
        panel.show(anchor: statusItem.anchor)
      }
    #endif
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    sender.reply(toOpenOrPrint: .success)
    let urls = filenames.map { URL(fileURLWithPath: $0) }
    guard let fileDrop else {
      pendingOpenFiles.append(contentsOf: urls)
      return
    }
    panel.show(anchor: statusItem.anchor)
    fileDrop.receive(urls)
  }
}
