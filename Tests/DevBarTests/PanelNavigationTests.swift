import AppKit
import Testing

@testable import DevBar

@MainActor @Test func pageCycleWrapsAndRestoresLastContentPage() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.navigation.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  #expect(model.page == .clipboard)
  model.cyclePage(backwards: true)
  #expect(model.page == .doc)
  model.cyclePage()
  #expect(model.page == .clipboard)
  model.page = .json
  model.page = .settings
  #expect(PanelModel(defaults: defaults).page == .json)
  model.cyclePage()
  #expect(model.page == .encode)
  #expect(!model.recordSystemAudio && !model.recordMicrophone)
}

@MainActor @Test func fivePagesCycleInOrderAndDefaultOnlyAppliesToOrdinaryOpen() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.fivepages.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  for expected in [PanelModel.Page.json, .encode, .qr, .doc, .clipboard] {
    model.cyclePage()
    #expect(model.page == expected)
  }
  model.defaultPage = "qr"
  model.prepareToOpen()
  #expect(model.page == .qr)
  #expect(PanelModel(defaults: defaults).defaultPage == "qr")
  model.page = .json
  #expect(model.showsEnlarge)
  model.page = .doc
  #expect(model.showsEnlarge)
  model.page = .encode
  #expect(!model.showsEnlarge)
  model.defaultPage = "last"
  model.prepareToOpen()
  #expect(model.page == .encode)
}

@MainActor @Test func reopeningAfterSettingsReturnsToRememberedContentPage() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.reopen.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  model.page = .json
  model.page = .settings
  model.prepareToOpen()
  #expect(model.page == .json)
}
