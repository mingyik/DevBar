import AppKit
import DevBarCapture
import DevBarCore
import Observation
import SwiftUI

@MainActor @Observable
private final class CaptureHUDState {
  var height = 0
  var unmatched = false
  var message = ""
  var path: URL?
  var finish: (() -> Void)?
  var save: (() -> Void)?
  var saveToDisk = false
  var cancel: (() -> Void)?
}

@MainActor final class CaptureCoordinator {
  private unowned let panel: PanelController
  private var task: Task<Void, Never>?
  private var hud: NSPanel?
  private let state = CaptureHUDState()
  private var noticeTask: Task<Void, Never>?

  init(panel: PanelController) { self.panel = panel }

  static func openScreenSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    {
      NSWorkspace.shared.open(url)
    }
  }

  func start(scrolling: Bool) {
    guard task == nil else { return }
    panel.dismiss()
    if !CGPreflightScreenCaptureAccess() {
      let key = "screenCapturePermissionRequested"
      if !UserDefaults.standard.bool(forKey: key) {
        UserDefaults.standard.set(true, forKey: key)
        _ = CGRequestScreenCaptureAccess()
        return
      }
      let alert = NSAlert()
      alert.messageText = Strings.capturePermissionTitle
      alert.informativeText = Strings.capturePermissionBody
      alert.addButton(withTitle: Strings.capturePermissionSettings)
      alert.addButton(withTitle: Strings.captureCancel)
      if alert.runModal() == .alertFirstButtonReturn { Self.openScreenSettings() }
      return
    }
    noticeTask?.cancel()
    hud?.orderOut(nil)
    task = Task { [weak self] in
      guard let self else { return }
      defer { self.task = nil }
      do {
        let selection = SelectionOverlay(
          appearanceName: self.panel.theme.appearance()?.name,
          iconColor: NSColor(DesignTokens.iconPrimary(self.panel.theme.effective)),
          disabledIconColor: NSColor(DesignTokens.iconDisabled(self.panel.theme.effective)))
        let selected = scrolling ? nil : try await selection.selectImage()
        let scrolling = scrolling || selection.scrollingRequested
        let image: CGImage
        var completionMessage = Strings.captureSaved
        if scrolling {
          let region: CaptureRegion
          if let selected {
            region = selected.0
          } else {
            region = try await selection.select(freeze: false)
          }
          let finish = ScreenshotScrollingCapture.FinishSignal()
          self.showProgress(region: region, finish: finish)
          if selection.saveRequested {
            self.state.saveToDisk = true
            finish.request()
          }
          let result = await ScreenshotScrollingCapture.capture(
            region: region, finishSignal: finish
          ) {
            [weak self] height, unmatched in
            self?.state.height = height
            if let self, self.state.unmatched != unmatched {
              self.state.unmatched = unmatched
              self.resizeHUDForProgress()
            }
          }
          self.hud?.orderOut(nil)
          switch result {
          case .success(let resultImage): image = resultImage
          case .partial(let resultImage):
            image = resultImage
            completionMessage = Strings.capturePartial
          case .limited(let resultImage):
            image = resultImage
            completionMessage = Strings.captureLimit
          case .cancelled: return
          case .failed:
            self.showNotice(Strings.captureFailed, path: nil)
            return
          }
        } else {
          guard let selected else { return }
          image = selected.1
        }
        try Task.checkCancellation()
        if scrolling && !self.state.saveToDisk {
          let data = try await Task.detached { try CaptureFileWriter.encode(image) }.value
          let copied = PasteboardBridge.writePNG(data, file: nil)
          if copied {
            self.panel.clipboard.monitor.markSelfWrite(NSPasteboard.general.changeCount)
            if let capture = ClipboardCapture(payloads: [
              ClipboardPayload(type: NSPasteboard.PasteboardType.png.rawValue, data: data)
            ]) {
              await self.panel.clipboard.record(capture, source: nil, allowOversizedImage: true)
            }
          }
          self.showNotice(copied ? Strings.captureCopied : Strings.captureFailed, path: nil)
          return
        }
        let directory = URL(fileURLWithPath: self.panel.storage.capturePath, isDirectory: true)
        let result = try await Task.detached(priority: .userInitiated) {
          try CaptureFileWriter.save(image, directory: directory, scrolling: scrolling)
        }.value
        self.showNotice(completionMessage, path: result.0)
      } catch is CancellationError {
        self.hud?.orderOut(nil)
      } catch CaptureError.cancelled {
        self.hud?.orderOut(nil)
      } catch {
        self.hud?.orderOut(nil)
        self.showNotice(Strings.captureFailed, path: nil)
      }
    }
  }

  private func showProgress(region: CaptureRegion, finish: ScreenshotScrollingCapture.FinishSignal)
  {
    state.height = 0
    state.unmatched = false
    state.message = ""
    state.path = nil
    state.saveToDisk = false
    state.finish = { finish.request() }
    state.save = { [weak self] in
      self?.state.saveToDisk = true
      finish.request()
    }
    state.cancel = { [weak self] in
      self?.task?.cancel()
      self?.hud?.orderOut(nil)
    }
    showHUD(displayID: region.displayID)
  }

  private func resizeHUDForProgress() {
    guard let hud else { return }
    var frame = hud.frame
    let top = frame.maxY
    frame.size.height = state.unmatched ? 68 : 48
    frame.origin.y = top - frame.height
    hud.setFrame(frame, display: true)
  }

  private func showNotice(_ message: String, path: URL?) {
    state.message = message
    state.unmatched = false
    state.path = path
    state.finish = nil
    state.save = nil
    state.cancel = nil
    showHUD(displayID: nil)
    noticeTask?.cancel()
    noticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      self?.hud?.orderOut(nil)
    }
  }

  private func showHUD(displayID: CGDirectDisplayID?) {
    let screen =
      NSScreen.screens.first { screen in
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
          .uint32Value == displayID
      } ?? NSScreen.main
    guard let screen else { return }
    let view = CaptureHUD(state: state, theme: panel.theme)
    let window =
      hud
      ?? NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.level = .statusBar
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.appearance = panel.theme.appearance()
    window.contentView = NSHostingView(rootView: view)
    let height: CGFloat = state.unmatched ? 68 : 48
    let width: CGFloat = 380
    let visible = screen.visibleFrame
    window.setFrame(
      NSRect(
        x: visible.midX - width / 2, y: visible.maxY - height - 8, width: width, height: height),
      display: true)
    hud = window
    window.orderFrontRegardless()
  }
}

