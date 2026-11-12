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
        Button {
        } label: {
          Text(Strings.documentPreview).padding(.horizontal, 12).frame(height: 28)
        }
        .buttonStyle(DevBarSurfaceButtonStyle(scheme: scheme))
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
    }.buttonStyle(DevBarSurfaceButtonStyle(scheme: scheme)).disabled(true)
      .accessibilityLabel(label).help(label)
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
