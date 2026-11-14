import DevBarCore
import SwiftUI

struct DocumentSidebarView: View {
  let theme: ThemeManager
  @Bindable var session: DocumentSession
  @Bindable var browser: DocumentBrowser
  let onOpen: (URL) -> Void
  let onPick: () -> Void

  private var scheme: ColorScheme { theme.effective }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      section(Strings.documentFolderSection)
      folderList
      divider
      section(Strings.documentRecentSection)
      recentList
      pickButton
    }
    .padding(.horizontal, 10)
    .padding(.top, 12)
    .padding(.bottom, 10)
    .frame(width: 260)
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

  @ViewBuilder
  private var folderList: some View {
    if browser.loading {
      message(Strings.documentLoading)
    } else if !browser.status.isEmpty {
      message(browser.status)
    } else if browser.files.isEmpty {
      Image(systemName: "folder")
        .font(.system(size: 28, weight: .light))
        .foregroundStyle(DesignTokens.textTertiary(scheme))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(browser.files) { node in
            DocumentFileRow(
              node: node, scheme: scheme, selectedPath: session.url?.path,
              onOpen: onOpen)
          }
        }
        .padding(.vertical, 2)
      }
      .frame(maxHeight: .infinity, alignment: .top)
    }
  }

  private var recentList: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(0..<RecentDocuments.limit, id: \.self) { index in
        if index < session.recentEntries.count {
          let entry = session.recentEntries[index]
          DocumentRecentRow(
            url: entry.url, missing: !entry.exists, scheme: scheme,
            selected: session.url?.path == entry.url.path,
            onOpen: { onOpen(entry.url) })
        } else {
          Color.clear.frame(height: 32)
        }
      }
    }
    .padding(.bottom, 8)
  }

  private var divider: some View {
    Rectangle()
      .fill(DesignTokens.lineDivider(scheme))
      .frame(height: 0.5)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
  }

  private var pickButton: some View {
    HStack {
      Button(action: onPick) {
        Image(systemName: "folder")
          .font(.system(size: 14))
          .foregroundStyle(DesignTokens.textSecondary(scheme))
          .frame(width: 24, height: 24)
          .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(DesignTokens.panelControl(scheme))
          }
          .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .strokeBorder(
                DesignTokens.lineBorder(scheme), lineWidth: DesignTokens.strokeHairline)
          }
      }
      .buttonStyle(.plain)
      .help(Strings.documentChooseFile)
      .accessibilityLabel(Strings.documentChooseFile)
      Spacer(minLength: 0)
    }
    .padding(.top, 4)
  }

  private func message(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(DesignTokens.textTertiary(scheme))
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(maxHeight: .infinity, alignment: .top)
  }
}

private struct DocumentFileRow: View {
  let node: DocumentNode
  let scheme: ColorScheme
  let selectedPath: String?
  let onOpen: (URL) -> Void
  @State private var hovered = false

  private var selected: Bool { selectedPath == node.url.path }
  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
  }()

  var body: some View {
    Button {
      onOpen(node.url)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(node.url.lastPathComponent)
          .font(.system(size: 13))
          .foregroundStyle(DesignTokens.textPrimary(scheme))
          .lineLimit(1)
          .truncationMode(.tail)
        Text(
          node.created.map { Self.dateFormatter.string(from: $0) }
            ?? Strings.documentUnknownDate
        )
        .font(.system(size: 11))
        .foregroundStyle(DesignTokens.textTertiary(scheme))
        .lineLimit(1)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
          .fill(
            selected
              ? Color.clear
              : DesignTokens.panelControl(scheme).opacity(hovered ? 0.35 : 0)
          )
      }
      .overlay {
        if selected {
          RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
            .strokeBorder(
              DesignTokens.lineBorder(scheme), lineWidth: 1)
        }
      }
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help(node.url.path)
    .accessibilityLabel(node.url.lastPathComponent)
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
        Image(systemName: "clock")
          .font(.system(size: 12))
          .foregroundStyle(DesignTokens.textTertiary(scheme))
          .frame(width: 16)
        Text(url.lastPathComponent)
          .font(.system(size: 13))
          .foregroundStyle(
            missing ? DesignTokens.textTertiary(scheme) : DesignTokens.textPrimary(scheme)
          )
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6)
      .frame(height: 32)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
          .fill(
            selected
              ? Color.clear
              : DesignTokens.panelControl(scheme).opacity(hovered ? 0.35 : 0)
          )
      }
      .overlay {
        if selected {
          RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
            .strokeBorder(
              DesignTokens.lineBorder(scheme), lineWidth: 1)
        }
      }
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help(url.path)
    .accessibilityLabel(url.lastPathComponent)
  }
}
