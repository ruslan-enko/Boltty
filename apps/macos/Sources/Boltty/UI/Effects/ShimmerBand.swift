import AppKit

final class ShimmerBand: CALayer {
  private let words = CALayer()
  private let band = CAGradientLayer()
  private var travel: CGFloat = 0

  override init() {
    super.init()
    mask = words
    band.startPoint = CGPoint(x: 0, y: 0.5)
    band.endPoint = CGPoint(x: 1, y: 0.5)
    addSublayer(band)
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func paint(_ light: [NSColor], still: Bool = false) {
    guard let first = light.first, let last = light.last else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    band.opacity = still ? Float(AgentPaletteMetrics.resultsWorkingStillOpacity) : 1
    if still {
      band.colors = OklabGradient.cgColors(light)
      band.locations = nil
      return
    }
    band.colors = OklabGradient.cgColors([first.withAlphaComponent(0)] + light + [last.withAlphaComponent(0)])
    let inner = AgentPaletteMetrics.resultsShimmerFade
    let steps = max(1, light.count - 1)
    band.locations = OklabGradient.numbers([0] + light.indices.map {
      inner + (1 - 2 * inner) * CGFloat($0) / CGFloat(steps)
    } + [1])
  }

  func cut(_ image: CGImage?, scale: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    words.contents = image
    words.contentsScale = scale
    CATransaction.commit()
  }

  @discardableResult
  func lay(in frame: CGRect, wordsWidth: CGFloat, leading: CGFloat = 0, still: Bool = false) -> CGFloat {
    let span = still
      ? wordsWidth
      : max(AgentPaletteMetrics.resultsShimmerMinimumBand, wordsWidth * AgentPaletteMetrics.resultsShimmerBandShare)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    self.frame = frame
    words.frame = bounds
    band.frame = CGRect(x: still ? leading : leading - span, y: 0, width: span, height: frame.height)
    CATransaction.commit()
    return wordsWidth + span
  }

  func sweep(across travel: CGFloat, phase: Double = 0, delay: CFTimeInterval = 0) {
    if abs(travel - self.travel) > 0.5 { band.removeAnimation(forKey: "sweep") }
    guard band.animation(forKey: "sweep") == nil else { return }
    self.travel = travel
    let pass = CABasicAnimation(keyPath: "transform.translation.x")
    pass.fromValue = 0
    pass.toValue = travel
    pass.duration = AgentPaletteMetrics.resultsShimmerSweepDuration
    pass.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    pass.fillMode = .both
    let cycle = CAAnimationGroup()
    cycle.animations = [pass]
    cycle.duration = pass.duration + AgentPaletteMetrics.resultsShimmerRest
    cycle.repeatCount = .infinity
    cycle.timeOffset = phase * cycle.duration
    if delay > 0 { cycle.beginTime = CACurrentMediaTime() + delay }
    band.add(cycle, forKey: "sweep")
  }

  func stopSweep() {
    band.removeAnimation(forKey: "sweep")
    travel = 0
  }
}
