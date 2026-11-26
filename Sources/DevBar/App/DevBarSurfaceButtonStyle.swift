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

/// Borderless macOS toolbar icon style: clean by default, subtle capsule pill on hover/press.
struct DevBarToolbarIconButtonStyle: ButtonStyle {
  let scheme: ColorScheme
  func makeBody(configuration: Configuration) -> some View {
    ToolbarIconBody(configuration: configuration, scheme: scheme)
  }

  private struct ToolbarIconBody: View {
    let configuration: ButtonStyle.Configuration
    let scheme: ColorScheme
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var shape: RoundedRectangle {
      RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
    }

    var body: some View {
      let activeHover = hovered && enabled
      let activePress = configuration.isPressed && enabled
      configuration.label
        .lineLimit(1)
        .background {
          if activePress {
            shape.fill(DesignTokens.panelControl(scheme))
              .overlay { shape.fill(DesignTokens.panelControl(scheme)) }
          } else if activeHover {
            shape.fill(DesignTokens.panelControl(scheme))
          }
        }
        .overlay {
          if activeHover || activePress {
            shape.strokeBorder(
              DesignTokens.lineBorder(scheme).opacity(activePress ? 1 : 0.7),
              lineWidth: DesignTokens.strokeHairline)
          }
        }
        .overlay {
          if focused {
            shape.strokeBorder(DesignTokens.textPrimary(scheme), lineWidth: 1.5)
          }
        }
        .contentShape(shape)
        .focusEffectDisabled()
        .scaleEffect(activePress && !reduceMotion ? 0.96 : 1)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: activePress)
    }
  }
}
