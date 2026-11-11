import AppKit
@preconcurrency import ApplicationServices
import DevBarCore
import Observation
import Synchronization

@MainActor @Observable
final class ClipboardController {
  let monitor: ClipboardMonitor
  let card: ClipboardCard
  private(set) var items: [ClipItem] = []
  private(set) var originals: [UUID: [ClipboardPayload]] = [:]
  private(set) var thumbnails: [UUID: NSImage] = [:]
  private(set) var cycler = ClipboardCycler()
  var detailID: UUID?
  private(set) var hoverID: UUID?
  var onHoverPreview: ((UUID?) -> Void)?
  var focusedIndex = 0
  var copiedID: UUID?
  var message = ""
  private var store: ClipboardStore?
  private var copyFeedback: Task<Void, Never>?
  private var reloadGeneration = 0
  private(set) var lastCycleMilliseconds = 0.0
  private var pasteTarget: pid_t?
  var currentIndex: Int { cycler.currentIndex }

  init(
    theme: ThemeManager, directory: URL? = nil,
    reader: any PasteboardReading = SystemPasteboardReader(), startMonitoring: Bool = true
  ) {
    monitor = ClipboardMonitor(reader: reader)
    card = ClipboardCard(theme: theme)
    do {
      let root = directory ?? URL.applicationSupportDirectory.appending(path: "DevBar/clipboard")
      let corrupt = Mutex(false)
      store = try ClipboardStore(
        directory: root, onCorruptHistory: { corrupt.withLock { $0 = true } })
      if corrupt.withLock({ $0 }) { message = Strings.historyRestarted }
    } catch { message = Strings.historyReadFailed }
    card.onMove = { [weak self] older in self?.cycle(older: older) }
    card.onConfirm = { [weak self] in self?.pasteSelection() }
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
      if payloads[item.id] == nil { message = Strings.historyReadFailed }
      if item.kind == .image, let data = try? await store.thumbnail(for: item.id) {
        images[item.id] = NSImage(data: data)
      }
    }
    guard generation == reloadGeneration else { return }
    if !updated.contains(where: { $0.id == detailID }) { detailID = nil }
    if let hoverID, !updated.contains(where: { $0.id == hoverID }) {
      self.hoverID = nil
      onHoverPreview?(nil)
    }
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
    if !card.panel.isVisible {
      pasteTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    let started = ContinuousClock.now
    let boundary = cycler.move(older: older, count: items.count)
    select(cycler.currentIndex, board: board)
    let item = items[cycler.currentIndex]
    let payloads = originals[item.id] ?? []
    let source =
      payloads.first { $0.type == NSPasteboard.PasteboardType.string.rawValue }.flatMap {
        String(data: $0.data, encoding: .utf8)
      } ?? item.preview
    let files = payloads.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
      .compactMap { String(data: $0.data, encoding: .utf8) }.compactMap(URL.init(string:)).map(
        \.lastPathComponent)
    let subtitle =
      item.kind == .text
      ? DragCard.textSubtitle(characters: source.count)
      : item.kind == .files ? DragCard.fileSubtitle(names: files) : item.preview
    let color = ClipboardColor.parse(item.preview)
    let swatch = color.map {
      NSColor(  // devbar:allow-color
        srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
    }
    card.show(
      index: cycler.currentIndex, count: items.count, title: DragCard.firstLine(source),
      subtitle: subtitle, thumbnail: thumbnails[item.id], swatch: swatch, fileCount: files.count,
      boundary: boundary)
    let elapsed = started.duration(to: .now).components
    lastCycleMilliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
  }

  nonisolated static func filePaths(payloads: [ClipboardPayload]) -> String? {
    let files = payloads.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
    guard !files.isEmpty else { return nil }
    var paths: [String] = []
    for file in files {
      guard let raw = String(data: file.data, encoding: .utf8),
        let url = URL(string: raw), url.isFileURL
      else { return nil }
      paths.append(url.path(percentEncoded: false))
    }
    return paths.joined(separator: "\n")
  }

  private func focusedRole(of target: pid_t) -> String? {
    let app = AXUIElementCreateApplication(target)
    AXUIElementSetMessagingTimeout(app, 0.3)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    let element = value as! AXUIElement
    var role: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
    else { return nil }
    return role as? String
  }

  private func pasteSelection() {
    guard let target = pasteTarget,
      target != ProcessInfo.processInfo.processIdentifier,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == target
    else { return }
    let options =
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else { return }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
    else { return }
    if items.indices.contains(cycler.currentIndex),
      let payloads = originals[items[cycler.currentIndex].id],
      payloads.contains(where: { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue })
    {
      guard let role = focusedRole(of: target),
        NSWorkspace.shared.frontmostApplication?.processIdentifier == target
      else { return }
      if ["AXTextField", "AXTextArea", "AXSearchField"].contains(role) {
        guard let paths = Self.filePaths(payloads: payloads) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(paths, forType: .string) else { return }
        monitor.markSelfWrite(board.changeCount)
      } else if NSRunningApplication(processIdentifier: target)?.bundleIdentifier
        != "com.apple.finder"
      {
        return
      }
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.postToPid(target)
    up.postToPid(target)
  }

  func setHovered(_ id: UUID, inside: Bool) {
    if inside {
      hoverID = id
      onHoverPreview?(id)
    } else if hoverID == id {
      hoverID = nil
      onHoverPreview?(nil)
    }
  }

  func showDetail(_ index: Int, board: NSPasteboard = .general) {
    guard items.indices.contains(index) else { return }
    select(index, board: board)
    detailID = items[index].id
  }

  func handleKey(_ code: UInt16, board: NSPasteboard = .general) -> Bool {
    guard detailID == nil else { return false }
    switch code {
    case 125:
      guard !items.isEmpty else { return false }
      select((focusedIndex + 1) % items.count, board: board)
    case 126:
      guard !items.isEmpty else { return false }
      select((focusedIndex + items.count - 1) % items.count, board: board)
    case 36: select(focusedIndex, board: board)
    case 51:
      guard items.indices.contains(focusedIndex) else { return false }
      let id = items[focusedIndex].id
      Task { await remove(id) }
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
