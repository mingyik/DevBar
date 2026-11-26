import AppKit
import DevBarCore
import KeyboardShortcuts
import SwiftUI

enum ClipboardListScroll {
  static func anchor(
    index: Int,
    rowHeight: CGFloat = ClipboardRowLayout.rowHeight,
    spacing: CGFloat = ClipboardRowLayout.rowSpacing,
    topPadding: CGFloat = ClipboardRowLayout.verticalPadding,
    offset: CGFloat,
    viewport: CGFloat
  ) -> UnitPoint? {
    guard index >= 0, viewport > 0 else { return nil }
    let rowTop = topPadding + CGFloat(index) * (rowHeight + spacing)
    let rowBottom = rowTop + rowHeight
    if rowTop < offset { return .top }
    if rowBottom > offset + viewport { return .bottom }
    return nil
  }
}

struct ClipboardListView: View {
  @Bindable var controller: ClipboardController
  let scheme: ColorScheme
  @State private var cycleShortcut = KeyboardShortcuts.getShortcut(for: .cycleOlder)?.description
  @State private var scrollOffset: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0
  var body: some View {
    VStack(spacing: 0) {
      authorization
      if controller.items.isEmpty {
        emptyState
      } else {
        ScrollViewReader { proxy in
          ReadOnlyScrollView(
            scheme: scheme, contentTrailingInset: 6, indicatorTrailingInset: -1,
            indicatorWidth: 2,
            onViewportChange: { offset, viewport in
              scrollOffset = offset
              viewportHeight = viewport
            }
          ) {
            LazyVStack(spacing: ClipboardRowLayout.rowSpacing) {
              ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                ClipboardRow(controller: controller, item: item, index: index, scheme: scheme)
                  .id(item.id)
              }
            }
            .padding(.leading, 2)
            .padding(.trailing, 0)
            .padding(.vertical, ClipboardRowLayout.verticalPadding)
          }
          .onAppear {
            scrollIntoViewIfNeeded(index: controller.focusedIndex, proxy: proxy)
          }
          .onChange(of: controller.focusedIndex) { _, index in
            scrollIntoViewIfNeeded(index: index, proxy: proxy)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
      }
    }
    .onAppear {
      cycleShortcut = KeyboardShortcuts.getShortcut(for: .cycleOlder)?.description
    }
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
      cycleShortcut = KeyboardShortcuts.getShortcut(for: .cycleOlder)?.description
    }
    .onDisappear {
      if let id = controller.hoverID { controller.setHovered(id, inside: false) }
    }
  }

  private func scrollIntoViewIfNeeded(index: Int, proxy: ScrollViewProxy) {
    guard controller.items.indices.contains(index) else { return }
    guard
      let anchor = ClipboardListScroll.anchor(
        index: index, offset: scrollOffset, viewport: viewportHeight)
    else { return }
    proxy.scrollTo(controller.items[index].id, anchor: anchor)
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "clipboard")
        .font(.system(size: 24, weight: .light))
        .foregroundStyle(DesignTokens.textTertiary(scheme).opacity(0.65))
      Text(Strings.clipboardEmpty)
        .font(.system(size: 13))
        .foregroundStyle(DesignTokens.textSecondary(scheme))
        .lineLimit(1)
      if let cycleShortcut, !cycleShortcut.isEmpty {
        Text(Strings.clipboardEmptyShortcut(cycleShortcut))
          .font(.system(size: 11))
          .foregroundStyle(DesignTokens.textTertiary(scheme))
          .lineLimit(1)
      }
    }
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
              .padding(.horizontal, 8).frame(height: 24)
              .buttonStyle(DevBarSurfaceButtonStyle(scheme: scheme))
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
          .padding(.horizontal, 8).frame(height: 24)
          .buttonStyle(DevBarSurfaceButtonStyle(scheme: scheme))
        }.font(.system(size: 11)).lineLimit(1)
      }.padding(.vertical, 8)
      Rectangle().fill(DesignTokens.lineDivider(scheme)).frame(height: 0.7)
    }
  }
}

private enum ClipboardRowLayout {
  /// Main column has 10pt horizontal padding, list expands by -4pt, stack pads 2pt on leading = 8pt.
  static let panelLeadingInset: CGFloat = 8
  static let rowCornerRadius: CGFloat = DesignTokens.radiusLarge - panelLeadingInset
  static let innerCornerRadius: CGFloat = max(4, rowCornerRadius - 4)
  static let rowHeight: CGFloat = 56
  static let rowSpacing: CGFloat = 8
  static let verticalPadding: CGFloat = 2
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
  private var selected: Bool { controller.focusedItemID == item.id }
  private var payloads: [ClipboardPayload] { controller.originals[item.id] ?? [] }

