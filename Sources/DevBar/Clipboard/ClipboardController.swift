import AppKit
import DevBarCore
import Observation
import Synchronization

@MainActor @Observable
final class ClipboardController {
  let monitor: ClipboardMonitor
  let hud: ClipboardHUD
  private(set) var items: [ClipItem] = []
  private(set) var originals: [UUID: [ClipboardPayload]] = [:]
  private(set) var thumbnails: [UUID: NSImage] = [:]
  private(set) var cycler = ClipboardCycler()
  var focusedIndex = 0
  var copiedID: UUID?
  var message = ""
  private var store: ClipboardStore?
  private var copyFeedback: Task<Void, Never>?
  private var reloadGeneration = 0
  var currentIndex: Int { cycler.currentIndex }

  init(
    theme: ThemeManager, directory: URL? = nil,
    reader: any PasteboardReading = SystemPasteboardReader(), startMonitoring: Bool = true
  ) {
    monitor = ClipboardMonitor(reader: reader)
    hud = ClipboardHUD(theme: theme)
    do {
      let root = directory ?? URL.applicationSupportDirectory.appending(path: "DevBar/clipboard")
      let corrupt = Mutex(false)
      store = try ClipboardStore(
        directory: root, onCorruptHistory: { corrupt.withLock { $0 = true } })
      if corrupt.withLock({ $0 }) { message = Strings.historyRestarted }
    } catch { message = Strings.historyReadFailed }
    monitor.onCapture = { [weak self] capture, source in await self?.record(capture, source: source)
    }
    Task { [weak self] in
      await self?.reload()
      if startMonitoring { self?.monitor.start() }
    }
  }

  func record(_ capture: ClipboardCapture, source: String?) async {
    guard let store else { return }
    do {
      let result = try await store.add(
        kind: capture.kind, sourceBundleID: source,
        preview: capture.preview, representations: capture.payloads, thumbnail: capture.thumbnail)
      if result == .rejectedImageTooLarge {
        message = Strings.imageTooLarge
        return
      }
      await reload()
      cycler.reset()
      focusedIndex = 0
    } catch { message = Strings.historyWriteFailed }
  }

  func reload() async {
    guard let store else { return }
    reloadGeneration += 1
    let generation = reloadGeneration
    let updated = await store.items
    var payloads: [UUID: [ClipboardPayload]] = [:]
    var images: [UUID: NSImage] = [:]
    for item in updated {
      payloads[item.id] = try? await store.payloads(for: item.id)
      if item.kind == .image,
        let capture = ClipboardCapture(payloads: payloads[item.id] ?? []),
        let data = capture.thumbnail
      {
        images[item.id] = NSImage(data: data)
      }
    }
    guard generation == reloadGeneration else { return }
    items = updated
    originals = payloads
    thumbnails = images
    cycler.select(cycler.currentIndex, count: items.count)
    focusedIndex = min(focusedIndex, max(items.count - 1, 0))
  }

  func select(_ index: Int, board: NSPasteboard = .general) {
    guard items.indices.contains(index), let payloads = originals[items[index].id] else { return }
    let entries = Self.pasteboardItems(payloads: payloads)
    board.clearContents()
    guard board.writeObjects(entries) else {
      message = Strings.historyWriteFailed
      return
    }
    if board.name == .general { monitor.markSelfWrite(board.changeCount) }
    cycler.select(index, count: items.count)
    focusedIndex = index
    copiedID = items[index].id
    copyFeedback?.cancel()
    copyFeedback = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(800))
      guard !Task.isCancelled else { return }
      self?.copiedID = nil
    }
  }

  static func pasteboardItems(payloads: [ClipboardPayload]) -> [NSPasteboardItem] {
    let files = payloads.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
    if !files.isEmpty {
      return files.map { payload in
        let item = NSPasteboardItem()
        item.setData(payload.data, forType: .fileURL)
        return item
      }
    }
    let item = NSPasteboardItem()
    for payload in payloads { item.setData(payload.data, forType: .init(payload.type)) }
    return payloads.isEmpty ? [] : [item]
  }

  func cycle(older: Bool, board: NSPasteboard = .general) {
    guard !items.isEmpty else { return }
    let boundary = cycler.move(older: older, count: items.count)
    select(cycler.currentIndex, board: board)
    let item = items[cycler.currentIndex]
    hud.show(
      index: cycler.currentIndex, count: items.count, preview: item.preview,
      thumbnail: thumbnails[item.id], boundary: boundary)
  }

  func handleKey(_ code: UInt16) -> Bool {
    switch code {
    case 125: focusedIndex = min(focusedIndex + 1, max(items.count - 1, 0))
    case 126: focusedIndex = max(focusedIndex - 1, 0)
    case 36: select(focusedIndex)
    default: return false
    }
    return true
  }

  func remove(_ id: UUID) async {
    guard let store else { return }
    let selected = items.indices.contains(currentIndex) ? items[currentIndex].id : nil
    do {
      try await store.remove(id)
      await reload()
      if let index = items.firstIndex(where: { $0.id == selected }) {
        cycler.select(index, count: items.count)
      }
    } catch { message = Strings.historyWriteFailed }
  }

  func clear() async {
    do {
      try await store?.clear()
      await reload()
      cycler.reset()
    } catch { message = Strings.historyWriteFailed }
  }
}
