import SwiftUI

@MainActor
@Observable
final class PanelModel {
  enum Page: Int, CaseIterable {
    case clipboard
    case tools
    case document
    case capture
    case settings
  }

  var page: Page = .clipboard
  var pinned = false
  var enlarged = false
  var toast = ""

  var showsEnlarge: Bool {
    page == .tools || page == .document
  }
}
