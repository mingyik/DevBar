import AppKit
import Foundation
import Testing

@testable import DevBar

@Test func pageStateKeysAreIndependentAndLegacyToolsMigrates() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let legacy = "{\"text\":\"legacy original\"}"
  try Data(legacy.utf8).write(to: root.appending(path: "tools.json"))
  let store = ScreenStateStore(directory: root)
  #expect(await store.load(screen: "json") == legacy)
  await store.save(screen: "qr", json: "{\"text\":\"QR\"}")
  await store.save(screen: "doc", json: "{\"text\":\"doc\"}")
  #expect(await store.load(screen: "json") == legacy)
  #expect(await store.load(screen: "qr") == "{\"text\":\"QR\"}")
  #expect(await store.load(screen: "../../escape") == nil)
}

@Test func inMemoryScreenStateStoreIgnoresAndPreservesDiskFiles() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let jsonDir = root.appending(path: "Json")
  try FileManager.default.createDirectory(at: jsonDir, withIntermediateDirectories: true)
  let stateFile = jsonDir.appending(path: "state.json")
  let extraFile = jsonDir.appending(path: "keep.txt")
  try Data(#"{"text":"old","view":"preview"}"#.utf8).write(to: stateFile)
  try Data("preserve".utf8).write(to: extraFile)

  let firstLaunch = ScreenStateStore(directory: root, inMemory: true)
  #expect(await firstLaunch.load(screen: "json") == nil)
  #expect(await firstLaunch.load(screen: "qr") == nil)
  #expect(await firstLaunch.load(screen: "doc") == nil)
  #expect(await firstLaunch.save(screen: "doc", json: #"{"text":"title","view":"preview"}"#))
  #expect(await firstLaunch.load(screen: "doc") == #"{"text":"title","view":"preview"}"#)
  #expect(FileManager.default.fileExists(atPath: stateFile.path))
  #expect(try String(contentsOf: extraFile, encoding: .utf8) == "preserve")

  let nextLaunch = ScreenStateStore(directory: root, inMemory: true)
  #expect(await nextLaunch.load(screen: "doc") == nil)
  #expect(FileManager.default.fileExists(atPath: stateFile.path))
  #expect(try String(contentsOf: extraFile, encoding: .utf8) == "preserve")
}

@MainActor @Test func webHostRestoresContentAndPreviewAfterWebViewReleaseAndResetsOnRestart()
  async throws
{
  _ = NSApplication.shared
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let webDist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Web/dist")
  let defaults = UserDefaults(suiteName: "local.devbar.test.pagestate.\(UUID().uuidString)")!
  let theme = ThemeManager(defaults: defaults)
  let store = ScreenStateStore(directory: root, inMemory: true)
  let host = WebHost(theme: theme, webRoot: webDist, store: store)
  host.setPanelVisible(true)

  let ready1 = await waitUntil {
    (try? await host.webView.evaluateJavaScript("!!window.__devbar")) as? Bool == true
  }
  #expect(ready1)
  host.showScreen("doc")
  let initialEditMode = await waitUntil {
    (try? await host.webView.evaluateJavaScript(
      """
      (() => {
        const v = document.querySelector('#doc .cm-content')?.cmTile?.root?.view;
        const p = document.querySelector('#doc .preview');
        return !!v && v.state.doc.toString() === '' && p?.hidden === true;
      })()
      """)) as? Bool == true
  }
  #expect(initialEditMode)

  host.importFile(text: "# Session Title", name: "note.md", document: true)
  host.toggleDocumentMode()
  let previewEntered = await waitUntil {
    (try? await host.webView.evaluateJavaScript(
      """
      (() => {
        const v = document.querySelector('#doc .cm-content')?.cmTile?.root?.view;
        const p = document.querySelector('#doc .preview');
        return v?.state.doc.toString() === '# Session Title' && p?.hidden === false;
      })()
      """)) as? Bool == true
  }
  #expect(previewEntered)

  let genBeforeRelease = host.generation
  host.setPanelVisible(false)
  await host.flushHiddenMemory()
  #expect(host.generation > genBeforeRelease)

  let genAfterRelease = host.generation
  host.setPanelVisible(true)
  host.showScreen("doc")
  #expect(host.generation > genAfterRelease)
  let restoredAfterRebuild = await waitUntil {
    (try? await host.webView.evaluateJavaScript(
      """
      (() => {
        const v = document.querySelector('#doc .cm-content')?.cmTile?.root?.view;
        const p = document.querySelector('#doc .preview');
        return v?.state.doc.toString() === '# Session Title' && p?.hidden === false;
      })()
      """)) as? Bool == true
  }
  #expect(restoredAfterRebuild)

  let restartedStore = ScreenStateStore(directory: root, inMemory: true)
  let restartedHost = WebHost(theme: theme, webRoot: webDist, store: restartedStore)
  restartedHost.setPanelVisible(true)
  let restartedEmptyEdit = await waitUntil {
    (try? await restartedHost.webView.evaluateJavaScript(
      """
      (() => {
        if (!window.__devbar) return false;
        const v = document.querySelector('#doc .cm-content')?.cmTile?.root?.view;
        const p = document.querySelector('#doc .preview');
        return !!v && v.state.doc.toString() === '' && p?.hidden === true;
      })()
      """)) as? Bool == true
  }
  #expect(restartedEmptyEdit)
}

@MainActor private func waitUntil(
  seconds: Double = 10, condition: @MainActor () async -> Bool
) async -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(50))
  }
  return false
}
