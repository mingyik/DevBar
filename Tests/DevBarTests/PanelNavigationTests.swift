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

@MainActor @Test func pageSizesUseLargeJSONAndMarkdownDefaults() {
  let defaults = UserDefaults(suiteName: "local.devbar.test.sizes.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  #expect(model.panelSize == CGSize(width: 380, height: 520))
  model.page = .json
  #expect(model.panelSize == CGSize(width: 640, height: 720))
  model.enlarged = true
  #expect(model.panelSize == CGSize(width: 640, height: 720))
  model.page = .doc
  #expect(model.panelSize == CGSize(width: 640, height: 720))
  model.page = .qr
  #expect(model.panelSize == CGSize(width: 360, height: 480))
  model.page = .json
  #expect(model.enlarged)
  defaults.set(true, forKey: "enlarged.json")
  defaults.set(true, forKey: "enlarged.doc")
  let restored = PanelModel(defaults: defaults)
  restored.page = .json
  #expect(restored.enlarged)
  restored.page = .doc
  #expect(restored.enlarged)
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
  #expect(model.settingsGroup == "general")
  let opening = model.settingsOpenGeneration
  model.enterSettings()
  #expect(model.settingsOpenGeneration == opening + 1)
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
  #expect(model.panelSize == CGSize(width: 360, height: 96))
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
  #expect(panel.performKeyEquivalent(with: shiftP))
  #expect(modeCalls == 1)

  let cmdE = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: 0, context: nil, characters: "e", charactersIgnoringModifiers: "e",
      isARepeat: false, keyCode: 14))
  #expect(panel.performKeyEquivalent(with: cmdE))
  #expect(modeCalls == 2)
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

