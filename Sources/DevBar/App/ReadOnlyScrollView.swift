import DevBarCore
import SwiftUI

/// The indicator is a passive overlay; wheel, trackpad and keyboard own scrolling.
struct ReadOnlyScrollView<Content: View>: View {
  let scheme: ColorScheme
  var contentTrailingInset: CGFloat = 10
  var indicatorTrailingInset: CGFloat = 2
  var indicatorWidth: CGFloat = 3
  var indicatorOpacity: Double = 1
  var flashOnAppear = false
  var onViewportChange: ((_ offset: CGFloat, _ viewport: CGFloat) -> Void)? = nil
  @ViewBuilder let content: () -> Content
  @State private var metrics = Metrics()
  @State private var visible = false
  @State private var dismissal: Task<Void, Never>?

  private struct Metrics: Equatable {
    var viewport = 0.0
    var content = 0.0
    var offset = 0.0
  }

  var body: some View {
    ScrollView { content().padding(.trailing, contentTrailingInset) }
      .scrollIndicators(.never)
      .onScrollGeometryChange(for: Metrics.self) { geometry in
        Metrics(
          viewport: geometry.containerSize.height, content: geometry.contentSize.height,
          offset: geometry.contentOffset.y + geometry.contentInsets.top)
      } action: { old, new in
        metrics = new
        onViewportChange?(new.offset, new.viewport)
        let scrolled = abs(new.offset - old.offset) > 0.1
        let appeared = flashOnAppear && old.content <= old.viewport && new.content > new.viewport
        if scrolled || appeared {
          visible = true
          dismissal?.cancel()
          dismissal = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            visible = false
          }
        }
      }
      .overlay(alignment: .topTrailing) {
        if let thumb = ScrollThumb.geometry(
          viewport: metrics.viewport,
          content: metrics.content, offset: metrics.offset)
        {
          Capsule().fill(DesignTokens.scrollThumb(scheme))
            .frame(width: indicatorWidth, height: thumb.length)
            .offset(x: -indicatorTrailingInset, y: thumb.position)
            .opacity(visible ? indicatorOpacity : 0)
            .animation(.easeOut(duration: 0.25), value: visible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
  }
}
