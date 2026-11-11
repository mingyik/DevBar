import Foundation
import Testing

@testable import DevBarCore

@Test func fileRouteUsesExtensionAndOnlyLeadingJSONMarker() {
  for name in ["a.json", "a.JSONC", "a.geojson"] {
    #expect(FileRoute.route(fileName: name, sniff: nil) == .tools)
  }
  #expect(FileRoute.route(fileName: "a.md", sniff: "{}") == .doc(.markdown))
  #expect(FileRoute.route(fileName: "a.mmd", sniff: nil) == .doc(.mermaid))
  #expect(FileRoute.route(fileName: "a.txt", sniff: " \n [1]") == .tools)
  #expect(FileRoute.route(fileName: "LICENSE", sniff: "hello") == .doc(nil))
  #expect(FileRoute.route(fileName: "a.txt", sniff: "hello {}") == .doc(nil))
  #expect(FileRoute.route(fileName: "a.png", sniff: "{}") == .rejected(.unsupportedType))
}
@Test func fileReaderRejectsBeforeReadingAndPreservesUTF8() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let text = directory.appending(path: "a.txt")
  try Data([0xEF, 0xBB, 0xBF] + Array("{\"中文\":1}".utf8)).write(to: text)
  let result = try FileDropReader.read([text, text]).get()
  #expect(result.text == "{\"中文\":1}")
  #expect(result.route == .tools)
  #expect(result.multiple)
  #expect(FileDropReader.read([directory]) == .failure(.notRegularFile))
  try Data([0xD6, 0xD0]).write(to: text)
  #expect(FileDropReader.read([text]) == .failure(.notUTF8))
  let large = directory.appending(path: "large.json")
  FileManager.default.createFile(atPath: large.path, contents: nil)
  let handle = try FileHandle(forWritingTo: large)
  try handle.truncate(atOffset: 10 * 1024 * 1024 + 1)
  try handle.close()
  #expect(FileDropReader.read([large]) == .failure(.tooLarge))
  #expect(FileDropReader.read([]) == .failure(.noFile))
}
@Test func mermaidImportPreservesEveryUTF8ByteIncludingBOMAndMixedLineEndings() throws {
  let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).mmd")
  let bytes = Data([0xEF, 0xBB, 0xBF] + Array("\r\nflowchart LR\r\n A --> B\n".utf8))
  defer { try? FileManager.default.removeItem(at: file) }
  try bytes.write(to: file)
  let imported = try FileDropReader.read([file]).get()
  #expect(Data(imported.text.utf8) == bytes)
  #expect(imported.route == .doc(.mermaid))
}
