import AppKit
import DevBarCore
import SwiftUI

struct ClipboardListView: View {
  @Bindable var controller: ClipboardController
  let scheme: ColorScheme
  var body: some View {
    VStack(spacing: 0) {
      authorization
      if controller.items.isEmpty {
        Text(Strings.clipboardEmpty).font(.system(size: 13))
          .foregroundStyle(DesignTokens.textSecondary(scheme)).lineLimit(1)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ReadOnlyScrollView(
            scheme: scheme, contentTrailingInset: 12, indicatorTrailingInset: 0.5
          ) {
            LazyVStack(spacing: 10) {
              ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                ClipboardRow(controller: controller, item: item, index: index, scheme: scheme)
                  .id(item.id)
              }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
          }
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
        .padding(.trailing, -8)
      }
      if !controller.message.isEmpty {
        Text(controller.message).font(.system(size: 11))
          .foregroundStyle(DesignTokens.textTertiary(scheme)).lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .onDisappear {
      if let id = controller.hoverID { controller.setHovered(id, inside: false) }
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false
  @State private var dragging = false
  private var mono: Bool {
    item.preview.contains("\n") && ["{", ";", "=>", "</"].contains(where: item.preview.contains)
  }
  private var selected: Bool { controller.focusedIndex == index }
  private var payloads: [ClipboardPayload] { controller.originals[item.id] ?? [] }

  var body: some View {
    let rowShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        if let color = ClipboardColor.parse(item.preview) {
          RoundedRectangle(cornerRadius: 4)
            .fill(
              Color(  // devbar:allow-color
                .sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
            )
            .frame(width: 16, height: 16)
        }
        if let image = controller.thumbnails[item.id] {
          Image(nsImage: image).resizable().scaledToFill().frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        Text(item.preview)
          .font(.system(size: 13, design: mono ? .monospaced : .default))
          .foregroundStyle(DesignTokens.textPrimary(scheme))
          .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: .infinity)
      .overlay {
        ClipboardDragView(
          payloads: payloads,
          thumbnail: item.kind == .image ? controller.thumbnails[item.id] : nil,
          title: DragCard.firstLine(dragSource),
          subtitle: dragSubtitle,
          fileCount: fileNames.count,
          swatch: swatch,
          scheme: scheme,
          onClick: { controller.select(index) },
          onDelete: { Task { await controller.remove(item.id) } },
          onDragging: { isDragging in
            dragging = isDragging
            controller.setDragging(isDragging)
          }
        )
      }
      if controller.copiedID == item.id {
        Image(systemName: "checkmark").font(.system(size: 11))
          .foregroundStyle(DesignTokens.textPrimary(scheme))
      }
      Text(kindLabel).font(.system(size: 11))
        .foregroundStyle(DesignTokens.textTertiary(scheme)).lineLimit(1)
    }
    .padding(.horizontal, 12).frame(height: 56)
    .background {
      ZStack {
        if hovered && !dragging {
          ClipboardOuterGlow(cornerRadius: 10)
        }
        rowShape.fill(
          selected ? DesignTokens.panelControl(scheme) : DesignTokens.panelCard(scheme)
        )
      }
    }
    .overlay {
      if hovered && !dragging {
        rowShape
          .strokeBorder(
            Color(red: 0.22, green: 0.58, blue: 1.0, opacity: 0.72),  // devbar:allow-color
            lineWidth: 1
          )
          .allowsHitTesting(false)
      }
    }
    .overlay(alignment: .leading) {
      if selected && !dragging {
        GeometryReader { geometry in
          HStack(spacing: 0) {
            Rectangle().fill(Color.blue).frame(width: 4)  // devbar:allow-color
            Spacer(minLength: 0)
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
          .clipShape(rowShape)
        }
        .allowsHitTesting(false)
      }
    }
    .opacity(dragging ? 0.4 : 1)
    .animation(reduceMotion || dragging ? nil : .easeOut(duration: 0.16), value: dragging)
    .contentShape(Rectangle()).onTapGesture { controller.select(index) }
    .onHover { inside in
      hovered = inside
      controller.setHovered(item.id, inside: inside && !dragging)
    }
    .onDisappear { controller.setHovered(item.id, inside: false) }
  }

  private var dragSource: String {
    payloads.first { $0.type == NSPasteboard.PasteboardType.string.rawValue }
      .flatMap { String(data: $0.data, encoding: .utf8) } ?? item.preview
  }

  private var fileNames: [String] {
    payloads.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
      .compactMap { String(data: $0.data, encoding: .utf8) }
      .compactMap(URL.init(string:))
      .map(\.lastPathComponent)
  }

  private var dragSubtitle: String {
    switch item.kind {
    case .text: DragCard.textSubtitle(characters: dragSource.count)
    case .image: item.preview
    case .files: DragCard.fileSubtitle(names: fileNames)
    }
  }

  private var swatch: NSColor? {
    guard let color = ClipboardColor.parse(item.preview) else { return nil }
    return NSColor(  // devbar:allow-color
      srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
  }

  private var kindLabel: String {
    switch item.kind {
    case .text: Strings.clipboardTextType
    case .image: Strings.clipboardImageType
    case .files: Strings.clipboardFileType
    }
  }
}

private struct ClipboardOuterGlow: View {
  let cornerRadius: CGFloat

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    let primaryGlow = Color(  // devbar:allow-color
      red: 0.15, green: 0.55, blue: 1.0, opacity: 0.75)
    let secondaryGlow = Color(  // devbar:allow-color
      red: 0.25, green: 0.65, blue: 1.0, opacity: 0.45)
    shape
      .fill(Color.black)  // devbar:allow-color
      .shadow(color: primaryGlow, radius: 7, x: 0, y: 0)
      .shadow(color: secondaryGlow, radius: 12, x: 0, y: 0)
      .padding(-20)
      .compositingGroup()
      .mask {
        ZStack {
          Rectangle().fill(Color.white)  // devbar:allow-color
          shape.fill(Color.black).padding(20)  // devbar:allow-color
        }
        .compositingGroup()
        .luminanceToAlpha()
      }
      .padding(20)
      .allowsHitTesting(false)
  }
}
