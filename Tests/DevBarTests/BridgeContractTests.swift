import Foundation
import Testing
@testable import DevBar

@Test func bridgeSamplesRoundTrip() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Samples/bridge")
  let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
  let samples = files.filter { $0.pathExtension == "json" }
  #expect(!samples.isEmpty)
  for file in samples {
    let raw = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let decoded = try #require(BridgeEnvelope.decode(raw))
    #expect(decoded.encoded() == raw)
  }
}

@Test func schemeMapRejectsParentPaths() throws {
  let root = URL(fileURLWithPath: "/tmp/devbar-web")
  #expect(WebFileMap.file(for: URL(string: "devbar://app/../secret")!, root: root) == nil)
  #expect(WebFileMap.file(for: URL(string: "https://example.com/")!, root: root) == nil)
  let index = try #require(WebFileMap.file(for: URL(string: "devbar://app/index.html")!, root: root))
  #expect(index.lastPathComponent == "index.html")
}

@Test func cspHeaderMatchesTheSpec() {
  #expect(DevBarCSP.header.contains("script-src devbar:"))
  #expect(!DevBarCSP.header.contains("unsafe-eval"))
}
