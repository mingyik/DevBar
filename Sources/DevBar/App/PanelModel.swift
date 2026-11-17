import DevBarCore
import SwiftUI

@MainActor @Observable
final class PanelModel {
  enum Page: String, CaseIterable {
    case clipboard, json, qr, doc, settings
    static let contentPages: [Self] = [.clipboard, .json, .qr, .doc]
  }

  private let defaults: UserDefaults
  private(set) var pageOrder: [Page]
  private var hasOpened = false
  private(set) var cyclingPages: [Page]
  func participatesInCycle(_ page: Page) -> Bool { cyclingPages.contains(page) }
  func canChangeCycleParticipation(_ page: Page) -> Bool {
    !participatesInCycle(page) || cyclingPages.count > 1
  }
  func setCycleParticipation(_ page: Page, enabled: Bool) {
    guard Page.contentPages.contains(page) else { return }
    guard enabled || canChangeCycleParticipation(page) else { return }
    cyclingPages = pageOrder.filter { candidate in
      candidate == page ? enabled : cyclingPages.contains(candidate)
    }
    defaults.set(cyclingPages.map(\.rawValue), forKey: "cyclingPages")
  }
  func movePage(_ source: Page, to target: Page) {
    guard source != target, let from = pageOrder.firstIndex(of: source),
      let destination = pageOrder.firstIndex(of: target)
    else { return }
    var order = pageOrder
    order.remove(at: from)
    order.insert(source, at: min(destination, order.count))
    pageOrder = order
    cyclingPages = order.filter { cyclingPages.contains($0) }
    defaults.set(order.map(\.rawValue), forKey: "pageOrder")
    defaults.set(cyclingPages.map(\.rawValue), forKey: "cyclingPages")
  }

  var page: Page {
    didSet {
      guard oldValue != page else { return }
      if page != .settings { defaults.set(page.rawValue, forKey: "lastContentPage") }
      onPageChange?()
    }
  }
  @ObservationIgnored var onPageChange: (() -> Void)?
  private(set) var settingsOrigin: Page = .clipboard
  static let autoImportKey = "autoImport.manual"
  private(set) var settingsGroup = "general"
  private(set) var settingsOpenGeneration = 0
  var autoImport: Bool { didSet { defaults.set(autoImport, forKey: Self.autoImportKey) } }
  var pinned = false
  private var jsonEnlarged = false
  private var docEnlarged = false
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
  var documentSidebarVisible = false
  var documentSplit = false
  var documentDisplay = "source"
  var documentSidebarWidth: CGFloat = PanelLayout.sidebarWidth
  @ObservationIgnored var fileDrop: FileDropCoordinator?
  @ObservationIgnored var onToggleDocumentSidebar: (() -> Void)?
  @ObservationIgnored var onOpenDocument: ((URL) -> Void)?
  @ObservationIgnored var onOpenDocumentDraft: ((String) -> Void)?
  @ObservationIgnored var onPickDocument: (() -> Void)?
  var toast = ""
  #if DEBUG
    var showsWebViewForSelfCheck =
      CommandLine.arguments.contains("--devbar-selfcheck")
      || CommandLine.arguments.contains("--devbar-manual-editor")
  #endif

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    var order: [Page] = []
    for raw in defaults.stringArray(forKey: "pageOrder") ?? [] {
      if let page = Page(rawValue: raw), Page.contentPages.contains(page), !order.contains(page) {
        order.append(page)
      }
    }
    order.append(contentsOf: Page.contentPages.filter { !order.contains($0) })
    pageOrder = order
    if let saved = defaults.stringArray(forKey: "cyclingPages") {
      let selected = order.filter { saved.contains($0.rawValue) }
      cyclingPages = selected.isEmpty ? [order[0]] : selected
    } else {
      cyclingPages = order
    }
    autoImport = defaults.object(forKey: Self.autoImportKey) as? Bool ?? false
    let raw = defaults.string(forKey: "lastContentPage") ?? ""
    let stored: Page = raw == "encode" ? .json : Page(rawValue: raw) ?? .clipboard
    if raw == "encode" { defaults.set("json", forKey: "lastContentPage") }
    page = stored == .settings ? .clipboard : stored
  }

  func enterSettings() {
    if page != .settings { settingsOrigin = page }
    settingsGroup = "general"
    settingsOpenGeneration += 1
    page = .settings
  }

  func leaveSettings() { page = settingsOrigin }

  func prepareToOpen(page requested: Page? = nil) {
    if let requested, Page.contentPages.contains(requested) {
      hasOpened = true
      page = requested
      return
    }
    if !hasOpened {
      hasOpened = true
      page = cyclingPages[0]
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
    let all = pageOrder
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
