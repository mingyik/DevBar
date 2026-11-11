import DevBarCore
import KeyboardShortcuts
import SwiftUI

struct PanelView: View {
  @Bindable var model: PanelModel
  @Bindable var theme: ThemeManager
  var webHost: WebHost
  @State private var titleHovered = false
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    let scheme = theme.effective
    let _ = theme.increaseContrast
    VStack(spacing: 0) {
      titleRow(scheme).frame(height: 32)
      Rectangle().fill(DesignTokens.lineDivider(scheme)).frame(height: 0.7)
      content(scheme)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(model.page)
        .transition(.opacity)
      if !model.toast.isEmpty {
        Text(model.toast).font(.system(size: 11))
          .foregroundStyle(DesignTokens.textSecondary(scheme)).lineLimit(1)
      }
    }
    .animation(.easeInOut(duration: 0.15), value: model.page)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background { chrome(scheme) }
    .clipShape(panelShape)
    .environment(\.colorScheme, scheme)
  }

  private var panelShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous)
  }

  @ViewBuilder
  private func chrome(_ scheme: ColorScheme) -> some View {
    if reduceTransparency || theme.reduceTransparency {
      panelShape.fill(DesignTokens.opaqueBackdrop(scheme))
        .overlay(panelShape.fill(DesignTokens.panelBase(scheme)))
        .overlay(panelOutline(scheme))
    } else {
      panelShape.fill(Color.clear)
        .glassEffect(.regular, in: panelShape)
        .overlay(panelShape.fill(DesignTokens.panelGlassTint(scheme)))
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

  private func titleRow(_ scheme: ColorScheme) -> some View {
    HStack(spacing: 8) {
      Button {
        model.cyclePage()
      } label: {
        HStack(spacing: 6) {
          Text(model.page.title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DesignTokens.textPrimary(scheme))
            .overlay(alignment: .bottom) {
              if titleHovered {
                Rectangle().fill(DesignTokens.textPrimary(scheme)).frame(height: 0.7)
              }
            }
          Text("⌘P").font(.system(size: 11))
            .foregroundStyle(DesignTokens.textTertiary(scheme))
        }.lineLimit(1)
      }.buttonStyle(.plain).onHover { titleHovered = $0 }
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
    case .json, .encode, .qr, .doc:
      #if DEBUG
        if model.showsWebViewForSelfCheck {
          // Mount the existing host only in the runtime harness. Product pages remain placeholders.
          WebViewBox(host: webHost).id(webHost.generation)
        } else {
          placeholder(Strings.pageNotImplemented(model.page.title), scheme)
        }
      #else
        placeholder(Strings.pageNotImplemented(model.page.title), scheme)
      #endif
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
        Picker(Strings.defaultPage, selection: $model.defaultPage) {
          Text(Strings.lastPage).tag("last")
          ForEach(PanelModel.Page.contentPages, id: \.self) { page in
            Text(page.title).tag(page.rawValue)
          }
        }.lineLimit(1)
        Text(Strings.pageShortcuts).font(.system(size: 13, weight: .semibold))
          .foregroundStyle(DesignTokens.textPrimary(scheme)).lineLimit(1)
        ForEach(PanelModel.Page.contentPages, id: \.self) { page in
          shortcut(page.title, page.shortcutName, scheme)
        }
        shortcut(Strings.shortcutToggle, .togglePanel, scheme)
        shortcut(Strings.shortcutOlder, .cycleOlder, scheme)
        shortcut(Strings.shortcutNewer, .cycleNewer, scheme)
        shortcut(Strings.shortcutTools, .openTools, scheme)
        shortcut(Strings.shortcutCapture, .captureRegion, scheme)
        shortcut(Strings.shortcutLong, .captureScroll, scheme)
        shortcut(Strings.shortcutRecord, .recordToggle, scheme)
        Toggle(Strings.recordSystemAudio, isOn: $model.recordSystemAudio)
        Toggle(Strings.recordMicrophone, isOn: $model.recordMicrophone)
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

private struct WebViewBox: NSViewRepresentable {
  var host: WebHost

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    mount(host.webView, in: container)
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    if container.subviews.first !== host.webView {
      for view in container.subviews {
        view.removeFromSuperview()
      }
      mount(host.webView, in: container)
    }
  }

  private func mount(_ view: NSView, in container: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      view.topAnchor.constraint(equalTo: container.topAnchor),
      view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
  }
}

extension PanelModel.Page {
  var title: String {
    switch self {
    case .clipboard: Strings.tabClipboard
    case .json: Strings.pageJSON
    case .encode: Strings.pageEncode
    case .qr: Strings.pageQR
    case .doc: Strings.tabDocument
    case .settings: Strings.settingsPage
    }
  }

  @MainActor var shortcutName: KeyboardShortcuts.Name {
    switch self {
    case .clipboard: .pageClipboard
    case .json: .pageJSON
    case .encode: .pageEncode
    case .qr: .pageQR
    case .doc: .pageDoc
    case .settings: preconditionFailure("Settings has no page shortcut")
    }
  }
}