@MainActor @Test func closeShortcutsOnlyReachTheVisibleKeyPanelAndGlobalRDoesNotCycleTwice()
  throws
{
  _ = NSApplication.shared
  let panel = DevBarPanel()
  var closes = 0
  var cycles = 0
  panel.onEscape = {
    closes += 1
    panel.orderOut(nil)
  }
  panel.onCyclePage = { _ in cycles += 1 }
  panel.globalCycleOwnsR = { true }
  func keyEvent(_ key: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws
    -> NSEvent
  {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: key,
        charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
  }
  let commandW = try keyEvent("w", code: 13, modifiers: .command)
  let escape = try keyEvent("\u{1b}", code: 53)
  #expect(!panel.performKeyEquivalent(with: commandW))
  #expect(!panel.performKeyEquivalent(with: escape))
  panel.makeKeyAndOrderFront(nil)
  defer { panel.orderOut(nil) }
  #expect(panel.performKeyEquivalent(with: try keyEvent("r", code: 15, modifiers: .command)))
  #expect(cycles == 0)
  #expect(panel.performKeyEquivalent(with: commandW))
  #expect(!panel.isVisible)
  #expect(!panel.performKeyEquivalent(with: escape))
  panel.makeKeyAndOrderFront(nil)
  #expect(panel.performKeyEquivalent(with: escape))
  #expect(!panel.isVisible)
  #expect(closes == 2)
}

@MainActor @Test func markdownSingleWindowSplitLifecycleAndPersistence() async throws {
  _ = NSApplication.shared
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let webDist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Web/dist")
  let theme = ThemeManager(defaults: UserDefaults(suiteName: "devbar.docsplit.\(UUID())")!)
  let host = WebHost(
    theme: theme, webRoot: webDist, store: ScreenStateStore(directory: root, inMemory: true))
  host.webView.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
  let window = NSWindow(
    contentRect: host.webView.frame, styleMask: .borderless,
    backing: .buffered, defer: false)
  window.contentView = host.webView
  window.orderFrontRegardless()
  defer { window.orderOut(nil) }
  host.setPanelVisible(true)

  for _ in 0..<200 {
    if (try? await host.webView.evaluateJavaScript("!!window.__devbar")) as? Bool == true { break }
    try? await Task.sleep(for: .milliseconds(50))
  }
  host.showScreen("doc")
  host.importFile(text: "# Initial", name: "note.md", document: true)
  for _ in 0..<100 {
    if await host.documentText() == "# Initial" { break }
    try? await Task.sleep(for: .milliseconds(50))
  }

  // 1. Edit -> Preview -> Split -> Edit preserves text, visibility, and equal pane widths.
  _ = try await host.webView.evaluateJavaScript(
    """
    (() => {
      const view = document.querySelector('#doc .cm-content')?.cmTile?.root?.view;
      if (!view) return false;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: '# Edited' }, userEvent: 'input.type' });
      return true;
    })()
    """)
  host.cycleDocumentMode()  // source -> preview
  for _ in 0..<100 {
    if (try? await host.webView.evaluateJavaScript(
      "document.querySelector('#doc .source')?.hidden === true && document.querySelector('#doc .preview')?.hidden === false"
    )) as? Bool == true {
      break
    }
    try? await Task.sleep(for: .milliseconds(50))
  }
  #expect(
    (try? await host.webView.evaluateJavaScript(
      "document.querySelector('#doc .page-content')?.classList.contains('split') === false"
    )) as? Bool == true)

  host.cycleDocumentMode()  // preview -> split
  var splitReady = false
  for _ in 0..<100 {
    if (try? await host.webView.evaluateJavaScript(
      """
      (() => {
        const content = document.querySelector('#doc .page-content');
        const src = document.querySelector('#doc .source');
        const prv = document.querySelector('#doc .preview');
        return !!content?.classList.contains('split') && !src?.hidden && !prv?.hidden
          && (prv?.textContent?.includes('Edited') ?? false);
      })()
      """
    )) as? Bool == true {
      splitReady = true
      break
    }
    try? await Task.sleep(for: .milliseconds(50))
  }
  #expect(splitReady)
  var equalWidth = false
  for _ in 0..<40 {
    equalWidth =
      (try? await host.webView.evaluateJavaScript(
        """
        (() => {
          const s = document.querySelector('#doc .source').getBoundingClientRect().width;
          const p = document.querySelector('#doc .preview').getBoundingClientRect().width;
          return s > 100 && p > 100 && Math.abs(s - p) <= 2;
        })()
        """)) as? Bool == true
    if equalWidth { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  let widths = try await host.webView.evaluateJavaScript(
    """
    ['.source','.preview'].map(s => { const e = document.querySelector('#doc '+s); const r=e.getBoundingClientRect(); const c=getComputedStyle(e); return [r.width,c.left,c.right,c.padding,c.transition]; })
    """)
  #expect(equalWidth, "Widths: \(String(describing: widths))")

  host.cycleDocumentMode()  // split -> source
  for _ in 0..<100 {
    if (try? await host.webView.evaluateJavaScript(
      "document.querySelector('#doc .preview')?.hidden === true"
    )) as? Bool == true {
      break
    }
    try? await Task.sleep(for: .milliseconds(50))
  }
  #expect(await host.documentText() == "# Edited")

  // Scroll sync in split mode before memory release.
  let longDoc = (1...80).map { "Line \($0)\n\nParagraph \($0) content." }.joined(separator: "\n\n")
  host.importFile(text: longDoc, name: "long.md", document: true)
  host.setDocumentDisplay("split")
  for _ in 0..<100 {
    if (try? await host.webView.evaluateJavaScript(
      """
      (() => {
        const s = document.querySelector('#doc .cm-scroller');
        const p = document.querySelector('#doc .preview');
        return !!s && !!p && s.scrollHeight > s.clientHeight && p.scrollHeight > p.clientHeight;
      })()
      """
    )) as? Bool == true {
      break
    }
    try? await Task.sleep(for: .milliseconds(50))
  }
  _ = try await host.webView.evaluateJavaScript(
    """
    (() => {
      const s = document.querySelector('#doc .cm-scroller');
      s.scrollTop = Math.round((s.scrollHeight - s.clientHeight) * 0.5);
      s.dispatchEvent(new Event('scroll'));
      return true;
    })()
    """)
  try? await Task.sleep(for: .milliseconds(100))
  let syncedPreview =
    try await host.webView.evaluateJavaScript(
      """
      (() => {
        const s = document.querySelector('#doc .cm-scroller');
        const p = document.querySelector('#doc .preview');
        return [s.scrollTop, s.scrollHeight, s.clientHeight, p.scrollTop, p.scrollHeight, p.clientHeight];
      })()
      """) as? [Double]
  let metrics = try #require(syncedPreview)
  let ratio = metrics[3] / max(1, metrics[4] - metrics[5])
  #expect(ratio > 0.4 && ratio < 0.6, "metrics=\(metrics)")

  // Restore original short doc for subsequent save/restore checks.
  host.importFile(text: "# Edited", name: "note.md", document: true)
  for _ in 0..<100 {
    if await host.documentText() == "# Edited" { break }
    try? await Task.sleep(for: .milliseconds(50))
  }

  // 3 & 4. Rapid typing + typing during in-flight save does not overwrite newer text.
  host.setDocumentDisplay("split")
  for _ in 0..<100 {
    if (try? await host.webView.evaluateJavaScript(
      "document.querySelector('#doc .page-content')?.classList.contains('split') === true"
    )) as? Bool == true {
      break
    }
    try? await Task.sleep(for: .milliseconds(50))
  }
  var saveContinuation: CheckedContinuation<String, Never>?
  var savedPayloadText: String?
  host.saveDocument = { text, _ in
    savedPayloadText = text
    return await withCheckedContinuation { continuation in
      saveContinuation = continuation
    }
  }
  _ = try await host.webView.evaluateJavaScript(
    """
    (() => {
      const view = document.querySelector('#doc .cm-content')?.cmTile?.root?.view;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: '# Rapid' }, userEvent: 'input.type' });
      document.querySelector('#doc .icon-save').click();
      return true;
    })()
    """)
  for _ in 0..<100 {
    if saveContinuation != nil { break }
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(savedPayloadText == "# Rapid")
  _ = try await host.webView.evaluateJavaScript(
    """
    (() => {
      const view = document.querySelector('#doc .cm-content')?.cmTile?.root?.view;
      view.dispatch({ changes: { from: view.state.doc.length, to: view.state.doc.length, insert: ' + during-save' }, userEvent: 'input.type' });
      return true;
    })()
    """)
  saveContinuation?.resume(
    returning: ##"{"status":"saved","fileName":"note.md","documentId":"doc-1","text":"# Rapid"}"##)
  for _ in 0..<100 {
    if (try? await host.webView.evaluateJavaScript(
      "document.querySelector('#doc .icon-save')?.disabled === false"
    )) as? Bool == true {
      break
    }
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(await host.documentText() == "# Rapid + during-save")
  #expect((await host.documentStatus())?["dirty"] as? Bool == true)

  // 5. Resize, release memory, and restore keeps split mode and preview content.
  host.setPanelVisible(false)
  await host.flushHiddenMemory()
  host.setPanelVisible(true)
  host.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
  var restoredSplit = false
  for _ in 0..<200 {
    if (try? await host.webView.evaluateJavaScript(
      """
      (() => {
        const content = document.querySelector('#doc .page-content');
        const prv = document.querySelector('#doc .preview');
        return !!content?.classList.contains('split') && !prv?.hidden
          && (prv?.textContent?.includes('during-save') ?? false);
      })()
      """
    )) as? Bool == true {
      restoredSplit = true
      break
    }
    try? await Task.sleep(for: .milliseconds(50))
  }
  #expect(restoredSplit)

  // 6. Export in split mode preserves split mode.
  _ = try await host.webView.evaluateJavaScript(
    "document.querySelector('#doc .icon-exportImage')?.click(); true")
  try? await Task.sleep(for: .milliseconds(100))
  #expect(
    (try? await host.webView.evaluateJavaScript(
      "document.querySelector('#doc .page-content')?.classList.contains('split') === true"
    )) as? Bool == true)
}

@MainActor @Test func singleWindowHostsSidebarSplitAndNeverSpawnsAuxiliaryPanels() async throws {
  _ = NSApplication.shared
  let webRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Web/dist")
  let defaults = UserDefaults(suiteName: "devbar.singlewin.\(UUID())")!
  let controller = PanelController(theme: ThemeManager(defaults: defaults), webRoot: webRoot)
  controller.model.prepareToOpen(page: .doc)
  controller.show(anchor: nil, activateApplication: false)
  defer { controller.dismiss() }
  for _ in 0..<100 {
    if (try? await controller.webHost.webView.evaluateJavaScript("!!window.__devbar")) as? Bool
      == true
    {
      break
    }
    try await Task.sleep(for: .milliseconds(50))
  }
  let webView = controller.webHost.webView
  controller.webHost.importFile(text: "# Single window", name: "note.md", document: true)
  controller.webHost.setDocumentDisplay("split")
  for _ in 0..<100 {
    if controller.model.documentSplit { break }
    try await Task.sleep(for: .milliseconds(50))
  }
  #expect(controller.model.documentSplit)
  #expect(controller.model.documentDisplay == "split")
  for _ in 0..<2 {
    controller.model.onToggleDocumentSidebar?()
    for _ in 0..<15 {
      try await Task.sleep(for: .milliseconds(20))
      let container = try #require(webView.superview)
      #expect(abs(webView.frame.width - container.bounds.width) < 1)
      #expect(abs(webView.frame.height - container.bounds.height) < 1)
      let content = try #require(controller.panel.contentView)
      let rect = container.convert(container.bounds, to: content)
      #expect(abs(rect.maxX - (content.bounds.maxX - 10)) < 1)
    }
    #expect(controller.webHost.webView === webView)
    #expect(webView.window === controller.panel)
  }
  #expect(!controller.model.documentSidebarVisible)
  let controls = try await webView.evaluateJavaScript(
    """
    (() => {
      const content = document.querySelector('#doc .page-content');
      const previewActions = content.querySelector('.doc-preview-actions');
      const editorActions = content.querySelector('.doc-editing-actions');
      const toolbar = content.querySelector('.page-toolbar');
      const save = content.querySelector('.icon-save');
      const clear = content.querySelector('.icon-clear');
      const image = content.querySelector('.icon-exportImage');
      return content.classList.contains('split') && previewActions.contains(save)
        && previewActions.contains(image) && editorActions.contains(clear)
        && getComputedStyle(toolbar).display === 'none'
        && getComputedStyle(content.querySelector('.file-label')).display === 'none'
        && getComputedStyle(image).display === 'flex'
        && getComputedStyle(image).justifyContent === 'center'
        && getComputedStyle(content.querySelector('.preview')).bottom === '0px';
    })()
    """)
  #expect(controls as? Bool == true)
  let auxiliary = NSApp.windows.filter {
    let name = NSStringFromClass(type(of: $0))
    return name.contains("DocumentSidebarPanel") || name.contains("DocumentEditorPanel")
  }
  #expect(auxiliary.isEmpty)
}

@MainActor @Test func captureMarkdownMultiPaneScreenshotsIfRequested() async throws {
  guard let outDir = ProcessInfo.processInfo.environment["DEVBAR_DOC_REVIEW_DIR"], !outDir.isEmpty
  else { return }
  _ = NSApplication.shared
  let webDist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Web/dist")
  let sample = """
    # DevBar Markdown

    单窗口多面板布局验证：

    - 左侧目录栏
    - 中间编辑器
    - 右侧实时预览

    ```swift
    let layout = PanelLayout.documentPanelSize(
      enlarged: false, split: true, sidebar: true, visibleFrame: frame)
    ```
    """
  let dirURL = URL(fileURLWithPath: outDir)
  try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

  for themeName in ["light", "dark"] {
    let defaults = UserDefaults(suiteName: "devbar.docreview.\(themeName).\(UUID())")!
    let theme = ThemeManager(defaults: defaults)
    theme.mode = themeName == "dark" ? .dark : .light
    let controller = PanelController(theme: theme, webRoot: webDist)
    controller.model.autoImport = false
    controller.model.page = .doc
    controller.show(anchor: nil, activateApplication: false)

    for _ in 0..<200 {
      if (try? await controller.webHost.webView.evaluateJavaScript("!!window.__devbar")) as? Bool
        == true
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    controller.webHost.importFile(text: sample, name: "README.md", document: true)
    try? await Task.sleep(for: .milliseconds(400))

    func capture(_ name: String) async throws {
      try? await Task.sleep(for: .milliseconds(400))
      _ = try? await controller.webHost.webView.evaluateJavaScript(
        "new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(true))))")
      controller.panel.displayIfNeeded()
      let path = dirURL.appending(path: "\(name).png").path
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l", "\(controller.panel.windowNumber)", path]
      try process.run()
      process.waitUntilExit()
    }

    try await capture("1pane-edit-\(themeName)")

    controller.model.onToggleDocumentSidebar?()
    try await capture("2pane-sidebar-\(themeName)")

    controller.model.onToggleDocumentSidebar?()
    controller.webHost.setDocumentDisplay("split")
    try await capture("2pane-split-\(themeName)")

    controller.model.onToggleDocumentSidebar?()
    try await capture("3pane-split-sidebar-\(themeName)")

    controller.dismiss()
  }
}
