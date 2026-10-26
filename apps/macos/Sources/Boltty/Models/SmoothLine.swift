import CoreGraphics

/// A line through points sampled from a moving hand, without the corners.
///
/// Joined straight, samples a display frame apart turn a quick curve into a
/// polygon — 20 to 50 points a side at speed. Here each sample is a curve's
/// control instead, and the curve runs through the midpoints between
/// samples: no corner anywhere, the tangent carried through every joint, and
/// still through the middle of every stretch the hand drew. It is drawn as it
/// arrives, half a sample behind the hand.
struct SmoothLine {
  /// One piece of the line: a quadratic curve.
  struct Piece: Equatable {
    var from: CGPoint
    var to: CGPoint
    var control: CGPoint
  }

  /// Where the drawn line ends so far.
  private(set) var pen: CGPoint?
  private var last: CGPoint?

  /// Takes the next sample; the piece it completes, if any.
  mutating func add(_ point: CGPoint) -> Piece? {
    guard let last, let pen else {
      self.last = point
      pen = point
      return nil
    }
    let middle = CGPoint(x: (last.x + point.x) / 2, y: (last.y + point.y) / 2)
    self.last = point
    self.pen = middle
    return Piece(from: pen, to: middle, control: last)
  }

  /// The whole line through `points`, to their last.
  static func path(through points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    var line = SmoothLine()
    for point in points {
      guard let piece = line.add(point) else { continue }
      if path.isEmpty { path.move(to: piece.from) }
      path.addQuadCurve(to: piece.to, control: piece.control)
    }
    if let end = points.last, !path.isEmpty { path.addLine(to: end) }
    return path
  }
}
