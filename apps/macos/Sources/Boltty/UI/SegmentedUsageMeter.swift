import AppKit

final class SegmentedUsageMeter: NSView {
  var segments = 1 { didSet { if segments != oldValue { needsDisplay = true } } }
  var used: Double = 0 { didSet { if used != oldValue { needsDisplay = true } } }
  var fill: NSColor = BolttyBrand.accent { didSet { needsDisplay = true } }
  var track: NSColor = .quaternaryLabelColor { didSet { needsDisplay = true } }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    Self.draw(in: bounds, segments: segments, used: used, fill: fill, track: track)
  }

  static func draw(in rect: NSRect, segments: Int, used: Double, fill: NSColor, track: NSColor) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let shapes = UsageSegments.rects(in: rect, count: segments).map { piece in
      CGPath(
        roundedRect: piece, cornerWidth: UsageSegments.cornerRadius(of: piece),
        cornerHeight: UsageSegments.cornerRadius(of: piece), transform: nil)
    }
    context.setFillColor(track.cgColor)
    for shape in shapes {
      context.addPath(shape)
      context.fillPath()
    }
    let fraction = CGFloat(min(max(used, 0), 1))
    guard fraction > 0 else { return }
    let reach = max(rect.width * fraction, rect.height)
    let fade = UsageSegments.fade(reach: reach, length: rect.width)
    context.saveGState()
    for shape in shapes { context.addPath(shape) }
    context.clip()
    context.setFillColor(fill.cgColor)
    context.fill(CGRect(x: rect.minX, y: rect.minY, width: reach - fade, height: rect.height))
    if fade > 0, let gradient = fadeGradient(fill) {
      context.clip(to: CGRect(x: rect.minX + reach - fade, y: rect.minY, width: fade, height: rect.height))
      context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX + reach - fade, y: rect.midY),
        end: CGPoint(x: rect.minX + reach, y: rect.midY),
        options: [])
    }
    context.restoreGState()
  }

  static func drawRing(
    center: NSPoint, radius: CGFloat, stroke: CGFloat, flipped: Bool,
    segments: Int, used: Double, fill: NSColor, track: NSColor
  ) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let circumference = 2 * .pi * radius
    let pieces = UsageSegments.rects(
      in: CGRect(x: 0, y: 0, width: circumference, height: stroke), count: segments, closed: true)
    let whole = pieces.count == 1
    let visualTop: CGFloat = flipped ? -.pi / 2 : .pi / 2
    let turn: CGFloat = flipped ? 1 : -1
    func angle(_ along: CGFloat) -> CGFloat { visualTop + turn * along / radius }

    let shapes: [CGPath] = pieces.map { piece in
      if whole {
        return CGPath(
          ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius),
          transform: nil
        ).copy(strokingWithWidth: stroke, lineCap: .butt, lineJoin: .round, miterLimit: 1)
      }
      let inset = min(stroke / 2, piece.width / 2 - 0.01)
      let path = CGMutablePath()
      path.addArc(
        center: center, radius: radius,
        startAngle: angle(piece.minX + inset), endAngle: angle(piece.maxX - inset),
        clockwise: !flipped)
      return path.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }
    context.setFillColor(track.cgColor)
    for shape in shapes {
      context.addPath(shape)
      context.fillPath()
    }
    let fraction = CGFloat(min(max(used, 0), 1))
    guard fraction > 0 else { return }
    let reach = circumference * fraction
    let fade = UsageSegments.fade(reach: reach, length: circumference)
    context.saveGState()
    for shape in shapes { context.addPath(shape) }
    context.clip()
    context.setShouldAntialias(false)
    let outer = radius + stroke
    func wedge(from start: CGFloat, to end: CGFloat, alpha: CGFloat) {
      let path = CGMutablePath()
      path.move(to: center)
      path.addArc(center: center, radius: outer, startAngle: angle(start), endAngle: angle(end), clockwise: !flipped)
      path.closeSubpath()
      context.setFillColor(fill.withAlphaComponent(fill.alphaComponent * alpha).cgColor)
      context.addPath(path)
      context.fillPath()
    }
    wedge(from: 0, to: reach - fade, alpha: 1)
    if fade > 0 {
      let steps = max(Int((fade / ringFadeStep).rounded(.up)), 1)
      let step = fade / CGFloat(steps)
      for index in 0..<steps {
        let from = reach - fade + CGFloat(index) * step
        wedge(from: from, to: from + step, alpha: UsageSegments.opacity(at: (CGFloat(index) + 0.5) / CGFloat(steps)))
      }
    }
    context.restoreGState()
  }

  static let ringFadeStep: CGFloat = 0.25

  private static func fadeGradient(_ fill: NSColor) -> CGGradient? {
    let locations = UsageSegments.fadeLocations
    let colors = locations.map { fill.withAlphaComponent(fill.alphaComponent * UsageSegments.opacity(at: $0)).cgColor }
    return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)
  }
}
