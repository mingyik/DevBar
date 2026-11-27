import DevBarCore
import SwiftUI

enum DocumentSidebarHoverZone {
  /// Show the trailing delete icon only when the pointer hovers over the trailing portion of the row.
  static func showsDelete(localX: CGFloat, width: CGFloat) -> Bool {
    guard width > 0 else { return false }
    return localX >= width * 0.65 && localX <= width
  }
}

struct DocumentSidebarView: View {
  let theme: ThemeManager
  @Bindable var session: DocumentSession
  var width: CGFloat = 240
  let onOpen: (URL) -> Void
  let onOpenDraft: (String) -> Void
  let onPick: () -> Void

  private var scheme: ColorScheme { theme.effective }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      section(Strings.documentRecentSection)
      recentList
      if !session.drafts.isEmpty {
        divider
        section(Strings.documentUnsavedSection)
        draftList
      }
      Spacer(minLength: 12)
      footerActions
    }
    .padding(.horizontal, 10)
    .padding(.top, 12)
    .padding(.bottom, 10)
    .frame(width: width)
    .frame(maxHeight: .infinity, alignment: .top)
    .environment(\.colorScheme, scheme)
  }

  private func section(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 11))
      .foregroundStyle(DesignTokens.textTertiary(scheme))
      .padding(.horizontal, 8)
      .frame(height: 24, alignment: .leading)
  }

  private var footerActions: some View {
    HStack(spacing: 8) {
      chooseFileButton
      Spacer(minLength: 8)
      clearSidebarButton
    }
    .padding(.horizontal, 4)
  }

  private var chooseFileButton: some View {
    Button(action: onPick) {
      Image(systemName: "folder").devbarIconColor(scheme)
        .font(.system(size: 13))
        .frame(width: 24, height: 24)
    }
    .buttonStyle(DevBarToolbarIconButtonStyle(scheme: scheme))
    .help(Strings.documentChooseFile)
    .accessibilityLabel(Strings.documentChooseFile)
  }

  private var clearSidebarButton: some View {
    Button {
      session.clearSidebarEntries()
    } label: {
      Image(systemName: "trash").devbarIconColor(scheme)
        .font(.system(size: 13))
        .frame(width: 24, height: 24)
    }
    .buttonStyle(DevBarToolbarIconButtonStyle(scheme: scheme))
    .disabled(session.recentEntries.isEmpty && session.drafts.isEmpty)
    .help(Strings.clipboardClear)
    .accessibilityLabel(Strings.clipboardClear)
  }

  private var recentList: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(session.recentEntries.indices, id: \.self) { index in
        let entry = session.recentEntries[index]
        DocumentRecentRow(
          url: entry.url, missing: !entry.exists, scheme: scheme,
          selected: session.url?.path == entry.url.path,
          onOpen: { onOpen(entry.url) },
          onDelete: { session.removeRecent(entry.url) })
      }
    }
    .padding(.bottom, session.recentEntries.isEmpty ? 0 : 8)
  }

  private var divider: some View {
    Rectangle()
      .fill(DesignTokens.lineDivider(scheme))
      .frame(height: 0.5)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
  }

  private var draftList: some View {
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(session.drafts) { draft in
          DocumentDraftRow(
            draft: draft, scheme: scheme,
            selected: session.documentID == draft.id,
            onOpen: { onOpenDraft(draft.id) },
            onDelete: { session.removeDraft(id: draft.id) })
        }
      }
      .padding(.vertical, 2)
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }
}

private struct DocumentRecentRow: View {
  let url: URL
  let missing: Bool
  let scheme: ColorScheme
  let selected: Bool
  let onOpen: () -> Void
  let onDelete: () -> Void
  @State private var hovered = false
  @State private var deleteZoneHovered = false
  @State private var rowWidth: CGFloat = 0

