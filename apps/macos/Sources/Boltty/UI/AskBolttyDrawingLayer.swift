import AppKit

final class AskBolttyDrawingLayer: CALayer {
  static var width: CGFloat { live(7) }
  static var arrowHead: CGFloat { live(24) }
  static let cornerRadius: CGFloat = 12
  static let standOff: CGFloat = 8
  static let arrowBow: CGFloat = 0.14
  static let arrowBowLimit: CGFloat = 40
  static let arrowSpread: CGFloat = 0.55
  static let markerChroma = 0.19
  static let markerLightness: ClosedRange<Double> = 0.58...0.64
  static var labelFont: NSFont { roundedAppFont(size: AgentPaletteMetrics.typeSecondary, weight: .semibold) }
  static let drawSpeed: CGFloat = 1900
  static let drawDuration: ClosedRange<CFTimeInterval> = 0.22...0.6
  static let stagger: CFTimeInterval = 0.06
  static let nextStroke: CFTimeInterval = 0.14

  var colours: [NSColor] = []
  var scale: CGFloat = 1
  var animates = true

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

  func draw(_ shape: AskBolttyShape, in space: CGRect) {
    let now = CACurrentMediaTime()
    let begin = max(now, queuedUntil)
    shapeCount += 1
    let strokes = Self.strokes(of: shape, in: space, scale: scale)
    let path = Self.path(of: shape, in: space, scale: scale)
    let colour = Self.markerColour(from: colours)
    let still = MotionPreferences.reduceMotion || !animates
    var duration: CFTimeInterval = 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if !strokes.isEmpty {
      let mark = CALayer()
      mark.shadowColor = colour.cgColor
      mark.shadowOpacity = 0.35
      mark.shadowRadius = 5 * scale
      mark.shadowOffset = CGSize(width: 0, height: -1 * scale)
      for (index, stroke) in strokes.enumerated() {
        let line = MarkerLine(along: stroke, width: Self.width * scale, seed: shapeCount * 7 + index)
        let length = Self.length(of: stroke)
        let time = still ? 0 : index > 0 ? Self.nextStroke
          : min(max(Double(length / Self.drawSpeed), Self.drawDuration.lowerBound), Self.drawDuration.upperBound)
        mark.addSublayer(layer(for: line, colour: colour, begin: begin + duration, duration: time))
        duration += time
      }
      addSublayer(mark)
    }
    queuedUntil = begin + duration + Self.stagger
    if let words = shape.label {
      addSublayer(label(words, for: shape, in: space, path: path, appearAt: begin + duration * 0.6))
    }
    CATransaction.commit()
  }

  private func layer(
    for line: MarkerLine, colour: NSColor, begin: CFTimeInterval, duration: CFTimeInterval
  ) -> CALayer {
    let ink = CAShapeLayer()
    ink.contentsScale = contentsScale
    ink.path = line.outline
    ink.fillColor = colour.cgColor
    guard duration > 0 else { return ink }
    let pen = CAShapeLayer()
    pen.contentsScale = contentsScale
    pen.path = line.centre
    pen.fillColor = nil
    pen.strokeColor = NSColor.black.cgColor
    pen.lineWidth = Self.width * scale * 2
    pen.lineCap = .round
    pen.lineJoin = .round
    let draw = CABasicAnimation(keyPath: "strokeEnd")
    draw.fromValue = 0
    draw.toValue = 1
    draw.duration = duration
    draw.beginTime = convertTime(begin, from: nil)
    draw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    draw.fillMode = .backwards
    pen.add(draw, forKey: "draw")
    ink.mask = pen
    let show = CABasicAnimation(keyPath: "opacity")
    show.fromValue = 0
    show.toValue = 1
    show.duration = 0.05
    show.beginTime = draw.beginTime
    show.fillMode = .backwards
    ink.add(show, forKey: "show")
    return ink
  }

  static func markerColour(from colours: [NSColor]) -> NSColor {
    guard var ink = colours.map(Oklab.init).max(by: { $0.chroma < $1.chroma })?.oklch else { return .white }
    ink.l = min(max(ink.l, markerLightness.lowerBound), markerLightness.upperBound)
    ink.c = max(ink.c, markerChroma)
    return ink.color
  }

