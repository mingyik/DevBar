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

enum DocumentSaveOutcome: Equatable {
  case saved(SavedDocument)
  case canceled
  case failed
  case externalChanged
  case missing
}

/// Owns the current Markdown source file association, file signatures, recent
/// documents and safe writes. The Web process only ever sees opaque ids.
@MainActor @Observable
final class DocumentSession {
  private let defaults: UserDefaults
  private static let recentKey = "recentDocumentPaths"
  private(set) var url: URL?
  private(set) var documentID: String?
  private(set) var recent: [URL]
  private var signature: FileSignature?
  private var hadBOM = false
  private var newline = "\n"
  private var saveInProgress = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let paths = defaults.stringArray(forKey: Self.recentKey) ?? []
    var unique: [URL] = []
    for path in paths {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      if !unique.contains(url) { unique.append(url) }
    }
    recent = Array(unique.prefix(RecentDocuments.limit))
  }

  var recentEntries: [(url: URL, exists: Bool)] {
    recent.map {
      ($0, FileManager.default.fileExists(atPath: $0.path))
    }
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
    let types = ["md", "markdown", "mmd", "mermaid", "txt"].compactMap {
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
