import Foundation
import os

/// What has not come by the deadline is gone on without; the work itself runs on.
enum Deadline {
  static func answer<Value: Sendable>(
    within seconds: TimeInterval, _ read: @escaping @Sendable () -> Value?
  ) async -> Value? {
    await first(within: seconds) { finish in
      DispatchQueue.global(qos: .userInitiated).async { finish(read()) }
    }
  }

  static func value<Value: Sendable>(
    of task: Task<Value, Never>, within seconds: TimeInterval
  ) async -> Value? {
    await first(within: seconds) { finish in
      Task { finish(await task.value) }
    }
  }

  private static func first<Value: Sendable>(
    within seconds: TimeInterval, _ start: (@escaping @Sendable (Value?) -> Void) -> Void
  ) async -> Value? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
      let answered = OSAllocatedUnfairLock(initialState: false)
      let finish: @Sendable (Value?) -> Void = { value in
        guard answered.withLock({ was in defer { was = true }; return !was }) else { return }
        continuation.resume(returning: value)
      }
      start(finish)
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(nil) }
    }
  }
}
