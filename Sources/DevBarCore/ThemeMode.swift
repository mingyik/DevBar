public enum ThemeAppearance: String, Sendable {
  case light
  case dark
}

public enum ThemeMode: String, Sendable {
  case system
  case light
  case dark

  public func effective(system: ThemeAppearance) -> ThemeAppearance {
    switch self {
    case .system:
      system
    case .light:
      .light
    case .dark:
      .dark
    }
  }

  public func toggled(from effective: ThemeAppearance) -> ThemeMode {
    effective == .light ? .dark : .light
  }
}
