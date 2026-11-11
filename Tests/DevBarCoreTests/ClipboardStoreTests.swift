import Foundation
import Synchronization
import Testing

@testable import DevBarCore

private func temporaryClipboardDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func addText(_ text: String, to store: ClipboardStore, date: Date = Date()) async throws
  -> ClipItem
{
  let result = try await store.add(
    kind: .text, createdAt: date, preview: text,
    representations: [ClipboardPayload(type: "public.utf8-plain-text", data: Data(text.utf8))])
  switch result {
  case .inserted(let item), .duplicate(let item): return item
  case .rejectedImageTooLarge: throw CocoaError(.fileWriteUnknown)
  }
}

@Test func clipboardEvictsEleventhItemAndItsFiles() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  let first = try await store.add(
    kind: .image, preview: "1×1",
    representations: [ClipboardPayload(type: "public.png", data: Data([1]))], thumbnail: Data([2]))
  guard case .inserted(let oldest) = first else {
    Issue.record("Expected insertion")
    return
  }
  for n in 0..<10 { _ = try await addText(String(n), to: store) }
  #expect(await store.items.count == 10)
  #expect(
    !FileManager.default.fileExists(
      atPath: root.appendingPathComponent("blobs/" + oldest.representations[0].blob).path))
  #expect(
    !FileManager.default.fileExists(
      atPath: root.appendingPathComponent("thumbs/\(oldest.id).png").path))
}

@Test func clipboardDuplicateMovesExistingIDAndUpdatesDate() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  let original = try await addText("same", to: store, date: Date(timeIntervalSince1970: 1))
  let other = try await addText("other", to: store)
  let updated = try await addText("same", to: store, date: Date(timeIntervalSince1970: 3))
  #expect(updated.id == original.id)
  #expect(updated.createdAt == Date(timeIntervalSince1970: 3))
  #expect(await store.items.map(\.id) == [original.id, other.id])
  #expect(await store.items.count == 2)
}

@Test func clipboardRejectsImagesOver20MBAcrossRepresentationsAndNotifiesOnce() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let calls = Mutex(0)
  let store = try ClipboardStore(directory: root, onImageTooLarge: { calls.withLock { $0 += 1 } })
  let result = try await store.add(
    kind: .image, preview: "large",
    representations: [
      ClipboardPayload(type: "public.png", data: Data(repeating: 1, count: 10 * 1024 * 1024)),
      ClipboardPayload(type: "public.tiff", data: Data(repeating: 2, count: 10 * 1024 * 1024 + 1)),
    ])
  #expect(result == .rejectedImageTooLarge)
  #expect(calls.withLock { $0 } == 1)
  #expect(await store.items.isEmpty)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("blobs").path)
      .isEmpty)
}

@Test func clipboardAcceptsExactly20MBImage() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  _ = try await store.add(
    kind: .image, preview: "boundary",
    representations: [
      ClipboardPayload(type: "public.png", data: Data(repeating: 0, count: 20 * 1024 * 1024))
    ])
  #expect(await store.items.count == 1)
}

@Test func clipboardRecoversCommittedIndexAfterPartialTemporaryWrite() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  let saved = try await addText("kept", to: store)
  try Data("{partial".utf8).write(to: root.appendingPathComponent("index.json.tmp"))
  let reopened = try ClipboardStore(directory: root)
  #expect(await reopened.items == [saved])
  #expect(
    !FileManager.default.fileExists(atPath: root.appendingPathComponent("index.json.tmp").path))
}

@Test func clipboardRecoversCompleteTemporaryIndexWithoutMainIndex() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  let saved = try await addText("kept", to: store)
  try FileManager.default.moveItem(
    at: root.appendingPathComponent("index.json"), to: root.appendingPathComponent("index.json.tmp")
  )
  let reopened = try ClipboardStore(directory: root)
  #expect(await reopened.items == [saved])
}

