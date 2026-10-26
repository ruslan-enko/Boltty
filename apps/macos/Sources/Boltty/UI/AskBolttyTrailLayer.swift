import AppKit

/// The line the pointer leaves while Ask Boltty's chord is held: the face's
/// gradient walked along it, soft, and gone a moment after it is drawn — it
/// follows the hand and does not stay. The whole line still goes onto the
/// screen's picture; this is only what the eye sees.
///
/// It is drawn in **runs**, not steps: a shape layer per `runLength` of line,
/// grown point by point while it is the newest. A layer per pointer step grew
/// to thousands on a scribble, every one composited each frame the face moved;
/// and now each run lives `life` and is taken away.
///
/// **Soft, not hard**: the stroke is translucent and its glow is the run's
/// own shadow, blurred, in its colour, cast from a path (`shadowPath`) so no
/// offscreen pass is needed. Runs end square: the line's curves are tangent
/// where two meet (`SmoothLine`), so square ends meet exactly, where round
/// ones overlapped and lit a bead at every joint.
final class AskBolttyTrailLayer: CALayer {
  static let width: CGFloat = 5
  static let lineAlpha: CGFloat = 0.55
  static let glowRadius: CGFloat = 9
  static let glowOpacity: Float = 0.8
  /// Below this the pointer has not moved: no point is added.
  static let step: CGFloat = 3
  static let runLength: CGFloat = 20
  /// Line per pass through the face's gradient, top to foot and back.
  static let colourPeriod: CGFloat = 480
  /// How long a stretch of line is on screen: whole for `hold`, then fading.
  static let life: CFTimeInterval = 0.9
  static let hold: CFTimeInterval = 0.25

  /// The face's gradient, top to foot.
  var colours: [NSColor] = []
  /// The line's width and glow at this many times their size — the first
  /// run's show draws Ask Boltty larger than the screen does.
  var lineScale: CGFloat = 1
  /// Tests hand in their own.
  var clock: () -> CFTimeInterval = { Motion.now }

  /// Each run is drawn at this, the screen's: a shape layer left at 1 is a
  /// blurred line on Retina.
  override var contentsScale: CGFloat {
    didSet { for run in runs { run.layer.contentsScale = contentsScale } }
  }

  private var runs: [(layer: CAShapeLayer, born: CFTimeInterval)] = []
  private var run: (layer: CAShapeLayer, path: CGMutablePath, length: CGFloat)?
  private var last: CGPoint?
  private var smoother = SmoothLine()
  private(set) var length: CGFloat = 0

  override init() {
    super.init()
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// How many layers the line is drawn with now.
  var runCount: Int { runs.count }
  var isEmpty: Bool { runs.isEmpty }

  /// Adds the pointer's next place, in this layer's coordinates.
  func extend(to point: CGPoint) {
    sweep()
    let step = last.map { hypot(point.x - $0.x, point.y - $0.y) } ?? 0
    if last != nil, step < Self.step * lineScale { return }
    last = point
    // Curves through the midpoints, not straight joins: a quick stroke was a
    // polygon with a corner at every display frame.
    guard let piece = smoother.add(point) else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if run == nil || run!.length >= Self.runLength * lineScale {
      let middle = (length + Self.runLength * lineScale / 2) / lineScale
      run = start(from: piece.from, colour: Self.colour(at: middle, stops: colours))
    }
    run!.path.addQuadCurve(to: piece.to, control: piece.control)
    run!.length += step
    let path = run!.path.copy()!
    run!.layer.path = path
    run!.layer.shadowPath = path.copy(
      strokingWithWidth: Self.width * lineScale, lineCap: .butt, lineJoin: .round, miterLimit: 10)
    CATransaction.commit()
    length += step
  }

  /// Takes away the runs whose time is up. Called every frame the overlay is
  /// up, so a line stops being drawn and is gone a moment later.
  func sweep() {
    let now = clock()
    guard let oldest = runs.first, now - oldest.born >= Self.life else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    while let first = runs.first, now - first.born >= Self.life {
      first.layer.removeFromSuperlayer()
      runs.removeFirst()
      if run?.layer === first.layer { run = nil }
    }
    CATransaction.commit()
  }

  /// The line is done with: what is left fades on its own clock; the next
  /// stroke starts anew.
  func finish() {
    last = nil
    smoother = SmoothLine()
    run = nil
    if MotionPreferences.reduceMotion { clear() }
  }

  func clear() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for run in runs { run.layer.removeFromSuperlayer() }
    CATransaction.commit()
    runs.removeAll()
    last = nil
    smoother = SmoothLine()
    run = nil
    length = 0
  }

  // MARK: - Colour

  /// The line's colour `length` points along it: the face's gradient, top to
  /// foot and back, so a long line keeps cycling through it.
  static func colour(at length: CGFloat, stops: [NSColor]) -> NSColor {
    guard stops.count > 1 else { return stops.first ?? .white }
    let phase = (length / colourPeriod).truncatingRemainder(dividingBy: 1)
    let there = phase < 0.5 ? phase * 2 : (1 - phase) * 2
    let scaled = there * CGFloat(stops.count - 1)
    let index = min(Int(scaled), stops.count - 2)
    return MascotPalette.mix(stops[index], stops[index + 1], scaled - CGFloat(index))
  }

  // MARK: - Runs

  private func start(
    from point: CGPoint, colour: NSColor
  ) -> (layer: CAShapeLayer, path: CGMutablePath, length: CGFloat) {
    let layer = CAShapeLayer()
    layer.strokeColor = colour.withAlphaComponent(Self.lineAlpha).cgColor
    layer.fillColor = nil
    layer.lineWidth = Self.width * lineScale
    layer.lineCap = .butt
    layer.lineJoin = .round
    layer.shadowColor = colour.cgColor
    layer.shadowOpacity = Self.glowOpacity
    layer.shadowRadius = Self.glowRadius * lineScale
    layer.shadowOffset = .zero
    layer.contentsScale = contentsScale
    if !MotionPreferences.reduceMotion {
      let decay = CAKeyframeAnimation(keyPath: "opacity")
      decay.values = [1, 1, 0]
      decay.keyTimes = [0, NSNumber(value: Self.hold / Self.life), 1]
      decay.timingFunctions = [CAMediaTimingFunction(name: .linear), Motion.standardCurve]
      decay.duration = Self.life
      layer.opacity = 0
      layer.add(decay, forKey: "decay")
    }
    addSublayer(layer)
    runs.append((layer, clock()))
    let path = CGMutablePath()
    path.move(to: point)
    return (layer, path, 0)
  }
}
