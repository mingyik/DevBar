#if DEBUG
  import AppKit
  import DevBarCore
  import SwiftUI

  /// Isolated native UI fixtures; never starts the general-pasteboard monitor.
  @MainActor enum R7UICheck {
    static func runIfRequested(panel: PanelController) {
      let args = CommandLine.arguments
      guard let index = args.firstIndex(of: "--devbar-uicheck"), index + 3 < args.count else {
        return
      }
      let output = URL(fileURLWithPath: args[index + 1])
      let theme = args[index + 2]
      let size = args[index + 3]
      Task {
        panel.theme.mode = theme == "dark" ? .dark : .light
        let fixtures = [
          "SELECT * FROM users;\nWHERE active = true;",
          "https://example.com/docs?lang=zh",
          "{\"message\": \"保留原始内容\"}",
          "第一行内容\n第二行内容",
          "#7A96CB",  // devbar:allow-color
          "hello, clipboard",
          "<div>\n  content\n</div>",
          "URL 与富文本原始表示一起保存",
        ]
        for text in fixtures {
          let capture = ClipboardCapture(payloads: [
            ClipboardPayload(
              type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
          ])!
          await panel.clipboard.record(capture, source: "com.apple.TextEdit")
        }
        let fixturesDirectory = FileManager.default.temporaryDirectory.appending(
          path: "devbar-r7-drag-fixtures")
        try? FileManager.default.createDirectory(
          at: fixturesDirectory, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 900, height: 600))
        image.lockFocus()
        NSColor(DesignTokens.panelBase(panel.theme.effective)).setFill()
        NSRect(x: 0, y: 0, width: 900, height: 600).fill()
        NSColor(DesignTokens.textPrimary(panel.theme.effective)).setFill()
        NSRect(x: 100, y: 100, width: 500, height: 300).fill()
        image.unlockFocus()
        var imageBytes = 0
        if let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
        {
          imageBytes = png.count
          try? png.write(to: fixturesDirectory.appending(path: "original.png"))
          let capture = ClipboardCapture(payloads: [
            ClipboardPayload(type: NSPasteboard.PasteboardType.png.rawValue, data: png)
          ])!
          await panel.clipboard.record(capture, source: "com.apple.Preview")
        }
        var files: [ClipboardPayload] = []
        for name in ["first.txt", "second.txt"] {
          let url = fixturesDirectory.appending(path: name)
          try? Data("DevBar synthetic drag fixture".utf8).write(to: url)
          files.append(
            ClipboardPayload(
              type: NSPasteboard.PasteboardType.fileURL.rawValue,
              data: Data(url.absoluteString.utf8)))
        }
        await panel.clipboard.record(ClipboardCapture(payloads: files)!, source: "com.apple.finder")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let order = panel.clipboard.items.map(\.id)
        var timings: [Double] = []
        for _ in 0..<15 {
          let started = ContinuousClock.now
          panel.clipboard.cycle(older: true, board: board)
          let elapsed = started.duration(to: .now).components
          timings.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
          try? await Task.sleep(for: .milliseconds(30))
        }
        let noReorder = order == panel.clipboard.items.map(\.id)
        panel.clipboard.select(0, board: board)
        panel.clipboard.card.dismiss()
        if args.contains("--empty-error") {
          await panel.clipboard.clear()
          let tooLarge = ClipboardCapture(payloads: [
            ClipboardPayload(
              type: "public.jpeg",
              data: Data(repeating: 1, count: ClipboardStore.imageByteLimit + 1))
          ])!
          await panel.clipboard.record(tooLarge, source: nil)
        }
        panel.model.page =
          args.first(where: { $0.hasPrefix("--page=") })
          .flatMap { PanelModel.Page(rawValue: String($0.dropFirst(7))) }
          ?? (size == "large" ? .json : .clipboard)
        panel.model.enlarged = size == "large"
        panel.show(anchor: nil)
        try? await Task.sleep(for: .milliseconds(900))
        if size != "large" {
          panel.clipboard.focusedIndex = 1
          try? await Task.sleep(for: .milliseconds(100))
          panel.clipboard.focusedIndex = 0
          try? await Task.sleep(for: .milliseconds(100))
        }
        let initial = panel.model.page
        panel.open(page: .qr, anchor: nil)
        let opensQR = panel.model.page == .qr && panel.panel.isVisible
        panel.open(page: .qr, anchor: nil)
        let sameStaysOpen = panel.panel.isVisible
        panel.model.page = initial
        panel.show(anchor: nil)
        try? await Task.sleep(for: .milliseconds(700))
        if args.contains("--scrolling") {
          panel.clipboard.focusedIndex = 8
          try? await Task.sleep(for: .milliseconds(80))
        }
        let results: [String: Any] = [
          "processID": ProcessInfo.processInfo.processIdentifier,
          "windowNumber": panel.panel.windowNumber,
          "frame": [
            panel.panel.frame.minX, panel.panel.frame.minY, panel.panel.frame.width,
            panel.panel.frame.height,
          ],
          "scale": panel.panel.backingScaleFactor,
          "increaseContrast": panel.theme.increaseContrast,
          "reduceTransparency": panel.theme.reduceTransparency,
          "originalImageBytes": imageBytes,
          "fixturesDirectory": fixturesDirectory.path,
          "historyCount": panel.clipboard.items.count,
          "orderUnchangedAfter15Cycles": noReorder,
          "cycleToOrderFrontMilliseconds": timings,
          "pageShortcutOpensQR": opensQR,
          "samePageShortcutStaysOpen": sameStaysOpen,
          "page": panel.model.page.rawValue,
        ]
        if let data = try? JSONSerialization.data(
          withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        {
          try? data.write(to: output)
        }
        // Stays open for screenshots or physical drag acceptance; close this Debug process afterwards.
      }
    }
  }
#endif
