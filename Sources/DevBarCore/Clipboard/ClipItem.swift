import Foundation

public struct ClipItem: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public var kind: Kind
  public var createdAt: Date
  public var sourceBundleID: String?
  public var preview: String
  public var representations: [Representation]
  public var contentHash: String
  public var byteSize: Int

  public enum Kind: String, Codable, Sendable { case text, image, files }
}

public struct Representation: Codable, Sendable, Equatable {
  public var type: String
  public var blob: String
}

/// Raw original bytes. Repeated types (e.g. multiple file URLs) retain their order.
public struct ClipboardPayload: Sendable, Equatable {
  public let type: String
  public let data: Data

  public init(type: String, data: Data) {
    self.type = type
    self.data = data
  }
}

struct ClipboardIndex: Codable {
  var version = 1
  var items: [ClipItem]
}
