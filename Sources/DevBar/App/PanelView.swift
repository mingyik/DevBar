import DevBarCore
import KeyboardShortcuts
import SwiftUI

struct PanelView: View {
  @Bindable var model: PanelModel
  @Bindable var theme: ThemeManager
  var webHost: WebHost
  var clipboard: ClipboardController
  @State private var titleHovered = false

  var body: some View {
    let scheme = theme.effective
    let _ = theme.increaseContrast
    VStack(spacing: 0) {
      if model.dropActive {
        HStack {
          Text(Strings.appName).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DesignTokens.textPrimary(scheme))
          Spacer()
        }.frame(height: 24).padding(.bottom, 8)
      } else {
        titleRow(scheme).frame(height: 32).padding(.bottom, 8)
      }
      ZStack {
        content(scheme)
          .opacity(model.dropActive ? 0 : 1)
          .allowsHitTesting(!model.dropActive)
        if model.dropActive { FileDropOverlay(document: model.dropDocument, scheme: scheme) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onDrop(of: [.fileURL], delegate: PanelFileDrop(model: model))
      .transition(.opacity)
      if !model.dropActive && !model.toast.isEmpty {
        Text(model.toast).font(.system(size: 11))
          .foregroundStyle(DesignTokens.textSecondary(scheme)).lineLimit(1)
      }
    }
    .animation(.easeInOut(duration: 0.15), value: model.page)
    .padding(.horizontal, 16)
    .padding(.top, 12)
    .padding(.bottom, 16)
    .background { PanelChrome(theme: theme, scheme: scheme) }
    .clipShape(panelShape)
    .environment(\.colorScheme, scheme)
  }

  private var panelShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous)
  }

  private func titleRow(_ scheme: ColorScheme) -> some View {
    HStack(spacing: 8) {
      if model.page == .settings {
        Button {
          model.leaveSettings()
        } label: {
          Label(Strings.settingsBack, systemImage: "chevron.left").font(.system(size: 13))
            .foregroundStyle(DesignTokens.textPrimary(scheme))
        }.buttonStyle(.plain)
      } else {
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
      }
      Spacer(minLength: 8)
      actionButton(model.pinned ? "pin.fill" : "pin.slash", label: Strings.pin, scheme: scheme) {
        model.pinned.toggle()
      }
      actionButton("devbar.settings", label: Strings.settingsPage, scheme: scheme) {
        model.enterSettings()
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
      ClipboardListView(controller: clipboard, scheme: scheme)
    case .json, .qr, .doc:
      WebViewBox(host: webHost).id(webHost.generation)
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
    ScrollViewReader { proxy in
      ReadOnlyScrollView(scheme: scheme) {
        VStack(alignment: .leading, spacing: 16) {
          Text(Strings.generalGroup).font(.system(size: 13, weight: .semibold)).id("general")
          Picker(Strings.appearance, selection: $theme.mode) {
            Text(Strings.followSystem).tag(ThemeMode.system)
            Text(Strings.light).tag(ThemeMode.light)
            Text(Strings.dark).tag(ThemeMode.dark)
          }.pickerStyle(.segmented)
          Picker(Strings.defaultPage, selection: $model.defaultPage) {
            Text(Strings.lastPage).tag("last")
            ForEach(PanelModel.Page.contentPages, id: \.self) { page in
              Text(page.title).tag(page.rawValue)
            }
          }
          Toggle(Strings.autoImport, isOn: $model.autoImport)
          shortcut(Strings.shortcutToggle, .togglePanel, scheme)
          shortcut(Strings.shortcutTools, .openTools, scheme)
          Text(Strings.clipboardGroup).font(.system(size: 13, weight: .semibold)).id("clipboard")
          shortcut(Strings.shortcutOlder, .cycleOlder, scheme)
          Text(Strings.captureGroup).font(.system(size: 13, weight: .semibold)).id("capture")
          Toggle(Strings.recordSystemAudio, isOn: $model.recordSystemAudio)
          Toggle(Strings.recordMicrophone, isOn: $model.recordMicrophone)
          shortcut(Strings.shortcutCapture, .captureRegion, scheme)
          shortcut(Strings.shortcutLong, .captureScroll, scheme)
          shortcut(Strings.shortcutRecord, .recordToggle, scheme)
          Text(Strings.pageShortcuts).font(.system(size: 13, weight: .semibold)).id("shortcuts")
          ForEach(PanelModel.Page.contentPages, id: \.self) { page in
            shortcut(page.title, page.shortcutName, scheme)
          }
          Text(Strings.aboutBody).font(.system(size: 11)).foregroundStyle(
            DesignTokens.textSecondary(scheme))
        }.foregroundStyle(DesignTokens.textPrimary(scheme))
          .frame(maxWidth: .infinity, alignment: .leading)
      }.task(id: model.settingsGroup) {
        try? await Task.sleep(for: .milliseconds(80))
        proxy.scrollTo(model.settingsGroup, anchor: .top)
      }
    }
  }

  private func shortcut(_ title: String, _ name: KeyboardShortcuts.Name, _ scheme: ColorScheme)
    -> some View
  {
    ShortcutRow(title: title, name: name, scheme: scheme)
  }
}

struct PanelChrome: View {
  @Bindable var theme: ThemeManager
  let scheme: ColorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  private var panelShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous)
  }
  var body: some View { chrome(scheme) }
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

}

private struct ShortcutRow: View {
  let title: String
  let name: KeyboardShortcuts.Name
  let scheme: ColorScheme
  @State private var shown = ""

  var body: some View {
    HStack {
      Text(title)
        .font(.system(size: 13))
        .foregroundStyle(DesignTokens.textPrimary(scheme))
        .lineLimit(1)
      Spacer(minLength: 8)
      Text(shown.isEmpty ? Strings.shortcutUnset : shown)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(DesignTokens.textSecondary(scheme))
        .lineLimit(1)
      KeyboardShortcuts.Recorder(
        for: name,
        onChange: { shortcut in
          shown = shortcut?.description ?? ""
        })
    }
    .onAppear { shown = KeyboardShortcuts.getShortcut(for: name)?.description ?? "" }
  }
}

private struct ActionIcon: View {
  let symbol: String
  let label: String
  let scheme: ColorScheme
  let action: () -> Void
  @State private var hovered = false

  private var icon: Image {
    symbol == "devbar.settings" ? Image(nsImage: AppIcons.settings) : Image(systemName: symbol)
  }

  var body: some View {
    Button(action: action) {
      icon
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
    case .qr: Strings.pageQR
    case .doc: Strings.tabDocument
    case .settings: Strings.settingsPage
    }
  }

  @MainActor var shortcutName: KeyboardShortcuts.Name {
    switch self {
    case .clipboard: .pageClipboard
    case .json: .pageJSON
    case .qr: .pageQR
    case .doc: .pageDoc
    case .settings: preconditionFailure("Settings has no page shortcut")
    }
  }
}
