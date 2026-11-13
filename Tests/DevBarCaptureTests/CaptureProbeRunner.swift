// Compile only for the standalone verification executable, never the app/test entry point.
#if DEVBAR_CAPTURE_PROBE
  import AppKit
  import ImageIO
  import UniformTypeIdentifiers

  @main
  @MainActor
  final class CaptureProbeRunner: NSObject, NSApplicationDelegate {
    static func main() {
      let app = NSApplication.shared
      app.setActivationPolicy(.accessory)
      let delegate = CaptureProbeRunner()
      app.delegate = delegate
      withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
      Task { @MainActor in
        do {
          let args = CommandLine.arguments
          if args.contains("--request-permission") {
            print("permission=\(CGRequestScreenCaptureAccess())")
          } else {
            try await screenshot(interactive: args.contains("--interactive"))
          }
          fflush(stdout)
          NSApplication.shared.terminate(nil)
        } catch {
          // Only typed error/codes; never log screen or document content.
          let nsError = error as NSError
          print("probe_failed domain=\(nsError.domain) code=\(nsError.code)")
          fflush(stdout)
          exit(1)
        }
      }
    }

    private func screenshot(interactive: Bool) async throws {
      print(
        "screen_permission=\(CGPreflightScreenCaptureAccess()) screens=\(NSScreen.screens.count)")
      let region: CaptureRegion
      let image: CGImage
      if interactive {
        (region, image) = try await SelectionOverlay().selectImage()
      } else {
        guard let screen = NSScreen.main,
          let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { throw CaptureError.displayUnavailable }
        let sample = CGRect(
          x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 320, height: 240)
        region = try CaptureRegion(
          displayID: id.uint32Value, globalRect: sample,
          screenFrame: screen.frame, scale: screen.backingScaleFactor)
        guard let captured = await ScreenshotCaptureEngine.captureDisplayRegion(region: region)
        else {
          throw CaptureError.noImage
        }
        image = captured
      }
      let output = URL(fileURLWithPath: "/tmp/devbar-v4-\(UUID().uuidString).png")
      guard
        let destination = CGImageDestinationCreateWithURL(
          output as CFURL, UTType.png.identifier as CFString, 1, nil)
      else { throw CaptureError.noImage }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { throw CaptureError.noImage }
      print(
        "V4 display=\(region.displayID) scale=\(region.scale) rect=\(region.rectInPoints) pixels=\(image.width)x\(image.height) output=\(output.path)"
      )
    }
  }
#endif
