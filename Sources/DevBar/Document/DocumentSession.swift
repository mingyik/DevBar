import AppKit
import DevBarCore
import Foundation
import UniformTypeIdentifiers

struct OpenedDocument: Equatable {
  let id: String
  let url: URL
  let text: String
  let fileName: String
  let mode: DocMode?
  let hadBOM: Bool
  let newline: String
}

enum DocumentOpenError: Error {
  case unsupported, tooLarge, notUTF8, unreadable
}

struct SavedDocument: Equatable {
  let id: String
  let url: URL
  let fileName: String
}

struct DocumentDraft: Identifiable, Equatable {
  let id: String
  let fileName: String?
  let text: String
  let savedText: String
  let docMode: String
  let modeLocked: Bool
  let display: String
  let url: URL?
  let signature: FileSignature?
  let hadBOM: Bool
  let newline: String

  var title: String {
    guard let fileName, !fileName.isEmpty else { return Strings.documentUntitled }
    let name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    return name.isEmpty ? fileName : name
  }

  var typeTag: String {
    guard let fileName, !fileName.isEmpty else { return docMode == "mermaid" ? "MMD" : "MD" }
    return documentTypeLabel(URL(fileURLWithPath: fileName).pathExtension)
  }
}

enum DocumentSaveOutcome: Equatable {
  case saved(SavedDocument)
  case canceled
  case failed
  case externalChanged
  case missing
}

