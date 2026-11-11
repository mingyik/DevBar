import AppKit

@MainActor enum AppIcons {
  static var settings: NSImage {
    let url = Bundle.module.url(
      forResource: "settings", withExtension: "pdf",
      subdirectory: "Assets.xcassets/Settings.imageset")
    let image =
      url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(size: NSSize(width: 13, height: 13))
    image.isTemplate = true
    return image
  }
}
