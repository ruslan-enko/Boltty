import AppKit
import QuartzCore

@MainActor
final class ChipEntranceAnimator {
  private var displayLink: CADisplayLink?
  private var timer: Timer?
  private var watchdog: Timer?
  private var startTime: CFTimeInterval = 0
  private let duration: TimeInterval
  private let onProgress: (CGFloat) -> Void
  private(set) var isFinished = false

  init(duration: TimeInterval, onProgress: @escaping (CGFloat) -> Void) {
    self.duration = duration
    self.onProgress = onProgress
  }

  func start(in view: NSView) {
    stop()
    startTime = Motion.now
    isFinished = false
    onProgress(0)

    if view.window != nil {
      let link = view.displayLink(target: self, selector: #selector(tick))
      link.preferredFrameRateRange = MotionPreferences.highFrameRateRange
      link.add(to: .main, forMode: .common)
      displayLink = link
      startWatchdog()
    } else {
      let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [self] _ in
        MainActor.assumeIsolated { self.tick() }
      }
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    }
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    timer?.invalidate()
    timer = nil
    watchdog?.invalidate()
    watchdog = nil
  }

  private func startWatchdog() {
    let watchdog = Timer(timeInterval: duration + Self.watchdogSlack, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.land() }
    }
    RunLoop.main.add(watchdog, forMode: .common)
    self.watchdog = watchdog
  }

  private static let watchdogSlack: TimeInterval = 0.05

  private func land() {
    guard !isFinished else { return }
    onProgress(1)
    isFinished = true
    stop()
  }

  @objc private func tick() {
    let elapsed = Motion.now - startTime
    guard elapsed < duration else {
      land()
      return
    }
    onProgress(ChipEntranceAnimator.progress(elapsed: elapsed, duration: duration))
  }

  static func progress(elapsed: TimeInterval, duration: TimeInterval) -> CGFloat {
    guard duration > 0 else { return 1 }
    let t = min(max(CGFloat(elapsed / duration), 0), 1)
    let remaining = 1 - t
    return 1 - remaining * remaining * remaining
  }
}
