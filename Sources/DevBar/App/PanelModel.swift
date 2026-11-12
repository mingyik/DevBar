import SwiftUI

@MainActor @Observable
final class PanelModel {
  enum Page: String, CaseIterable {
    case clipboard, json, qr, doc, settings
    static let contentPages: [Self] = [.clipboard, .json, .qr, .doc]
  }

  private let defaults: UserDefaults
  private(set) var cyclingPages: [Page]
  func participatesInCycle(_ page: Page) -> Bool { cyclingPages.contains(page) }
  func canChangeCycleParticipation(_ page: Page) -> Bool {
    !participatesInCycle(page) || cyclingPages.count > 1
  }
  func setCycleParticipation(_ page: Page, enabled: Bool) {
    guard Page.contentPages.contains(page) else { return }
    guard enabled || canChangeCycleParticipation(page) else { return }
    cyclingPages = Page.contentPages.filter { candidate in
      candidate == page ? enabled : cyclingPages.contains(candidate)
    }
    defaults.set(cyclingPages.map(\.rawValue), forKey: "cyclingPages")
    if !enabled, defaultPage == page.rawValue { defaultPage = "last" }
  }
  var page: Page {
    didSet {
      guard oldValue != page else { return }
      if page != .settings { defaults.set(page.rawValue, forKey: "lastContentPage") }
      onPageChange?()
    }
  }
  @ObservationIgnored var onPageChange: (() -> Void)?
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
    if dropActive { return CGSize(width: 400, height: 144) }
    return switch page {
    case .clipboard: CGSize(width: 380, height: 520)
    case .json, .doc: enlarged ? CGSize(width: 640, height: 720) : CGSize(width: 480, height: 600)
    case .qr: CGSize(width: 360, height: 480)
    case .settings: CGSize(width: 420, height: 560)
    }
  }
  var sizePreferences: (dropActive: Bool, jsonEnlarged: Bool, docEnlarged: Bool) {
    (dropActive, jsonEnlarged, docEnlarged)
  }
  var dropActive = false
  var dropDocument = false
  @ObservationIgnored var fileDrop: FileDropCoordinator?
  var toast = ""
  #if DEBUG
    var showsWebViewForSelfCheck =
      CommandLine.arguments.contains("--devbar-selfcheck")
      || CommandLine.arguments.contains("--devbar-manual-editor")
  #endif

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let saved = defaults.stringArray(forKey: "cyclingPages") {
      let selected = Page.contentPages.filter { saved.contains($0.rawValue) }
      cyclingPages = selected.isEmpty ? [.clipboard] : selected
    } else {
      cyclingPages = Page.contentPages
    }
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
  }

  func enterSettings() {
    if page != .settings { settingsOrigin = page }
    settingsGroup = settingsOrigin == .clipboard ? "clipboard" : "general"
    page = .settings
  }

  func leaveSettings() { page = settingsOrigin }

  func prepareToOpen() {
    if let fixed = Page(rawValue: defaultPage), cyclingPages.contains(fixed) {
      page = fixed
    } else if page == .settings {
      let remembered = Page(rawValue: defaults.string(forKey: "lastContentPage") ?? "")
      page = remembered.flatMap { cyclingPages.contains($0) ? $0 : nil } ?? cyclingPages[0]
    } else if !cyclingPages.contains(page) {
      page = cyclingPages[0]
    }
  }

  func cyclePage(backwards: Bool = false) {
    let remembered = Page(rawValue: defaults.string(forKey: "lastContentPage") ?? "") ?? .clipboard
    let origin = page == .settings ? remembered : page
    let all = Page.contentPages
    let current = all.firstIndex(of: origin) ?? 0
    for distance in 1...all.count {
      let offset = backwards ? all.count - distance : distance
      let candidate = all[(current + offset) % all.count]
      if cyclingPages.contains(candidate) {
        page = candidate
        return
      }
    }
  }

  var showsEnlarge: Bool { page == .json || page == .doc }
}
