import Testing
@testable import DevBarCore

@Test func systemModeFollowsTheCurrentAppearance() {
  #expect(ThemeMode.system.effective(system: .dark) == .dark)
  #expect(ThemeMode.light.effective(system: .dark) == .light)
  #expect(ThemeMode.dark.effective(system: .light) == .dark)
}

@Test func manualToggleLeavesSystemMode() {
  #expect(ThemeMode.system.toggled(from: .light) == .dark)
  #expect(ThemeMode.dark.toggled(from: .dark) == .light)
}
