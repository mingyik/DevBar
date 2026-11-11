import SwiftUI

/// Layout only. Conversion, preview and QR generation belong to R8/R9.
struct PlaceholderPage: View {
  let page: PanelModel.Page
  let scheme: ColorScheme
  @State private var inputFraction = 0.35
  @State private var dragStart: Double?

  var body: some View {
    GeometryReader { geometry in
      let height = max(geometry.size.height - 40, 0)
      VStack(alignment: .leading, spacing: 12) {
        block {
          VStack(alignment: .leading, spacing: 8) {
            Text(page.title).font(.system(size: 11)).lineLimit(1)
            Text(Strings.notImplemented).font(.system(size: 13, design: .monospaced))
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          }
        }.frame(height: max(90, height * inputFraction))
        Rectangle().fill(DesignTokens.lineDivider(scheme)).frame(height: 0.7)
          .padding(.vertical, 2)
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
              if dragStart == nil { dragStart = inputFraction }
              inputFraction = min(
                0.65, max(0.2, (dragStart ?? 0.35) + value.translation.height / max(height, 1)))
            }.onEnded { _ in dragStart = nil })
        HStack {
          Text(Strings.result).font(.system(size: 11))
          Spacer()
        }.lineLimit(1)
        block {
          Text(Strings.pageNotImplemented(page.title))
            .font(.system(size: 13, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
      }
      .foregroundStyle(DesignTokens.textSecondary(scheme))
      .padding(.top, 12)
    }
  }

  private func block<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content().padding(12)
      .background(
        DesignTokens.panelCard(scheme),
        in: RoundedRectangle(cornerRadius: DesignTokens.radiusMedium, style: .continuous))
  }
}

struct DevBarCapsuleStyle: ButtonStyle {
  let scheme: ColorScheme
  var prominent = false
  func makeBody(configuration: Configuration) -> some View {
    CapsuleBody(configuration: configuration, scheme: scheme, prominent: prominent)
  }

  private struct CapsuleBody: View {
    let configuration: ButtonStyle.Configuration
    let scheme: ColorScheme
    let prominent: Bool
    @State private var hovered = false
    @Environment(\.isFocused) private var focused
    var body: some View {
      configuration.label.font(.system(size: 12)).lineLimit(1)
        .padding(.horizontal, 12).frame(height: 28)
        .foregroundStyle(
          prominent ? DesignTokens.selectionText(scheme) : DesignTokens.textPrimary(scheme)
        )
        .background {
          RoundedRectangle(cornerRadius: DesignTokens.radiusSmall)
            .fill(
              prominent ? DesignTokens.selectionFill(scheme) : DesignTokens.panelControl(scheme)
            )
            .overlay {
              if hovered {
                RoundedRectangle(cornerRadius: DesignTokens.radiusSmall).fill(
                  DesignTokens.panelControl(scheme))
              }
            }
        }
        .overlay {
          if focused {
            RoundedRectangle(cornerRadius: DesignTokens.radiusSmall).strokeBorder(
              DesignTokens.textPrimary(scheme), lineWidth: 1.5)
          }
        }
        .focusEffectDisabled()
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .onHover { hovered = $0 }
    }
  }
}
