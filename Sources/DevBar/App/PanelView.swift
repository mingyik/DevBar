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
  @Bindable var documents: DocumentSession
  @State private var draggedPage: PanelModel.Page?
  @State private var pageFrames: [PanelModel.Page: CGRect] = [:]
  @State private var pageDragLocation: CGPoint?
  @State private var pageDragOffset = CGSize.zero
  @GestureState private var pageDragActive = false
  @State private var screenCaptureAllowed = CGPreflightScreenCaptureAccess()
  @State private var titleHovered = false
  @State private var titleShortcut: String?

  var body: some View {
    let scheme = theme.effective
    let _ = theme.increaseContrast
    Group {
      if model.page == .doc && !model.dropActive {
        ZStack(alignment: .leading) {
          documentSidebar(scheme)
          mainColumn(scheme)
            .frame(width: model.documentContentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      } else {
        mainColumn(scheme)
      }
    }
    .animation(.easeInOut(duration: 0.15), value: model.dropActive)
    .onDrop(of: [.fileURL], delegate: PanelFileDrop(model: model))
    .background { PanelChrome(theme: theme, scheme: scheme) }
    .clipShape(panelShape)
    .environment(\.colorScheme, scheme)
    .onAppear(perform: refreshTitleShortcut)
    .onChange(of: model.page) { _, _ in refreshTitleShortcut() }
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
      refreshTitleShortcut()
    }
  }

  private func documentSidebar(_ scheme: ColorScheme) -> some View {
    HStack(spacing: 0) {
      DocumentSidebarView(
        theme: theme, session: documents, width: model.documentSidebarWidth,
        onOpen: { model.onOpenDocument?($0) },
        onOpenDraft: { model.onOpenDocumentDraft?($0) },
        onPick: { model.onPickDocument?() }
      )
      Rectangle()
        .fill(DesignTokens.lineDivider(scheme))
        .frame(width: 0.7)
        .padding(.vertical, 10)
    }
    .frame(width: model.documentSidebarPresentationWidth, alignment: .leading)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .clipped()
  }

  private func mainColumn(_ scheme: ColorScheme) -> some View {
    VStack(spacing: 0) {
      if model.dropActive {
        FileDropOverlay(scheme: scheme)
      } else {
        titleRow(scheme).frame(height: 32).padding(.bottom, 8)
        ZStack {
          content(scheme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if !model.toast.isEmpty {
          Text(model.toast).font(.system(size: 11))
            .foregroundStyle(DesignTokens.textSecondary(scheme)).lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.top, 12)
    .padding(.bottom, 10)
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
  }

  private func refreshTitleShortcut() {
    guard model.page != .settings else {
      titleShortcut = nil
      return
    }
    titleShortcut = KeyboardShortcuts.getShortcut(for: model.page.shortcutName)?.description
  }

  private var panelShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous)
  }

  private func titleRow(_ scheme: ColorScheme) -> some View {
    HStack(spacing: 8) {
      if model.page == .doc {
        sidebarButton(scheme)
      }
      if model.page == .settings {
        Button {
          model.leaveSettings()
        } label: {
          Label {
            Text(Strings.settingsBack)
          } icon: {
            Image(systemName: "chevron.left").devbarIconColor(scheme)
          }.font(.system(size: 13))
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
            if let titleShortcut {
              Text(titleShortcut).font(.system(size: 11))
                .foregroundStyle(DesignTokens.textTertiary(scheme))
            }
          }.lineLimit(1)
        }.buttonStyle(.plain).onHover { titleHovered = $0 }
      }
      Spacer(minLength: 8)
      if model.page == .doc {
        Button {
          webHost.cycleDocumentMode()
        } label: {
          Group {
            if model.documentDisplay == "split" {
              Image(nsImage: AppIcons.documentEdit).resizable().frame(width: 16, height: 16)
            } else {
              Image(systemName: model.documentDisplay == "source" ? "eye" : "rectangle.split.2x1")
                .font(.system(size: 13))
            }
          }
          .devbarIconColor(scheme)
          .frame(width: 24, height: 24)
        }
        .buttonStyle(DevBarSurfaceButtonStyle(scheme: scheme))
        .help(
          model.documentDisplay == "source"
            ? Strings.documentPreview
            : model.documentDisplay == "preview" ? Strings.documentSplit : Strings.documentEdit
        )
        .accessibilityLabel(
          model.documentDisplay == "source"
            ? Strings.documentPreview
            : model.documentDisplay == "preview" ? Strings.documentSplit : Strings.documentEdit)
      }
      NativeCloseButton {
        model.onClosePanel?()
      }
      .frame(width: 24, height: 24)
    }
  }

  private func sidebarButton(_ scheme: ColorScheme) -> some View {
    Button(action: { model.onToggleDocumentSidebar?() }) {
      Image(systemName: "sidebar.left").devbarIconColor(scheme)
        .font(.system(size: 13, weight: .regular))
        .frame(width: 24, height: 24)
        .foregroundStyle(DesignTokens.textSecondary(scheme))
    }
    .buttonStyle(DevBarSurfaceButtonStyle(scheme: scheme))
    .help(Strings.documentSidebar)
    .accessibilityLabel(Strings.documentSidebar)
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

  /// 松手后被拖页面在列表里的最终位置：指针上方有几行，就排在第几位。
  private func pageDropIndex(_ y: CGFloat, dragging source: PanelModel.Page) -> Int? {
    guard model.pageOrder.contains(source) else { return nil }
    var index = 0
    for candidate in model.pageOrder where candidate != source {
      guard let frame = pageFrames[candidate] else { return nil }
      if y > frame.midY { index += 1 }
    }
    return index
  }

  /// 插入线画在目标行的哪一边：往下拖画在下边，往上拖画在上边。
  private func pageDropEdge(for page: PanelModel.Page) -> Alignment? {
    guard let source = draggedPage, source != page, let location = pageDragLocation,
      let from = model.pageOrder.firstIndex(of: source),
      let index = pageDropIndex(location.y, dragging: source), index != from,
      model.pageOrder.indices.contains(index), model.pageOrder[index] == page
    else { return nil }
    return index > from ? .bottom : .top
  }

  /// 被拖的行只在页面列表范围内上下移动。
  private func pageDragClampedOffset(_ page: PanelModel.Page) -> CGFloat {
    let frames = model.pageOrder.compactMap { pageFrames[$0] }
    guard let own = pageFrames[page], let top = frames.map(\.minY).min(),
      let bottom = frames.map(\.maxY).max()
    else { return 0 }
    return min(max(pageDragOffset.height, top - own.minY), bottom - own.maxY)
  }

  private func settings(_ scheme: ColorScheme) -> some View {
    ScrollViewReader { proxy in
      ReadOnlyScrollView(scheme: scheme) {
        VStack(alignment: .leading, spacing: 16) {
          settingsHeading(Strings.generalGroup, scheme: scheme).padding(.top, 5).id("general")
          HStack {
            Text(Strings.appearance).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 12)
            Picker(Strings.appearance, selection: $theme.mode) {
              Text(Strings.followSystem).tag(ThemeMode.system)
              Text(Strings.light).tag(ThemeMode.light)
              Text(Strings.dark).tag(ThemeMode.dark)
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
              .frame(width: SettingsControlLayout.width)
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
          HStack {
            Text(Strings.autoImport).font(.system(size: 13))
            Spacer(minLength: 12)
            Toggle(Strings.autoImport, isOn: $model.autoImport)
              .labelsHidden().toggleStyle(.switch)
          }
          shortcut(Strings.shortcutToggle, .togglePanel, scheme)
          settingsHeading(Strings.clipboardGroup, scheme: scheme).id("clipboard")
          HistoryLimitRow(clipboard: clipboard, scheme: scheme).disabled(storage.busy)
          shortcut(Strings.shortcutOlder, .cycleOlder, scheme)
          directPasteAuthorization(scheme)
          settingsHeading(Strings.captureGroup, scheme: scheme).id("capture")
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(Strings.capturePermission).font(.system(size: 13))
              Text(screenCaptureAllowed ? Strings.captureAllowed : Strings.captureDenied)
                .font(.system(size: 11)).foregroundStyle(DesignTokens.textSecondary(scheme))
            }
            Spacer(minLength: 12)
            Button {
              CaptureCoordinator.openScreenSettings()
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "gearshape").devbarIconColor(scheme).font(.system(size: 12))
                Text(Strings.systemSettingsButton)
                Image(systemName: "arrow.up.right").devbarIconColor(scheme).font(
                  .system(size: 9, weight: .medium))
              }.font(.system(size: 12)).padding(.horizontal, 10).frame(
                width: SettingsControlLayout.width, height: 30)
            }.buttonStyle(DevBarSurfaceButtonStyle(scheme: scheme))
          }
          shortcut(Strings.shortcutCapture, .captureRegion, scheme)
          shortcut(Strings.shortcutLong, .captureScroll, scheme)
          settingsHeading(Strings.pageShortcuts, scheme: scheme).id("shortcuts")
          ForEach(model.pageOrder, id: \.self) { page in
            HStack(spacing: 10) {
              Image(systemName: "line.3.horizontal")
                .font(.system(size: 12)).foregroundStyle(DesignTokens.textTertiary(scheme))
                .frame(width: 18, height: 28).contentShape(Rectangle())
                .help(Strings.reorderPages)
                .accessibilityLabel(Strings.reorderPages + " " + page.title)
                .highPriorityGesture(
                  DragGesture(minimumDistance: 4, coordinateSpace: .named("page-order"))
                    .updating($pageDragActive) { _, active, _ in active = true }
                    .onChanged { value in
                      draggedPage = page
                      pageDragLocation = value.location
                      pageDragOffset = value.translation
                    }
                    .onEnded { value in
                      if let index = pageDropIndex(value.location.y, dragging: page),
                        model.pageOrder.indices.contains(index)
                      {
                        model.movePage(page, to: model.pageOrder[index])
                      }
                      draggedPage = nil
                      pageDragLocation = nil
                      pageDragOffset = .zero
                    }
                )
              Text(page.title).font(.system(size: 13)).lineLimit(1)
              Spacer(minLength: 8)
              Toggle(
                page.title,
                isOn: Binding(
                  get: { model.participatesInCycle(page) },
                  set: { model.setCycleParticipation(page, enabled: $0) })
              )
              .labelsHidden().toggleStyle(.switch).controlSize(.mini)
              .disabled(!model.canChangeCycleParticipation(page))
              .help(Strings.pageCycleSwitchHelp)
              KeyboardShortcuts.Recorder(for: page.shortcutName).frame(
                width: SettingsControlLayout.width)
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { proxy in
              proxy.frame(in: .named("page-order"))
            } action: { frame in
              pageFrames[page] = frame
            }
            .background {
              if draggedPage == page {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .fill(DesignTokens.panelControl(scheme)).padding(.horizontal, -6)
              }
            }
            .offset(y: draggedPage == page ? pageDragClampedOffset(page) : 0)
            .zIndex(draggedPage == page ? 1 : 0)
            .overlay {
              if let edge = pageDropEdge(for: page) {
                Rectangle().fill(DesignTokens.textPrimary(scheme)).frame(height: 2)
                  .frame(maxHeight: .infinity, alignment: edge)
                  .offset(y: edge == .top ? -8 : 8)
                  .allowsHitTesting(false)
              }
            }
          }
          Text(Strings.aboutBody).font(.system(size: 11)).foregroundStyle(
            DesignTokens.textSecondary(scheme))
        }.foregroundStyle(DesignTokens.textPrimary(scheme))
          .frame(maxWidth: .infinity, alignment: .leading)
          .coordinateSpace(name: "page-order")
          .onChange(of: pageDragActive) { _, active in
            if !active {
              draggedPage = nil
              pageDragLocation = nil
              pageDragOffset = .zero
            }
          }
          .onDisappear {
            draggedPage = nil
            pageDragLocation = nil
            pageDragOffset = .zero
          }
      }.task(id: model.settingsOpenGeneration) {
        await Task.yield()
        guard !Task.isCancelled else { return }
        proxy.scrollTo("general", anchor: .top)
        while !Task.isCancelled {
          if NSApp.isActive {
            clipboard.refreshDirectPasteAuthorization()
            screenCaptureAllowed = CGPreflightScreenCaptureAccess()
          }
          try? await Task.sleep(for: .seconds(1))
        }
      }
    }
  }

  private func settingsHeading(_ title: String, scheme: ColorScheme) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Rectangle().fill(DesignTokens.lineDivider(scheme)).frame(height: 0.5)
      Text(title).font(.system(size: 13, weight: .semibold))
    }.frame(maxWidth: .infinity, alignment: .leading)
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
          Image(systemName: "folder").devbarIconColor(scheme).font(.system(size: 12))
          Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).truncationMode(.middle)
          Image(systemName: "chevron.down").devbarIconColor(scheme).font(
            .system(size: 9, weight: .medium))
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
          Image(systemName: "gearshape").devbarIconColor(scheme).font(.system(size: 12))
          Text(Strings.systemSettingsButton)
          Image(systemName: "arrow.up.right").devbarIconColor(scheme).font(
            .system(size: 9, weight: .medium))
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

private struct NativeCloseButton: NSViewRepresentable {
  let action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(action: action) }

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    guard let button = NSWindow.standardWindowButton(.closeButton, for: .titled) else {
      return container
    }
    button.target = context.coordinator
    button.action = #selector(Coordinator.close)
    button.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(button)
    NSLayoutConstraint.activate([
      button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    return container
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.action = action
  }

  final class Coordinator: NSObject {
    var action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    @objc func close() { action() }
  }
}

private struct ActionIcon: View {
  let symbol: String
  let label: String
  let scheme: ColorScheme
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).devbarIconColor(scheme)
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

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
    guard let width = proposal.width, let height = proposal.height else { return nil }
    return CGSize(width: max(0, width), height: max(0, height))
  }

  private func mount(_ view: NSView, in container: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = true
    view.autoresizingMask = [.width, .height]
    view.frame = container.bounds
    container.addSubview(view)
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
