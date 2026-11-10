import Foundation
import Testing

@testable import DevBarCapture

@Test @MainActor func recordingProbeRejectsInvalidDurationsBeforeScreenAccess() async {
  for seconds in [Double.zero, -1, .infinity, .nan, 61] {
    await #expect(throws: CapturePrototypeError.self) {
      try await RecordingOutputPrototype().record(
        displayID: 0, seconds: seconds,
        outputURL: URL(fileURLWithPath: "/tmp/devbar-invalid-duration-never-created.mov"))
    }
  }
}
