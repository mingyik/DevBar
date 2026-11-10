import DevBarCore
import KeyboardShortcuts
import SwiftUI

struct PanelView: View {
  @Bindable var model: PanelModel
  @Bindable var theme: ThemeManager

  var body: some View {
    let scheme = theme.effective
    let _ = theme.increaseContrast
    VStack(spacing: 0) {
      toolbar(scheme)
      Divider().overlay(DesignTokens.lineDivider(scheme))
      content(scheme)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(alignment: .top) {
      LinearGradient(
        colors: [DesignTokens.panelRaised(scheme), DesignTokens.panelBase(scheme).opacity(0)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 36)
      .allowsHitTesting(false)
    }
    .background(DesignTokens.panelBase(scheme))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous)
        .strokeBorder(DesignTokens.lineBorder(scheme), lineWidth: DesignTokens.strokeHairline)
    }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous))
    .environment(\.colorScheme, scheme)
  }

  private func toolbar(_ scheme: ColorScheme) -> some View {
    HStack(spacing: 6) {
      ForEach(PanelModel.Page.allCases.filter { $0 != .settings }, id: \.self) { page in
        tab(page, scheme: scheme)
      }
      Spacer(minLength: 8)
      iconButton(model.pinned ? "pin.fill" : "pin", label: Strings.pin, scheme: scheme) {
        model.pinned.toggle()
      }
      iconButton("circle.lefthalf.filled", label: Strings.theme, scheme: scheme) {
        theme.toggleManual()
      }
      if model.showsEnlarge {
        iconButton(
          model.enlarged ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
          label: Strings.enlarge,
          scheme: scheme
        ) {
          model.enlarged.toggle()
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private func tab(_ page: PanelModel.Page, scheme: ColorScheme) -> some View {
    let selected = model.page == page
    return Button {
      model.page = page
    } label: {
      Label(page.title, systemImage: page.symbol)
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(selected ? DesignTokens.selectionText(scheme) : DesignTokens.textPrimary(scheme))
        .background(
          selected ? DesignTokens.selectionFill(scheme) : DesignTokens.panelControl(scheme),
          in: RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
        )
    }
    .buttonStyle(.plain)
  }

  private func iconButton(
    _ symbol: String,
    label: String,
    scheme: ColorScheme,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .frame(width: 28, height: 28)
        .foregroundStyle(DesignTokens.textPrimary(scheme))
        .background(
          DesignTokens.panelControl(scheme),
          in: RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  @ViewBuilder
  private func content(_ scheme: ColorScheme) -> some View {
    switch model.page {
    case .clipboard:
      placeholder(Strings.clipboardPlaceholder, scheme)
    case .tools:
      placeholder(Strings.toolsPlaceholder, scheme)
    case .document:
      placeholder(Strings.documentPlaceholder, scheme)
    case .capture:
      placeholder(Strings.capturePlaceholder, scheme)
    case .settings:
      settings(scheme)
    }
  }

  private func placeholder(_ text: String, _ scheme: ColorScheme) -> some View {
    Text(text)
      .font(.system(size: 14))
      .foregroundStyle(DesignTokens.textSecondary(scheme))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(20)
  }

  private func settings(_ scheme: ColorScheme) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text(Strings.settingsPage)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(DesignTokens.textPrimary(scheme))
        Picker(Strings.appearance, selection: $theme.mode) {
          Text(Strings.followSystem).tag(ThemeMode.system)
          Text(Strings.light).tag(ThemeMode.light)
          Text(Strings.dark).tag(ThemeMode.dark)
        }
        .pickerStyle(.radioGroup)
        .foregroundStyle(DesignTokens.textPrimary(scheme))
        shortcut(Strings.shortcutToggle, .togglePanel, scheme)
        shortcut(Strings.shortcutOlder, .cycleOlder, scheme)
        shortcut(Strings.shortcutNewer, .cycleNewer, scheme)
        shortcut(Strings.shortcutTools, .openTools, scheme)
        shortcut(Strings.shortcutCapture, .captureRegion, scheme)
        shortcut(Strings.shortcutLong, .captureLong, scheme)
        shortcut(Strings.shortcutRecord, .record, scheme)
        Text(Strings.aboutBody)
          .font(.system(size: 13))
          .foregroundStyle(DesignTokens.textSecondary(scheme))
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func shortcut(_ title: String, _ name: KeyboardShortcuts.Name, _ scheme: ColorScheme) -> some View {
    HStack {
      Text(title)
        .font(.system(size: 13))
        .foregroundStyle(DesignTokens.textPrimary(scheme))
      Spacer()
      KeyboardShortcuts.Recorder(for: name) { EmptyView() }
    }
  }
}

extension PanelModel.Page {
  var title: String {
    switch self {
    case .clipboard: Strings.tabClipboard
    case .tools: Strings.tabTools
    case .document: Strings.tabDocument
    case .capture: Strings.tabCapture
    case .settings: Strings.settingsTitle
    }
  }

  var symbol: String {
    switch self {
    case .clipboard: "clipboard"
    case .tools: "wrench.and.screwdriver"
    case .document: "doc.text"
    case .capture: "camera.viewfinder"
    case .settings: "gearshape"
    }
  }
}
