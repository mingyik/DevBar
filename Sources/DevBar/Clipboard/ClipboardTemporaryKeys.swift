import Carbon

/// These hot keys exist only for the lifetime of the visible switching card.
@MainActor final class ClipboardTemporaryKeys {
  private var references: [EventHotKeyRef] = []
  private var handler: EventHandlerRef?
  var onKey: ((UInt32) -> Void)?
  var isRegistered: Bool { !references.isEmpty }
  private static let signature: OSType = 0x4442_4343
  @discardableResult func register() -> Bool {
    unregister()
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let result = InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        guard
          GetEventParameter(
            event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
          id.signature == 0x4442_4343
        else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<ClipboardTemporaryKeys>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { owner.onKey?(id.id) }
        return noErr
      }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard result == noErr else {
      unregister()
      return false
    }
    for modifiers: UInt32 in [0, UInt32(cmdKey | shiftKey)] {
      for key: UInt32 in [123, 124, 125, 126, 36, 76, 53] {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
          key, modifiers, EventHotKeyID(signature: Self.signature, id: key),
          GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else {
          unregister()
          return false
        }
        references.append(reference)
      }
    }
    return true
  }
  func unregister() {
    for reference in references { UnregisterEventHotKey(reference) }
    references.removeAll()
    if let handler { RemoveEventHandler(handler) }
    handler = nil
  }
}
