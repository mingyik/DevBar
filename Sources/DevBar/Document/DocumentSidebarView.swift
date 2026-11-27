import DevBarCore
import SwiftUI

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
      chooseFileButton
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

  private var chooseFileButton: some View {
    Button(action: onPick) {
      Image(systemName: "folder").devbarIconColor(scheme)
        .font(.system(size: 13))
        .frame(width: 24, height: 24)
    }
    .buttonStyle(DevBarToolbarIconButtonStyle(scheme: scheme))
    .help(Strings.documentChooseFile)
    .accessibilityLabel(Strings.documentChooseFile)
    .padding(.leading, 8)
  }

  private var recentList: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(session.recentEntries.indices, id: \.self) { index in
        let entry = session.recentEntries[index]
        DocumentRecentRow(
          url: entry.url, missing: !entry.exists, scheme: scheme,
          selected: session.url?.path == entry.url.path,
          onOpen: { onOpen(entry.url) })
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
            onOpen: { onOpenDraft(draft.id) })
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
  @State private var hovered = false

  var body: some View {
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
        DocumentTypeBadge(label: documentTypeLabel(url.pathExtension), scheme: scheme)
      }
      .padding(.horizontal, 6)
      .frame(height: 32)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
          .fill(
            selected
              ? DesignTokens.panelControl(scheme)
              : DesignTokens.panelControl(scheme).opacity(hovered ? 0.45 : 0)
          )
      }
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help(url.path)
    .accessibilityLabel(url.lastPathComponent)
  }
}

private struct DocumentDraftRow: View {
  let draft: DocumentDraft
  let scheme: ColorScheme
  let selected: Bool
  let onOpen: () -> Void
  @State private var hovered = false

  var body: some View {
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
        DocumentTypeBadge(label: draft.typeTag, scheme: scheme)
      }
      .padding(.horizontal, 6)
      .frame(height: 32)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
          .fill(
            selected
              ? DesignTokens.panelControl(scheme)
              : DesignTokens.panelControl(scheme).opacity(hovered ? 0.45 : 0)
          )
      }
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help(draft.fileName ?? Strings.documentUntitled)
    .accessibilityLabel("\(draft.title), \(draft.typeTag)")
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