@Test func clipboardFirstWriteCrashWithPartialTempRecoversEmpty() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  try Data("{".utf8).write(to: root.appendingPathComponent("index.json.tmp"))
  let store = try ClipboardStore(directory: root)
  #expect(await store.items.isEmpty)
}

@Test func clipboardRemovesOrphanBlobsAndThumbnails() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  _ = try await addText("kept", to: store)
  for path in ["blobs/orphan", "thumbs/orphan.png"] {
    try Data([1]).write(to: root.appendingPathComponent(path))
  }
  _ = try ClipboardStore(directory: root)
  for path in ["blobs/orphan", "thumbs/orphan.png"] {
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
  }
}

@Test func clipboardDropsEntryWithMissingBlobAndCleansRemainingFiles() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  let item = try await addText("missing", to: store)
  try FileManager.default.removeItem(
    at: root.appendingPathComponent("blobs/" + item.representations[0].blob))
  let reopened = try ClipboardStore(directory: root)
  #expect(await reopened.items.isEmpty)
  #expect(
    try JSONDecoder().decode(
      ClipboardIndex.self, from: Data(contentsOf: root.appendingPathComponent("index.json"))
    ).items.isEmpty)
}

@Test func clipboardPreservesEveryRepresentationAndRepeatedFileURLs() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  for (kind, types) in [
    (ClipItem.Kind.text, ["public.utf8-plain-text", "public.rtf", "public.html"]),
    (.files, ["public.file-url", "public.file-url"]),
  ] {
    let payloads = types.enumerated().map {
      ClipboardPayload(type: $0.element, data: Data([UInt8($0.offset), 255, 0]))
    }
    guard
      case .inserted(let item) = try await store.add(
        kind: kind, preview: "preview", representations: payloads)
    else {
      Issue.record("Expected insertion")
      return
    }
    #expect(try await store.payloads(for: item.id) == payloads)
  }
  let reopened = try ClipboardStore(directory: root)
  #expect(await reopened.items.count == 2)
}

@Test func clipboardWriteFailureKeepsMemoryAndCommittedFiles() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  let item = try await addText("kept", to: store)
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("index.json.tmp"), withIntermediateDirectories: false)
  await #expect(throws: (any Error).self) { _ = try await addText("failed", to: store) }
  #expect(await store.items == [item])
  #expect(try await store.payloads(for: item.id)[0].data == Data("kept".utf8))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("blobs").path)
      .count == 1)
}

@Test func clipboardHashIncludesTypesAndFramedRepresentationBoundaries() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  for types in [["a", "bc"], ["ab", "c"]] {
    _ = try await store.add(
      kind: .text, preview: "",
      representations: types.map { ClipboardPayload(type: $0, data: Data()) })
  }
  #expect(await store.items.count == 2)
  #expect(await store.items.allSatisfy { $0.contentHash.count == 64 })
}

@Test func clipboardDamagedMainRecoversCompleteTemporaryIndex() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  let saved = try await addText("saved", to: store)
  let main = root.appendingPathComponent("index.json")
  try FileManager.default.copyItem(at: main, to: root.appendingPathComponent("index.json.tmp"))
  try Data("broken".utf8).write(to: main)
  let reopened = try ClipboardStore(directory: root)
  #expect(await reopened.items == [saved])
}

@Test func clipboardCorruptIndexBacksUpAndRestartsWithOneNotification() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let calls = Mutex(0)
  let corrupt = Data("not json".utf8)
  try corrupt.write(to: root.appendingPathComponent("index.json"))
  let store = try ClipboardStore(directory: root, onCorruptHistory: { calls.withLock { $0 += 1 } })
  #expect(await store.items.isEmpty)
  #expect(calls.withLock { $0 } == 1)
  let backups = try FileManager.default.contentsOfDirectory(
    at: root, includingPropertiesForKeys: nil
  ).filter { $0.lastPathComponent.hasPrefix("index.json.corrupt-") }
  #expect(backups.count == 1)
  #expect(try Data(contentsOf: #require(backups.first)) == corrupt)
  _ = try await addText("new", to: store)
  let reopened = try ClipboardStore(
    directory: root, onCorruptHistory: { calls.withLock { $0 += 1 } })
  #expect(await reopened.items.count == 1)
  #expect(calls.withLock { $0 } == 1)
}

