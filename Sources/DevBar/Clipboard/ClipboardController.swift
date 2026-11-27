import AppKit
@preconcurrency import ApplicationServices
import DevBarCore
import Observation
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

@MainActor @Observable
final class ClipboardController {
  struct DisplayedCardSnapshot {
    let id: UUID
    let kind: ClipItem.Kind
    let payloads: [ClipboardPayload]
    let pasteboardChangeCount: Int
    let pasteboardName: NSPasteboard.Name
  }

  private var authorizationPrompt: DirectPasteAuthorizationPrompt?
  let monitor: ClipboardMonitor
  let card: ClipboardCard
  private(set) var historyLimit: Int
  private(set) var items: [ClipItem] = []
  private(set) var originals: [UUID: [ClipboardPayload]] = [:]
  private(set) var previewTexts: [UUID: String] = [:]
  private(set) var thumbnails: [UUID: NSImage] = [:]
  private(set) var cycler = ClipboardCycler()
  private(set) var needsVisualCacheReload = false
  private(set) var hoveredRowID: UUID?
  private(set) var hoverID: UUID?
  private(set) var isDragging = false
  var onHoverPreview: ((UUID?) -> Void)?
  var focusedIndex = 0 {
    didSet {
      guard !updatingFocusedIndex else { return }
      trackedFocusedID = items.indices.contains(focusedIndex) ? items[focusedIndex].id : nil
    }
  }
  private var trackedFocusedID: UUID?
  private var updatingFocusedIndex = false
  var copiedID: UUID?
  var message = ""
  private var store: ClipboardStore?
  private let defaults: UserDefaults
  private var copyFeedback: Task<Void, Never>?
  private var reloadGeneration = 0
  private var retainVisualCaches = true
  private var visualReloadTask: Task<Void, Never>?
  private(set) var lastCycleMilliseconds = 0.0
  private var pasteTarget: pid_t?
  @ObservationIgnored private(set) var displayedCardItem: DisplayedCardSnapshot?
  @ObservationIgnored var onReloadSuspended: (@MainActor () async -> Void)?
  private(set) var isDirectPasteAuthorized = false
  var currentIndex: Int { cycler.currentIndex }
  var focusedItemID: UUID? { items.indices.contains(focusedIndex) ? items[focusedIndex].id : nil }

  init(
    theme: ThemeManager, directory: URL? = nil,
    reader: any PasteboardReading = SystemPasteboardReader(), startMonitoring: Bool = true,
    defaults: UserDefaults = .standard
  ) {
    self.defaults = defaults
    historyLimit = min(30, max(3, defaults.object(forKey: "clipboardHistoryLimit") as? Int ?? 10))
    monitor = ClipboardMonitor(reader: reader)
    card = ClipboardCard(theme: theme)
    do {
      if directory == nil { try DataLocations.prepare(DataLocations.root) }
      let root = directory ?? DataLocations.root.appending(path: "Paste")
      let corrupt = Mutex(false)
      store = try ClipboardStore(
        directory: root, historyLimit: historyLimit,
        onCorruptHistory: { corrupt.withLock { $0 = true } })
      if corrupt.withLock({ $0 }) { message = Strings.historyRestarted }
    } catch { message = Strings.historyReadFailed }
    monitor.onMemoryRejected = { [weak self] in self?.message = Strings.insufficientMemory }
    card.onMove = { [weak self] older in self?.cycle(older: older) }
    card.onConfirm = { [weak self] in self?.pasteSelection() }
    card.onDismiss = { [weak self] in
      self?.pasteTarget = nil
      self?.displayedCardItem = nil
    }
    monitor.onCapture = { [weak self] capture, source in await self?.record(capture, source: source)
    }
    Task { [weak self] in
      await self?.reload()
      if startMonitoring { self?.monitor.start() }
    }
  }

  func reopenStorage() async throws {
    let replacement = try ClipboardStore(
      directory: DataLocations.root.appending(path: "Paste"), historyLimit: historyLimit)
    store = replacement
    await reload()
  }

  func setHistoryLimit(_ value: Int) async {
    let bounded = min(30, max(3, value))
    do {
      try await store?.setHistoryLimit(bounded)
      historyLimit = bounded
      defaults.set(bounded, forKey: "clipboardHistoryLimit")
      await reload()
    } catch { message = Strings.historyWriteFailed }
  }

  func record(_ capture: ClipboardCapture, source: String?, allowOversizedImage: Bool = false) async
  {
    guard let store else { return }
    do {
      let result = try await store.add(
        kind: capture.kind, sourceBundleID: source,
        preview: capture.preview, representations: capture.payloads, thumbnail: capture.thumbnail,
        allowOversizedImage: allowOversizedImage)
      if result == .rejectedImageTooLarge {
        message = Strings.imageTooLarge
        return
      }
      if card.panel.isVisible {
        card.dismiss()
      } else {
        displayedCardItem = nil
      }
      await reload()
      cycler.reset()
    } catch { message = Strings.historyWriteFailed }
  }

