import AppKit

@MainActor
final class AppPresence {
  typealias PolicyWriter = (NSApplication.ActivationPolicy) -> Void
  typealias Activator = (Bool) -> Void
  typealias RunLoopScheduler = (@escaping @MainActor @Sendable () -> Void) -> Void

  private let applyPolicy: PolicyWriter
  private let setActive: Activator
  private let scheduleOnNextRunLoop: RunLoopScheduler

  private(set) var isTrayOnly = false

  init(
    applyPolicy: @escaping PolicyWriter = { _ = NSApp.setActivationPolicy($0) },
    setActive: @escaping Activator = { active in
      if active {
        NSApp.activate(ignoringOtherApps: true)
      } else {
        NSApp.deactivate()
      }
    },
    scheduleOnNextRunLoop: @escaping RunLoopScheduler = { action in
      DispatchQueue.main.async(execute: action)
    }
  ) {
    self.applyPolicy = applyPolicy
    self.setActive = setActive
    self.scheduleOnNextRunLoop = scheduleOnNextRunLoop
  }

  func enterForeground() {
    guard isTrayOnly else { return }
    isTrayOnly = false
    applyPolicy(.regular)
    setActive(true)
  }

  func enterForeground(thenPresent present: @escaping @MainActor @Sendable () -> Void) {
    let isRestoringRegularPolicy = isTrayOnly
    enterForeground()
    if isRestoringRegularPolicy {
      scheduleOnNextRunLoop(present)
    } else {
      present()
    }
  }

  func enterTrayOnly() {
    guard !isTrayOnly else { return }
    isTrayOnly = true
    applyPolicy(.accessory)
    setActive(false)
  }
}
