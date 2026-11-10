// 自动生成，勿手改。来源：design/tokens.json
import AppKit
import SwiftUI

enum DesignTokens {
  static let radiusSmall: CGFloat = 7
  static let radiusMedium: CGFloat = 10
  static let radiusLarge: CGFloat = 12
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

  static func syntaxKeyword(_ scheme: ColorScheme) -> Color {
    textPrimary(scheme)
  }

  static let syntaxKeywordStyle = SyntaxStyle(weight: 600, italic: false, tabular: false)

  static func syntaxString(_ scheme: ColorScheme) -> Color {
    textSecondary(scheme)
  }

  static let syntaxStringStyle = SyntaxStyle(weight: nil, italic: false, tabular: false)

  static func syntaxNumber(_ scheme: ColorScheme) -> Color {
    textPrimary(scheme)
  }

  static let syntaxNumberStyle = SyntaxStyle(weight: nil, italic: false, tabular: true)

  static func syntaxConstant(_ scheme: ColorScheme) -> Color {
    textPrimary(scheme)
  }

  static let syntaxConstantStyle = SyntaxStyle(weight: nil, italic: true, tabular: false)

  static func syntaxComment(_ scheme: ColorScheme) -> Color {
    textTertiary(scheme)
  }

  static let syntaxCommentStyle = SyntaxStyle(weight: nil, italic: true, tabular: false)

  static func syntaxPunct(_ scheme: ColorScheme) -> Color {
    textTertiary(scheme)
  }

  static let syntaxPunctStyle = SyntaxStyle(weight: nil, italic: false, tabular: false)

  static func selectionFill(_ scheme: ColorScheme) -> Color {
    textPrimary(scheme)
  }

  static let selectionFillStyle = SyntaxStyle(weight: nil, italic: false, tabular: false)

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
