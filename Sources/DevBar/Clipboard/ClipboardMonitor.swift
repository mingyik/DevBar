import AppKit
import Observation

@MainActor @Observable
final class ClipboardMonitor {
  private let reader: any PasteboardReading
  private var timer: Task<Void, Never>?
  private var observedCount: Int?
  private var lastSelfWrite: Int?
  private(set) var access: PasteboardMetadata.Access = .ask
  private(set) var pending = false
  private(set) var waiting = false
  private(set) var busy = false
  var suspended = false
  var onMemoryRejected: (() -> Void)?
  var onCapture: ((ClipboardCapture, String?) async -> Void)?

  init(reader: any PasteboardReading = SystemPasteboardReader()) { self.reader = reader }

  func start() {
    guard timer == nil else { return }
    timer = Task { [weak self] in
      while !Task.isCancelled {
        await self?.poll()
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }
  func markSelfWrite(_ count: Int) {
    lastSelfWrite = count
    observedCount = count
    pending = false
  }

  func poll(userInitiated: Bool = false) async {
    guard !busy, !suspended else { return }
    let metadata = reader.metadata()
    access = metadata.access
    guard userInitiated || metadata.count != observedCount || (pending && access == .allow) else {
      return
    }
    observedCount = metadata.count
    // Read types before asking for access, including for explicit reads.
    guard metadata.count != lastSelfWrite, !metadata.concealed else {
      pending = false
      return
    }
    guard access != .deny else {
      pending = false
      return
    }
    guard access == .allow || userInitiated else {
      pending = true
      return
    }
    guard MemoryBudget.allows(bytes: 0) else {
      onMemoryRejected?()
      return
    }
    busy = true
    waiting = access == .ask
    pending = false
    let reader = reader
    let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let expectedCount = metadata.count
    let explicit = userInitiated
    let capture = await Task.detached(priority: .utility) { () -> ClipboardCapture? in
      let before = reader.metadata()
      guard before.count == expectedCount, !before.concealed,
        before.access != .deny, before.access == .allow || explicit
      else { return nil }
      let payloads = reader.read()
      guard reader.metadata().count == expectedCount else { return nil }
      return ClipboardCapture(payloads: payloads)
    }.value
    // A UI write while the detached read was in flight must also invalidate it.
    if reader.metadata().count == expectedCount, let capture {
      guard MemoryBudget.allows(bytes: capture.payloads.reduce(0) { $0 + $1.data.count }) else {
        busy = false
        waiting = false
        onMemoryRejected?()
        return
      }
      await onCapture?(capture, source)
    }
    busy = false
    waiting = false
    access = reader.metadata().access
  }
}
