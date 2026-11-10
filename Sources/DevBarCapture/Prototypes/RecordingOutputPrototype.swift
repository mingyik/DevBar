import AVFoundation
import AppKit
import ScreenCaptureKit

public struct RecordingProbeReport: Sendable {
  public let events: [String]
  public let finished: Bool
  public let failed: Bool
  public let timedOut: Bool
  public let playable: Bool
  public let duration: Double
  public let bytes: Int
  public let videoTracks: Int
  public let decodedFirstFrame: Bool
}

/// V5 spike only. No app state machine, microphone, history, or permanent settings.
@MainActor
public final class RecordingOutputPrototype: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
  private var stream: SCStream?
  private var output: SCRecordingOutput?
  private var events: [String] = []
  private var finished = false
  private var failed = false
  private var interrupted = false
  private var used = false

  public func record(
    displayID: CGDirectDisplayID, seconds: Double = 10, outputURL: URL
  ) async throws -> RecordingProbeReport {
    guard !used else { throw CapturePrototypeError.alreadyRunning }
    guard seconds.isFinite, seconds > 0, seconds <= 60 else {
      throw CapturePrototypeError.invalidRegion
    }
    used = true
    events = []
    finished = false
    failed = false
    interrupted = false
    defer {
      stream = nil
      output = nil
    }
    guard CGPreflightScreenCaptureAccess() else {
      throw CapturePrototypeError.screenPermissionDenied
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID })
    else { throw CapturePrototypeError.displayUnavailable }
    let own = content.windows.filter {
      $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
    }
    let filter = SCContentFilter(display: display, excludingWindows: own)
    let configuration = SCStreamConfiguration()
    configuration.width = Int(CGDisplayPixelsWide(displayID)) / 2 * 2
    configuration.height = Int(CGDisplayPixelsHigh(displayID)) / 2 * 2
    configuration.showsCursor = true
    configuration.capturesAudio = false
    configuration.captureMicrophone = false
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    let recording = SCRecordingOutputConfiguration()
    recording.outputURL = outputURL
    recording.outputFileType = .mov
    recording.videoCodecType = .h264
    let output = SCRecordingOutput(configuration: recording, delegate: self)
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    self.stream = stream
    self.output = output
    try stream.addRecordingOutput(output)
    do {
      events.append("startCapture_requested")
      try await stream.startCapture()
      events.append("startCapture_returned")
      let clock = ContinuousClock()
      let stopAt = clock.now.advanced(by: .seconds(seconds))
      while clock.now < stopAt, !finished, !failed, !interrupted {
        try await Task.sleep(for: .milliseconds(50))
      }
      events.append("stopCapture_requested")
      do {
        try await stream.stopCapture()
        events.append("stopCapture_returned")
      } catch {
        let code = (error as NSError).code
        events.append("stopCapture_error_\(code)")
      }
      // stopCapture returning is NOT a file completion signal.
      let deadline = clock.now.advanced(by: .seconds(10))
      while !finished, !failed, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      if !finished && !failed { events.append("terminal_callback_timeout") }
    } catch {
      try? await stream.stopCapture()
      throw error
    }
    let asset = AVURLAsset(url: outputURL)
    let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
    let playable = (try? await asset.load(.isPlayable)) ?? false
    let tracks = (try? await asset.loadTracks(withMediaType: .video).count) ?? 0
    let generator = AVAssetImageGenerator(asset: asset)
    let decodedFirstFrame = (try? await generator.image(at: .zero)) != nil
    let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
    let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    return RecordingProbeReport(
      events: events, finished: finished, failed: failed, timedOut: !finished && !failed,
      playable: playable && duration.isFinite && duration > 0 && tracks > 0 && decodedFirstFrame,
      duration: duration.isFinite ? duration : 0, bytes: bytes, videoTracks: tracks,
      decodedFirstFrame: decodedFirstFrame)
  }

  public nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
    Task { @MainActor [weak self] in self?.events.append("didStartRecording") }
  }

  public nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    Task { @MainActor [weak self] in
      self?.events.append("didFinishRecording")
      self?.finished = true
    }
  }

  public nonisolated func recordingOutput(
    _ recordingOutput: SCRecordingOutput, didFailWithError error: any Error
  ) {
    let code = (error as NSError).code
    Task { @MainActor [weak self] in
      self?.events.append("didFailRecording_\(code)")
      self?.failed = true
    }
  }

  public nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
    let code = (error as NSError).code
    Task { @MainActor [weak self] in
      self?.events.append("streamInterrupted_\(code)")
      self?.interrupted = true
    }
  }
}
