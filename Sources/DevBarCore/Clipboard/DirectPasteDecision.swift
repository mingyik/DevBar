import Foundation

public struct DirectPasteInput: Sendable, Equatable {
  public let capturedPID: Int32?
  public let currentPID: Int32?
  public let ownPID: Int32
  public let isAuthorized: Bool
  public let selectedItemIsFile: Bool
  public let focusedRole: String?
  public let targetIsFinder: Bool
  public let selectedItemIsImage: Bool
  public let targetIsTerminal: Bool

  public init(
    capturedPID: Int32?, currentPID: Int32?, ownPID: Int32, isAuthorized: Bool,
    selectedItemIsFile: Bool, focusedRole: String?, targetIsFinder: Bool,
    selectedItemIsImage: Bool = false, targetIsTerminal: Bool = false
  ) {
    self.capturedPID = capturedPID
    self.currentPID = currentPID
    self.ownPID = ownPID
    self.isAuthorized = isAuthorized
    self.selectedItemIsFile = selectedItemIsFile
    self.focusedRole = focusedRole
    self.targetIsFinder = targetIsFinder
    self.selectedItemIsImage = selectedItemIsImage
    self.targetIsTerminal = targetIsTerminal
  }
}

public enum DirectPasteAction: Sendable, Equatable {
  case none
  case original
  case filePaths
  case imageFilePath
  case authorizationRequired
}

public enum DirectPasteDecision {
  private static let pasteableTextRoles: Set<String> = [
    "AXTextField", "AXTextArea", "AXSearchField",
  ]

  public static func action(for input: DirectPasteInput) -> DirectPasteAction {
    guard let capturedPID = input.capturedPID,
      capturedPID == input.currentPID,
      capturedPID != input.ownPID
    else { return .none }
    guard input.isAuthorized else { return .authorizationRequired }
    if input.selectedItemIsImage && input.targetIsTerminal { return .imageFilePath }
    guard input.selectedItemIsFile else { return .original }
    if input.targetIsFinder { return .original }
    guard let role = input.focusedRole, pasteableTextRoles.contains(role) else { return .none }
    return .filePaths
  }
}

public enum DirectPastePromptPolicy {
  public static func shouldRequest(isTrusted: Bool, wasRequested: Bool) -> Bool {
    !isTrusted && !wasRequested
  }
}
