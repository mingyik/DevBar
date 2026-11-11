import AppKit
import CoreImage
import Testing

@testable import DevBar

@Test @MainActor func qrReturnsPNGWithoutOpeningAWindowAndRoundTripsUTF8() throws {
  let before = NSApp?.windows.count ?? 0
  let data = try #require(QRGenerator.png(text: "DevBar 中文 😀"))
  let bitmap = try #require(NSBitmapImageRep(data: data))
  #expect(bitmap.pixelsWide == bitmap.pixelsHigh)
  let image = try #require(CIImage(data: data))
  let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil))
  let feature = try #require(detector.features(in: image).first as? CIQRCodeFeature)
  #expect(feature.messageString == "DevBar 中文 😀")
  #expect((NSApp?.windows.count ?? 0) == before)
  #expect(QRGenerator.png(text: String(repeating: "a", count: 2332)) == nil)
  #expect(QRGenerator.png(text: String(repeating: "a", count: 2331)) != nil)
  #expect(QRGenerator.png(text: String(repeating: "中", count: 778)) == nil)
}
