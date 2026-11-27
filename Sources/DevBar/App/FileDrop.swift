import AppKit
import DevBarCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class FileDropCoordinator {
  private unowned let panel: PanelController
  private unowned let status: StatusItemController
  private var generation = 0
  private var origin: PanelModel.Page = .clipboard
  private var cancellation: Task<Void, Never>?
  init(panel: PanelController, status: StatusItemController) {
    self.panel = panel
    self.status = status
  }
  func enteredIcon(_ urls: [URL]) -> NSDragOperation {
    cancellation?.cancel()
    guard let first = urls.first,
      case .doc = FileRoute.route(
        fileName: first.lastPathComponent, sniff: FileDropReader.sniff(first))
    else { return [] }
    if !panel.model.dropActive {
      origin = panel.model.page
      panel.model.dropDocument = true
      panel.model.dropActive = true
      panel.show(anchor: status.anchor)
    }
    return .copy
  }
  func enteredPanel() {
    cancellation?.cancel()
  }
  func exited() {
    cancellation?.cancel()
    cancellation = Task {
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      cancel()
    }
  }
  func cancel() {
    cancellation?.cancel()
    let wasActive = panel.model.dropActive
    panel.model.dropActive = false
    if wasActive { panel.model.page = origin }
  }
  func receive(_ urls: [URL], document: Bool? = nil, previewMarkdown: Bool = true) {
    guard MemoryBudget.allows(bytes: 0) else {
      panel.model.dropActive = false
      panel.model.toast = Strings.insufficientMemory
      return
    }
    cancellation?.cancel()
    let target: Bool? =
      document
      ?? (panel.model.dropActive
        ? panel.model.dropDocument
        : panel.model.page == .json ? false : panel.model.page == .doc ? true : nil)
    panel.model.dropActive = false
    generation += 1
    let current = generation
    if let first = urls.first {
      let route = FileRoute.route(
        fileName: first.lastPathComponent, sniff: FileDropReader.sniff(first))
      if case .doc = route {
        if urls.count > 1 { panel.model.toast = Strings.fileDropFirst }
        Task { await panel.openDocument(first, previewMarkdown: previewMarkdown) }
        return
      }
    }
    Task {
      let result = await Task.detached { FileDropReader.read(urls) }.value
      guard current == generation else { return }
      switch result {
      case .failure(let reason): panel.model.toast = Strings.fileDropError(reason)
      case .success(let file):
        guard MemoryBudget.allows(bytes: file.text.utf8.count) else {
          panel.model.toast = Strings.insufficientMemory
          return
        }
        let isDoc =
          target
          ?? {
            if case .doc = file.route { return true }
            return false
          }()
        let mode: String? = {
          if case .doc(let mode) = file.route { return mode?.rawValue }
          return nil
        }()
        panel.model.page = isDoc ? .doc : .json
        panel.webHost.importFile(
          text: file.text, name: file.fileName, docMode: isDoc ? mode : nil, document: isDoc)
        panel.model.toast = file.multiple ? Strings.fileDropFirst : ""
      }
    }
  }
}

@MainActor final class StatusFileDropView: NSView {
  weak var coordinator: FileDropCoordinator?
  var onClick: (() -> Void)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { nil }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) { onClick?() }
  override func rightMouseUp(with event: NSEvent) { onClick?() }
  private func urls(_ sender: any NSDraggingInfo) -> [URL] {
    sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
  }
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    coordinator?.enteredIcon(urls(sender)) ?? []
  }
  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
  override func draggingExited(_ sender: (any NSDraggingInfo)?) { coordinator?.exited() }
  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }
  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    coordinator?.receive(urls(sender))
    return true
  }
}

@MainActor struct PanelFileDrop: DropDelegate {
  let model: PanelModel
  func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
  func dropEntered(info: DropInfo) {
    model.fileDrop?.enteredPanel()
  }
  func dropUpdated(info: DropInfo) -> DropProposal? {
    model.fileDrop?.enteredPanel()
    return DropProposal(operation: .copy)
  }
  func dropExited(info: DropInfo) { model.fileDrop?.exited() }
  func performDrop(info: DropInfo) -> Bool {
    let providers = info.itemProviders(for: [.fileURL])
    let coordinator = model.fileDrop
    let document: Bool? =
      model.dropActive
      ? model.dropDocument : model.page == .json ? false : model.page == .doc ? true : nil
    Task {
      var urls: [URL] = []
      for provider in providers {
        let data: Data? = await withCheckedContinuation { continuation in
          provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            continuation.resume(returning: data)
          }
        }
        if let data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
      }
      coordinator?.receive(urls, document: document)
    }
    return !providers.isEmpty
  }
}

struct FileDropOverlay: View {
  let scheme: ColorScheme
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "arrow.down.doc")
        .devbarIconColor(scheme)
        .font(.system(size: 18, weight: .regular))
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 4) {
        Text(Strings.fileDropDocTitle)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(DesignTokens.textPrimary(scheme))
          .lineLimit(1)
        Text(Strings.fileDropDocTypes)
          .font(.system(size: 10))
          .foregroundStyle(DesignTokens.textSecondary(scheme))
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DesignTokens.panelControl(scheme))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(
          DesignTokens.lineBorder(scheme), lineWidth: DesignTokens.strokeHairline
        ).allowsHitTesting(false)
    }
    .accessibilityElement(children: .combine)
  }
}
