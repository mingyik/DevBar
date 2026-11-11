import AppKit
import Testing

@testable import DevBar

@Test @MainActor func previewImageLimitsApplyAfterDoublingDimensions() {
  #expect(PreviewImage.dimensions(width: 8192, height: 100)?.0 == 16384)
  #expect(PreviewImage.dimensions(width: 8192.1, height: 100) == nil)
  #expect(PreviewImage.dimensions(width: 4001, height: 4000) == nil)
  #expect(PreviewImage.dimensions(width: .greatestFiniteMagnitude, height: 10) == nil)
  #expect(PreviewImage.dimensions(width: .infinity, height: 10) == nil)
  #expect(PreviewImage.dimensions(width: 1, height: 0) == nil)
  #expect(PreviewImage.snapshotPointWidth(pixels: 720, scale: 2) == 360)
  #expect(PreviewImage.snapshotPointWidth(pixels: 720, scale: 1) == 720)
}

@Test @MainActor func previewImageFileNameFollowsScreenshotConvention() {
  let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
  let date = Date(timeIntervalSince1970: 1_762_000_000)
  var taken = Set<String>()
  let first = PreviewImage.destination(directory: directory, now: date) { taken.contains($0) }
  taken.insert(first.path)
  let second = PreviewImage.destination(directory: directory, now: date) { taken.contains($0) }
  #expect(first.lastPathComponent.hasPrefix("DevBar 截图 "))
  #expect(first.pathExtension == "png")
  #expect(!first.lastPathComponent.contains(".SSS"))
  #expect(second.lastPathComponent.contains(" (2)"))
}

@Test @MainActor func previewImageCapturesContentBelowASmallViewport() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let exporter = PreviewImage()
  exporter.writesClipboard = false
  let html = """
    <div class="snapshot-root" style="width:180px">
      <div style="height:30px;background:CanvasText"></div>
      <div style="height:700px"></div>
      <div style="height:30px;background:CanvasText"></div>
    </div>
    """
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 180, height: 100), styleMask: .borderless,
    backing: .buffered, defer: false)
  window.orderBack(nil)
  defer { window.orderOut(nil) }
  let reply = await exporter.export(
    page: "json", width: 180, height: 760, html: html, css: "", theme: "light", background: "",
    directory: directory, host: window.contentView)
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: String])
  let path = try #require(object["path"])
  let data = try Data(contentsOf: URL(fileURLWithPath: path))
  let bitmap = try #require(NSBitmapImageRep(data: data))
  #expect(bitmap.pixelsWide == 360)
  #expect(bitmap.pixelsHigh == 1520)
  let top = try #require(bitmap.colorAt(x: 8, y: 8)?.usingColorSpace(.sRGB))
  let middle = try #require(
    bitmap.colorAt(x: 8, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
  let bottom = try #require(
    bitmap.colorAt(x: 8, y: bitmap.pixelsHigh - 8)?.usingColorSpace(.sRGB))
  #expect(abs(top.redComponent - bottom.redComponent) < 0.08)
  #expect(abs(top.greenComponent - bottom.greenComponent) < 0.08)
  #expect(abs(top.blueComponent - bottom.blueComponent) < 0.08)
  #expect(abs(top.redComponent - middle.redComponent) > 0.2)
}

@Test @MainActor func previewImageCapturesCompositedDocumentFooterBeyondViewport() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let exporter = PreviewImage()
  exporter.writesClipboard = false
  let html = """
    <div class="snapshot-root prose" style="width:180px">
      <div style="height:30px;background:CanvasText"></div>
      <div style="height:700px"></div>
      <div style="height:30px;background:CanvasText"></div>
    </div>
    """
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 180, height: 100), styleMask: .borderless,
    backing: .buffered, defer: false)
  window.orderBack(nil)
  defer { window.orderOut(nil) }
  let reply = await exporter.export(
    page: "json", width: 180, height: 760, html: html,
    css:
      "html,body{height:100%}body{display:flex}.prose{container-type:inline-size;transform:translateZ(0)}",
    theme: "light", background: "",
    directory: directory, host: window.contentView)
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: String])
  let path = try #require(object["path"])
  let data = try Data(contentsOf: URL(fileURLWithPath: path))
  let bitmap = try #require(NSBitmapImageRep(data: data))
  #expect(bitmap.pixelsWide == 360)
  #expect(bitmap.pixelsHigh == 1520)
  let top = try #require(bitmap.colorAt(x: 8, y: 8)?.usingColorSpace(.sRGB))
  let middle = try #require(
    bitmap.colorAt(x: 8, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
  let bottom = try #require(
    bitmap.colorAt(x: 8, y: bitmap.pixelsHigh - 8)?.usingColorSpace(.sRGB))
  #expect(abs(top.redComponent - bottom.redComponent) < 0.08)
  #expect(abs(top.greenComponent - bottom.greenComponent) < 0.08)
  #expect(abs(top.blueComponent - bottom.blueComponent) < 0.08)
  #expect(abs(top.redComponent - middle.redComponent) > 0.2)
}
