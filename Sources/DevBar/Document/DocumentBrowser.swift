import AppKit
import Observation

private let documentFileExtensions: Set<String> = ["md", "markdown", "mmd", "mermaid", "txt"]

@MainActor @Observable
final class DocumentNode: Identifiable {
  nonisolated let url: URL
  nonisolated let created: Date?
  nonisolated var id: String { url.path }

  init(url: URL, created: Date?) {
    self.url = url
    self.created = created
  }
}

/// Lists the Markdown files in the configured data directory. The folder is
/// flat; subfolders are not shown or traversed.
@MainActor @Observable
final class DocumentBrowser {
  private(set) var files: [DocumentNode] = []
  private(set) var status = ""
  private(set) var loading = false
  private(set) var directory: URL?
  private var generation = 0

  func setDirectory(_ directory: URL?) {
    self.directory = directory?.standardizedFileURL
    reload()
  }

  func reload() {
    generation += 1
    let current = generation
    guard let directory else {
      files = []
      status = Strings.documentNoProject
      loading = false
      return
    }
    loading = true
    status = ""
    Task {
      let listing = await Self.list(directory)
      guard current == generation else { return }
      loading = false
      switch listing {
      case .success(let found):
        files = found.map { DocumentNode(url: $0.url, created: $0.created) }
        status = files.isEmpty ? Strings.documentEmptyFolder : ""
      case .failure:
        files = []
        status = Strings.documentFolderUnreadable
      }
    }
  }

  private struct Entry: Sendable {
    let url: URL
    let created: Date?
  }

  private enum ListingError: Error { case unreadable }

  private static func list(_ directory: URL) async -> Result<[Entry], ListingError> {
    await Task.detached(priority: .userInitiated) {
      guard FileManager.default.fileExists(atPath: directory.path) else {
        return .success([])
      }
      guard
        let items = try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
          options: [.skipsHiddenFiles])
      else { return .failure(.unreadable) }
      var entries: [Entry] = []
      for item in items {
        let name = item.lastPathComponent
        guard
          !name.hasPrefix("."), !name.hasPrefix("~$"), !name.hasSuffix(".tmp"),
          (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          documentFileExtensions.contains(item.pathExtension.lowercased())
        else { continue }
        let created = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate
        entries.append(Entry(url: item.standardizedFileURL, created: created ?? nil))
      }
      entries.sort { first, second in
        let left = first.created ?? .distantPast
        let right = second.created ?? .distantPast
        if left != right { return left > right }
        return first.url.lastPathComponent.localizedStandardCompare(
          second.url.lastPathComponent) == .orderedAscending
      }
      return .success(entries)
    }.value
  }
}
