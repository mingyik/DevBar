import Testing

@testable import DevBar

@Test func directPasteAuthorizationWaitsForSystemPromptInsteadOfOverlayingIt() {
  var flow = DirectPasteAuthorizationWait(gracePeriod: 2)
  #expect(
    flow.next(trusted: false, systemPrompt: false, settingsActive: false, elapsed: 0) == .wait)
  #expect(flow.next(trusted: false, systemPrompt: true, settingsActive: false, elapsed: 5) == .wait)
  #expect(
    flow.next(trusted: false, systemPrompt: false, settingsActive: false, elapsed: 5.1) == .fallback
  )
}

@Test func directPasteAuthorizationFallsBackWhenSystemPromptDoesNotAppear() {
  var flow = DirectPasteAuthorizationWait(gracePeriod: 2)
  #expect(
    flow.next(trusted: false, systemPrompt: false, settingsActive: false, elapsed: 1) == .wait)
  #expect(
    flow.next(trusted: false, systemPrompt: false, settingsActive: false, elapsed: 2) == .fallback)
}

@Test func directPasteAuthorizationAlreadyRequestedOffersSettingsAgain() {
  var flow = DirectPasteAuthorizationWait(gracePeriod: 0)
  #expect(
    flow.next(trusted: false, systemPrompt: false, settingsActive: false, elapsed: 0) == .fallback)
  #expect(flow.next(trusted: false, systemPrompt: true, settingsActive: false, elapsed: 0) == .wait)
}

@Test func directPasteAuthorizationDoesNotInterruptSystemSettingsOrGrantedAccess() {
  var flow = DirectPasteAuthorizationWait(gracePeriod: 2)
  #expect(
    flow.next(trusted: false, systemPrompt: true, settingsActive: false, elapsed: 0.2) == .wait)
  #expect(flow.next(trusted: false, systemPrompt: false, settingsActive: true, elapsed: 3) == .wait)
  #expect(
    flow.next(trusted: true, systemPrompt: false, settingsActive: true, elapsed: 4) == .finished)
}
