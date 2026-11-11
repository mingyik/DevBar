import AppKit
import DevBarCore
import SwiftUI

struct ClipboardListView: View {
  @Bindable var controller: ClipboardController
  let scheme: ColorScheme
  @State private var confirmingClear = false
  @State private var confirmation: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      authorization
      if controller.items.isEmpty {
        Text(Strings.clipboardEmpty).font(.system(size: 13))
          .foregroundStyle(DesignTokens.textSecondary(scheme)).lineLimit(1)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                ClipboardRow(controller: controller, item: item, index: index, scheme: scheme)
                  .id(item.id)
                if index < controller.items.count - 1 {
                  Rectangle().fill(DesignTokens.lineDivider(scheme)).frame(height: 0.7)
                }
              }
            }
          }
          .defaultScrollAnchor(.top)
          .onAppear {
            if controller.items.indices.contains(controller.focusedIndex) {
              proxy.scrollTo(controller.items[controller.focusedIndex].id, anchor: .top)
            }
          }
          .onChange(of: controller.items.first?.id) { _, id in
            if let id { proxy.scrollTo(id, anchor: .top) }
          }
          .onChange(of: controller.focusedIndex) { _, index in
            if controller.items.indices.contains(index) {
              proxy.scrollTo(controller.items[index].id, anchor: .top)
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        HStack {
          Text(controller.message).lineLimit(1)
          Spacer()
          Button(confirmingClear ? Strings.confirmClear : Strings.clearHistory) {
            if confirmingClear {
              confirmation?.cancel()
              confirmingClear = false
              Task { await controller.clear() }
            } else {
              confirmingClear = true
              confirmation = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                confirmingClear = false
              }
            }
          }.buttonStyle(.plain).lineLimit(1)
        }
        .font(.system(size: 11)).foregroundStyle(DesignTokens.textTertiary(scheme))
        .frame(height: 28)
        .layoutPriority(1)
      }
    }
  }

  @ViewBuilder private var authorization: some View {
    let monitor = controller.monitor
    if monitor.access != .allow || monitor.pending || monitor.waiting {
      VStack(alignment: .leading, spacing: 6) {
        Text(
          monitor.waiting
            ? Strings.clipboardWaiting
            : monitor.access == .deny ? Strings.clipboardDenied : Strings.clipboardAsk
        )
        .font(.system(size: 11)).foregroundStyle(DesignTokens.textSecondary(scheme)).lineLimit(1)
        HStack {
          if monitor.pending {
            Button(Strings.clipboardPending) { Task { await monitor.poll(userInitiated: true) } }
              .disabled(monitor.waiting)
          }
          Spacer(minLength: 4)
          Button(Strings.openSystemSettings) {
            if let url = URL(
              string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
            {
              NSWorkspace.shared.open(url)
            }
          }
        }.font(.system(size: 11)).buttonStyle(.plain).lineLimit(1)
      }.padding(.vertical, 8)
      Rectangle().fill(DesignTokens.lineDivider(scheme)).frame(height: 0.7)
    }
  }
}

private struct ClipboardRow: View {
  @Bindable var controller: ClipboardController
  let item: ClipItem
  let index: Int
  let scheme: ColorScheme
  @State private var hovered = false
  private var current: Bool { controller.currentIndex == index }
  private var mono: Bool {
    item.preview.contains("\n") && ["{", ";", "=>", "</"].contains(where: item.preview.contains)
  }

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        if let color = ClipboardColor.parse(item.preview) {
          RoundedRectangle(cornerRadius: 3)
            .fill(
              Color(  // devbar:allow-color
                .sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
            )
            .frame(width: 14, height: 14)
        }
        if let image = controller.thumbnails[item.id] {
          Image(nsImage: image).resizable().scaledToFit().frame(width: 32, height: 32)
        }
        Text(item.preview)
          .font(.system(size: 13, design: mono ? .monospaced : .default))
          .foregroundStyle(DesignTokens.textPrimary(scheme))
          .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: .infinity)
      .overlay {
        ClipboardDragView(
          payloads: controller.originals[item.id] ?? [],
          thumbnail: controller.thumbnails[item.id]
        ) { controller.select(index) }
      }
      if controller.copiedID == item.id {
        Image(systemName: "checkmark").font(.system(size: 11))
          .foregroundStyle(DesignTokens.textPrimary(scheme))
      }
      if hovered {
        Button {
          Task { await controller.remove(item.id) }
        } label: {
          Image(systemName: "xmark").font(.system(size: 11)).frame(width: 20, height: 24)
        }.buttonStyle(.plain).help(Strings.deleteItem)
      } else {
        if let bundle = item.sourceBundleID,
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        {
          Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable().saturation(0).frame(width: 16, height: 16)
        }
        TimelineView(.periodic(from: .now, by: 60)) { context in
          Text(relativeTime(now: context.date)).font(.system(size: 11))
            .foregroundStyle(DesignTokens.textTertiary(scheme)).lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 8).frame(height: 52)
    .background {
      if current { RoundedRectangle(cornerRadius: 7).fill(DesignTokens.panelControl(scheme)) }
    }
    .overlay(alignment: .leading) {
      if current {
        Rectangle().fill(DesignTokens.textPrimary(scheme)).frame(width: 2).padding(.vertical, 8)
      }
    }
    .overlay {
      if controller.focusedIndex == index && !current {
        RoundedRectangle(cornerRadius: 7).strokeBorder(
          DesignTokens.lineBorder(scheme), lineWidth: 0.7)
      }
    }
    .contentShape(Rectangle()).onTapGesture { controller.select(index) }
    .onHover { hovered = $0 }
  }

  private func relativeTime(now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(item.createdAt)))
    if seconds < 60 { return Strings.justNow }
    if seconds < 3600 { return Strings.minutesAgo(seconds / 60) }
    if seconds < 86400 { return Strings.hoursAgo(seconds / 3600) }
    return Strings.yesterday
  }
}
