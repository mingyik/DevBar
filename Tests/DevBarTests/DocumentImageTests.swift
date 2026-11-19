import Foundation
import Testing

@testable import DevBar

@Test func documentImagesResolveRelativeToTheOpenedFile() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let folder = root.appendingPathComponent("notes")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let sample = try #require(
    Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l2sAAAAASUVORK5CYII="
    ))
  try sample.write(to: folder.appendingPathComponent("图 片.png"))
  try sample.write(to: root.appendingPathComponent("outside.png"))
  let document = folder.appendingPathComponent("README.md")

  #expect(
    await DocumentImage.load("%E5%9B%BE%20%E7%89%87.png", relativeTo: document)
      == "data:image/png;base64," + sample.base64EncodedString())
  #expect(await DocumentImage.load("../outside.png", relativeTo: document) == nil)
  #expect(await DocumentImage.load("missing.png", relativeTo: document) == nil)
}
