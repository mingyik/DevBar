/// 录屏状态机（实现规格 §9.6）。
///
/// 纯逻辑，不依赖 ScreenCaptureKit：`ScreenRecorder` 把系统回调翻译成
/// `RecordingEvent` 交给它，界面只读 `phase`。不在表里的迁移一律忽略，
/// 并记进 `ignoredEvents`，便于排查回调顺序问题。
///
/// ```
/// idle ──start──▶ preparing ──streamStarted──▶ recording ──stop(原因)──▶ finishing
/// preparing ──prepareFailed──▶ failed(.preparation)
/// finishing ──didFinish──▶ completed
/// finishing ──didFail(fileUsable: true)──▶ incomplete
/// finishing ──didFail(fileUsable: false)──▶ failed(.recording)
/// completed / incomplete / failed ──reset──▶ idle
/// ```

/// 进入「正在结束」的原因。结束后保留，界面据此说明为什么停了。
public enum RecordingStopReason: Sendable, Equatable, CaseIterable {
  /// 用户点了停止或按了快捷键。
  case user
  /// 系统停止共享、显示器断开等，来自 `stream(_:didStopWithError:)`。
  case interrupted
  /// 录制中剩余空间低于 500MB，自动停止。
  case lowDisk
  /// 系统即将休眠。
  case sleep
  /// 用户退出应用。
  case quit
}

/// 录制失败发生在哪个阶段。
public enum RecordingFailure: Sendable, Equatable {
  /// 还没开始录：权限、找不到屏幕、`startCapture` 抛错等。
  case preparation
  /// 已经在录，收尾时写文件失败，且文件不可用。
  case recording(RecordingStopReason)
}

public enum RecordingPhase: Sendable, Equatable {
  case idle
  case preparing
  case recording
  case finishing(RecordingStopReason)
  case completed(RecordingStopReason)
  /// 写文件失败，但已写出的部分能播放。
  case incomplete(RecordingStopReason)
  case failed(RecordingFailure)

  /// 正在占用屏幕采集：不能再开始新的录制。
  public var isBusy: Bool {
    switch self {
    case .preparing, .recording, .finishing: true
    case .idle, .completed, .incomplete, .failed: false
    }
  }

  /// 退出应用时需要等收尾完成（`applicationShouldTerminate` 返回 `.terminateLater`）。
  public var delaysTermination: Bool {
    switch self {
    case .recording, .finishing: true
    case .idle, .preparing, .completed, .incomplete, .failed: false
    }
  }

  /// 已经结束（成功、不完整或失败），等待 `reset` 回到空闲。
  public var isTerminal: Bool {
    switch self {
    case .completed, .incomplete, .failed: true
    case .idle, .preparing, .recording, .finishing: false
    }
  }
}

public enum RecordingEvent: Sendable, Equatable {
  /// 用户开始录制（选区已确定）。
  case start
  /// `startCapture` 成功返回。
  case streamStarted
  /// 准备阶段出错。
  case prepareFailed
  /// 需要停止录制，附原因。
  case stop(RecordingStopReason)
  /// `recordingOutputDidFinishRecording`。
  case didFinish
  /// `recordingOutput(_:didFailWithError:)`；`fileUsable` 表示已写出的文件存在且时长大于 0。
  case didFail(fileUsable: Bool)
  /// 结果已展示，回到空闲。
  case reset
}

/// 一次被忽略的事件。
public struct IgnoredRecordingEvent: Sendable, Equatable {
  public let phase: RecordingPhase
  public let event: RecordingEvent

  public init(phase: RecordingPhase, event: RecordingEvent) {
    self.phase = phase
    self.event = event
  }
}

public enum RecordingTransition: Sendable, Equatable {
  case moved(from: RecordingPhase, to: RecordingPhase)
  case ignored(IgnoredRecordingEvent)
}

public struct RecordingStateMachine: Sendable, Equatable {
  /// 最多保留多少条被忽略的事件，只用于排查。
  public static let ignoredEventLimit = 20

  public private(set) var phase: RecordingPhase
  /// 最近被忽略的事件，最旧的在前。
  public private(set) var ignoredEvents: [IgnoredRecordingEvent] = []

  public init(phase: RecordingPhase = .idle) {
    self.phase = phase
  }

  /// 纯函数：给定阶段和事件，返回下一个阶段；不允许的迁移返回 `nil`。
  public static func nextPhase(after phase: RecordingPhase, on event: RecordingEvent)
    -> RecordingPhase?
  {
    switch (phase, event) {
    case (.idle, .start):
      .preparing
    case (.preparing, .streamStarted):
      .recording
    case (.preparing, .prepareFailed):
      .failed(.preparation)
    case (.recording, .stop(let reason)):
      .finishing(reason)
    case (.finishing(let reason), .didFinish):
      .completed(reason)
    case (.finishing(let reason), .didFail(let fileUsable)):
      fileUsable ? .incomplete(reason) : .failed(.recording(reason))
    case (.completed, .reset), (.incomplete, .reset), (.failed, .reset):
      .idle
    default:
      nil
    }
  }

  @discardableResult
  public mutating func handle(_ event: RecordingEvent) -> RecordingTransition {
    let from = phase
    guard let to = Self.nextPhase(after: from, on: event) else {
      let ignored = IgnoredRecordingEvent(phase: from, event: event)
      ignoredEvents.append(ignored)
      if ignoredEvents.count > Self.ignoredEventLimit {
        ignoredEvents.removeFirst(ignoredEvents.count - Self.ignoredEventLimit)
      }
      return .ignored(ignored)
    }
    phase = to
    return .moved(from: from, to: to)
  }
}
