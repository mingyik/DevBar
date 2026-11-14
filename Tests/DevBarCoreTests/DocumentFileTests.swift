import Foundation
import Testing

@testable import DevBarCore

@Test func documentEditorComparisonAllowsOnlyNewlineDifferences() {
  #expect(DocumentFile.editorTextMatches("标题\r\n正文\r", "标题\n正文\n"))
  #expect(!DocumentFile.editorTextMatches("标题\r\n正文", "标题\n新正文"))
  #expect(!DocumentFile.editorTextMatches("正文\n", "正文"))
  let original = "第一行\r\n第二行\n"
  #expect(DocumentFile.editorTextMatches(original, "第一行\n第二行\n"))
  #expect(DocumentFile.encode(original, hadBOM: false, newline: "\n") == Data(original.utf8))
}

@Test func documentReplacementFailsClosedWhenSnapshotOrStatusUnavailable() {
  #expect(
    DocumentFile.replacementReadiness(
      requiresEditorSnapshot: true, hasEditorSnapshot: false, dirty: false) == .unavailable)
  #expect(
    DocumentFile.replacementReadiness(
      requiresEditorSnapshot: true, hasEditorSnapshot: true, dirty: nil) == .unavailable)
  #expect(
    DocumentFile.replacementReadiness(
      requiresEditorSnapshot: false, hasEditorSnapshot: false, dirty: nil) == .unavailable)
  #expect(
    DocumentFile.replacementReadiness(
      requiresEditorSnapshot: true, hasEditorSnapshot: true, dirty: true) == .modified)
  #expect(
    DocumentFile.replacementReadiness(
      requiresEditorSnapshot: true, hasEditorSnapshot: true, dirty: false) == .clean)
  #expect(
    DocumentFile.replacementReadiness(
      requiresEditorSnapshot: false, hasEditorSnapshot: false, dirty: false) == .clean)
}

@Test func documentDecodeKeepsBOMAndCRLF() {
  let decoded = DocumentFile.decode(Data([0xEF, 0xBB, 0xBF]) + Data("第一行\r\n第二行\r\n".utf8))
  #expect(decoded?.text == "第一行\r\n第二行\r\n")
  #expect(decoded?.hadBOM == true)
  #expect(decoded?.newline == "\r\n")
}

@Test func documentEncodeRestoresBOMAndCRLFAfterEditing() {
  let data = DocumentFile.encode("第一行\n新的一行\n", hadBOM: true, newline: "\r\n")
  #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
  #expect(String(data: data.dropFirst(3), encoding: .utf8) == "第一行\r\n新的一行\r\n")
}

@Test func documentNewlineIgnoresMixedFiles() {
  #expect(DocumentFile.newline(of: "a\nb") == "\n")
  #expect(DocumentFile.newline(of: "a\r\nb\r\n") == "\r\n")
  #expect(DocumentFile.newline(of: "a\r\nb\n") == "\n")
}

@Test func recentDocumentsDeduplicateAndLimit() {
  let urls = (1...4).map { URL(fileURLWithPath: "/tmp/\($0).md") }
  var list: [URL] = []
  for url in urls { list = RecentDocuments.adding(url, to: list) }
  #expect(list == [urls[3], urls[2], urls[1]])
  list = RecentDocuments.adding(urls[1], to: list)
  #expect(list == [urls[1], urls[3], urls[2]])
}

@Test func fileSignatureDetectsExternalChange() throws {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".md")
  defer { try? FileManager.default.removeItem(at: url) }
  try Data("one".utf8).write(to: url)
  let first = try #require(DocumentFile.signature(of: url))
  #expect(first.matches(DocumentFile.signature(of: url)))
  try Data("new content".utf8).write(to: url)
  let second = DocumentFile.signature(of: url)
  #expect(second?.size == 11)
  #expect(!first.matches(second))
}
