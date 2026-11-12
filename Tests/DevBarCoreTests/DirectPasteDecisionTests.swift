import DevBarCore
import Testing

@Test func changedFrontmostApplicationDoesNotPaste() {
  #expect(DirectPasteDecision.action(for: input(currentPID: 2)) == .none)
}

@Test func devBarTargetDoesNotPaste() {
  #expect(DirectPasteDecision.action(for: input(ownPID: 1)) == .none)
}

@Test func untrustedAccessibilityRequiresAuthorizationNotice() {
  #expect(DirectPasteDecision.action(for: input(isAuthorized: false)) == .authorizationRequired)
}

@Test func filesPasteAsPathsIntoTextField() {
  #expect(DirectPasteDecision.action(for: input(isFile: true, focusRole: "AXTextField")) == .filePaths)
}

@Test func filesPasteAsPathsIntoTextArea() {
  #expect(DirectPasteDecision.action(for: input(isFile: true, focusRole: "AXTextArea")) == .filePaths)
}

@Test func filesPasteAsPathsIntoSearchField() {
  #expect(DirectPasteDecision.action(for: input(isFile: true, focusRole: "AXSearchField")) == .filePaths)
}

@Test func filesPasteOriginalRepresentationIntoFinder() {
  #expect(DirectPasteDecision.action(for: input(isFile: true, targetIsFinder: true)) == .original)
}

@Test func filesDoNotPasteIntoOtherControls() {
  #expect(DirectPasteDecision.action(for: input(isFile: true, focusRole: "AXButton")) == .none)
  #expect(DirectPasteDecision.action(for: input(isFile: true, focusRole: nil)) == .none)
}

@Test func textAndImageEntriesPasteOriginalRepresentation() {
  #expect(DirectPasteDecision.action(for: input(isFile: false, focusRole: nil)) == .original)
}

private func input(
  capturedPID: Int32? = 1,
  currentPID: Int32? = 1,
  ownPID: Int32 = 99,
  isAuthorized: Bool = true,
  isFile: Bool = false,
  focusRole: String? = nil,
  targetIsFinder: Bool = false
) -> DirectPasteInput {
  DirectPasteInput(
    capturedPID: capturedPID,
    currentPID: currentPID,
    ownPID: ownPID,
    isAuthorized: isAuthorized,
    selectedItemIsFile: isFile,
    focusedRole: focusRole,
    targetIsFinder: targetIsFinder
  )
}