  private func applyFocusedIndex(_ index: Int) {
    updatingFocusedIndex = true
    focusedIndex = index
    updatingFocusedIndex = false
  }

  func reload() async {
    guard let store else { return }
    reloadGeneration += 1
    let generation = reloadGeneration
    let updated = await store.items
    var payloads: [UUID: [ClipboardPayload]] = [:]
    var images: [UUID: NSImage] = [:]
    for item in updated where retainVisualCaches {
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
          payload.data.count <= 128_000,
          let text = String(data: payload.data, encoding: .utf8)
        {
          result[id] = text
        }
      }
      return result
    }.value
    if let onReloadSuspended {
      await onReloadSuspended()
    }
    guard generation == reloadGeneration else { return }
    let selectedID = items.indices.contains(currentIndex) ? items[currentIndex].id : nil
    let focusedID = trackedFocusedID
    if let hoveredRowID, !updated.contains(where: { $0.id == hoveredRowID }) {
      self.hoveredRowID = nil
    }
    if let hoverID, !updated.contains(where: { $0.id == hoverID }) {
      self.hoverID = nil
      onHoverPreview?(nil)
    }
    if let displayedID = displayedCardItem?.id, !updated.contains(where: { $0.id == displayedID }) {
      card.dismiss()
    }
    items = updated
    originals = payloads
    previewTexts = texts
    thumbnails = images
    needsVisualCacheReload = !retainVisualCaches
    let restoredSelected =
      selectedID.flatMap { id in updated.firstIndex { $0.id == id } }
      ?? min(cycler.currentIndex, max(updated.count - 1, 0))
    cycler.select(restoredSelected, count: items.count)
    if let focusedID, let restoredFocused = updated.firstIndex(where: { $0.id == focusedID }) {
      applyFocusedIndex(restoredFocused)
    } else {
      applyFocusedIndex(min(focusedIndex, max(items.count - 1, 0)))
      if focusedID != nil {
        trackedFocusedID = items.indices.contains(focusedIndex) ? items[focusedIndex].id : nil
      }
    }
  }

  func restoreVisualCaches() async {
    retainVisualCaches = true
    await ensureVisualCaches()
  }

  private func ensureVisualCaches() async {
    retainVisualCaches = true
    if let task = visualReloadTask {
      await task.value
      return
    }
    let task = Task { await reload() }
    visualReloadTask = task
    await task.value
    visualReloadTask = nil
  }

  func releaseVisualCaches() {
    retainVisualCaches = false
    reloadGeneration += 1
    originals.removeAll(keepingCapacity: false)
    thumbnails.removeAll(keepingCapacity: false)
    previewTexts.removeAll(keepingCapacity: false)
    needsVisualCacheReload = true
  }

  @discardableResult
  func select(_ index: Int, board: NSPasteboard = .general) -> Bool {
    if needsVisualCacheReload {
      guard items.indices.contains(index) else { return false }
      let id = items[index].id
      Task {
        await ensureVisualCaches()
        if let current = items.firstIndex(where: { $0.id == id }) { select(current, board: board) }
      }
      return false
    }
    guard items.indices.contains(index), let payloads = originals[items[index].id] else {
      return false
    }
    let entries = Self.pasteboardItems(payloads: payloads)
    board.clearContents()
    guard board.writeObjects(entries) else {
      message = Strings.historyWriteFailed
      return false
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
    return true
  }

  static func pasteboardItems(payloads: [ClipboardPayload]) -> [NSPasteboardItem] {
    let files = payloads.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
    let hasImage = payloads.contains {
      SystemPasteboardReader.imageTypes.map(\.rawValue).contains($0.type)
        || UTType($0.type)?.conforms(to: .image) == true
    }
    if !files.isEmpty && !hasImage {
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
    if needsVisualCacheReload {
      Task {
        await ensureVisualCaches()
        cycle(older: older, board: board)
      }
      return
    }
    guard !items.isEmpty else { return }
    if !card.panel.isVisible {
      pasteTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    let started = ContinuousClock.now
    let boundary = cycler.move(older: older, count: items.count)
    guard select(cycler.currentIndex, board: board) else {
      card.dismiss()
      return
    }
    let item = items[cycler.currentIndex]
    let payloads = originals[item.id] ?? []
    displayedCardItem = DisplayedCardSnapshot(
      id: item.id, kind: item.kind, payloads: payloads,
      pasteboardChangeCount: board.changeCount, pasteboardName: board.name)
    let content = ClipCardContent.make(
      item: item, payloads: payloads, thumbnail: thumbnails[item.id])
    card.show(
      index: cycler.currentIndex, count: items.count, content: content, boundary: boundary,
      target: pasteTarget)
    let elapsed = started.duration(to: .now).components
    lastCycleMilliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
  }

  func tag(for item: ClipItem) -> String {
    let payloads = originals[item.id] ?? []
    let fileNames = payloads.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
      .compactMap { String(data: $0.data, encoding: .utf8) }.compactMap(URL.init(string:))
      .map { $0.hasDirectoryPath ? $0.lastPathComponent + "/" : $0.lastPathComponent }
    let text =
      item.kind == .text
      ? payloads.first { $0.type == NSPasteboard.PasteboardType.string.rawValue }
        .flatMap { String(data: $0.data, encoding: .utf8) } ?? item.preview : ""
    return ClipTag.label(
      kind: item.kind, types: payloads.map(\.type), fileNames: fileNames, text: text)
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

  func directPasteItem(board: NSPasteboard = .general) -> DisplayedCardSnapshot? {
    guard let snapshot = displayedCardItem,
      items.contains(where: { $0.id == snapshot.id }),
      board.name == snapshot.pasteboardName,
      board.changeCount == snapshot.pasteboardChangeCount
    else { return nil }
    return snapshot
  }

  private func pasteSelection(board: NSPasteboard = .general) {
    guard let target = pasteTarget,
      target != ProcessInfo.processInfo.processIdentifier,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
      let targetItem = directPasteItem(board: board)
    else {
      card.dismiss()
      return
    }
    let selectedPayloads = targetItem.payloads
    let isFile = targetItem.kind == .files
    let isImage = targetItem.kind == .image
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
        targetIsFinder: targetIsFinder,
        selectedItemIsImage: isImage,
        targetIsTerminal: TerminalApps.bundleIDs.contains(frontmost?.bundleIdentifier ?? "")
      ))
    if action == .authorizationRequired {
      card.dismiss()
      if authorizationPrompt == nil {
        authorizationPrompt = DirectPasteAuthorizationPrompt(
          defaults: defaults, beforeFallback: { [weak self] in self?.card.dismiss() },
          didAuthorize: { [weak self] in self?.refreshDirectPasteAuthorization() },
          openSettings: { [weak self] in self?.openAccessibilitySettings() })
      }
      authorizationPrompt?.request()
      return
    }
    guard action != .none,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
      board.name == targetItem.pasteboardName,
      board.changeCount == targetItem.pasteboardChangeCount
    else {
      card.dismiss()
      return
    }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
    else { return }
    var expectedChangeCount = targetItem.pasteboardChangeCount
    if action == .filePaths {
      guard let paths = Self.filePaths(payloads: selectedPayloads),
        NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
        board.name == targetItem.pasteboardName,
        board.changeCount == targetItem.pasteboardChangeCount
      else {
        card.dismiss()
        return
      }
      board.clearContents()
      guard board.setString(paths, forType: .string) else { return }
      expectedChangeCount = board.changeCount
      if board.name == .general { monitor.markSelfWrite(expectedChangeCount) }
    } else if action == .imageFilePath {
      guard let item = ClipboardDragFile(payloads: selectedPayloads)?.imagePasteboardItem(),
        NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
        board.name == targetItem.pasteboardName,
        board.changeCount == targetItem.pasteboardChangeCount
      else {
        card.dismiss()
        return
      }
      board.clearContents()
      guard board.writeObjects([item]) else { return }
      expectedChangeCount = board.changeCount
      if board.name == .general { monitor.markSelfWrite(expectedChangeCount) }
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
      board.name == targetItem.pasteboardName,
      board.changeCount == expectedChangeCount
    else {
      card.dismiss()
      return
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
      hoveredRowID = nil
      hoverID = nil
      onHoverPreview?(nil)
    }
  }

  func setRowHovered(_ id: UUID, inside: Bool) {
    if inside {
      guard !isDragging, hoveredRowID != id else { return }
      hoveredRowID = id
    } else if hoveredRowID == id {
      hoveredRowID = nil
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

  func handleKey(_ code: UInt16, board: NSPasteboard = .general) -> Bool {
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
    do {
      try await store.remove(id)
      reloadGeneration += 1
      let updated = await store.items
      let selected = items.indices.contains(currentIndex) ? items[currentIndex].id : nil
      let focused = trackedFocusedID
      setRowHovered(id, inside: false)
      if hoverID == id {
        hoverID = nil
        onHoverPreview?(nil)
      }
      if copiedID == id { copiedID = nil }
      if displayedCardItem?.id == id { card.dismiss() }
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
      if let focused, let restoredFocused = updated.firstIndex(where: { $0.id == focused }) {
        applyFocusedIndex(restoredFocused)
      } else {
        applyFocusedIndex(min(focusedIndex, max(updated.count - 1, 0)))
        if trackedFocusedID != nil {
          trackedFocusedID = items.indices.contains(focusedIndex) ? items[focusedIndex].id : nil
        }
      }
    } catch { message = Strings.historyWriteFailed }
  }

  func clear() async {
    do {
      try await store?.clear()
      copyFeedback?.cancel()
      copiedID = nil
      card.dismiss()
      trackedFocusedID = nil
      await reload()
      cycler.reset()
      applyFocusedIndex(0)
    } catch { message = Strings.historyWriteFailed }
  }
}
