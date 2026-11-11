import AppKit
import Testing

@testable import DevBar

@MainActor @Test func pageCycleWrapsAndRestoresLastContentPage() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.navigation.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  #expect(model.page == .clipboard)
  model.cyclePage(backwards: true)
  #expect(model.page == .document)
  model.cyclePage()
  #expect(model.page == .clipboard)
  model.page = .tools
  model.page = .settings
  #expect(PanelModel(defaults: defaults).page == .tools)
  model.cyclePage()
  #expect(model.page == .document)
  #expect(!model.recordSystemAudio && !model.recordMicrophone)
}
