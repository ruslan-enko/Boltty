import AppKit

/// What an Ask Boltty answer draws, in the answering agent's gradient and
/// soft as its traced line is: each shape strokes
/// itself on — a circle round, an arrow to its head — over a glow of its own,
/// and its words fade in once it is drawn. It stays until the next question.
///
/// One layer holds one surface's shapes: the screen's, or the board's. Its
/// 0–1000 is measured across `space` (the layer's own coordinates, origin at
/// the bottom left, as AppKit's are), y counted from its top.
final class AskBolttyDrawingLayer: CALayer {
  static let width: CGFloat = 3.5
  static let glowRadius: CGFloat = 9
  static let glowOpacity: Float = 0.9
  static let glowAlpha: CGFloat = 0.55
  static let arrowHead: CGFloat = 16
  static var labelFont: NSFont { roundedAppFont(size: AgentPaletteMetrics.typeSecondary, weight: .semibold) }
  /// Stroked at this many points a second, held between these bounds.
  static let drawSpeed: CGFloat = 900
  static let drawDuration: ClosedRange<CFTimeInterval> = 0.35...1.1
  /// Between two shapes put up by one sentence.
  static let stagger: CFTimeInterval = 0.18

  /// The face's gradient, lifted to read on any page, top to foot.
  var colours: [NSColor] = []
  /// Lines and words at this many times their size: the board is small.
  var scale: CGFloat = 1

  private(set) var shapeCount = 0
  private var queuedUntil: CFTimeInterval = 0

