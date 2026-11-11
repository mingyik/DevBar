import SwiftUI

@MainActor
@Observable
final class PanelModel {
  enum Page: Int, CaseIterable {
    case clipboard, tools, document, settings
    static let contentPages: [Self] = [.clipboard, .tools, .document]
  }

  private let defaults: UserDefaults
  var page: Page {
    didSet {
      if page != .settings { defaults.set(page.rawValue, forKey: "lastContentPage") }
    }
  }
  var pinned = false
  var enlarged = false
  var toast = ""
  var recordSystemAudio: Bool {
    didSet { defaults.set(recordSystemAudio, forKey: "recordSystemAudio") }
  }
  var recordMicrophone: Bool {
    didSet { defaults.set(recordMicrophone, forKey: "recordMicrophone") }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = Page(rawValue: defaults.integer(forKey: "lastContentPage")) ?? .clipboard
    page = stored == .settings ? .clipboard : stored
    recordSystemAudio = defaults.bool(forKey: "recordSystemAudio")
    recordMicrophone = defaults.bool(forKey: "recordMicrophone")
  }

  func cyclePage(backwards: Bool = false) {
    let remembered = Page(rawValue: defaults.integer(forKey: "lastContentPage")) ?? .clipboard
    let current = Page.contentPages.firstIndex(of: page == .settings ? remembered : page) ?? 0
    page = Page.contentPages[(current + (backwards ? 2 : 1)) % 3]
  }

  var showsEnlarge: Bool { page == .tools || page == .document }
}
