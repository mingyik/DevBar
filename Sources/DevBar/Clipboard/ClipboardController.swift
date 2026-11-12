import AppKit
@preconcurrency import ApplicationServices
import DevBarCore
import Observation
import SwiftUI
import Synchronization

@MainActor @Observable
final class ClipboardController {
  private static let directPastePromptKey = "directPasteAccessibilityPromptRequested"
  let monitor: ClipboardMonitor
  let card: ClipboardCard
  private(set) var items: [ClipItem] = []
  private(set) var originals: [UUID: [ClipboardPayload]] = [:]
  private(set) var previewTexts: [UUID: String] = [:]
  private(set) var thumbnails: [UUID: NSImage] = [:]
  private(set) var cycler = ClipboardCycler()
  var detailID: UUID?
  private(set) var hoverID: UUID?
  private(set) var isDragging = false
  var onHoverPreview: ((UUID?) -> Void)?
  var focusedIndex = 0
  var copiedID: UUID?
  var message = ""
  private var store: ClipboardStore?
  private let defaults: UserDefaults
  private var copyFeedback: Task<Void, Never>?
  private var reloadGeneration = 0
  private(set) var lastCycleMilliseconds = 0.0
  private var pasteTarget: pid_t?
  private(set) var isDirectPasteAuthorized = false
  var currentIndex: Int { cycler.currentIndex }

  init(
    theme: ThemeManager, directory: URL? = nil,
    reader: any PasteboardReading = SystemPasteboardReader(), startMonitoring: Bool = true,
    defaults: UserDefaults = .standard
  ) {
    self.defaults = defaults
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
    card.onDismiss = { [weak self] in self?.pasteTarget = nil }
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
    let previewPayloads = payloads
    let plainTextType = NSPasteboard.PasteboardType.string.rawValue
    let texts = await Task.detached(priority: .utility) {
      var result: [UUID: String] = [:]
      for (id, entries) in previewPayloads {
        if let payload = entries.first(where: { $0.type == plainTextType }),
          let text = String(data: payload.data, encoding: .utf8)
        {
          result[id] = text
        }
      }
      return result
    }.value
    guard generation == reloadGeneration else { return }
    if !updated.contains(where: { $0.id == detailID }) { detailID = nil }
    if let hoverID, !updated.contains(where: { $0.id == hoverID }) {
      self.hoverID = nil
      onHoverPreview?(nil)
    }
    items = updated
    originals = payloads
    previewTexts = texts
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
    let textMode = item.kind == .text
    let subtitle: String
    if textMode {
      subtitle = ""
    } else if item.kind == .files {
      subtitle = DragCard.fileSubtitle(names: files)
    } else {
      subtitle = item.preview
    }
    let footer = textMode ? DragCard.textSubtitle(characters: source.count) : nil
    let color = ClipboardColor.parse(item.preview)
    let swatch = color.map {
      NSColor(  // devbar:allow-color
        srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
    }
    let title: String
    if item.kind == .image {
      title = ""
    } else if textMode {
      title = DragCard.previewText(source)
    } else {
      title = DragCard.firstLine(source)
    }
    card.show(
      index: cycler.currentIndex, count: items.count, title: title,
      subtitle: subtitle, thumbnail: thumbnails[item.id], swatch: swatch, fileCount: files.count,
      boundary: boundary, footer: footer, multilineContent: textMode)
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
    let selectedPayloads =
      items.indices.contains(cycler.currentIndex)
      ? originals[items[cycler.currentIndex].id] ?? [] : []
    let isFile = selectedPayloads.contains {
      $0.type == NSPasteboard.PasteboardType.fileURL.rawValue
    }
    let isTrusted = AXIsProcessTrusted()
    isDirectPasteAuthorized = isTrusted
    let initialFrontmost = NSWorkspace.shared.frontmostApplication
    let targetIsFinder = initialFrontmost?.bundleIdentifier == "com.apple.finder"
    let role =
      isTrusted && isFile && !targetIsFinder
        && initialFrontmost?.processIdentifier == target
      ? focusedRole(of: target) : nil
    let frontmost = NSWorkspace.shared.frontmostApplication
    let action = DirectPasteDecision.action(
      for: DirectPasteInput(
        capturedPID: target,
        currentPID: frontmost?.processIdentifier,
        ownPID: ProcessInfo.processInfo.processIdentifier,
        isAuthorized: isTrusted,
        selectedItemIsFile: isFile,
        focusedRole: role,
        targetIsFinder: targetIsFinder
      ))
    if action == .authorizationRequired {
      card.showAuthorizationNotice(
        title: Strings.directPasteCopiedNotice, subtitle: Strings.directPasteAuthorizationHint)
      if DirectPastePromptPolicy.shouldRequest(
        isTrusted: isTrusted,
        wasRequested: defaults.bool(forKey: Self.directPastePromptKey))
      {
        defaults.set(true, forKey: Self.directPastePromptKey)
        let options =
          [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
      }
      return
    }
    guard action != .none,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == target
    else { return }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
    else { return }
    if action == .filePaths {
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
        let paths = Self.filePaths(payloads: selectedPayloads)
      else { return }
      let board = NSPasteboard.general
      board.clearContents()
      guard board.setString(paths, forType: .string) else { return }
      monitor.markSelfWrite(board.changeCount)
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.postToPid(target)
    up.postToPid(target)
  }

  func refreshDirectPasteAuthorization() {
    isDirectPasteAuthorized = AXIsProcessTrusted()
  }

  func openAccessibilitySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    else { return }
    NSWorkspace.shared.open(url)
  }

  func setDragging(_ active: Bool) {
    isDragging = active
    if active {
      hoverID = nil
      onHoverPreview?(nil)
    }
  }

  func setHovered(_ id: UUID, inside: Bool) {
    if inside {
      guard !isDragging, hoverID != id else { return }
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
      reloadGeneration += 1
      let updated = await store.items
      if detailID == id { detailID = nil }
      if hoverID == id {
        hoverID = nil
        onHoverPreview?(nil)
      }
      if copiedID == id { copiedID = nil }
      originals[id] = nil
      previewTexts[id] = nil
      thumbnails[id] = nil
      withAnimation(
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18)
      ) {
        items = updated
      }
      let selectedIndex =
        selected.flatMap { id in
          updated.firstIndex { $0.id == id }
        } ?? min(cycler.currentIndex, max(updated.count - 1, 0))
      cycler.select(selectedIndex, count: updated.count)
      focusedIndex = min(focusedIndex, max(updated.count - 1, 0))
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
