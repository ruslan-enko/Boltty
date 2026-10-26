import AppKit
import QuartzCore

enum MotionPreferences {
  static var reduceMotion: Bool {
    if let cached = cachedReduceMotion { return cached }
    let value = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    cachedReduceMotion = value
    startObservingAccessibilityChanges()
    return value
  }

  private nonisolated(unsafe) static var cachedReduceMotion: Bool?
  private nonisolated(unsafe) static var accessibilityObserver: NSObjectProtocol?

  private static func startObservingAccessibilityChanges() {
    guard accessibilityObserver == nil else { return }
    accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      refreshReduceMotion()
    }
  }

  @discardableResult
  static func refreshReduceMotion() -> Bool {
    let value = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    cachedReduceMotion = value
    return value
  }

  static let highFrameRateRange = CAFrameRateRange(
    minimum: 80,
    maximum: 120,
    preferred: 120
  )
}

extension CAAnimation {
  @discardableResult
  func preferringHighFrameRate() -> Self {
    preferredFrameRateRange = MotionPreferences.highFrameRateRange
    return self
  }
}

struct SpringParameters {
  var duration: TimeInterval
  var bounce: CGFloat = 0
}

enum Motion {
  static let quick: TimeInterval = 0.12
  static let standard: TimeInterval = 0.2
  static var emphasizedCurve: CAMediaTimingFunction {
    CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
  }
  static var standardCurve: CAMediaTimingFunction {
    CAMediaTimingFunction(name: .easeOut)
  }

  static let pressSpring = SpringParameters(duration: 0.24, bounce: 0)

  /// AppKit anchors a view's layer at (0, 0) and resets it on layout, so the scale is about the centre by transform.
  static func centredScale(_ scale: CGFloat, size: CGSize) -> CATransform3D {
    let offset = CATransform3DMakeTranslation(
      size.width * (1 - scale) / 2, size.height * (1 - scale) / 2, 0
    )
    return CATransform3DScale(offset, scale, scale, 1)
  }
}

// MARK: - Slow motion

extension Motion {
  static let timeScale: Double = {
    #if DEBUG
    let value = UserDefaults.standard.double(forKey: "boltty.slowMotion")
    return value > 1 ? value : 1
    #else
    return 1
    #endif
  }()

  static var now: CFTimeInterval { CACurrentMediaTime() / timeScale }

  static func scaled(_ interval: TimeInterval) -> TimeInterval { interval * timeScale }

  @MainActor
  static func applyTimeScale(to window: NSWindow?) {
    guard timeScale > 1, let layer = window?.contentView?.layer else { return }
    layer.speed = Float(1 / timeScale)
  }
}

extension MotionPreferences {
  @MainActor
  static func animate(
    duration: TimeInterval,
    timingName: CAMediaTimingFunctionName = .easeOut,
    changes: () -> Void,
    completion: (@Sendable () -> Void)? = nil
  ) {
    let effective = (reduceMotion || duration <= 0) ? 0 : duration
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = effective
      context.timingFunction = CAMediaTimingFunction(name: timingName)
      context.allowsImplicitAnimation = effective > 0
      changes()
    }, completionHandler: completion)
  }

  @MainActor
  static func springScale(_ layer: CALayer, to scale: CGFloat) {
    let target = Motion.centredScale(scale, size: layer.bounds.size)
    let from = (layer.presentation() ?? layer).transform
    layer.transform = target
    guard !reduceMotion else { return }
    animateSpring(
      on: layer,
      keyPath: "transform",
      from: NSValue(caTransform3D: from),
      to: NSValue(caTransform3D: target),
      spring: Motion.pressSpring
    )
  }

  @MainActor
  static func animateSpring(
    on layer: CALayer,
    keyPath: String,
    from: Any,
    to: Any,
    spring: SpringParameters = Motion.pressSpring,
    completion: (@Sendable () -> Void)? = nil
  ) {
    if reduceMotion {
      if keyPath == "opacity" {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = Motion.standard
        fade.timingFunction = Motion.standardCurve
        fade.preferringHighFrameRate()
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(fade, forKey: keyPath)
        CATransaction.commit()
      } else {
        layer.setValue(to, forKeyPath: keyPath)
        completion?()
      }
      return
    }

    let anim = CASpringAnimation(perceptualDuration: spring.duration, bounce: spring.bounce)
    anim.keyPath = keyPath
    anim.fromValue = from
    anim.toValue = to
    anim.fillMode = .forwards
    anim.isRemovedOnCompletion = false
    anim.preferringHighFrameRate()

    CATransaction.begin()
    CATransaction.setAnimationDuration(anim.settlingDuration)
    CATransaction.setCompletionBlock(completion)
    layer.add(anim, forKey: keyPath)
    CATransaction.commit()
  }
}
