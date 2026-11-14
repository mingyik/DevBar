import SwiftUI

private struct DevBarIconColor: ViewModifier {
  let scheme: ColorScheme
  @Environment(\.isEnabled) private var enabled
  func body(content: Content) -> some View {
    content.foregroundStyle(
      enabled ? DesignTokens.iconPrimary(scheme) : DesignTokens.iconDisabled(scheme))
  }
}

extension View {
  func devbarIconColor(_ scheme: ColorScheme) -> some View {
    modifier(DevBarIconColor(scheme: scheme))
  }
}

struct DevBarSurfaceButtonStyle: ButtonStyle {
  let scheme: ColorScheme
  func makeBody(configuration: Configuration) -> some View {
    SurfaceBody(configuration: configuration, scheme: scheme)
  }

  private struct SurfaceBody: View {
    let configuration: ButtonStyle.Configuration
    let scheme: ColorScheme
    @State private var hovered = false
    @Environment(\.isFocused) private var focused
    private var shape: RoundedRectangle {
      RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
    }
    var body: some View {
      configuration.label
        .foregroundStyle(DesignTokens.textPrimary(scheme))
        .lineLimit(1)
        .background {
          shape.fill(DesignTokens.panelControl(scheme))
        }
        .overlay {
          shape.strokeBorder(
            DesignTokens.lineBorder(scheme).opacity(hovered ? 1.35 : 1),
            lineWidth: DesignTokens.strokeHairline)
        }
        .overlay {
          if focused {
            shape.strokeBorder(
              DesignTokens.textPrimary(scheme), lineWidth: 1.5)
          }
        }
        .focusEffectDisabled()
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
  }
}