  var body: some View {
    HStack(spacing: 6) {
      Button(action: onOpen) {
        HStack(spacing: 6) {
          Image(systemName: "doc.text").devbarIconColor(scheme)
            .font(.system(size: 12))
            .foregroundStyle(DesignTokens.textTertiary(scheme))
            .frame(width: 16)
          Text(url.deletingPathExtension().lastPathComponent)
            .font(.system(size: 13))
            .foregroundStyle(
              missing ? DesignTokens.textTertiary(scheme) : DesignTokens.textPrimary(scheme)
            )
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if deleteZoneHovered {
        DocumentSidebarDeleteButton(action: onDelete)
      } else {
        DocumentTypeBadge(label: documentTypeLabel(url.pathExtension), scheme: scheme)
      }
    }
    .padding(.horizontal, 6)
    .frame(height: 32)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      GeometryReader { proxy in
        RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
          .fill(
            selected
              ? DesignTokens.panelControl(scheme)
              : DesignTokens.panelControl(scheme).opacity(hovered ? 0.45 : 0)
          )
          .onAppear { rowWidth = proxy.size.width }
          .onChange(of: proxy.size.width) { _, width in rowWidth = width }
      }
    }
    .onContinuousHover(coordinateSpace: .local) { phase in
      switch phase {
      case .active(let location):
        hovered = true
        deleteZoneHovered = DocumentSidebarHoverZone.showsDelete(
          localX: location.x, width: rowWidth)
      case .ended:
        hovered = false
        deleteZoneHovered = false
      }
    }
    .help(url.path)
    .accessibilityLabel(url.lastPathComponent)
  }
}

private struct DocumentDraftRow: View {
  let draft: DocumentDraft
  let scheme: ColorScheme
  let selected: Bool
  let onOpen: () -> Void
  let onDelete: () -> Void
  @State private var hovered = false
  @State private var deleteZoneHovered = false
  @State private var rowWidth: CGFloat = 0

  var body: some View {
    HStack(spacing: 6) {
      Button(action: onOpen) {
        HStack(spacing: 6) {
          Image(systemName: "doc.text").devbarIconColor(scheme)
            .font(.system(size: 12))
            .foregroundStyle(DesignTokens.textTertiary(scheme))
            .frame(width: 16)
          Text(draft.title)
            .font(.system(size: 13))
            .foregroundStyle(DesignTokens.textPrimary(scheme))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if deleteZoneHovered {
        DocumentSidebarDeleteButton(action: onDelete)
      } else {
        DocumentTypeBadge(label: draft.typeTag, scheme: scheme)
      }
    }
    .padding(.horizontal, 6)
    .frame(height: 32)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      GeometryReader { proxy in
        RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
          .fill(
            selected
              ? DesignTokens.panelControl(scheme)
              : DesignTokens.panelControl(scheme).opacity(hovered ? 0.45 : 0)
          )
          .onAppear { rowWidth = proxy.size.width }
          .onChange(of: proxy.size.width) { _, width in rowWidth = width }
      }
    }
    .onContinuousHover(coordinateSpace: .local) { phase in
      switch phase {
      case .active(let location):
        hovered = true
        deleteZoneHovered = DocumentSidebarHoverZone.showsDelete(
          localX: location.x, width: rowWidth)
      case .ended:
        hovered = false
        deleteZoneHovered = false
      }
    }
    .help(draft.fileName ?? Strings.documentUntitled)
    .accessibilityLabel("\(draft.title), \(draft.typeTag)")
  }
}

private struct DocumentSidebarDeleteButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "trash")
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(Color(nsColor: .systemRed))  // devbar:allow-color
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(Strings.deleteItem)
    .accessibilityLabel(Strings.deleteItem)
  }
}

private struct DocumentTypeBadge: View {
  let label: String
  let scheme: ColorScheme

  var body: some View {
    Text(label)
      .font(.system(size: 9, weight: .medium))
      .foregroundStyle(DesignTokens.textSecondary(scheme))
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(DesignTokens.panelControl(scheme))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .strokeBorder(DesignTokens.lineBorder(scheme), lineWidth: DesignTokens.strokeHairline)
      }
      .fixedSize()
  }
}
