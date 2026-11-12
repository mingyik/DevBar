import AppKit
import DevBarCore
import KeyboardShortcuts
import SwiftUI

private enum SettingsControlLayout {
  static let width: CGFloat = 130
}

struct PanelView: View {
  @Bindable var model: PanelModel
  @Bindable var theme: ThemeManager
  var webHost: WebHost
  var clipboard: ClipboardController
  @Bindable var storage: StorageSettings
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
      if !model.dropActive && !model.toast.isEmpty {
        Text(model.toast).font(.system(size: 11))
          .foregroundStyle(DesignTokens.textSecondary(scheme)).lineLimit(1)
      }
    }
    .animation(.easeInOut(duration: 0.15), value: model.dropActive)
    .padding(.horizontal, 10)
    .padding(.top, 12)
    .padding(.bottom, 10)
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
      ClipboardListView(controller: clipboard, scheme: scheme).padding(.horizontal, -4)
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
          storageLocation(Strings.dataLocation, path: storage.dataPath, scheme: scheme) {
            storage.chooseDataLocation()
          }.disabled(storage.busy)
          storageLocation(Strings.captureLocation, path: storage.capturePath, scheme: scheme) {
            storage.chooseCaptureLocation()
          }.disabled(storage.busy)
          if !storage.message.isEmpty {
            Text(storage.message).font(.system(size: 11)).foregroundStyle(
              DesignTokens.textSecondary(scheme))
          }
          Toggle(Strings.autoImport, isOn: $model.autoImport)
          shortcut(Strings.shortcutToggle, .togglePanel, scheme)
          Text(Strings.clipboardGroup).font(.system(size: 13, weight: .semibold)).id("clipboard")
          HistoryLimitRow(clipboard: clipboard, scheme: scheme).disabled(storage.busy)
          shortcut(Strings.shortcutOlder, .cycleOlder, scheme)
          directPasteAuthorization(scheme)
          Text(Strings.captureGroup).font(.system(size: 13, weight: .semibold)).id("capture")
          shortcut(Strings.shortcutCapture, .captureRegion, scheme)
          shortcut(Strings.shortcutLong, .captureScroll, scheme)
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
        while !Task.isCancelled {
          if NSApp.isActive { clipboard.refreshDirectPasteAuthorization() }
          try? await Task.sleep(for: .seconds(1))
        }
      }
    }
  }

  private func storageLocation(
    _ title: String, path: String, scheme: ColorScheme, action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 13)).lineLimit(1)
        Text(path).font(.system(size: 11))
          .foregroundStyle(DesignTokens.textSecondary(scheme))
          .lineLimit(1).truncationMode(.head).help(path)
          .frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxWidth: .infinity, alignment: .leading)
      Spacer(minLength: 32)
      Button(action: action) {
        HStack(spacing: 6) {
          Image(systemName: "folder").font(.system(size: 12))
          Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).truncationMode(.middle)
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
        }
        .font(.system(size: 12)).padding(.horizontal, 10).frame(
          width: SettingsControlLayout.width, height: 30)
      }
      .buttonStyle(DevBarSurfaceButtonStyle(scheme: scheme))
      .help(path).accessibilityLabel(title).accessibilityValue(path)
    }
  }

  private func directPasteAuthorization(_ scheme: ColorScheme) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(Strings.directPaste).font(.system(size: 13))
        Text(
          clipboard.isDirectPasteAuthorized
            ? Strings.directPasteAuthorized : Strings.directPasteUnauthorized
        )
        .font(.system(size: 11)).foregroundStyle(DesignTokens.textSecondary(scheme))
      }
      Spacer(minLength: 12)
      Button {
        clipboard.openAccessibilitySettings()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "gearshape").font(.system(size: 12))
          Text(Strings.systemSettingsButton)
          Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
        }.font(.system(size: 12)).padding(.horizontal, 10).frame(
          width: SettingsControlLayout.width, height: 30)
      }.buttonStyle(DevBarSurfaceButtonStyle(scheme: scheme))
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
        .environment(\.appearsActive, true)
        .materialActiveAppearance(.active)
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

private struct HistoryLimitRow: View {
  @Bindable var clipboard: ClipboardController
  let scheme: ColorScheme
  @State private var draft = ""
  @FocusState private var focused: Bool
  var body: some View {
    HStack {
      Text(Strings.historyLimitTitle).font(.system(size: 13))
      Spacer(minLength: 12)
      TextField(Strings.historyLimitPlaceholder, text: $draft)
        .textFieldStyle(.plain).font(.system(size: 12)).multilineTextAlignment(.center)
        .padding(.horizontal, 10).frame(width: SettingsControlLayout.width, height: 30)
        .background(DesignTokens.panelControl(scheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8).strokeBorder(
            DesignTokens.lineBorder(scheme), lineWidth: DesignTokens.strokeHairline
          ).allowsHitTesting(false)
        }
        .focused($focused).onSubmit(commit)
        .accessibilityLabel(Strings.historyLimitTitle)
    }
    .onAppear { draft = String(clipboard.historyLimit) }
    .onChange(of: focused) { _, active in if !active { commit() } }
    .onChange(of: clipboard.historyLimit) { _, value in if !focused { draft = String(value) } }
  }
  private func commit() {
    guard let value = Int(draft.trimmingCharacters(in: .whitespaces)), (3...30).contains(value)
    else {
      draft = String(clipboard.historyLimit)
      return
    }
    guard value != clipboard.historyLimit else { return }
    Task {
      await clipboard.setHistoryLimit(value)
      if !focused { draft = String(clipboard.historyLimit) }
    }
  }
}

private struct ShortcutRow: View {
  let title: String
  let name: KeyboardShortcuts.Name
  let scheme: ColorScheme
  var body: some View {
    HStack {
      Text(title).font(.system(size: 13)).foregroundStyle(DesignTokens.textPrimary(scheme))
        .lineLimit(1)
      Spacer(minLength: 12)
      KeyboardShortcuts.Recorder(for: name).frame(width: SettingsControlLayout.width)
    }
  }
}

private struct ActionIcon: View {
  let symbol: String
  let label: String
  let scheme: ColorScheme
  let action: () -> Void
  private var icon: Image {
    symbol == "devbar.settings" ? Image(nsImage: AppIcons.settings) : Image(systemName: symbol)
  }

  var body: some View {
    Button(action: action) {
      icon
        .font(.system(size: 13, weight: .regular))
        .frame(width: 24, height: 24)
        .foregroundStyle(DesignTokens.textSecondary(scheme))
    }
    .buttonStyle(DevBarSurfaceButtonStyle(scheme: scheme))
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
