import AppKit
import DevBarCore
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

@MainActor @Test func commandRDoesNotCycleTwiceAndCommandWClosesThePanel() throws {
  _ = NSApplication.shared
  let controller = PanelController(theme: ThemeManager())
  controller.show(anchor: nil)
  defer { controller.dismiss() }
  var cycles = 0
  let panel = controller.panel
  panel.onCyclePage = { _ in cycles += 1 }
  panel.globalCycleOwnsR = { true }
  let eventR = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: panel.windowNumber, context: nil, characters: "r",
      charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
  _ = panel.performKeyEquivalent(with: eventR)
  #expect(cycles == 0)
  #expect(panel.isVisible)
  let eventW = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: panel.windowNumber, context: nil, characters: "w",
      charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
  _ = panel.performKeyEquivalent(with: eventW)
  #expect(!panel.isVisible)
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
      return true;
    })()
    """)
  host.saveCurrentDocument()
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
    if (await host.documentStatus())?["documentId"] as? String == "doc-1" {
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
  host.exportDocumentImage()
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
  let visible = try #require(controller.panel.screen?.visibleFrame)
  var initialFrame = controller.panel.frame
  initialFrame.size.width = min(initialFrame.width, floor(visible.width * 0.6))
  func toolbarCornerOnScreen() async throws -> CGPoint {
    let result = try await webView.evaluateJavaScript(
      """
      (() => {
        const rect = document.querySelector('#doc .doc-floating-actions').getBoundingClientRect();
        return [rect.right, rect.bottom];
      })()
      """)
    let coordinates = try #require(result as? [Double])
    try #require(coordinates.count == 2)
    let webFrame = controller.panel.convertToScreen(webView.convert(webView.bounds, to: nil))
    return CGPoint(x: webFrame.minX + coordinates[0], y: webFrame.maxY - coordinates[1])
  }
  func clickModeButton(_ selector: String) async throws {
    _ = try await webView.evaluateJavaScript(
      "document.querySelector('#doc .doc-floating-actions .\(selector)').click()")
  }
  func waitForToolbarCornerStable() async throws -> CGPoint {
    var previous: CGPoint?
    for _ in 0..<100 {
      let current = try await toolbarCornerOnScreen()
      if let previous,
        abs(current.x - previous.x) < 0.5,
        abs(current.y - previous.y) < 0.5
      {
        return current
      }
      previous = current
      try await Task.sleep(for: .milliseconds(20))
    }
    return try await toolbarCornerOnScreen()
  }
  func waitForLayoutSettled() async throws {
    var previous = controller.panel.frame
    var stable = 0
    for _ in 0..<100 {
      try await Task.sleep(for: .milliseconds(20))
      let current = controller.panel.frame
      if current == previous {
        stable += 1
        if stable >= 2 { break }
      } else {
        stable = 0
        previous = current
      }
    }
    let container = try #require(webView.superview)
    for _ in 0..<100 {
      if abs(webView.frame.width - container.bounds.width) < 1,
        abs(webView.frame.height - container.bounds.height) < 1
      {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
  for originX in [visible.maxX - initialFrame.width, visible.minX] {
    initialFrame.origin.x = originX
    controller.panel.setFrame(initialFrame, display: true)
    try await Task.sleep(for: .milliseconds(100))
    let toolbarCorner = try await waitForToolbarCornerStable()
    for (button, mode) in [
      ("icon-split", "split"), ("icon-preview", "preview"), ("icon-preview", "source"),
    ] {
      try await clickModeButton(button)
      for _ in 0..<100 {
        if controller.model.documentDisplay == mode { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(controller.model.documentDisplay == mode)
      #expect(controller.model.documentSplit == (mode == "split"))
      try await waitForLayoutSettled()
      _ = try await waitForToolbarCornerStable()
      for _ in 0..<10 {
        let current = try await toolbarCornerOnScreen()
        #expect(abs(current.x - toolbarCorner.x) < 1)
        #expect(abs(current.y - toolbarCorner.y) < 1)
        try await Task.sleep(for: .milliseconds(20))
      }
    }
  }
  try await clickModeButton("icon-split")
  for _ in 0..<100 {
    if controller.model.documentSplit { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(controller.model.documentSplit)
  for _ in 0..<2 {
    controller.model.onToggleDocumentSidebar?()
    try await waitForLayoutSettled()
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
      const preview = previewActions.querySelector('.icon-preview');
      const split = previewActions.querySelector('.icon-split');
      const reading = previewActions.querySelector('.icon-solidReading');
      return content.classList.contains('split') && editorActions === null
        && content.querySelector('.icon-save') === null
        && content.querySelector('.icon-clear') === null
        && content.querySelector('.icon-exportImage') === null
        && preview !== null && split !== null && reading !== null
        && split.dataset.icon === 'edit'
        && getComputedStyle(toolbar).display === 'none'
        && getComputedStyle(content.querySelector('.file-label')).display === 'none'
        && getComputedStyle(reading).display === 'flex'
        && getComputedStyle(reading).justifyContent === 'center'
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
      enlarged: false, split: true, sidebar: true, screenFrame: frame, visibleFrame: frame)
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

@MainActor @Test func devBarPanelUsesNormalActivatingWindowOrdering() {
  _ = NSApplication.shared
  let panel = DevBarPanel()
  #expect(panel.level == .normal)
  #expect(!panel.isFloatingPanel)
  #expect(!panel.styleMask.contains(.nonactivatingPanel))
  #expect(!panel.hidesOnDeactivate)
}

@MainActor @Test func documentSplitButtonTogglesBetweenSplitAndSource() {
  let defaults = UserDefaults(suiteName: "devbar.doc.split.\(UUID())")!
  let model = PanelModel(defaults: defaults)
  model.documentDisplay = "source"
  #expect(model.documentSplitButtonTarget == "split")
  model.documentDisplay = "split"
  #expect(model.documentSplitButtonTarget == "source")
  model.documentDisplay = "preview"
  #expect(model.documentSplitButtonTarget == "split")
}

@MainActor @Test func pageTitlesAndSwitchTooltipFollowUnifiedCopy() {
  #expect(PanelModel.Page.clipboard.title == "Paste")
  #expect(PanelModel.Page.json.title == "JSON")
  #expect(PanelModel.Page.qr.title == "QR")
  #expect(PanelModel.Page.doc.title == "Markdown")
  #expect(Strings.switchNextPage("⌘R") == "切换到下一页 · ⌘R")
  #expect(Strings.switchNextPage("") == "切换到下一页 · ⌘R（面板内）")
  #expect(Strings.switchNextPage(nil) == "切换到下一页 · ⌘R（面板内）")
}

@MainActor @Test func documentSolidReadingPersistsAcrossPanelModels() {
  let suite = "devbar.solid-reading.\(UUID())"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let first = PanelModel(defaults: defaults)
  #expect(!first.documentSolidReading)
  first.documentSolidReading = true
  let second = PanelModel(defaults: defaults)
  #expect(second.documentSolidReading)
}

@MainActor @Test func commandSSavesOnlyOnDocumentPage() throws {
  _ = NSApplication.shared
  let panel = DevBarPanel()
  var triggered = 0
  panel.onDocumentSave = {
    triggered += 1
    return true
  }
  let event = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: panel.windowNumber, context: nil, characters: "s",
      charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
  #expect(panel.performKeyEquivalent(with: event))
  #expect(triggered == 1)

  panel.onDocumentSave = { false }
  #expect(!panel.performKeyEquivalent(with: event))
}

@MainActor @Test func commandSDoesNotOverwriteNewlyAdoptedFileBeforeWebLoadsIt() async throws {
  _ = NSApplication.shared
  let webRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Web/dist")
  let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tempDir) }
  let fileB = tempDir.appending(path: "target-b.md")
  let originalB = "# Original File B\n"
  try Data(originalB.utf8).write(to: fileB)

  let suiteName = "devbar.save-race.\(UUID())"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  struct EmptyPasteboardReader: PasteboardReading {
    func metadata() -> PasteboardMetadata {
      PasteboardMetadata(count: 0, types: [], access: .allow)
    }
    func read() -> [ClipboardPayload] { [] }
  }
  let controller = PanelController(
    theme: ThemeManager(defaults: defaults),
    webRoot: webRoot,
    defaults: defaults,
    clipboardDirectory: tempDir.appending(path: "clipboard"),
    clipboardReader: EmptyPasteboardReader(),
    startClipboardMonitoring: false,
    screenStateStore: ScreenStateStore(directory: tempDir.appending(path: "state")))
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

  let commandS = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: controller.panel.windowNumber, context: nil, characters: "s",
      charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))

  // Untitled content may have a clean editor baseline before its first file save.
  let firstSaveText = "# Untitled content"
  controller.webHost.importFile(text: firstSaveText, name: "note.md", document: true)
  for _ in 0..<100 {
    if (await controller.webHost.documentStatus())?["dirty"] as? Bool == false,
      await controller.webHost.documentText() == firstSaveText
    {
      break
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(controller.documents.url == nil)
  let saveToFile = controller.webHost.saveDocument
  var firstSaveRequest: String?
  controller.webHost.saveDocument = { text, _ in
    firstSaveRequest = text
    return #"{"status":"canceled"}"#
  }
  #expect(controller.panel.performKeyEquivalent(with: commandS))
  for _ in 0..<100 {
    if firstSaveRequest != nil { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(firstSaveRequest == firstSaveText)
  controller.webHost.saveDocument = saveToFile

  // Create an untitled dirty draft A in Web (documentID == nil).
  _ = try await controller.webHost.webView.evaluateJavaScript(
    """
    (() => {
      const view = document.querySelector('#doc .cm-content')?.cmTile?.root?.view;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: '# Untitled Draft A' }, userEvent: 'input.type' });
      return true;
    })()
    """)
  for _ in 0..<50 {
    if await controller.webHost.documentText() == "# Untitled Draft A" { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect((await controller.webHost.documentStatus())?["dirty"] as? Bool == true)

  // Native adopts file B before Web has imported file B.
  let openedB = try await controller.documents.read(fileB).get()
  controller.documents.adopt(openedB)

  #expect(controller.panel.performKeyEquivalent(with: commandS))

  // Wait for the rejected save round-trip to show the failure notice in Web.
  for _ in 0..<100 {
    if (try? await controller.webHost.webView.evaluateJavaScript(
      "document.querySelector('#doc .page-info')?.hidden === false"
    )) as? Bool == true {
      break
    }
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(try String(contentsOf: fileB, encoding: .utf8) == originalB)

  // Once Web loads file B and edits it, ⌘S saves normally to file B.
  controller.webHost.importDocument(openedB, display: "source")
  for _ in 0..<100 {
    if await controller.webHost.documentText() == originalB { break }
    try await Task.sleep(for: .milliseconds(25))
  }
  _ = try await controller.webHost.webView.evaluateJavaScript(
    """
    (() => {
      const view = document.querySelector('#doc .cm-content')?.cmTile?.root?.view;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: '# Updated File B\\n' }, userEvent: 'input.type' });
      return true;
    })()
    """)
  for _ in 0..<50 {
    if await controller.webHost.documentText() == "# Updated File B\n" { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(controller.panel.performKeyEquivalent(with: commandS))
  for _ in 0..<100 {
    if (try? String(contentsOf: fileB, encoding: .utf8)) == "# Updated File B\n" { break }
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(try String(contentsOf: fileB, encoding: .utf8) == "# Updated File B\n")
}

@MainActor @Test func externalOpenMarkdownDefaultsToPreviewMode() async throws {
  _ = NSApplication.shared
  let webRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Web/dist")
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let mdFile = directory.appending(path: "external.md")
  try Data("# External Preview\n".utf8).write(to: mdFile)

  let defaults = UserDefaults(suiteName: "devbar.external.preview.\(UUID())")!
  let controller = PanelController(theme: ThemeManager(defaults: defaults), webRoot: webRoot)
  let status = StatusItemController()
  let coordinator = FileDropCoordinator(panel: controller, status: status)
  controller.model.prepareToOpen(page: .clipboard)
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

  coordinator.receive([mdFile])
  for _ in 0..<100 {
    if controller.model.page == .doc && controller.model.documentDisplay == "preview"
      && controller.documents.url?.standardizedFileURL == mdFile.standardizedFileURL
    {
      break
    }
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(controller.model.page == .doc)
  #expect(controller.model.documentDisplay == "preview")
  #expect(!controller.model.documentSplit)
}
