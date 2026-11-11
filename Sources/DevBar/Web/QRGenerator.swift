import AppKit
import CoreImage

@MainActor enum QRGenerator {
  static let byteLimit = 2331
  static func png(text: String) -> Data? {
    guard text.utf8.count <= byteLimit, let filter = CIFilter(name: "CIQRCodeGenerator") else {
      return nil
    }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage else { return nil }
    // Core Image already includes one quiet module; add three on each edge.
    let extent = image.extent.insetBy(dx: -3, dy: -3)
    let background = CIImage(
      color: CIColor(cgColor: NSColor(DesignTokens.qrBackground(.light)).cgColor))
    let composed = image.composited(over: background).cropped(to: extent)
    let context = CIContext()
    guard let cgImage = context.createCGImage(composed, from: composed.extent) else { return nil }
    let scale = max(1, (560 / composed.extent.width).rounded())
    let pixels = Int(composed.extent.width * scale)
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .none
    NSGraphicsContext.current?.cgContext.draw(
      cgImage, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
  }
  static func reply(text: String) -> String {
    guard text.utf8.count <= byteLimit else {
      return #"{"status":"tooLarge","bytes":\#(text.utf8.count),"limit":2331}"#
    }
    guard let data = png(text: text) else { return #"{"status":"failed"}"# }
    return BridgeJSON.object([
      "status": .string("shown"), "pngBase64": .string(data.base64EncodedString()),
    ]).canonical()
  }
}
