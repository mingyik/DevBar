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
          } else if args.contains("--record") || args.contains("--record-interrupt") {
            try await recording(seconds: args.contains("--record-interrupt") ? 60 : 10)
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

    private func recording(seconds: Double) async throws {
      guard let screen = NSScreen.main,
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      else { throw CapturePrototypeError.displayUnavailable }
      let output = URL(fileURLWithPath: "/tmp/devbar-v5-\(UUID().uuidString).mov")
      print("V5 recording_seconds=\(seconds) output=\(output.path)")
      fflush(stdout)
      let report = try await RecordingOutputPrototype().record(
        displayID: id.uint32Value, seconds: seconds, outputURL: output)
      print("V5 events=\(report.events.joined(separator: ","))")
      print(
        "V5 finished=\(report.finished) failed=\(report.failed) timeout=\(report.timedOut) playable=\(report.playable) duration=\(report.duration) bytes=\(report.bytes) tracks=\(report.videoTracks) decoded=\(report.decodedFirstFrame)"
      )
      if !report.playable || report.timedOut { exit(2) }
    }

    private func screenshot(interactive: Bool) async throws {
      print(
        "screen_permission=\(CGPreflightScreenCaptureAccess()) screens=\(NSScreen.screens.count)")
      let region: CaptureRegion
      let image: CGImage
      if interactive {
        (region, image) = try await SelectionOverlayPrototype().selectImage()
      } else {
        guard let screen = NSScreen.main,
          let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { throw CapturePrototypeError.displayUnavailable }
        let sample = CGRect(
          x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 320, height: 240)
        region = try CaptureRegion(
          displayID: id.uint32Value, globalRect: sample,
          screenFrame: screen.frame, scale: screen.backingScaleFactor)
        image = try await RegionCapturePrototype.image(for: region)
      }
      let output = URL(fileURLWithPath: "/tmp/devbar-v4-\(UUID().uuidString).png")
      guard
        let destination = CGImageDestinationCreateWithURL(
          output as CFURL, UTType.png.identifier as CFString, 1, nil)
      else { throw CapturePrototypeError.noImage }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { throw CapturePrototypeError.noImage }
      print(
        "V4 display=\(region.displayID) scale=\(region.scale) rect=\(region.rectInPoints) pixels=\(image.width)x\(image.height) output=\(output.path)"
      )
    }
  }
#endif
