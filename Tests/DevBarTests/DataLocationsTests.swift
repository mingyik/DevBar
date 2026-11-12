import Foundation
import Testing

@testable import DevBar

@Test func dataLocationsMigrateLegacyAndRefuseOverwrite() throws {
  let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: base) }
  let source = base.appending(path: "old/DevBar")
  try FileManager.default.createDirectory(
    at: source.appending(path: "state"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: source.appending(path: "clipboard/blobs"), withIntermediateDirectories: true)
  let original = Data(#"{"text":"12345678901234567890 0.1000"}"#.utf8)
  try original.write(to: source.appending(path: "state/json.json"))
  try DataLocations.prepare(source)
  #expect(try Data(contentsOf: source.appending(path: "Json/state.json")) == original)
  #expect(FileManager.default.fileExists(atPath: source.appending(path: "Paste/blobs").path))
  let target = base.appending(path: "new/DevBar")
  try FileManager.default.createDirectory(
    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
  try DataLocations.move(from: source, to: target)
  #expect(try Data(contentsOf: target.appending(path: "Json/state.json")) == original)
  #expect(throws: DataLocations.LocationError.self) {
    try DataLocations.move(from: target, to: target.appending(path: "nested"))
  }
  let occupied = base.appending(path: "occupied")
  try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
  #expect(throws: DataLocations.LocationError.self) {
    try DataLocations.move(from: target, to: occupied)
  }
  #expect(FileManager.default.fileExists(atPath: target.path))
  #expect(DataLocations.destination(in: target) == target)
}

@Test func memoryBudgetUsesCurrentHeadroomAndRejectsOversizedInput() {
  let gib: UInt64 = 1024 * 1024 * 1024
  #expect(MemoryBudget.permits(incoming: 2 * 1024 * 1024, available: 10 * gib, total: 16 * gib))
  #expect(!MemoryBudget.permits(incoming: 1, available: 128 * 1024 * 1024, total: 16 * gib))
  #expect(!MemoryBudget.permits(incoming: gib, available: 2 * gib, total: 16 * gib))
}

@Test func stateSaveFailureIsReportedAndDoesNotClaimSuccess() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try Data("occupied".utf8).write(to: root)
  let store = ScreenStateStore(directory: root)
  #expect(await store.save(screen: "json", json: "{}") == false)
  #expect(try String(contentsOf: root, encoding: .utf8) == "occupied")
}
