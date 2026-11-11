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
