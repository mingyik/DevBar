import AppKit
import CoreImage

enum QRPanel {
  static func present(text: String) -> String {
    let bytes = text.utf8.count
    guard bytes <= 2331 else {
      return #"{"status":"tooLarge","bytes":\#(bytes),"limit":2331}"#
    }
    guard let data = text.data(using: .utf8),
      let filter = CIFilter(name: "CIQRCodeGenerator")
    else { return #"{"status":"tooLarge","bytes":\#(bytes),"limit":2331}"# }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else {
      return #"{"status":"tooLarge","bytes":\#(bytes),"limit":2331}"#
    }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 280, height: 320),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    panel.title = "二维码"
    let view = NSImageView(frame: NSRect(x: 20, y: 20, width: 240, height: 240))
    view.image = image
    panel.contentView = view
    panel.center()
    panel.orderFront(nil)
    return #"{"status":"shown"}"#
  }
}