  private func label(
    _ words: String, for shape: AskBolttyShape, in space: CGRect, path: CGPath?,
    appearAt time: CFTimeInterval
  ) -> CALayer {
    let font = Self.labelFont.withSize(Self.labelFont.pointSize * scale)
    let attributed = NSAttributedString(string: words, attributes: [
      .font: font, .foregroundColor: NSColor.black,
    ])
    let size = attributed.boundingRect(
      with: CGSize(width: 260 * scale, height: 200), options: [.usesLineFragmentOrigin], context: nil).size
    let text = CATextLayer()
    text.contentsScale = contentsScale
    text.string = attributed
    text.isWrapped = true
    text.alignmentMode = .center
    let padding = CGSize(width: 11 * scale, height: 5 * scale)
    let box = CGSize(width: ceil(size.width) + 2 + padding.width * 2, height: ceil(size.height) + padding.height * 2)
    let gap: CGFloat = (Self.width / 2 + 6) * scale
    let anchor: CGPoint
    switch shape.kind {
    case let .label(at):
      let p = Self.place(at, in: space)
      anchor = CGPoint(x: p.x - box.width / 2, y: p.y - box.height / 2)
    case let .arrow(from, _):
      let p = Self.place(from, in: space)
      anchor = CGPoint(x: p.x - box.width / 2, y: p.y + gap)
    default:
      let bounds = path?.boundingBoxOfPath ?? CGRect(origin: space.origin, size: .zero)
      anchor = CGPoint(x: bounds.midX - box.width / 2, y: bounds.maxY + gap)
    }
    var frame = CGRect(origin: anchor, size: box)
    if frame.maxY > bounds.maxY - 4 { frame.origin.y = (path?.boundingBoxOfPath.minY ?? frame.minY) - gap - box.height }
    frame.origin.x = min(max(frame.minX, bounds.minX + 4), bounds.maxX - 4 - box.width)
    frame.origin.y = min(max(frame.minY, bounds.minY + 4), bounds.maxY - 4 - box.height)
    let pill = CALayer()
    pill.contentsScale = contentsScale
    pill.frame = frame
    pill.backgroundColor = NSColor.white.cgColor
    pill.applyPaletteCorner(radius: min(box.height / 2, 14 * scale))
    pill.shadowColor = NSColor.black.cgColor
    pill.shadowOpacity = 0.2
    pill.shadowRadius = 4 * scale
    pill.shadowOffset = CGSize(width: 0, height: -1 * scale)
    text.frame = CGRect(origin: CGPoint(x: padding.width, y: padding.height),
                        size: CGSize(width: box.width - padding.width * 2, height: box.height - padding.height * 2))
    pill.addSublayer(text)
    if !MotionPreferences.reduceMotion, animates {
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

  static func place(_ point: CGPoint, in space: CGRect) -> CGPoint {
    CGPoint(x: space.minX + point.x / 1000 * space.width,
            y: space.maxY - point.y / 1000 * space.height)
  }

  static func strokes(of shape: AskBolttyShape, in space: CGRect, scale: CGFloat = 1) -> [[CGPoint]] {
    switch shape.kind {
    case .label:
      return []
    case let .circle(center, radius):
      let c = place(center, in: space)
      let r = radius / 1000 * space.width + standOff * scale / 2
      let turn = 2 * CGFloat.pi + 0.4
      let count = max(24, Int(r * turn / MarkerLine.step))
      return [(0...count).map { index in
        let t = CGFloat(index) / CGFloat(count)
        let angle = .pi * 0.62 - t * turn
        let reach = r * (0.975 + 0.06 * t)
        return CGPoint(x: c.x + cos(angle) * reach * 1.02, y: c.y + sin(angle) * reach * 0.98)
      }]
    case let .arrow(from, to):
      let a = place(from, in: space), tip = place(to, in: space)
      let length = hypot(tip.x - a.x, tip.y - a.y)
      guard length > 1 else { return [] }
      let bow = min(length * arrowBow, arrowBowLimit * scale)
      var across = CGPoint(x: -(tip.y - a.y) / length, y: (tip.x - a.x) / length)
      if across.y < 0 { across = CGPoint(x: -across.x, y: -across.y) }
      let control = CGPoint(x: (a.x + tip.x) / 2 + across.x * bow, y: (a.y + tip.y) / 2 + across.y * bow)
      let angle = atan2(tip.y - control.y, tip.x - control.x)
      let side = min(arrowHead * scale, length * 0.45)
      func barb(_ turn: CGFloat, _ reach: CGFloat) -> CGPoint {
        CGPoint(x: tip.x - cos(angle + turn) * reach, y: tip.y - sin(angle + turn) * reach)
      }
      let tail = CGMutablePath()
      tail.move(to: a)
      tail.addQuadCurve(to: tip, control: control)
      let head = CGMutablePath()
      head.move(to: barb(arrowSpread, side))
      head.addLine(to: tip)
      head.addLine(to: barb(-arrowSpread * 1.1, side * 0.92))
      return MarkerLine.points(of: tail) + MarkerLine.points(of: head)
    case .box, .line, .path:
      guard let path = path(of: shape, in: space, scale: scale) else { return [] }
      return MarkerLine.points(of: path).map { run in
        guard let first = run.first, let last = run.last, run.count > 12,
              hypot(first.x - last.x, first.y - last.y) < MarkerLine.step * 2
        else { return run }
        return run + run[1...min(5, run.count - 1)]
      }
    }
  }

  static func path(of shape: AskBolttyShape, in space: CGRect, scale: CGFloat = 1) -> CGPath? {
    let path = CGMutablePath()
    switch shape.kind {
    case .circle, .arrow:
      for run in strokes(of: shape, in: space, scale: scale) { path.addLines(between: run) }
    case let .box(rect):
      let a = place(rect.origin, in: space)
      let b = place(CGPoint(x: rect.maxX, y: rect.maxY), in: space)
      let frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        .insetBy(dx: -standOff * scale, dy: -standOff * scale)
      let corner = min(cornerRadius * scale, min(frame.width, frame.height) / 2)
      path.move(to: CGPoint(x: frame.minX + corner, y: frame.maxY))
      path.addArc(tangent1End: CGPoint(x: frame.maxX, y: frame.maxY),
                  tangent2End: CGPoint(x: frame.maxX, y: frame.minY), radius: corner)
      path.addArc(tangent1End: CGPoint(x: frame.maxX, y: frame.minY),
                  tangent2End: CGPoint(x: frame.minX, y: frame.minY), radius: corner)
      path.addArc(tangent1End: CGPoint(x: frame.minX, y: frame.minY),
                  tangent2End: CGPoint(x: frame.minX, y: frame.maxY), radius: corner)
      path.addArc(tangent1End: CGPoint(x: frame.minX, y: frame.maxY),
                  tangent2End: CGPoint(x: frame.maxX, y: frame.maxY), radius: corner)
      path.closeSubpath()
    case let .line(from, to):
      path.move(to: place(from, in: space))
      path.addLine(to: place(to, in: space))
    case let .path(segments):
      if let rounded = rounded(segments, in: space) {
        path.addPath(rounded)
        break
      }
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

  private static func rounded(_ segments: [AskBolttyShape.Segment], in space: CGRect) -> CGPath? {
    var points: [CGPoint] = []
    var closes = false
    for (index, segment) in segments.enumerated() {
      switch segment {
      case let .move(p) where index == 0: points.append(place(p, in: space))
      case let .line(p) where !closes: points.append(place(p, in: space))
      case .close where index == segments.count - 1: closes = true
      default: return nil
      }
    }
    if points.count > 1, points.first == points.last {
      points.removeLast()
      closes = true
    }
    guard points.count > 2 else { return nil }
    let count = points.count
    func turn(at index: Int) -> CGFloat {
      let a = points[(index + count - 1) % count], b = points[index], c = points[(index + 1) % count]
      let before = hypot(a.x - b.x, a.y - b.y), after = hypot(c.x - b.x, c.y - b.y)
      guard before > 0, after > 0 else { return 0 }
      let cosine = ((a.x - b.x) * (c.x - b.x) + (a.y - b.y) * (c.y - b.y)) / (before * after)
      let half = acos(min(1, max(-1, cosine))) / 2
      return min(cornerRadius, min(before, after) * 0.12 * tan(half))
    }
    let path = CGMutablePath()
    if closes {
      path.move(to: CGPoint(
        x: points[0].x + (points[count - 1].x - points[0].x) * 0.15,
        y: points[0].y + (points[count - 1].y - points[0].y) * 0.15))
      for index in 0..<count {
        path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % count], radius: turn(at: index))
      }
      path.closeSubpath()
    } else {
      path.move(to: points[0])
      for index in 1..<(count - 1) {
        path.addArc(tangent1End: points[index], tangent2End: points[index + 1], radius: turn(at: index))
      }
      path.addLine(to: points[count - 1])
    }
    return path
  }

  static func length(of run: [CGPoint]) -> CGFloat {
    zip(run, run.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
  }
}

struct MarkerLine {
  static let step: CGFloat = 3
  let centre: CGPath
  let outline: CGPath

  init(along run: [CGPoint], width: CGFloat, seed: Int) {
    let scale = width / 7
    let count = run.count
    var travelled: CGFloat = 0
    var centres: [CGPoint] = []
    var halves: [CGFloat] = []
    for index in run.indices {
      let before = run[max(0, index - 2)], after = run[min(count - 1, index + 2)]
      if index > 0 { travelled += hypot(run[index].x - run[index - 1].x, run[index].y - run[index - 1].y) }
      let angle = atan2(after.y - before.y, after.x - before.x)
      let s = travelled / max(scale, 0.1)
      let sway = (Self.noise(s / 85, seed) * 2.6 + Self.noise(s / 38, seed + 101) * 0.8) * scale
      centres.append(CGPoint(x: run[index].x - sin(angle) * sway, y: run[index].y + cos(angle) * sway))
      let end = CGFloat(count - 1 - index) * Self.step
      let lift = 0.62 + 0.38 * min(1, end / (22 * max(scale, 0.1)))
      let press = 1 + 0.12 * max(0, 1 - s / 14)
      let share = 1 + 0.2 * sin(2 * angle + 0.5) + 0.16 * Self.noise(s / 46, seed + 211)
      halves.append(width / 2 * share * lift * press)
    }
    let centre = CGMutablePath()
    centre.addLines(between: centres)
    self.centre = centre
    let outline = CGMutablePath()
    for index in centres.indices {
      let c = centres[index], h = halves[index]
      outline.addEllipse(in: CGRect(x: c.x - h, y: c.y - h, width: h * 2, height: h * 2))
      guard index > 0 else { continue }
      let p = centres[index - 1], k = halves[index - 1]
      let length = hypot(c.x - p.x, c.y - p.y)
      guard length > 0.01 else { continue }
      let nx = -(c.y - p.y) / length, ny = (c.x - p.x) / length
      outline.move(to: CGPoint(x: p.x - nx * k, y: p.y - ny * k))
      outline.addLine(to: CGPoint(x: c.x - nx * h, y: c.y - ny * h))
      outline.addLine(to: CGPoint(x: c.x + nx * h, y: c.y + ny * h))
      outline.addLine(to: CGPoint(x: p.x + nx * k, y: p.y + ny * k))
      outline.closeSubpath()
    }
    self.outline = outline
  }

  private static func noise(_ x: CGFloat, _ seed: Int) -> CGFloat {
    func value(_ n: Int) -> CGFloat {
      var h = UInt64(bitPattern: Int64(n &* 374_761_393 &+ seed &* 668_265_263))
      h = (h ^ (h >> 13)) &* 1_274_126_177
      h ^= h >> 16
      return CGFloat(h % 2000) / 1000 - 1
    }
    let cell = Int(floor(x)), t = x - floor(x)
    let eased = t * t * (3 - 2 * t)
    return value(cell) + (value(cell + 1) - value(cell)) * eased
  }

  static func points(of path: CGPath) -> [[CGPoint]] {
    var runs: [[CGPoint]] = []
    var run: [CGPoint] = []
    var start = CGPoint.zero
    func line(to end: CGPoint) {
      guard let from = run.last else { return run = [end] }
      let count = max(1, Int((hypot(end.x - from.x, end.y - from.y) / step).rounded()))
      for index in 1...count {
        let t = CGFloat(index) / CGFloat(count)
        run.append(CGPoint(x: from.x + (end.x - from.x) * t, y: from.y + (end.y - from.y) * t))
      }
    }
    func curve(reach: CGFloat, _ at: (CGFloat) -> CGPoint) {
      let count = max(4, Int(reach / step))
      for index in 1...count { run.append(at(CGFloat(index) / CGFloat(count))) }
    }
    path.applyWithBlock { element in
      let p = element.pointee.points
      switch element.pointee.type {
      case .moveToPoint:
        if run.count > 1 { runs.append(run) }
        start = p[0]
        run = [start]
      case .addLineToPoint:
        line(to: p[0])
      case .addQuadCurveToPoint:
        let a = run.last ?? start, c = p[0], b = p[1]
        curve(reach: hypot(c.x - a.x, c.y - a.y) + hypot(b.x - c.x, b.y - c.y)) { t in
          let u = 1 - t
          return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        }
      case .addCurveToPoint:
        let a = run.last ?? start, c = p[0], d = p[1], b = p[2]
        let reach = hypot(c.x - a.x, c.y - a.y) + hypot(d.x - c.x, d.y - c.y) + hypot(b.x - d.x, b.y - d.y)
        curve(reach: reach) { t in
          let u = 1 - t
          let w = (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
          return CGPoint(
            x: w.0 * a.x + w.1 * c.x + w.2 * d.x + w.3 * b.x, y: w.0 * a.y + w.1 * c.y + w.2 * d.y + w.3 * b.y)
        }
      case .closeSubpath:
        line(to: start)
      @unknown default:
        break
      }
    }
    if run.count > 1 { runs.append(run) }
    return runs
  }
}
