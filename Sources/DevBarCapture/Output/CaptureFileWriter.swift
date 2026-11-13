import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CaptureFileWriter {
  public enum OutputError: Error { case encodingFailed }

  public static func destination(
    directory: URL, scrolling: Bool, date: Date, exists: (URL) -> Bool
  ) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let name = "DevBar \(scrolling ? "长图" : "截图") \(formatter.string(from: date))"
    var candidate = directory.appending(path: name + ".png")
    var index = 2
    while exists(candidate) {
      candidate = directory.appending(path: "\(name) (\(index)).png")
      index += 1
    }
    return candidate
  }

  public static func encode(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil)
    else { throw OutputError.encodingFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw OutputError.encodingFailed }
    return data as Data
  }

  public static func save(_ image: CGImage, directory: URL, scrolling: Bool, date: Date = Date())
    throws -> (URL, Data)
  {
    let data = try encode(image)
    let file = destination(directory: directory, scrolling: scrolling, date: date) {
      FileManager.default.fileExists(atPath: $0.path)
    }
    try data.write(to: file, options: .withoutOverwriting)
    return (file, data)
  }
}