  var body: some View {
    let rowShape = RoundedRectangle(
      cornerRadius: ClipboardRowLayout.rowCornerRadius, style: .continuous)
    let innerShape = RoundedRectangle(
      cornerRadius: ClipboardRowLayout.innerCornerRadius, style: .continuous)
    let activeHover = hovered && !dragging
    let activeSelect = selected && !dragging
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        if let color = ClipboardColor.parse(item.preview) {
          innerShape
            .fill(
              Color(  // devbar:allow-color
                .sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
            )
            .overlay {
              innerShape.strokeBorder(DesignTokens.lineBorder(scheme), lineWidth: 0.5)
            }
            .frame(width: 16, height: 16)
        }
        if let image = controller.thumbnails[item.id] {
          Image(nsImage: image).resizable().scaledToFill().frame(width: 32, height: 32)
            .clipShape(innerShape)
            .overlay {
              innerShape.strokeBorder(DesignTokens.lineBorder(scheme), lineWidth: 0.5)
            }
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
          cardContent: cardContent,
          scheme: scheme,
          onClick: { controller.select(index) },
          onDelete: { Task { await controller.remove(item.id) } },
          onHover: { inside in
            hovered = inside
            controller.setHovered(item.id, inside: inside && !dragging)
          },
          onDragging: { isDragging in
            dragging = isDragging
            controller.setDragging(isDragging)
          }
        )
      }
      if controller.copiedID == item.id {
        Image(systemName: "checkmark").font(.system(size: 11))
          .foregroundStyle(DesignTokens.textPrimary(scheme))
          .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.7)))
      }
      ClipTagChip(tag: cardContent.tag, scheme: scheme)
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: controller.copiedID == item.id)
    .padding(.horizontal, 10).frame(height: ClipboardRowLayout.rowHeight)
    .background {
      ZStack {
        rowShape.fill(DesignTokens.panelCard(scheme))
        if activeSelect || activeHover {
          rowShape.fill(DesignTokens.panelControl(scheme))
        }
      }
    }
    .overlay {
      if activeSelect {
        rowShape.strokeBorder(
          DesignTokens.selectionBorder(scheme).opacity(activeHover ? 0.9 : 0.72),
          lineWidth: DesignTokens.strokeStrong
        )
        .allowsHitTesting(false)
      } else if activeHover {
        rowShape.strokeBorder(
          DesignTokens.lineBorder(scheme).opacity(1.35),
          lineWidth: DesignTokens.strokeHairline
        )
        .allowsHitTesting(false)
      }
    }
    .opacity(dragging ? 0 : 1)
    .animation(reduceMotion || dragging ? nil : .easeOut(duration: 0.16), value: dragging)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: activeHover)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: activeSelect)
    .contentShape(Rectangle()).onTapGesture { controller.select(index) }
    .onHover { inside in
      hovered = inside
      controller.setHovered(item.id, inside: inside && !dragging)
    }
    .onAppear { if dragging { dragging = false } }
    .onDisappear { controller.setHovered(item.id, inside: false) }
  }

  private var cardContent: ClipCardContent {
    ClipCardContent.make(item: item, payloads: payloads, thumbnail: controller.thumbnails[item.id])
  }
}

/// Filled monochrome format tag (TXT / PNG / SVG); matches the floating card chip.
struct ClipTagChip: View {
  let tag: String
  let scheme: ColorScheme
  var body: some View {
    Text(tag)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(DesignTokens.textPrimary(scheme).opacity(0.85))
      .lineLimit(1).fixedSize()
      .padding(.horizontal, 5).frame(height: 16)
      .background {
        RoundedRectangle(
          cornerRadius: ClipboardRowLayout.innerCornerRadius, style: .continuous
        )
        .fill(DesignTokens.panelControl(scheme))
        .overlay {
          RoundedRectangle(
            cornerRadius: ClipboardRowLayout.innerCornerRadius, style: .continuous
          )
          .strokeBorder(DesignTokens.lineBorder(scheme), lineWidth: DesignTokens.strokeHairline)
        }
      }
  }
}