  override init() { super.init() }
  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func clear() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    sublayers?.forEach { $0.removeFromSuperlayer() }
    CATransaction.commit()
    shapeCount = 0
    queuedUntil = 0
  }

  /// Draws `shape`, its 0–1000 measured across `space`.
  func draw(_ shape: AskBolttyShape, in space: CGRect) {
    let now = CACurrentMediaTime()
    let begin = max(now, queuedUntil)
    let colour = colours.isEmpty ? NSColor.white
      : colours[(shapeCount * 2) % colours.count]
    shapeCount += 1
    let path = Self.path(of: shape, in: space, head: Self.arrowHead * scale)
    let length = Self.length(of: path)
    let duration = MotionPreferences.reduceMotion ? 0
      : min(max(Double(length / Self.drawSpeed), Self.drawDuration.lowerBound), Self.drawDuration.upperBound)
    queuedUntil = begin + duration + Self.stagger

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if let path {
      let glow = CAShapeLayer()
      glow.contentsScale = contentsScale
      glow.path = path
      glow.fillColor = nil
      glow.lineWidth = Self.width * scale
      glow.lineCap = .round
      glow.lineJoin = .round
      glow.strokeColor = colour.withAlphaComponent(Self.glowAlpha).cgColor
      glow.shadowColor = colour.cgColor
      glow.shadowOpacity = Self.glowOpacity
      glow.shadowRadius = Self.glowRadius * scale
      glow.shadowOffset = .zero
      addSublayer(glow)

      let bounds = path.boundingBoxOfPath.insetBy(dx: -Self.width * 2 * scale, dy: -Self.width * 2 * scale)
      let gradient = CAGradientLayer()
      gradient.contentsScale = contentsScale
      gradient.frame = bounds
      gradient.colors = (colours.isEmpty ? [NSColor.white] : colours).map(\.cgColor)
      gradient.startPoint = CGPoint(x: 0, y: 1)
      gradient.endPoint = CGPoint(x: 1, y: 0)
      let line = CAShapeLayer()
      line.contentsScale = contentsScale
      var shift = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
      line.path = path.copy(using: &shift)
      line.fillColor = nil
      line.strokeColor = NSColor.white.cgColor
      line.lineWidth = Self.width * scale
      line.lineCap = .round
      line.lineJoin = .round
      gradient.mask = line
      addSublayer(gradient)

      if duration > 0 {
        for layer in [glow, line] {
          let stroke = CABasicAnimation(keyPath: "strokeEnd")
          stroke.fromValue = 0
          stroke.toValue = 1
          stroke.duration = duration
          stroke.beginTime = convertTime(begin, from: nil)
          stroke.timingFunction = Motion.emphasizedCurve
          stroke.fillMode = .backwards
          layer.add(stroke, forKey: "draw")
        }
      }
    }
    if let words = shape.label {
      addSublayer(label(words, for: shape, in: space, path: path, appearAt: begin + duration * 0.6))
    }
    CATransaction.commit()
  }

  // MARK: - Words

  private func label(
    _ words: String, for shape: AskBolttyShape, in space: CGRect, path: CGPath?,
    appearAt time: CFTimeInterval
  ) -> CALayer {
    let font = Self.labelFont.withSize(Self.labelFont.pointSize * scale)
    let attributed = NSAttributedString(string: words, attributes: [
      // Written down, not dynamic: the app's own appearance may be light.
      .font: font, .foregroundColor: NSColor.white,
    ])
    let size = attributed.boundingRect(
      with: CGSize(width: 260 * scale, height: 200), options: [.usesLineFragmentOrigin], context: nil).size
    let text = CATextLayer()
    text.contentsScale = contentsScale
    text.string = attributed
    text.isWrapped = true
    text.alignmentMode = .center
    let padding = CGSize(width: 8 * scale, height: 3 * scale)
    let box = CGSize(width: ceil(size.width) + 2 + padding.width * 2, height: ceil(size.height) + padding.height * 2)
    let gap: CGFloat = 8 * scale
    let anchor: CGPoint
    switch shape.kind {
    case let .label(at):
      let p = Self.place(at, in: space)
      anchor = CGPoint(x: p.x - box.width / 2, y: p.y - box.height / 2)
    case let .arrow(from, _):
      // At the tail, away from the head: the head points at the thing.
      let p = Self.place(from, in: space)
      anchor = CGPoint(x: p.x - box.width / 2, y: p.y + gap)
    default:
      let bounds = path?.boundingBoxOfPath ?? CGRect(origin: space.origin, size: .zero)
      anchor = CGPoint(x: bounds.midX - box.width / 2, y: bounds.maxY + gap)
    }
    var frame = CGRect(origin: anchor, size: box)
    // Inside the surface, whichever side the shape stands at.
    if frame.maxY > bounds.maxY - 4 { frame.origin.y = (path?.boundingBoxOfPath.minY ?? frame.minY) - gap - box.height }
    frame.origin.x = min(max(frame.minX, bounds.minX + 4), bounds.maxX - 4 - box.width)
    frame.origin.y = min(max(frame.minY, bounds.minY + 4), bounds.maxY - 4 - box.height)
    // On a dark capsule, so the words read over a light page as over a dark one.
    let pill = CALayer()
    pill.contentsScale = contentsScale
    pill.frame = frame
    pill.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
    pill.cornerRadius = min(box.height / 2, 12 * scale)
    pill.cornerCurve = .continuous
    text.frame = CGRect(origin: CGPoint(x: padding.width, y: padding.height),
                        size: CGSize(width: box.width - padding.width * 2, height: box.height - padding.height * 2))
    pill.addSublayer(text)
    if !MotionPreferences.reduceMotion {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0
      fade.toValue = 1
      fade.duration = Motion.standard
      fade.beginTime = convertTime(time, from: nil)
      fade.fillMode = .backwards
      pill.add(fade, forKey: "arrive")
    }
    return pill
  }

  // MARK: - Geometry

  /// A 0–1000 point in `space`, y counted from its top.
  static func place(_ point: CGPoint, in space: CGRect) -> CGPoint {
    CGPoint(x: space.minX + point.x / 1000 * space.width,
            y: space.maxY - point.y / 1000 * space.height)
  }

  static func path(of shape: AskBolttyShape, in space: CGRect, head: CGFloat) -> CGPath? {
    let path = CGMutablePath()
    switch shape.kind {
    case let .circle(center, radius):
      let c = place(center, in: space)
      let r = radius / 1000 * space.width
      // Started at the top and drawn clockwise, as a hand rings something.
      path.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
    case let .box(rect):
      let a = place(rect.origin, in: space)
      let b = place(CGPoint(x: rect.maxX, y: rect.maxY), in: space)
      let frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
      let corner = min(8, min(frame.width, frame.height) / 5)
      path.addRoundedRect(in: frame, cornerWidth: corner, cornerHeight: corner)
    case let .arrow(from, to):
      let a = place(from, in: space)
      let b = place(to, in: space)
      path.move(to: a)
      path.addLine(to: b)
      let angle = atan2(b.y - a.y, b.x - a.x)
      let spread: CGFloat = .pi / 7
      let reach = min(head, hypot(b.x - a.x, b.y - a.y) / 2)
      path.move(to: CGPoint(x: b.x - reach * cos(angle - spread), y: b.y - reach * sin(angle - spread)))
      path.addLine(to: b)
      path.addLine(to: CGPoint(x: b.x - reach * cos(angle + spread), y: b.y - reach * sin(angle + spread)))
    case let .line(from, to):
      path.move(to: place(from, in: space))
      path.addLine(to: place(to, in: space))
    case let .path(segments):
      for segment in segments {
        switch segment {
        case let .move(p): path.move(to: place(p, in: space))
        case let .line(p): path.addLine(to: place(p, in: space))
        case let .quad(p, c): path.addQuadCurve(to: place(p, in: space), control: place(c, in: space))
        case let .curve(p, c1, c2):
          path.addCurve(to: place(p, in: space), control1: place(c1, in: space), control2: place(c2, in: space))
        case .close: path.closeSubpath()
        }
      }
    case .label:
      return nil
    }
    return path.isEmpty ? nil : path
  }

  /// Roughly how long the path is, to pace its stroke.
  static func length(of path: CGPath?) -> CGFloat {
    guard let path else { return 0 }
    var length: CGFloat = 0
    var last = CGPoint.zero
    var start = CGPoint.zero
    path.applyWithBlock { element in
      let points = element.pointee.points
      switch element.pointee.type {
      case .moveToPoint:
        last = points[0]
        start = last
      case .addLineToPoint:
        length += hypot(points[0].x - last.x, points[0].y - last.y)
        last = points[0]
      case .addQuadCurveToPoint:
        length += hypot(points[1].x - last.x, points[1].y - last.y) * 1.1
        last = points[1]
      case .addCurveToPoint:
        length += hypot(points[2].x - last.x, points[2].y - last.y) * 1.2
        last = points[2]
      case .closeSubpath:
        length += hypot(start.x - last.x, start.y - last.y)
        last = start
      @unknown default:
        break
      }
    }
    return length
  }
}
