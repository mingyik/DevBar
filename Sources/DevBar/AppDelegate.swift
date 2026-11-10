import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?

  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
      app.run()
    }
  }

  func applicationDidFinishLaunching(_: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.action = nil
      button.target = nil
      let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
      let symbol = NSImage(
        systemSymbolName: "square.stack",
        accessibilityDescription: Strings.statusItemAccessibilityLabel
      )
      if let image = symbol?.withSymbolConfiguration(configuration) {
        image.isTemplate = true
        button.image = image
      } else {
        button.title = Strings.statusItemTitle
      }
    }
    statusItem = item
  }
}
