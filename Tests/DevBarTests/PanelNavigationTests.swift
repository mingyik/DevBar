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
  #expect(model.page == .qr)
  #expect(!model.recordSystemAudio && !model.recordMicrophone)
}

@MainActor @Test func fourPagesCycleInOrderAndDefaultOnlyAppliesToOrdinaryOpen() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.fivepages.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  for expected in [PanelModel.Page.json, .qr, .doc, .clipboard] {
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
  model.page = .qr
  #expect(!model.showsEnlarge)
  model.defaultPage = "last"
  model.prepareToOpen()
  #expect(model.page == .qr)
}

@MainActor @Test func reopeningAfterSettingsReturnsToRememberedContentPage() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.reopen.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  model.page = .json
  model.page = .settings
  model.prepareToOpen()
  #expect(model.page == .json)
}

@MainActor @Test func pageSizesAndIndependentEnlargementPersist() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.sizes.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  #expect(model.panelSize == CGSize(width: 380, height: 520))
  model.page = .json
  #expect(model.panelSize == CGSize(width: 480, height: 600))
  model.enlarged = true
  #expect(model.panelSize == CGSize(width: 640, height: 720))
  model.page = .doc
  #expect(model.panelSize == CGSize(width: 480, height: 600))
  model.page = .qr
  #expect(model.panelSize == CGSize(width: 360, height: 480))
  let restored = PanelModel(defaults: defaults)
  restored.page = .json
  #expect(restored.enlarged)
  restored.page = .doc
  #expect(!restored.enlarged)
}

@MainActor @Test func removedEncodeMemoryMigratesToJSONAndFourPageCycle() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.r8.\(UUID())")!
  defaults.set("encode", forKey: "lastContentPage")
  defaults.set("encode", forKey: "defaultPage")
  let model = PanelModel(defaults: defaults)
  #expect(model.page == .json)
  #expect(model.defaultPage == "json")
  #expect(PanelModel.Page.contentPages.map(\.rawValue) == ["clipboard", "json", "qr", "doc"])
  model.cyclePage()
  #expect(model.page == .qr)
}

@MainActor @Test func settingsReturnsToOriginAndTargetsOneSharedGroup() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.r8.settings.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  model.enterSettings()
  #expect(model.settingsGroup == "clipboard")
  #expect(model.page == .settings)
  model.leaveSettings()
  #expect(model.page == .clipboard)
  model.page = .qr
  model.enterSettings()
  #expect(model.settingsGroup == "general")
  model.leaveSettings()
  #expect(model.page == .qr)
}

@MainActor @Test func iconDropUsesCompactSizeAndRestoresPageDimensions() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.drop-size.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  model.page = .json
  model.enlarged = true
  let before = model.panelSize
  model.dropActive = true
  #expect(model.panelSize == CGSize(width: 400, height: 144))
  #expect(model.page == .json && model.enlarged)
  model.dropActive = false
  #expect(model.panelSize == before)
}
