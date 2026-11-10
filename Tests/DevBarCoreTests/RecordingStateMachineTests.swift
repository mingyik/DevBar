import Testing

@testable import DevBarCore

// MARK: - 全部阶段与事件

/// 每个阶段都取到全部关联值，保证「全部合法与非法迁移」真的是全部。
private let allPhases: [RecordingPhase] = {
  var phases: [RecordingPhase] = [.idle, .preparing, .recording]
  for reason in RecordingStopReason.allCases {
    phases.append(.finishing(reason))
    phases.append(.completed(reason))
    phases.append(.incomplete(reason))
    phases.append(.failed(.recording(reason)))
  }
  phases.append(.failed(.preparation))
  return phases
}()

private let allEvents: [RecordingEvent] = {
  var events: [RecordingEvent] = [
    .start, .streamStarted, .prepareFailed, .didFinish,
    .didFail(fileUsable: true), .didFail(fileUsable: false), .reset,
  ]
  for reason in RecordingStopReason.allCases {
    events.append(.stop(reason))
  }
  return events
}()

/// 合法迁移表：按实现规格 §9.6 手写，不调用被测代码推导。
private func expectedNext(_ phase: RecordingPhase, _ event: RecordingEvent) -> RecordingPhase? {
  switch phase {
  case .idle:
    return event == .start ? .preparing : nil
  case .preparing:
    if event == .streamStarted { return .recording }
    if event == .prepareFailed { return .failed(.preparation) }
    return nil
  case .recording:
    for reason in RecordingStopReason.allCases where event == .stop(reason) {
      return .finishing(reason)
    }
    return nil
  case .finishing(let reason):
    if event == .didFinish { return .completed(reason) }
    if event == .didFail(fileUsable: true) { return .incomplete(reason) }
    if event == .didFail(fileUsable: false) { return .failed(.recording(reason)) }
    return nil
  case .completed, .incomplete, .failed:
    return event == .reset ? .idle : nil
  }
}

// MARK: - 迁移表

@Test func everyPhaseAndEventPairMatchesTheSpecTable() {
  // 阶段：idle、preparing、recording + 4 种带原因的阶段 × 5 种原因 + failed(.preparation) = 24。
  // 事件：7 种 + stop × 5 种原因 = 12。
  #expect(allPhases.count == 24)
  #expect(allEvents.count == 12)
  var legal = 0
  for phase in allPhases {
    for event in allEvents {
      let actual = RecordingStateMachine.nextPhase(after: phase, on: event)
      #expect(actual == expectedNext(phase, event), "阶段 \(phase) 遇到 \(event)")
      if actual != nil { legal += 1 }
    }
  }
  // idle 1 + preparing 2 + recording 5 + finishing 5×3 + 终态 16×1 = 39
  #expect(legal == 39)
}

@Test func legalTransitionMovesAndReportsBothEnds() {
  var machine = RecordingStateMachine()
  #expect(machine.handle(.start) == .moved(from: .idle, to: .preparing))
  #expect(machine.phase == .preparing)
  #expect(machine.ignoredEvents.isEmpty)
}

@Test func illegalTransitionKeepsPhaseAndIsRecorded() {
  var machine = RecordingStateMachine(phase: .recording)
  let result = machine.handle(.start)
  let ignored = IgnoredRecordingEvent(phase: .recording, event: .start)
  #expect(result == .ignored(ignored))
  #expect(machine.phase == .recording)
  #expect(machine.ignoredEvents == [ignored])
}

@Test func everyIllegalPairIsIgnoredWithoutChangingPhase() {
  for phase in allPhases {
    for event in allEvents where expectedNext(phase, event) == nil {
      var machine = RecordingStateMachine(phase: phase)
      let result = machine.handle(event)
      #expect(result == .ignored(IgnoredRecordingEvent(phase: phase, event: event)))
      #expect(machine.phase == phase)
      #expect(machine.ignoredEvents.count == 1)
    }
  }
}

@Test func ignoredEventsKeepOnlyTheMostRecent() {
  var machine = RecordingStateMachine()
  let total = RecordingStateMachine.ignoredEventLimit + 5
  for index in 0..<total {
    machine.handle(index.isMultiple(of: 2) ? .didFinish : .reset)
  }
  #expect(machine.ignoredEvents.count == RecordingStateMachine.ignoredEventLimit)
  // 留下的是最后 20 条：第 5 条（下标 5，奇数 → reset）起。
  #expect(machine.ignoredEvents.first?.event == .reset)
  #expect(machine.ignoredEvents.last?.event == .didFinish)
  #expect(machine.phase == .idle)
}

// MARK: - 完整流程

@Test func userStopCompletes() {
  var machine = RecordingStateMachine()
  machine.handle(.start)
  machine.handle(.streamStarted)
  machine.handle(.stop(.user))
  #expect(machine.phase == .finishing(.user))
  machine.handle(.didFinish)
  #expect(machine.phase == .completed(.user))
  machine.handle(.reset)
  #expect(machine.phase == .idle)
  #expect(machine.ignoredEvents.isEmpty)
}

@Test func lowDiskStopKeepsReasonThroughCompletion() {
  var machine = RecordingStateMachine(phase: .recording)
  machine.handle(.stop(.lowDisk))
  machine.handle(.didFinish)
  #expect(machine.phase == .completed(.lowDisk))
}

@Test func interruptedWithUsableFileIsIncomplete() {
  var machine = RecordingStateMachine(phase: .recording)
  machine.handle(.stop(.interrupted))
  machine.handle(.didFail(fileUsable: true))
  #expect(machine.phase == .incomplete(.interrupted))
}

@Test func failureWithoutUsableFileFails() {
  var machine = RecordingStateMachine(phase: .recording)
  machine.handle(.stop(.sleep))
  machine.handle(.didFail(fileUsable: false))
  #expect(machine.phase == .failed(.recording(.sleep)))
}

@Test func preparationFailureFailsBeforeRecording() {
  var machine = RecordingStateMachine()
  machine.handle(.start)
  machine.handle(.prepareFailed)
  #expect(machine.phase == .failed(.preparation))
  machine.handle(.reset)
  #expect(machine.phase == .idle)
}

@Test func secondStopWhileFinishingIsIgnoredAndKeepsFirstReason() {
  var machine = RecordingStateMachine(phase: .recording)
  machine.handle(.stop(.user))
  machine.handle(.stop(.quit))
  #expect(machine.phase == .finishing(.user))
  #expect(
    machine.ignoredEvents == [IgnoredRecordingEvent(phase: .finishing(.user), event: .stop(.quit))])
}

@Test func cannotStartAgainUntilReset() {
  var machine = RecordingStateMachine(phase: .completed(.user))
  machine.handle(.start)
  #expect(machine.phase == .completed(.user))
  machine.handle(.reset)
  machine.handle(.start)
  #expect(machine.phase == .preparing)
}

// MARK: - 派生属性

@Test func derivedFlagsMatchSpec() {
  for phase in allPhases {
    switch phase {
    case .idle:
      #expect(!phase.isBusy && !phase.delaysTermination && !phase.isTerminal)
    case .preparing:
      #expect(phase.isBusy && !phase.delaysTermination && !phase.isTerminal)
    case .recording, .finishing:
      #expect(phase.isBusy && phase.delaysTermination && !phase.isTerminal)
    case .completed, .incomplete, .failed:
      #expect(!phase.isBusy && !phase.delaysTermination && phase.isTerminal)
    }
  }
}