/// Owns the current text source file association, file signatures, recent
/// documents and safe writes. The Web process only ever sees opaque ids.
@MainActor @Observable
final class DocumentSession {
  private let defaults: UserDefaults
  private static let recentKey = "recentDocumentPaths"
  private(set) var url: URL?
  private(set) var documentID: String?
  private(set) var recent: [URL]
  private(set) var drafts: [DocumentDraft] = []
  private var signature: FileSignature?
  private var hadBOM = false
  private var newline = "\n"
  private var saveInProgress = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let paths = defaults.stringArray(forKey: Self.recentKey) ?? []
    let supportedExtensions = Set(FileRoute.documentExtensions)
    var unique: [URL] = []
    for path in paths {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      guard supportedExtensions.contains(url.pathExtension.lowercased()),
        FileManager.default.fileExists(atPath: url.path)
      else { continue }
      if !unique.contains(url) { unique.append(url) }
    }
    recent = Array(unique.prefix(RecentDocuments.limit))
    if recent.map(\.path) != paths {
      defaults.set(recent.map(\.path), forKey: Self.recentKey)
    }
  }

  var recentEntries: [(url: URL, exists: Bool)] {
    recent.filter { FileManager.default.fileExists(atPath: $0.path) }.map { ($0, true) }
  }

  func pruneMissingRecent() {
    let existing = recent.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard existing != recent else { return }
    recent = existing
    defaults.set(recent.map(\.path), forKey: Self.recentKey)
  }

  func removeRecent(_ target: URL) {
    let standardized = target.standardizedFileURL.path
    let remaining = recent.filter { $0.standardizedFileURL.path != standardized }
    guard remaining != recent else { return }
    recent = remaining
    defaults.set(recent.map(\.path), forKey: Self.recentKey)
  }

  func removeDraft(id: String) {
    drafts.removeAll { $0.id == id }
  }

  func clearSidebarEntries() {
    if !recent.isEmpty {
      recent = []
      defaults.set([String](), forKey: Self.recentKey)
    }
    if !drafts.isEmpty {
      drafts = []
    }
  }

  func resolveDocumentLink(_ href: String) -> URL? {
    guard let url, let link = URLComponents(string: href),
      link.scheme == nil, link.host == nil, !link.path.isEmpty,
      !link.path.hasPrefix("/"), !link.path.contains("\0")
    else { return nil }
    return url.deletingLastPathComponent().appending(path: link.path).standardizedFileURL
  }

  func read(_ file: URL) async -> Result<OpenedDocument, DocumentOpenError> {
    let url = file.standardizedFileURL
    let result = await Task.detached(priority: .userInitiated) {
      () -> Result<
        (DocumentFile.Decoded, DocMode?), DocumentOpenError
      > in
      do {
        let values = try url.resourceValues(forKeys: [
          .isRegularFileKey, .isPackageKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isPackage != true else {
          return .failure(.unreadable)
        }
        guard let size = values.fileSize, size <= DocumentFile.byteLimit else {
          return .failure(.tooLarge)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= DocumentFile.byteLimit else { return .failure(.tooLarge) }
        guard let decoded = DocumentFile.decode(data) else { return .failure(.notUTF8) }
        let route = FileRoute.route(
          fileName: url.lastPathComponent, sniff: String(decoded.text.prefix(4096)))
        guard case .doc(let mode) = route else { return .failure(.unsupported) }
        return .success((decoded, mode))
      } catch {
        return .failure(.unreadable)
      }
    }.value
    guard case .success((let decoded, let mode)) = result else {
      if case .failure(let error) = result { return .failure(error) }
      return .failure(.unreadable)
    }
    return .success(
      OpenedDocument(
        id: UUID().uuidString, url: url, text: decoded.text,
        fileName: url.lastPathComponent, mode: mode, hadBOM: decoded.hadBOM,
        newline: decoded.newline))
  }

  func adopt(_ opened: OpenedDocument) {
    url = opened.url
    documentID = opened.id
    hadBOM = opened.hadBOM
    newline = opened.newline
    signature = DocumentFile.signature(of: opened.url)
    addRecent(opened.url)
  }

  /// Keeps an unsaved document in memory when the user opens another file.
  /// Draft contents are intentionally session-only and never written to logs or defaults.
  @discardableResult
  func stashDraft(_ snapshot: [String: Any]) -> DocumentDraft? {
    guard let text = snapshot["text"] as? String, requiresDraft(snapshot),
      MemoryBudget.allows(bytes: text.utf8.count)
    else { return nil }
    let savedText = snapshot["savedText"] as? String ?? text

    let id = documentID ?? UUID().uuidString
    documentID = id
    let draft = DocumentDraft(
      id: id,
      fileName: url?.lastPathComponent ?? snapshot["fileName"] as? String,
      text: text,
      savedText: savedText,
      docMode: snapshot["docMode"] as? String ?? "markdown",
      modeLocked: snapshot["modeLocked"] as? Bool ?? false,
      display: snapshot["display"] as? String ?? "source",
      url: url,
      signature: signature,
      hadBOM: hadBOM,
      newline: newline)
    drafts.removeAll { $0.id == id }
    drafts.insert(draft, at: 0)
    return draft
  }

  func requiresDraft(_ snapshot: [String: Any]) -> Bool {
    guard let text = snapshot["text"] as? String else { return false }
    let savedText = snapshot["savedText"] as? String ?? text
    return url == nil ? !text.isEmpty : text != savedText
  }

  func draft(id: String) -> DocumentDraft? {
    drafts.first { $0.id == id }
  }

  func activateDraft(id: String) -> DocumentDraft? {
    guard let index = drafts.firstIndex(where: { $0.id == id }) else { return nil }
    let draft = drafts.remove(at: index)
    url = draft.url
    documentID = draft.id
    signature = draft.signature
    hadBOM = draft.hadBOM
    newline = draft.newline
    return draft
  }

  func ensureID(_ candidate: String?) -> String {
    if documentID == nil { documentID = candidate ?? UUID().uuidString }
    return documentID!
  }

  func save(_ text: String, saveAs: Bool) async -> DocumentSaveOutcome {
    guard !saveInProgress else { return .failed }
    saveInProgress = true
    defer { saveInProgress = false }
    let target: URL
    let checksExisting: Bool
    if let url, !saveAs {
      target = url
      checksExisting = true
    } else {
      guard let chosen = chooseSaveLocation() else { return .canceled }
      target = chosen
      checksExisting = false
    }
    let expected = signature
    let hadBOM = hadBOM
    let newline = newline
    enum DiskFailure: Error { case missing, externalChanged, failed }
    let written = await Task.detached(priority: .userInitiated) {
      () -> Result<
        FileSignature, DiskFailure
      > in
      if checksExisting {
        guard FileManager.default.fileExists(atPath: target.path) else {
          return .failure(.missing)
        }
        guard let current = DocumentFile.signature(of: target) else {
          return .failure(.missing)
        }
        guard current.matches(expected) else { return .failure(.externalChanged) }
      }
      let data = DocumentFile.encode(text, hadBOM: hadBOM, newline: newline)
      do {
        try data.write(to: target, options: .atomic)
      } catch {
        return .failure(.failed)
      }
      guard let signature = DocumentFile.signature(of: target) else {
        return .failure(.failed)
      }
      return .success(signature)
    }.value
    switch written {
    case .failure(.missing): return .missing
    case .failure(.externalChanged): return .externalChanged
    case .failure(.failed): return .failed
    case .success(let signature):
      self.signature = signature
    }
    url = target
    if documentID == nil { documentID = UUID().uuidString }
    addRecent(target)
    return .saved(
      SavedDocument(
        id: documentID ?? UUID().uuidString, url: target,
        fileName: target.lastPathComponent))
  }

  private func addRecent(_ url: URL) {
    recent = RecentDocuments.adding(url, to: recent)
    defaults.set(recent.map(\.path), forKey: Self.recentKey)
  }

  private func chooseSaveLocation() -> URL? {
    let panel = NSSavePanel()
    let types = FileRoute.documentExtensions.compactMap {
      UTType(filenameExtension: $0)
    }
    if !types.isEmpty { panel.allowedContentTypes = types }
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = url?.lastPathComponent ?? "未命名.md"
    let markdownFolder = DataLocations.root.appending(path: "Markdown")
    if url == nil {
      try? FileManager.default.createDirectory(
        at: markdownFolder, withIntermediateDirectories: true)
    }
    panel.directoryURL =
      url?.deletingLastPathComponent()
      ?? (FileManager.default.fileExists(atPath: markdownFolder.path)
        ? markdownFolder
        : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
    panel.title = Strings.documentSavePanelTitle
    panel.prompt = Strings.documentSavePanelAction
    return panel.runModal() == .OK ? panel.url : nil
  }
}

func documentTypeLabel(_ extensionName: String) -> String {
  switch extensionName.lowercased() {
  case "md", "markdown": "MD"
  case "mmd", "mermaid": "MMD"
  default: ""
  }
}
