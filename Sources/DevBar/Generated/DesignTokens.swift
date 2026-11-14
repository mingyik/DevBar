// 自动生成，勿手改。来源：design/tokens.json
import AppKit
import SwiftUI

enum DesignTokens {
  static let radiusSmall: CGFloat = 8
  static let radiusMedium: CGFloat = 14
  static let radiusLarge: CGFloat = 16
  static let radiusInline: CGFloat = 4
  static let strokeHairline: CGFloat = 0.7
  static let strokeStrong: CGFloat = 1
  static let fontBody: CGFloat = 14
  static let fontBodyLarge: CGFloat = 15
  static let fontLineHeight: CGFloat = 1.65

  struct SyntaxStyle: Sendable {
    let weight: Int?
    let italic: Bool
    let tabular: Bool
  }

  static func panelBase(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.68)
    case .dark:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.42)
    @unknown default:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.68)
    }
  }

  static func panelCard(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.38)
    case .dark:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.075)
    @unknown default:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.38)
    }
  }

  static func panelControl(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.055)
    case .dark:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.085)
    @unknown default:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.055)
    }
  }

  static func panelRaised(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.88)
    case .dark:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.14)
    @unknown default:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.88)
    }
  }

  static func panelGlassTint(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.08)
    case .dark:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.08)
    @unknown default:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.08)
    }
  }

  @MainActor
  static func lineBorder(_ scheme: ColorScheme) -> Color {
    let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    switch scheme {
    case .light:
      return increaseContrast
        ? Color(red: 0, green: 0, blue: 0, opacity: 0.24)
        : Color(red: 0, green: 0, blue: 0, opacity: 0.09)
    case .dark:
      return increaseContrast
        ? Color(red: 1, green: 1, blue: 1, opacity: 0.28)
        : Color(red: 1, green: 1, blue: 1, opacity: 0.11)
    @unknown default:
      return increaseContrast
        ? Color(red: 0, green: 0, blue: 0, opacity: 0.24)
        : Color(red: 0, green: 0, blue: 0, opacity: 0.09)
    }
  }

  static func lineDivider(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.12)
    case .dark:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.12)
    @unknown default:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.12)
    }
  }

  static func textPrimary(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 0, green: 0, blue: 0, opacity: 1)
    case .dark:
      return Color(red: 1, green: 1, blue: 1, opacity: 1)
    @unknown default:
      return Color(red: 0, green: 0, blue: 0, opacity: 1)
    }
  }

  static func selectionBorder(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.6)
    case .dark:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.6)
    @unknown default:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.6)
    }
  }

  static func textSecondary(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.75)
    case .dark:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.75)
    @unknown default:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.75)
    }
  }

  static func textTertiary(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.6)
    case .dark:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.6)
    @unknown default:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.6)
    }
  }

  static func clipboardIndex(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 96.0 / 255, green: 119.0 / 255, blue: 140.0 / 255, opacity: 1)
    case .dark:
      return Color(red: 135.0 / 255, green: 153.0 / 255, blue: 170.0 / 255, opacity: 1)
    @unknown default:
      return Color(red: 96.0 / 255, green: 119.0 / 255, blue: 140.0 / 255, opacity: 1)
    }
  }

  static func syntaxKeyword(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return textPrimary(scheme)
    case .dark:
      return textPrimary(scheme)
    @unknown default:
      return textPrimary(scheme)
    }
  }

  static func syntaxKeywordStyle(_ scheme: ColorScheme) -> SyntaxStyle {
    switch scheme {
    case .light:
      return SyntaxStyle(weight: 600, italic: false, tabular: false)
    case .dark:
      return SyntaxStyle(weight: 600, italic: false, tabular: false)
    @unknown default:
      return SyntaxStyle(weight: 600, italic: false, tabular: false)
    }
  }

  static func syntaxString(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return textSecondary(scheme)
    case .dark:
      return textSecondary(scheme)
    @unknown default:
      return textSecondary(scheme)
    }
  }

  static func syntaxStringStyle(_ scheme: ColorScheme) -> SyntaxStyle {
    switch scheme {
    case .light:
      return SyntaxStyle(weight: nil, italic: false, tabular: false)
    case .dark:
      return SyntaxStyle(weight: nil, italic: false, tabular: false)
    @unknown default:
      return SyntaxStyle(weight: nil, italic: false, tabular: false)
    }
  }

  static func syntaxNumber(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return textPrimary(scheme)
    case .dark:
      return textPrimary(scheme)
    @unknown default:
      return textPrimary(scheme)
    }
  }

  static func syntaxNumberStyle(_ scheme: ColorScheme) -> SyntaxStyle {
    switch scheme {
    case .light:
      return SyntaxStyle(weight: nil, italic: false, tabular: true)
    case .dark:
      return SyntaxStyle(weight: nil, italic: false, tabular: true)
    @unknown default:
      return SyntaxStyle(weight: nil, italic: false, tabular: true)
    }
  }

  static func syntaxConstant(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return textPrimary(scheme)
    case .dark:
      return textPrimary(scheme)
    @unknown default:
      return textPrimary(scheme)
    }
  }

  static func syntaxConstantStyle(_ scheme: ColorScheme) -> SyntaxStyle {
    switch scheme {
    case .light:
      return SyntaxStyle(weight: nil, italic: true, tabular: false)
    case .dark:
      return SyntaxStyle(weight: nil, italic: true, tabular: false)
    @unknown default:
      return SyntaxStyle(weight: nil, italic: true, tabular: false)
    }
  }

  static func syntaxComment(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return textTertiary(scheme)
    case .dark:
      return textTertiary(scheme)
    @unknown default:
      return textTertiary(scheme)
    }
  }

  static func syntaxCommentStyle(_ scheme: ColorScheme) -> SyntaxStyle {
    switch scheme {
    case .light:
      return SyntaxStyle(weight: nil, italic: true, tabular: false)
    case .dark:
      return SyntaxStyle(weight: nil, italic: true, tabular: false)
    @unknown default:
      return SyntaxStyle(weight: nil, italic: true, tabular: false)
    }
  }

  static func syntaxPunct(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return textTertiary(scheme)
    case .dark:
      return textTertiary(scheme)
    @unknown default:
      return textTertiary(scheme)
    }
  }

  static func syntaxPunctStyle(_ scheme: ColorScheme) -> SyntaxStyle {
    switch scheme {
    case .light:
      return SyntaxStyle(weight: nil, italic: false, tabular: false)
    case .dark:
      return SyntaxStyle(weight: nil, italic: false, tabular: false)
    @unknown default:
      return SyntaxStyle(weight: nil, italic: false, tabular: false)
    }
  }

  static func selectionFill(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return textPrimary(scheme)
    case .dark:
      return textPrimary(scheme)
    @unknown default:
      return textPrimary(scheme)
    }
  }

  static func selectionFillStyle(_ scheme: ColorScheme) -> SyntaxStyle {
    switch scheme {
    case .light:
      return SyntaxStyle(weight: nil, italic: false, tabular: false)
    case .dark:
      return SyntaxStyle(weight: nil, italic: false, tabular: false)
    @unknown default:
      return SyntaxStyle(weight: nil, italic: false, tabular: false)
    }
  }

  static func selectionText(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 1, green: 1, blue: 1, opacity: 1)
    case .dark:
      return Color(red: 0, green: 0, blue: 0, opacity: 1)
    @unknown default:
      return Color(red: 1, green: 1, blue: 1, opacity: 1)
    }
  }

  static func scrollThumb(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.22)
    case .dark:
      return Color(red: 1, green: 1, blue: 1, opacity: 0.22)
    @unknown default:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.22)
    }
  }

  static func panelInset(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.035)
    case .dark:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.18)
    @unknown default:
      return Color(red: 0, green: 0, blue: 0, opacity: 0.035)
    }
  }

  static func qrBackground(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 1, green: 1, blue: 1, opacity: 1)
    case .dark:
      return Color(red: 1, green: 1, blue: 1, opacity: 1)
    @unknown default:
      return Color(red: 1, green: 1, blue: 1, opacity: 1)
    }
  }

  static func iconPrimary(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 51.0 / 255, green: 51.0 / 255, blue: 51.0 / 255, opacity: 1)
    case .dark:
      return Color(red: 217.0 / 255, green: 217.0 / 255, blue: 217.0 / 255, opacity: 1)
    @unknown default:
      return Color(red: 51.0 / 255, green: 51.0 / 255, blue: 51.0 / 255, opacity: 1)
    }
  }

  static func opaqueBackdrop(_ scheme: ColorScheme) -> Color {
    switch scheme {
    case .light:
      return Color(red: 242.0 / 255, green: 242.0 / 255, blue: 242.0 / 255, opacity: 1)
    case .dark:
      return Color(red: 28.0 / 255, green: 28.0 / 255, blue: 30.0 / 255, opacity: 1)
    @unknown default:
      return Color(red: 242.0 / 255, green: 242.0 / 255, blue: 242.0 / 255, opacity: 1)
    }
  }
}
