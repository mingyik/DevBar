import CryptoKit
import Foundation

public actor ClipboardStore {
  public enum AddResult: Sendable, Equatable {
    case inserted(ClipItem)
    case duplicate(ClipItem)
    case rejectedImageTooLarge
  }

  public enum StoreError: Error {
    case invalidIndex, emptyRepresentations, unknownItem
  }

  public private(set) var items: [ClipItem]
  private let directory: URL
  private let onImageTooLarge: @Sendable () -> Void
  public static let imageByteLimit = 20 * 1024 * 1024

  public init(
    directory: URL = URL.applicationSupportDirectory.appendingPathComponent("DevBar/clipboard"),
    onImageTooLarge: @escaping @Sendable () -> Void = {}
  ) throws {
    self.directory = directory
    self.onImageTooLarge = onImageTooLarge
    let fm = FileManager.default
    for name in ["blobs", "thumbs"] {
      try fm.createDirectory(
        at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let main = directory.appendingPathComponent("index.json")
    let temp = directory.appendingPathComponent("index.json.tmp")
    let mainExists = fm.fileExists(atPath: main.path)
    let committed = Self.readIndex(main)
    let pending = Self.readIndex(temp)
    // A valid committed index wins: a leftover temp was never committed. If the
    // committed index is absent/damaged, a complete temp can recover the transaction.
    guard let loaded = committed ?? pending ?? (mainExists ? nil : ClipboardIndex(items: []))
    else { throw StoreError.invalidIndex }
    var ids = Set<UUID>()
    let valid = loaded.items.filter { item in
      ids.insert(item.id).inserted && !item.representations.isEmpty
        && item.representations.allSatisfy {
          Self.safeBlob($0.blob)
            && fm.fileExists(atPath: directory.appendingPathComponent("blobs/" + $0.blob).path)
        }
    }
    items = Array(valid.prefix(10))
    try Self.persist(items, directory: directory)
    Self.cleanup(items, directory: directory)
  }

  /// Persists all originals before committing the index. The caller owns thumbnail
  /// rendering (PNG, longest edge 160pt @2x); Core never substitutes it for originals.
  public func add(
    kind: ClipItem.Kind, createdAt: Date = Date(), sourceBundleID: String? = nil,
    preview: String, representations: [ClipboardPayload], thumbnail: Data? = nil
  ) throws -> AddResult {
    guard !representations.isEmpty else { throw StoreError.emptyRepresentations }
    let size = representations.reduce(0) { $0 + $1.data.count }
    if kind == .image && size > Self.imageByteLimit {
      onImageTooLarge()
      return .rejectedImageTooLarge
    }
    let hash = Self.hash(kind: kind, payloads: representations)
    if let index = items.firstIndex(where: { $0.contentHash == hash }) {
      var next = items
      var existing = next.remove(at: index)
      existing.createdAt = createdAt
      next.insert(existing, at: 0)
      try Self.persist(next, directory: directory)
      items = next
      return .duplicate(existing)
    }
    let id = UUID()
    var written: [URL] = []
    do {
      var stored: [Representation] = []
      for (index, payload) in representations.enumerated() {
        let name = "\(id)-\(index).blob"
        let path = directory.appendingPathComponent("blobs/" + name)
        try payload.data.write(to: path, options: .atomic)
        written.append(path)
        stored.append(Representation(type: payload.type, blob: name))
      }
      if let thumbnail {
        let path = directory.appendingPathComponent("thumbs/\(id).png")
        try thumbnail.write(to: path, options: .atomic)
        written.append(path)
      }
      let summary =
        kind == .text
        ? String(
          preview.components(separatedBy: .newlines).prefix(2).joined(separator: "\n").prefix(200))
        : preview
      let item = ClipItem(
        id: id, kind: kind, createdAt: createdAt, sourceBundleID: sourceBundleID,
        preview: summary, representations: stored, contentHash: hash, byteSize: size)
      let next = Array(([item] + items).prefix(10))
      try Self.persist(next, directory: directory)
      items = next
      Self.cleanup(next, directory: directory)
      return .inserted(item)
    } catch {
      for path in written { try? FileManager.default.removeItem(at: path) }
      throw error
    }
  }

  public func payloads(for id: UUID) throws -> [ClipboardPayload] {
    guard let item = items.first(where: { $0.id == id }) else { throw StoreError.unknownItem }
    return try item.representations.map {
      ClipboardPayload(
        type: $0.type,
        data: try Data(contentsOf: directory.appendingPathComponent("blobs/" + $0.blob)))
    }
  }

  private static func safeBlob(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
  }

  private static func readIndex(_ path: URL) -> ClipboardIndex? {
    guard let data = try? Data(contentsOf: path),
      let index = try? JSONDecoder().decode(ClipboardIndex.self, from: data), index.version == 1
    else { return nil }
    return index
  }

  private static func persist(_ items: [ClipItem], directory: URL) throws {
    let fm = FileManager.default
    let main = directory.appendingPathComponent("index.json")
    let temp = directory.appendingPathComponent("index.json.tmp")
    let data = try JSONEncoder().encode(ClipboardIndex(items: items))
    try data.write(to: temp)
    if fm.fileExists(atPath: main.path) {
      _ = try fm.replaceItemAt(main, withItemAt: temp)
    } else {
      try fm.moveItem(at: temp, to: main)
    }
  }

  private static func cleanup(_ items: [ClipItem], directory: URL) {
    let blobs = Set(items.flatMap { $0.representations.map(\.blob) })
    let thumbs = Set(items.map { "\($0.id).png" })
    for (folder, kept) in [("blobs", blobs), ("thumbs", thumbs)] {
      let parent = directory.appendingPathComponent(folder)
      for path
        in (try? FileManager.default.contentsOfDirectory(
          at: parent, includingPropertiesForKeys: nil)) ?? []
      {
        if !kept.contains(path.lastPathComponent) { try? FileManager.default.removeItem(at: path) }
      }
    }
  }

  private static func hash(kind: ClipItem.Kind, payloads: [ClipboardPayload]) -> String {
    var hash = SHA256()
    func feed(_ data: Data) {
      var length = UInt64(data.count).bigEndian
      withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
      hash.update(data: data)
    }
    feed(Data(kind.rawValue.utf8))
    for payload in payloads {
      feed(Data(payload.type.utf8))
      feed(payload.data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
