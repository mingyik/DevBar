import AppKit

@MainActor
final class StatusItemController: NSObject {
  let item: NSStatusItem
  var onPrimaryClick: (() -> Void)?
  var onSettings: (() -> Void)?
  var onAbout: (() -> Void)?

  override init() {
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    guard let button = item.button else { return }
    button.target = self
    button.action = #selector(handleClick)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

  var anchor: CGRect? {
    guard let button = item.button, let window = button.window else { return nil }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  @objc private func handleClick() {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showMenu()
      return
    }
    onPrimaryClick?()
  }

  private func showMenu() {
    let menu = NSMenu()
    menu.addItem(item(Strings.settingsTitle, action: #selector(openSettings)))
    menu.addItem(item(Strings.aboutTitle, action: #selector(openAbout)))
    menu.addItem(.separator())
    menu.addItem(item(Strings.quit, action: #selector(quit)))
    item.menu = menu
    item.button?.performClick(nil)
    item.menu = nil
  }

  private func item(_ title: String, action: Selector) -> NSMenuItem {
    let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
    entry.target = self
    return entry
  }

  @objc private func openSettings() {
    onSettings?()
  }

  @objc private func openAbout() {
    onAbout?()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
