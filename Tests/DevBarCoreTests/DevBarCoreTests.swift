import Testing

@testable import DevBarCore

@Test func moduleNameIsDevBarCore() {
  #expect(DevBarCore.moduleName == "DevBarCore")
}
