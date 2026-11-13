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
}

@MainActor @Test func fourPagesCycleInOrderAndFirstOpenUsesFirstEnabledPage() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.fivepages.\(UUID())")!
  defaults.set("qr", forKey: "defaultPage")
  let model = PanelModel(defaults: defaults)
  model.prepareToOpen()
  #expect(model.page == .clipboard)
  for expected in [PanelModel.Page.json, .qr, .doc, .clipboard] {
    model.cyclePage()
    #expect(model.page == expected)
  }
  model.page = .json
  #expect(model.showsEnlarge)
  model.page = .doc
  #expect(model.showsEnlarge)
  model.page = .qr
  #expect(!model.showsEnlarge)
}

@MainActor @Test func reopeningAfterSettingsReturnsToRememberedContentPage() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.reopen.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  model.prepareToOpen()
  model.page = .json
  model.page = .settings
  model.prepareToOpen()
  #expect(model.page == .json)
}

@MainActor @Test func pageSizesKeepEnlargementOnlyWithinSession() {
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
  model.page = .json
  #expect(model.enlarged)
  defaults.set(true, forKey: "enlarged.json")
  defaults.set(true, forKey: "enlarged.doc")
  let restored = PanelModel(defaults: defaults)
  restored.page = .json
  #expect(!restored.enlarged)
  restored.page = .doc
  #expect(!restored.enlarged)
}

@MainActor @Test func removedEncodeMemoryMigratesToJSONAndFourPageCycle() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.r8.\(UUID())")!
  defaults.set("encode", forKey: "lastContentPage")
  let model = PanelModel(defaults: defaults)
  #expect(model.page == .json)
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

@MainActor @Test func pageCycleSkipsDisabledAndPreservesDirectShortcutAccess() {
  let defaults = UserDefaults(suiteName: "devbar.cycle.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  model.setCycleParticipation(.json, enabled: false)
  model.cyclePage()
  #expect(model.page == .qr)
  model.page = .json  // Dedicated shortcuts set the target directly.
  #expect(model.page == .json)
  model.cyclePage()
  #expect(model.page == .qr)
  model.page = .json
  model.prepareToOpen()
  #expect(model.page == .clipboard)
  #expect(!PanelModel(defaults: defaults).participatesInCycle(.json))
}

@MainActor @Test func pageCycleAlwaysRetainsOneEnabledPageAndRepairsEmptyPreferences() {
  let defaults = UserDefaults(suiteName: "devbar.cycle.single.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  for page in [PanelModel.Page.json, .qr, .doc, .clipboard] {
    model.setCycleParticipation(page, enabled: false)
  }
  #expect(model.cyclingPages == [.clipboard])
  #expect(!model.canChangeCycleParticipation(.clipboard))
  model.cyclePage()
  #expect(model.page == .clipboard)
  model.setCycleParticipation(.doc, enabled: true)
  #expect(model.cyclingPages == [.clipboard, .doc])
  defaults.set([], forKey: "cyclingPages")
  #expect(PanelModel(defaults: defaults).cyclingPages == [.clipboard])
}

@MainActor @Test func commandRCyclesPagesWhileShiftRAndCommandPDoNot() throws {
  let panel = DevBarPanel()
  var calls = 0
  panel.onCyclePage = { _ in calls += 1 }
  let shiftR = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
      windowNumber: 0, context: nil, characters: "R", charactersIgnoringModifiers: "r",
      isARepeat: false, keyCode: 15))
  _ = panel.performKeyEquivalent(with: shiftR)
  let oldP = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: 0, context: nil, characters: "p", charactersIgnoringModifiers: "p",
      isARepeat: false, keyCode: 35))
  #expect(!panel.performKeyEquivalent(with: oldP))
  #expect(calls == 0)
  let cmdR = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: 0, context: nil, characters: "r", charactersIgnoringModifiers: "r",
      isARepeat: false, keyCode: 15))
  #expect(panel.performKeyEquivalent(with: cmdR))
  #expect(calls == 1)
}

@MainActor @Test func commandEDispatchesModeToggleInsteadOfPageCycle() throws {
  let panel = DevBarPanel()
  var modeCalls = 0
  var cycleCalls = 0
  panel.onDocumentMode = {
    modeCalls += 1
    return true
  }
  panel.onCyclePage = { _ in cycleCalls += 1 }
  let shiftP = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
      windowNumber: 0, context: nil, characters: "P", charactersIgnoringModifiers: "p",
      isARepeat: false, keyCode: 35))
  #expect(!panel.performKeyEquivalent(with: shiftP))
  #expect(modeCalls == 0)

  let cmdE = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: 0, context: nil, characters: "e", charactersIgnoringModifiers: "e",
      isARepeat: false, keyCode: 14))
  #expect(panel.performKeyEquivalent(with: cmdE))
  #expect(modeCalls == 1)
  #expect(cycleCalls == 0)
}