@Test func clipboardRejectsTraversalInStoredBlobReference() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  var saved = try await addText("saved", to: store)
  let outside = root.appendingPathComponent("outside")
  try Data([1]).write(to: outside)
  saved.representations[0].blob = "../outside"
  try JSONEncoder().encode(ClipboardIndex(items: [saved])).write(
    to: root.appendingPathComponent("index.json"))
  let reopened = try ClipboardStore(directory: root)
  #expect(await reopened.items.isEmpty)
  #expect(try Data(contentsOf: outside) == Data([1]))
}

@Test func clipboardPreviewIsTwoLinesAnd200CharactersWithMetadataPreserved() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  let content = "first\nsecond\nthird"
  guard
    case .inserted(let item) = try await store.add(
      kind: .text, sourceBundleID: "local.test", preview: content,
      representations: [ClipboardPayload(type: "public.utf8-plain-text", data: Data(content.utf8))])
  else {
    Issue.record("Expected insertion")
    return
  }
  #expect(item.preview == "first\nsecond")
  #expect(item.sourceBundleID == "local.test")
  #expect(item.byteSize == content.utf8.count)
  let long = try await addText(String(repeating: "😀", count: 300), to: store)
  #expect(long.preview.count == 200)
  #expect(try await store.payloads(for: long.id)[0].data.count == 1200)
}

@Test func clipboardMissingOneRepresentationRemovesEntryAndOtherBlobAndThumbnail() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  guard
    case .inserted(let item) = try await store.add(
      kind: .image, preview: "1×1",
      representations: [
        ClipboardPayload(type: "public.png", data: Data([1, 2, 3])),
        ClipboardPayload(type: "public.tiff", data: Data([4, 5])),
      ], thumbnail: Data([6]))
  else {
    Issue.record("Expected insertion")
    return
  }
  #expect(try await store.payloads(for: item.id)[0].data == Data([1, 2, 3]))
  try FileManager.default.removeItem(
    at: root.appendingPathComponent("blobs/" + item.representations[0].blob))
  let reopened = try ClipboardStore(directory: root)
  #expect(await reopened.items.isEmpty)
  for folder in ["blobs", "thumbs"] {
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)
        .isEmpty)
  }
}

@Test func clipboardCorruptIndexWithInvalidTempKeepsDistinctBackups() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let calls = Mutex(0)
  for content in ["broken first", "broken second"] {
    try Data(content.utf8).write(to: root.appendingPathComponent("index.json"))
    try Data("{".utf8).write(to: root.appendingPathComponent("index.json.tmp"))
    let store = try ClipboardStore(
      directory: root, onCorruptHistory: { calls.withLock { $0 += 1 } })
    #expect(await store.items.isEmpty)
  }
  let backups = try FileManager.default.contentsOfDirectory(
    at: root, includingPropertiesForKeys: nil
  ).filter { $0.lastPathComponent.hasPrefix("index.json.corrupt-") }
  #expect(backups.count == 2)
  #expect(
    try Set(backups.map { try String(contentsOf: $0, encoding: .utf8) })
      == Set(["broken first", "broken second"]))
  #expect(calls.withLock { $0 } == 2)
}

@Test func clipboardDeleteAndClearPersistAndRemoveOriginals() async throws {
  let root = try temporaryClipboardDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ClipboardStore(directory: root)
  let first = try await addText("first", to: store)
  _ = try await addText("second", to: store)
  try await store.remove(first.id)
  #expect(await store.items.count == 1)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("blobs").path)
      .count == 1)
  try await store.clear()
  #expect(await store.items.isEmpty)
  let restored = try ClipboardStore(directory: root)
  #expect(await restored.items.isEmpty)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("blobs").path)
      .isEmpty)
}
