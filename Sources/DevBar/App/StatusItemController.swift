import AppKit

@MainActor
final class StatusItemController: NSObject {
  let item: NSStatusItem
  var onPrimaryClick: (() -> Void)?
  var onSettings: (() -> Void)?
  var onAbout: (() -> Void)?
  var onCaptureRegion: (() -> Void)?
  var onCaptureScroll: (() -> Void)?

  override init() {
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    guard let button = item.button else { return }
    button.target = self
    button.action = #selector(handleClick)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    button.image = AppIcons.menuBar
    button.setAccessibilityLabel(Strings.statusItemAccessibilityLabel)
  }

  func installFileDrop(_ coordinator: FileDropCoordinator) {
    guard let button = item.button else { return }
    let target = StatusFileDropView(frame: button.bounds)
    target.autoresizingMask = [.width, .height]
    target.coordinator = coordinator
    target.onClick = { [weak self] in self?.handleClick() }
    button.addSubview(target)
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
    menu.autoenablesItems = false
    for (title, symbol, action) in [
      (Strings.shortcutCapture, "viewfinder", #selector(captureRegion)),
      (Strings.shortcutLong, "rectangle.stack", #selector(captureScroll)),
    ] {
      let entry = item(title, action: action)
      entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      menu.addItem(entry)
    }
    menu.addItem(.separator())
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
    if title == Strings.settingsTitle { entry.image = AppIcons.settings }
    entry.target = self
    return entry
  }

  @objc private func captureRegion() { onCaptureRegion?() }
  @objc private func captureScroll() { onCaptureScroll?() }

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