@MainActor @Test func customPageOrderControlsStartupAndEnabledCycleAndPersists() {
  let defaults = UserDefaults(suiteName: "devbar.ordered.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  model.movePage(.doc, to: .clipboard)
  model.setCycleParticipation(.json, enabled: false)
  #expect(model.pageOrder == [.doc, .clipboard, .json, .qr])
  #expect(model.cyclingPages == [.doc, .clipboard, .qr])
  model.prepareToOpen()
  #expect(model.page == .doc)
  for next in [PanelModel.Page.clipboard, .qr, .doc] {
    model.cyclePage()
    #expect(model.page == next)
  }
  model.page = .qr
  let restored = PanelModel(defaults: defaults)
  restored.prepareToOpen()
  #expect(restored.page == .doc)
  #expect(restored.pageOrder == model.pageOrder)
  restored.setCycleParticipation(.json, enabled: true)
  #expect(restored.cyclingPages == restored.pageOrder)
}

@MainActor @Test func pageOrderMovesDownAndDirectOpeningDoesNotResetToStartup() {
  let defaults = UserDefaults(suiteName: "devbar.ordered.direct.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  model.movePage(.clipboard, to: .doc)
  #expect(model.pageOrder == [.json, .qr, .doc, .clipboard])
  model.prepareToOpen(page: .doc)
  model.prepareToOpen()
  #expect(model.page == .doc)
  model.setCycleParticipation(.json, enabled: false)
  model.page = .clipboard
  model.cyclePage()
  #expect(model.page == .qr)
}

@MainActor @Test func malformedPageOrderIsCompletedWithoutDuplicates() {
  let defaults = UserDefaults(suiteName: "devbar.ordered.repair.\(UUID())")!
  defaults.set(["doc", "doc", "settings", "unknown"], forKey: "pageOrder")
  let model = PanelModel(defaults: defaults)
  #expect(model.pageOrder == [.doc, .clipboard, .json, .qr])
  #expect(model.cyclingPages == model.pageOrder)
}

@MainActor @Test func commandETogglesBothDocAndQRPagesAndSkipsJsonTree() async throws {
  #expect(PanelController.supportsModeToggle(.doc))
  #expect(PanelController.supportsModeToggle(.qr))
  #expect(!PanelController.supportsModeToggle(.json))
  #expect(!PanelController.supportsModeToggle(.clipboard))
  #expect(!PanelController.supportsModeToggle(.settings))

  _ = NSApplication.shared
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let webDist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Web/dist")
  let host = WebHost(
    theme: ThemeManager(defaults: UserDefaults(suiteName: "devbar.mode.\(UUID())")!),
    webRoot: webDist, store: ScreenStateStore(directory: root, inMemory: true))
  host.setPanelVisible(true)

  for _ in 0..<200 {
    if (try? await host.webView.evaluateJavaScript("!!window.__devbar")) as? Bool == true { break }
    try? await Task.sleep(for: .milliseconds(50))
  }
  host.showScreen("qr")
  host.importFile(text: "DevBar QR", name: "qr.txt", document: false)
  for _ in 0..<100 {
    if (try? await host.webView.evaluateJavaScript(
      "document.querySelector('#qr .cm-content')?.cmTile?.root?.view?.state.doc.toString() === 'DevBar QR'"
    )) as? Bool == true {
      break
    }
    try? await Task.sleep(for: .milliseconds(50))
  }
  host.toggleDocumentMode()
  var qrPreviewed = false
  for _ in 0..<100 {
    if (try? await host.webView.evaluateJavaScript(
      "document.querySelector('#qr .preview')?.hidden === false"
    )) as? Bool == true {
      qrPreviewed = true
      break
    }
    try? await Task.sleep(for: .milliseconds(50))
  }
  #expect(qrPreviewed)

  host.toggleDocumentMode()
  var qrReturnedToEdit = false
  for _ in 0..<100 {
    if (try? await host.webView.evaluateJavaScript(
      "document.querySelector('#qr .preview')?.hidden === true"
    )) as? Bool == true {
      qrReturnedToEdit = true
      break
    }
    try? await Task.sleep(for: .milliseconds(50))
  }
  #expect(qrReturnedToEdit)
}
