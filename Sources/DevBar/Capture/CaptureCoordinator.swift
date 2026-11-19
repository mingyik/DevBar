import AppKit
import DevBarCapture
import DevBarCore
import KeyboardShortcuts
import Observation
import SwiftUI
import os

@MainActor @Observable
private final class CaptureHUDState {
  var height = 0
  var preview: NSImage?
  var unmatched = false
  var viewportRange: ClosedRange<Double>?
  var message = ""
  var path: URL?
  var finish: (() -> Void)?
  var save: (() -> Void)?
  var saveToDisk = false
  var cancel: (() -> Void)?
}

@MainActor final class CaptureCoordinator {
  /// The selection overlay uses `.screenSaver`; progress UI must sit above it.
  private static let overlayLevel = NSWindow.Level(
    rawValue: NSWindow.Level.screenSaver.rawValue + 2)
  private unowned let panel: PanelController
  private var task: Task<Void, Never>?
  private var hud: NSPanel?
  private var noticeHUD: NSPanel?
  private var previewWindow: NSPanel?
  private var activeRegion: CaptureRegion?
  private let state = CaptureHUDState()
  private let noticeState = CaptureHUDState()
  private var noticeTask: Task<Void, Never>?
  private var savedNoticeTask: Task<Void, Never>?
  private var escapeTask: Task<Void, Never>?

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
    savedNoticeTask?.cancel()
    noticeHUD?.orderOut(nil)
    task = Task { [weak self] in
      guard let self else { return }
      defer {
        self.stopEscapeMonitor()
        self.task = nil
      }
      guard await self.panel.prepareForCapture() else { return }
      do {
        let insets = ScrollingInsetControl()
        let selection = SelectionOverlay(
          appearanceName: self.panel.theme.appearance()?.name,
          iconColor: NSColor(DesignTokens.captureToolbarIcon(self.panel.theme.effective)),
          disabledIconColor: NSColor(DesignTokens.iconDisabled(self.panel.theme.effective)),
          toolbarTintColor: NSColor(DesignTokens.captureToolbarTint(self.panel.theme.effective)),
          toolbarBorderColor: NSColor(DesignTokens.captureToolbarBorder(self.panel.theme.effective))
        )
        selection.insetControl = insets
        selection.onVisibilityChange = { [weak self] visible in
          if visible {
            self?.startEscapeMonitor()
          } else {
            self?.stopEscapeMonitor()
          }
        }
        defer { selection.dismissScrollingOverlay() }
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
            region: region, finishSignal: finish, insets: insets,
            onInsets: { top, bottom, right in
              selection.setScrollingInsets(top: top, bottom: bottom, right: right)
            },
            onPreview: { [weak self] image in
              guard let self else { return }
              self.state.preview = NSImage(
                cgImage: image, size: NSSize(width: image.width, height: image.height))
              self.showPreview(region: region)
            },
            onLimitReached: { [weak self] in
              guard let self else { return }
              self.state.message = Strings.captureLimitPaused
              self.state.unmatched = false
            },
            onViewportRange: { [weak self] range, located in
              self?.state.viewportRange = range
              self?.state.unmatched = !located
            }
          ) {
            [weak self] height, _ in
            self?.state.height = height
          }
          self.closeProgress()
          selection.dismissScrollingOverlay()
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
        self.closeProgress()
      } catch CaptureError.cancelled {
        self.closeProgress()
      } catch {
        self.closeProgress()
        self.showNotice(Strings.captureFailed, path: nil)
      }
    }
  }

  /// Same result as the progress bar's cancel button: drop the selection or
  /// the in-progress stitch and write nothing.
  func cancel() {
    task?.cancel()
    closeProgress()
  }

  private func closeProgress() {
    stopEscapeMonitor()
    hidePreview()
    hud?.orderOut(nil)
  }

  private func startEscapeMonitor() {
    guard escapeTask == nil else { return }
    KeyboardShortcuts.setShortcut(.init(.escape), for: .captureExit)
    escapeTask = Task { [weak self] in
      guard !Task.isCancelled else { return }
      for await event in KeyboardShortcuts.events(for: .captureExit) where event == .keyUp {
        guard !Task.isCancelled else { return }
        self?.cancel()
      }
    }
  }

  private func stopEscapeMonitor() {
    guard let escapeTask else { return }
    // Clearing the shortcut unregisters it and blocks queued registration.
    KeyboardShortcuts.setShortcut(nil, for: .captureExit)
    escapeTask.cancel()
    self.escapeTask = nil
  }

  private static let scrollLogger = Logger(
    subsystem: "local.devbar.app", category: "scroll-capture")

  private func showProgress(region: CaptureRegion, finish: ScreenshotScrollingCapture.FinishSignal)
  {
    noticeTask?.cancel()
    activeRegion = region
    state.height = 0
    state.preview = nil
    state.viewportRange = nil
    state.unmatched = false
    state.message = ""
    state.path = nil
    state.saveToDisk = false
    state.finish = { finish.request() }
    state.save = { [weak self] in
      self?.state.saveToDisk = true
      finish.request()
    }
    state.cancel = { [weak self] in self?.cancel() }
    showPreview(region: region)
    showHUD(displayID: region.displayID)
    Self.scrollLogger.notice(
      "selection confirmed window=\(region.windowID != nil, privacy: .public) hud=\(self.hud?.isVisible == true, privacy: .public) preview=\(self.previewWindow?.isVisible == true, privacy: .public)"
    )
  }

  private func hidePreview() {
    previewWindow?.orderOut(nil)
    state.preview = nil
  }

  private func showPreview(region: CaptureRegion) {
    guard
      let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == region.displayID
      })
    else { return }
    let visible = screen.visibleFrame
    let width: CGFloat = min(160, visible.width)
    let maximumHeight = floor(visible.height * 2 / 3)
    let imageSize = state.preview?.size
    let fittedHeight =
      imageSize.map { size in
        ceil(max(1, width - 16) * size.height / max(1, size.width)) + 16
      } ?? 64
    let height = min(maximumHeight, max(64, fittedHeight))
    let rect = CGRect(
      x: screen.frame.minX + region.rectInPoints.minX,
      y: screen.frame.maxY - region.rectInPoints.maxY,
      width: region.rectInPoints.width, height: region.rectInPoints.height)
    let fitsRight = rect.maxX + width + 8 <= visible.maxX
    let fitsLeft = rect.minX - width - 8 >= visible.minX
    let x: CGFloat
    let y: CGFloat
    if fitsRight || fitsLeft {
      x = fitsRight ? rect.maxX + 8 : rect.minX - width - 8
      y = rect.maxY - height
    } else if rect.minY - maximumHeight - 8 >= visible.minY {
      x = min(max(rect.maxX - width, visible.minX + 8), visible.maxX - width - 8)
      y = rect.minY - height - 8
    } else {
      x = min(max(rect.maxX - width, visible.minX + 8), visible.maxX - width - 8)
      y = rect.maxY + 8
    }
    let frame = PanelLayout.clamp(
      CGRect(x: x, y: y, width: width, height: height), in: visible)
    if let window = previewWindow, window.isVisible {
      if window.frame != frame { window.setFrame(frame, display: true) }
      return
    }
    let window =
      previewWindow
      ?? NSPanel(
        contentRect: frame,
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.sharingType = .none
    window.level = Self.overlayLevel
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.ignoresMouseEvents = true
    window.animationBehavior = .none
    window.appearance = panel.theme.appearance()
    window.contentView = NSHostingView(
      rootView: ScrollingCapturePreview(state: state, theme: panel.theme))
    window.setFrame(frame, display: true)
    previewWindow = window
    window.orderFrontRegardless()
  }

  private func showNotice(_ message: String, path: URL?) {
    hidePreview()
    activeRegion = nil
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

  func showSavedNotice(_ message: String, path: URL?) {
    noticeState.message = message
    noticeState.unmatched = false
    noticeState.path = path
    noticeState.finish = nil
    noticeState.save = nil
    noticeState.cancel = nil
    guard
      let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main
    else { return }
    let view = CaptureHUD(state: noticeState, theme: panel.theme)
    let window =
      noticeHUD
      ?? NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.sharingType = .none
    window.level = Self.overlayLevel
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.animationBehavior = .none
    window.appearance = panel.theme.appearance()
    window.contentView = NSHostingView(rootView: view)
    let height: CGFloat = 43
    let width: CGFloat = 380
    let visible = screen.visibleFrame
    let frame = PanelLayout.clamp(
      CGRect(
        x: visible.maxX - width - 12, y: visible.maxY - height - 8,
        width: width, height: height), in: visible)
    window.setFrame(frame, display: true)
    noticeHUD = window
    window.orderFrontRegardless()
    savedNoticeTask?.cancel()
    savedNoticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      self?.noticeHUD?.orderOut(nil)
    }
  }

  static func progressFrame(region: CaptureRegion, screen: CGRect, visible: CGRect, size: CGSize)
    -> CGRect
  {
    let rect = CGRect(
      x: screen.minX + region.rectInPoints.minX,
      y: screen.maxY - region.rectInPoints.maxY,
      width: region.rectInPoints.width, height: region.rectInPoints.height)
    let below = rect.minY - size.height - 8
    let above = rect.maxY + 8
    let y = below >= visible.minY ? below : above + size.height <= visible.maxY ? above : below
    return PanelLayout.clamp(
      CGRect(
        x: rect.maxX - size.width, y: y,
        width: size.width, height: size.height), in: visible)
  }

  private func showHUD(displayID: CGDirectDisplayID?) {
    let screen =
      NSScreen.screens.first { screen in
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
          .uint32Value == displayID
      }
      ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
      ?? NSScreen.main
    guard let screen else { return }
    let view = CaptureHUD(state: state, theme: panel.theme)
    let window =
      hud
      ?? NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.sharingType = .none
    window.level = Self.overlayLevel
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.animationBehavior = .none
    window.appearance = panel.theme.appearance()
    window.contentView = NSHostingView(rootView: view)
    let height: CGFloat = 43
    let width: CGFloat = 380
    let visible = screen.visibleFrame
    let frame: CGRect
    if let region = activeRegion {
      frame = Self.progressFrame(
        region: region, screen: screen.frame,
        visible: visible, size: CGSize(width: width, height: height))
    } else {
      frame = PanelLayout.clamp(
        CGRect(
          x: visible.maxX - width - 12, y: visible.maxY - height - 8,
          width: width, height: height), in: visible)
    }
    window.setFrame(frame, display: true)
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
            Button(action: save) {
              Image(systemName: "arrow.down.to.line").foregroundStyle(
                DesignTokens.captureToolbarIcon(scheme)
              ).font(
                .system(size: 12))
            }
            .help(
              Strings.captureSave)
          }
          Button(action: cancel) {
            Image(systemName: "xmark").foregroundStyle(DesignTokens.captureToolbarIcon(scheme))
              .font(.system(size: 12))
          }.help(
            Strings.captureCancel)
          Button(action: finish) {
            Image(systemName: "checkmark").foregroundStyle(DesignTokens.captureToolbarIcon(scheme))
              .font(.system(size: 12))
          }.help(
            Strings.captureFinish)
        } else if let path = state.path {
          Button(Strings.captureReveal) { NSWorkspace.shared.activateFileViewerSelecting([path]) }
        }
      }
    }
    .foregroundStyle(DesignTokens.textPrimary(scheme))
    .padding(.horizontal, 12).padding(.vertical, 9)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background { PanelChrome(theme: theme, scheme: scheme) }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusLarge))
    .environment(\.colorScheme, scheme)
  }
}

