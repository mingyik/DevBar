import SwiftUI

@MainActor @Observable
final class PanelModel {
  enum Page: String, CaseIterable {
    case clipboard, json, qr, doc, settings
    static let contentPages: [Self] = [.clipboard, .json, .qr, .doc]
  }

  private let defaults: UserDefaults
  var page: Page {
    didSet {
      if page != .settings { defaults.set(page.rawValue, forKey: "lastContentPage") }
    }
  }
  var defaultPage: String {
    didSet { defaults.set(defaultPage, forKey: "defaultPage") }
  }
  private(set) var settingsOrigin: Page = .clipboard
  private(set) var settingsGroup = "general"
  var autoImport: Bool { didSet { defaults.set(autoImport, forKey: "autoImport") } }
  var pinned = false
  private var jsonEnlarged: Bool {
    didSet { defaults.set(jsonEnlarged, forKey: "enlarged.json") }
  }
  private var docEnlarged: Bool {
    didSet { defaults.set(docEnlarged, forKey: "enlarged.doc") }
  }
  var enlarged: Bool {
    get { page == .json ? jsonEnlarged : page == .doc ? docEnlarged : false }
    set {
      if page == .json { jsonEnlarged = newValue } else if page == .doc { docEnlarged = newValue }
    }
  }
  var panelSize: CGSize {
    switch page {
    case .clipboard: CGSize(width: 380, height: 520)
    case .json, .doc: enlarged ? CGSize(width: 640, height: 720) : CGSize(width: 480, height: 600)
    case .qr: CGSize(width: 360, height: 480)
    case .settings: CGSize(width: 420, height: 560)
    }
  }
  var toast = ""
  var recordSystemAudio: Bool {
    didSet { defaults.set(recordSystemAudio, forKey: "recordSystemAudio") }
  }
  var recordMicrophone: Bool {
    didSet { defaults.set(recordMicrophone, forKey: "recordMicrophone") }
  }
  #if DEBUG
    var showsWebViewForSelfCheck =
      CommandLine.arguments.contains("--devbar-selfcheck")
      || CommandLine.arguments.contains("--devbar-manual-editor")
  #endif

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    autoImport = defaults.object(forKey: "autoImport") as? Bool ?? true
    let raw = defaults.string(forKey: "lastContentPage") ?? ""
    let stored: Page = raw == "encode" ? .json : Page(rawValue: raw) ?? .clipboard
    if raw == "encode" { defaults.set("json", forKey: "lastContentPage") }
    page = stored == .settings ? .clipboard : stored
    let oldPreferred = defaults.string(forKey: "defaultPage") ?? "last"
    let preferred = oldPreferred == "encode" ? "json" : oldPreferred
    if oldPreferred == "encode" { defaults.set("json", forKey: "defaultPage") }
    defaultPage =
      Page.contentPages.contains(where: { $0.rawValue == preferred }) ? preferred : "last"
    jsonEnlarged = defaults.bool(forKey: "enlarged.json")
    docEnlarged = defaults.bool(forKey: "enlarged.doc")
    recordSystemAudio = defaults.bool(forKey: "recordSystemAudio")
    recordMicrophone = defaults.bool(forKey: "recordMicrophone")
  }

  func enterSettings() {
    if page != .settings { settingsOrigin = page }
    settingsGroup = settingsOrigin == .clipboard ? "clipboard" : "general"
    page = .settings
  }

  func leaveSettings() { page = settingsOrigin }

  func prepareToOpen() {
    if let fixed = Page(rawValue: defaultPage), fixed != .settings {
      page = fixed
    } else if page == .settings {
      page = Page(rawValue: defaults.string(forKey: "lastContentPage") ?? "") ?? .clipboard
    }
  }

  func cyclePage(backwards: Bool = false) {
    let remembered = Page(rawValue: defaults.string(forKey: "lastContentPage") ?? "") ?? .clipboard
    let pages = Page.contentPages
    let current = pages.firstIndex(of: page == .settings ? remembered : page) ?? 0
    page = pages[(current + (backwards ? pages.count - 1 : 1)) % pages.count]
  }

  var showsEnlarge: Bool { page == .json || page == .doc }
}
