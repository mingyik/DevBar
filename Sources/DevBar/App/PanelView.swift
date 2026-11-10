import DevBarCore
import KeyboardShortcuts
import SwiftUI

struct PanelView: View {
  @Bindable var model: PanelModel
  @Bindable var theme: ThemeManager
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    let scheme = theme.effective
    let _ = theme.increaseContrast
    VStack(spacing: 10) {
      tabTrack(scheme)
      titleRow(scheme)
      content(scheme)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
        .background(DesignTokens.panelCard(scheme), in: cardShape)
        .overlay(
          cardShape.strokeBorder(
            DesignTokens.lineBorder(scheme), lineWidth: DesignTokens.strokeHairline))
    }
    .padding(14)
    .background { chrome(scheme) }
    .clipShape(panelShape)
    .environment(\.colorScheme, scheme)
  }

  private var panelShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous)
  }

  private var cardShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DesignTokens.radiusMedium, style: .continuous)
  }

  @ViewBuilder
  private func chrome(_ scheme: ColorScheme) -> some View {
    if reduceTransparency || theme.reduceTransparency {
      panelShape.fill(DesignTokens.opaqueBackdrop(scheme))
        .overlay(panelShape.fill(DesignTokens.panelBase(scheme)))
        .overlay(panelOutline(scheme))
    } else if #available(macOS 26, *) {
      panelShape.fill(Color.clear)
        .glassEffect(.regular, in: panelShape)
        .overlay(panelShape.fill(DesignTokens.panelGlassTint(scheme)))
        .overlay(panelOutline(scheme))
    } else {
      panelShape.fill(DesignTokens.panelBase(scheme))
        .overlay(panelOutline(scheme))
    }
  }

  private func panelOutline(_ scheme: ColorScheme) -> some View {
    panelShape
      .strokeBorder(DesignTokens.lineBorder(scheme), lineWidth: DesignTokens.strokeHairline)
      .overlay(
        panelShape.strokeBorder(
          LinearGradient(
            colors: [DesignTokens.panelRaised(scheme), DesignTokens.lineBorder(scheme).opacity(0)],
            startPoint: .top,
            endPoint: .bottom
          ),
          lineWidth: DesignTokens.strokeHairline
        )
      )
  }

  private func tabTrack(_ scheme: ColorScheme) -> some View {
    HStack(spacing: 2) {
      ForEach(PanelModel.Page.allCases.filter { $0 != .settings }, id: \.self) { page in
        tab(page, scheme)
      }
    }
    .padding(2)
    .frame(height: 28)
    .background(
      DesignTokens.panelCard(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(DesignTokens.lineBorder(scheme), lineWidth: DesignTokens.strokeHairline)
    )
  }

  private func tab(_ page: PanelModel.Page, _ scheme: ColorScheme) -> some View {
    let selected = model.page == page
    return Button {
      model.page = page
    } label: {
      Image(systemName: page.symbol)
        .font(.system(size: 13, weight: .regular))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(
          selected ? DesignTokens.selectionText(scheme) : DesignTokens.textPrimary(scheme)
        )
        .background {
          if selected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(DesignTokens.selectionFill(scheme))
              .padding(.vertical, 1)
          }
        }
    }
    .buttonStyle(.plain)
    .help(page.title)
    .accessibilityLabel(page.title)
    .animation(.easeInOut(duration: 0.15), value: selected)
  }

  private func titleRow(_ scheme: ColorScheme) -> some View {
    HStack(spacing: 8) {
      Text(model.page.title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DesignTokens.textSecondary(scheme))
        .lineLimit(1)
      Spacer(minLength: 8)
      actionButton(model.pinned ? "pin.fill" : "pin", label: Strings.pin, scheme: scheme) {
        model.pinned.toggle()
      }
      actionButton("circle.lefthalf.filled", label: Strings.theme, scheme: scheme) {
        theme.toggleManual()
      }
      if model.showsEnlarge {
        actionButton(
          model.enlarged
            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
          label: Strings.enlarge,
          scheme: scheme
        ) {
          model.enlarged.toggle()
        }
      }
    }
  }

  private func actionButton(
    _ symbol: String,
    label: String,
    scheme: ColorScheme,
    action: @escaping () -> Void
  ) -> some View {
    ActionIcon(symbol: symbol, label: label, scheme: scheme, action: action)
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
      .lineLimit(1)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func settings(_ scheme: ColorScheme) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
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
        shortcut(Strings.shortcutLong, .captureScroll, scheme)
        shortcut(Strings.shortcutRecord, .recordToggle, scheme)
        Text(Strings.aboutBody)
          .font(.system(size: 13))
          .foregroundStyle(DesignTokens.textSecondary(scheme))
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func shortcut(_ title: String, _ name: KeyboardShortcuts.Name, _ scheme: ColorScheme)
    -> some View
  {
    HStack {
      Text(title)
        .font(.system(size: 13))
        .foregroundStyle(DesignTokens.textPrimary(scheme))
        .lineLimit(1)
      Spacer(minLength: 8)
      KeyboardShortcuts.Recorder(for: name) { EmptyView() }
    }
  }
}

private struct ActionIcon: View {
  let symbol: String
  let label: String
  let scheme: ColorScheme
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .regular))
        .frame(width: 24, height: 24)
        .foregroundStyle(DesignTokens.textSecondary(scheme))
        .background {
          if hovered {
            RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
              .fill(DesignTokens.panelControl(scheme))
          }
        }
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help(label)
    .accessibilityLabel(label)
  }
}

extension PanelModel.Page {
  var title: String {
    switch self {
    case .clipboard: Strings.tabClipboard
    case .tools: Strings.tabTools
    case .document: Strings.tabDocument
    case .capture: Strings.tabCapture
    case .settings: Strings.settingsPage
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
