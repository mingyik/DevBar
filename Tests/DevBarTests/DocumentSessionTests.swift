import Foundation
import Testing

@testable import DevBar

@MainActor
@Test func documentSessionSavesWithOriginalBOMAndCRLF() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appending(path: "notes.md")
  try (Data([0xEF, 0xBB, 0xBF]) + Data("旧内容\r\n".utf8)).write(to: url)
  let session = DocumentSession(defaults: UserDefaults(suiteName: UUID().uuidString)!)
  guard case .success(let opened) = await session.read(url) else {
    Issue.record("read failed")
    return
  }
  #expect(opened.hadBOM)
  session.adopt(opened)
  let outcome = await session.save("第一行\n第二行\n", saveAs: false)
  guard case .saved = outcome else {
    Issue.record("save failed: \(outcome)")
    return
  }
  let data = try Data(contentsOf: url)
  #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
  #expect(String(data: data.dropFirst(3), encoding: .utf8) == "第一行\r\n第二行\r\n")
}

@MainActor
@Test func documentSessionRefusesToOverwriteExternallyChangedFile() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appending(path: "notes.md")
  try Data("original".utf8).write(to: url)
  let session = DocumentSession(defaults: UserDefaults(suiteName: UUID().uuidString)!)
  guard case .success(let opened) = await session.read(url) else {
    Issue.record("read failed")
    return
  }
  session.adopt(opened)
  try Data("changed elsewhere".utf8).write(to: url)
  let outcome = await session.save("from DevBar", saveAs: false)
  #expect(outcome == .externalChanged)
  #expect(try String(contentsOf: url, encoding: .utf8) == "changed elsewhere")
}

@MainActor
@Test func documentSessionRemembersRecentFiles() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let defaults = UserDefaults(suiteName: UUID().uuidString)!
  let session = DocumentSession(defaults: defaults)
  var urls: [URL] = []
  for index in 0..<4 {
    let url = directory.appending(path: "\(index).md")
    try Data("file \(index)".utf8).write(to: url)
    urls.append(url)
    guard case .success(let opened) = await session.read(url) else {
      Issue.record("read failed")
      return
    }
    session.adopt(opened)
  }
  #expect(session.recent == [urls[3], urls[2], urls[1]])
  #expect(defaults.stringArray(forKey: "recentDocumentPaths") == session.recent.map(\.path))
  guard case .success(let again) = await session.read(urls[1]) else {
    Issue.record("read failed")
    return
  }
  session.adopt(again)
  #expect(session.recent == [urls[1], urls[3], urls[2]])
}

@MainActor @Test func missingRecentDocumentsAreHiddenAndPruned() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let existing = root.appending(path: "keep.md")
  let missing = root.appending(path: "gone.md")
  try Data("hello".utf8).write(to: existing)
  let defaults = UserDefaults(suiteName: UUID().uuidString)!
  defaults.set([missing.path, existing.path], forKey: "recentDocumentPaths")
  let session = DocumentSession(defaults: defaults)
  #expect(session.recent == [existing])
  try FileManager.default.removeItem(at: existing)
  #expect(session.recentEntries.isEmpty)
  session.pruneMissingRecent()
  #expect(session.recent.isEmpty)
  #expect(defaults.stringArray(forKey: "recentDocumentPaths") == [])
}

@MainActor
@Test func documentSessionResolvesRelativeMarkdownLinksFromTheOpenFile() {
  let document = URL(fileURLWithPath: "/tmp/devbar-link-test/方案.md")
  let session = DocumentSession(defaults: UserDefaults(suiteName: UUID().uuidString)!)
  let link = "docs/UI%E5%9F%BA%E5%87%86.md"
  #expect(session.resolveDocumentLink(link) == nil)

  session.adopt(
    OpenedDocument(
      id: "plan", url: document, text: "", fileName: "方案.md",
      mode: .markdown, hadBOM: false, newline: "\n"))

  #expect(session.resolveDocumentLink(link)?.path == "/tmp/devbar-link-test/docs/UI基准.md")
  #expect(session.resolveDocumentLink("docs/说明与视频制作提纲.md")?.lastPathComponent == "说明与视频制作提纲.md")
  #expect(session.resolveDocumentLink("file:///tmp/private.md") == nil)
  #expect(session.resolveDocumentLink("//example.com/page.md") == nil)
  #expect(session.resolveDocumentLink("%2Ftmp/private.md") == nil)
  #expect(session.resolveDocumentLink("docs/手册.pdf")?.lastPathComponent == "手册.pdf")
}

@MainActor
@Test func documentSessionRemovesIndividualEntriesAndClearsSidebar() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let first = directory.appending(path: "a.md").standardizedFileURL
  let second = directory.appending(path: "b.md").standardizedFileURL
  try Data("# A".utf8).write(to: first)
  try Data("# B".utf8).write(to: second)
  let suite = "devbar.sidebar.clear.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }

  let session = DocumentSession(defaults: defaults)
  session.adopt(
    OpenedDocument(
      id: "doc-a", url: first, text: "# A", fileName: "a.md",
      mode: .markdown, hadBOM: false, newline: "\n"))
  session.adopt(
    OpenedDocument(
      id: "doc-b", url: second, text: "# B", fileName: "b.md",
      mode: .markdown, hadBOM: false, newline: "\n"))
  let draft = session.stashDraft(["text": "# B edited", "savedText": "# B", "fileName": "b.md"])
  #expect(draft != nil)
  #expect(session.recent == [second, first])
  #expect(session.drafts.count == 1)

  session.removeRecent(first)
  #expect(session.recent == [second])
  #expect(defaults.stringArray(forKey: "recentDocumentPaths") == [second.path])

  if let draft {
    session.removeDraft(id: draft.id)
  }
  #expect(session.drafts.isEmpty)

  _ = session.stashDraft(["text": "# B edited again", "savedText": "# B", "fileName": "b.md"])
  #expect(session.drafts.count == 1)
  session.clearSidebarEntries()
  #expect(session.recent.isEmpty)
  #expect(session.drafts.isEmpty)
  #expect(defaults.stringArray(forKey: "recentDocumentPaths") == [])
}
