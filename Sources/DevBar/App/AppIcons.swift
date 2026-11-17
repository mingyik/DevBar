import AppKit

@MainActor enum AppIcons {
  static var menuBar: NSImage {
    let installed = Bundle.main.resourceURL?.appending(path: "DevBar_DevBar.bundle")
    let resources = installed.flatMap(Bundle.init(url:)) ?? Bundle.module
    let url = resources.url(
      forResource: "menubar", withExtension: "pdf",
      subdirectory: "Assets.xcassets/MenuBar.imageset")
    let image =
      url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(
        systemSymbolName: "square.stack",
        accessibilityDescription: Strings.statusItemAccessibilityLabel)
      ?? NSImage(size: NSSize(width: 18, height: 18))
    image.size = NSSize(width: 18, height: 18)
    image.isTemplate = true
    return image
  }

  static var documentEdit: NSImage {
    let installed = Bundle.main.resourceURL?.appending(path: "DevBar_DevBar.bundle")
    let resources = installed.flatMap(Bundle.init(url:)) ?? Bundle.module
    let url = resources.url(
      forResource: "edit", withExtension: "svg",
      subdirectory: "Assets.xcassets/DocumentEdit.imageset")
    let image =
      url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(size: NSSize(width: 24, height: 24))
    image.isTemplate = true
    return image
  }

  static var settings: NSImage {
    let installed = Bundle.main.resourceURL?.appending(path: "DevBar_DevBar.bundle")
    let resources = installed.flatMap(Bundle.init(url:)) ?? Bundle.module
    let url = resources.url(
      forResource: "settings", withExtension: "pdf",
      subdirectory: "Assets.xcassets/Settings.imageset")
    let image =
      url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(size: NSSize(width: 13, height: 13))
    image.isTemplate = true
    return image
  }
}
