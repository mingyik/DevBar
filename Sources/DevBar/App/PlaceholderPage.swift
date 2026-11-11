import SwiftUI

/// Document functionality is integrated in R9; keep its placeholder in the single-content shell.
struct PlaceholderPage: View {
  let page: PanelModel.Page
  let scheme: ColorScheme

  var body: some View {
    VStack(spacing: 0) {
      Text(Strings.notImplemented)
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(DesignTokens.textSecondary(scheme))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      HStack {
        Button(Strings.documentPreview) {}
          .buttonStyle(DevBarCapsuleStyle(scheme: scheme))
          .disabled(true)
        Spacer()
        placeholderAction("viewfinder.rectangular", label: Strings.documentCapture)
        placeholderAction("eraser", label: Strings.clearContent)
      }.frame(height: 28)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
    .background(
      DesignTokens.panelInset(scheme),
      in: RoundedRectangle(cornerRadius: DesignTokens.radiusMedium, style: .continuous))
  }

  private func placeholderAction(_ symbol: String, label: String) -> some View {
    Button {
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 16))
        .frame(width: 28, height: 28)
        .foregroundStyle(DesignTokens.textSecondary(scheme))
        .background(DesignTokens.panelControl(scheme), in: RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(.plain).disabled(true).accessibilityLabel(label).help(label)
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
