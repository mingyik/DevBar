import AppKit
import Observation

@MainActor @Observable
final class StorageSettings {
  private(set) var dataPath = DataLocations.root.path
  private(set) var capturePath = DataLocations.captures.path
  private(set) var busy = false
  var message = ""
  var saveState: (() async throws -> Void)?
  var relocate: ((URL) async throws -> Void)?
  var clipboard: ClipboardController?

  func chooseDataLocation() {
    guard !busy else { return }
    let picker = NSOpenPanel()
    picker.canChooseDirectories = true
    picker.canChooseFiles = false
    picker.canCreateDirectories = true
    picker.allowsMultipleSelection = false
    picker.directoryURL = DataLocations.root.deletingLastPathComponent()
    guard picker.runModal() == .OK, let selected = picker.url else { return }
    let destination = DataLocations.destination(in: selected)
    let old = DataLocations.root
    guard old.standardizedFileURL != destination.standardizedFileURL else { return }
    busy = true
    message = Strings.storageMoving
    clipboard?.monitor.suspended = true
    Task {
      defer {
        clipboard?.monitor.suspended = false
        busy = false
      }
      do {
        while clipboard?.monitor.busy == true { try await Task.sleep(for: .milliseconds(50)) }
        try await saveState?()
        guard let relocate else { throw DataLocations.LocationError.occupiedDestination }
        try await relocate(destination)
        do {
          try await clipboard?.reopenStorage()
        } catch {
          try await relocate(old)
          throw error
        }
        dataPath = destination.path
        message = Strings.storageMoved
      } catch {
        message = Strings.storageMoveFailed
      }
    }
  }

  func chooseCaptureLocation() {
    let picker = NSOpenPanel()
    picker.canChooseDirectories = true
    picker.canChooseFiles = false
    picker.canCreateDirectories = true
    picker.allowsMultipleSelection = false
    picker.directoryURL = DataLocations.captures
    guard picker.runModal() == .OK, let selected = picker.url else { return }
    UserDefaults.standard.set(selected.path, forKey: DataLocations.captureKey)
    capturePath = selected.path
  }
}