private struct CaptureHUD: View {
  @Bindable var state: CaptureHUDState
  var theme: ThemeManager
  var body: some View {
    let scheme = theme.effective
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(state.message.isEmpty ? Strings.captureHeight(state.height) : state.message)
          .font(.system(size: 12)).lineLimit(1)
        Spacer(minLength: 4)
        if let finish = state.finish, let cancel = state.cancel {
          if let save = state.save {
            Button(action: save) { Image(systemName: "arrow.down.to.line").devbarIconColor(scheme) }
              .help(
                Strings.captureSave)
          }
          Button(action: cancel) { Image(systemName: "xmark").devbarIconColor(scheme) }.help(
            Strings.captureCancel)
          Button(action: finish) { Image(systemName: "checkmark").devbarIconColor(scheme) }.help(
            Strings.captureFinish)
        } else if let path = state.path {
          Button(Strings.captureReveal) { NSWorkspace.shared.activateFileViewerSelecting([path]) }
        }
      }
      if state.unmatched { Text(Strings.capturePartial).font(.system(size: 10)).lineLimit(1) }
    }
    .foregroundStyle(DesignTokens.textPrimary(scheme))
    .padding(.horizontal, 12).padding(.vertical, 9)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background { PanelChrome(theme: theme, scheme: scheme) }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusLarge))
    .environment(\.colorScheme, scheme)
  }
}