private struct ScrollingCapturePreview: View {
  @Bindable var state: CaptureHUDState
  let theme: ThemeManager
  var body: some View {
    Group {
      if let image = state.preview {
        GeometryReader { geometry in
          let available = CGSize(
            width: max(1, geometry.size.width - 16),
            height: max(1, geometry.size.height - 16))
          let scale = min(
            available.width / max(1, image.size.width),
            available.height / max(1, image.size.height))
          let width = image.size.width * scale
          let height = image.size.height * scale
          Image(nsImage: image)
            .resizable()
            .frame(width: width, height: height)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .topLeading) {
              if let range = state.viewportRange {
                let cursorHeight = min(
                  height, max(6, height * (range.upperBound - range.lowerBound)))
                let y =
                  (geometry.size.height - height) / 2
                  + min(height - cursorHeight, height * range.lowerBound)
                Group {
                  if state.unmatched {
                    Capsule().strokeBorder(DesignTokens.textPrimary(theme.effective), lineWidth: 1)
                  } else {
                    Capsule().fill(Color(nsColor: .systemGreen))  // devbar:allow-color
                  }
                }
                .frame(width: 5, height: cursorHeight)
                .offset(x: 4, y: y)
                .accessibilityLabel(
                  state.unmatched ? Strings.captureRecoveryMarker : Strings.captureViewportMarker)
              }
            }
        }
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background { PanelChrome(theme: theme, scheme: theme.effective) }
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .environment(\.colorScheme, theme.effective)
  }
}
