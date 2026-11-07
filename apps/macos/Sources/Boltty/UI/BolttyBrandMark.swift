import AppKit

enum BolttyBrandMark {
  static let designSize: CGFloat = 333

  static let outlineWidth: CGFloat = 31

  static func emitOutline(into builder: inout some BrandMarkPathBuilder, rect: CGRect) {
    let scale = min(rect.width, rect.height) / designSize
    let offsetX = rect.minX + (rect.width - designSize * scale) / 2
    let offsetY = rect.minY + (rect.height - designSize * scale) / 2
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      builder.point(
        x: offsetX + x * scale,
        y: offsetY + y * scale,
        boxHeight: designSize * scale,
        boxMinY: offsetY
      )
    }

    // Each corner starts this far along its edges, so the sides stay long enough
    // to read as a hexagon. Rounder than this and it was a plain circle.
    let corners = outlineCorners
    for index in corners.indices {
      let before = corners[(index + corners.count - 1) % corners.count]
      let corner = corners[index]
      let after = corners[(index + 1) % corners.count]
      let enter = along(corner, before, by: cornerReach)
      let leave = along(corner, after, by: cornerReach)
      if index == corners.startIndex {
        builder.move(to: point(enter.x, enter.y))
      } else {
        builder.line(to: point(enter.x, enter.y))
      }
      let c1 = along(enter, corner, by: 2.0 / 3)
      let c2 = along(leave, corner, by: 2.0 / 3)
      builder.curve(to: point(leave.x, leave.y), c1: point(c1.x, c1.y), c2: point(c2.x, c2.y))
    }
    builder.close()
  }

  /// The hexagon's corners, tilted and a little uneven on purpose: it is a character.
  private static let outlineCorners: [CGPoint] = [
    CGPoint(x: 82.9, y: 69.2), CGPoint(x: 211, y: 45.1), CGPoint(x: 302.8, y: 151.6),
    CGPoint(x: 256.7, y: 286.4), CGPoint(x: 97.9, y: 291.4), CGPoint(x: 29.1, y: 180.5),
  ]
  private static let cornerReach: CGFloat = 0.35

  private static func along(_ from: CGPoint, _ to: CGPoint, by part: CGFloat) -> CGPoint {
    CGPoint(x: from.x + (to.x - from.x) * part, y: from.y + (to.y - from.y) * part)
  }

  static func emitEyes(into builder: inout some BrandMarkPathBuilder, rect: CGRect) {
    let scale = min(rect.width, rect.height) / designSize
    let offsetX = rect.minX + (rect.width - designSize * scale) / 2
    let offsetY = rect.minY + (rect.height - designSize * scale) / 2
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      builder.point(
        x: offsetX + x * scale,
        y: offsetY + y * scale,
        boxHeight: designSize * scale,
        boxMinY: offsetY
      )
    }

    builder.move(to: point(133.781, 143.962))
    builder.curve(
      to: point(139.161, 118.828),
      c1: point(128.54, 135.497),
      c2: point(130.914, 124.405)
    )
    builder.curve(
      to: point(164.908, 123.786),
      c1: point(147.641, 113.094),
      c2: point(159.164, 115.312)
    )
    builder.line(to: point(180.977, 147.488))
    builder.curve(
      to: point(175.21, 174.506),
      c1: point(187.084, 156.496),
      c2: point(184.463, 168.777)
    )
    builder.curve(
      to: point(148.856, 168.308),
      c1: point(166.221, 180.073),
      c2: point(154.422, 177.298)
    )
    builder.line(to: point(133.781, 143.962))
    builder.close()
    builder.move(to: point(194.154, 122.941))
    builder.curve(
      to: point(202.643, 99.7034),
      c1: point(188.626, 114.291),
      c2: point(192.841, 102.753)
    )
    builder.curve(
      to: point(219.76, 105.286),
      c1: point(208.955, 97.7396),
      c2: point(215.819, 99.9784)
    )
    builder.line(to: point(237.3, 128.912))
    builder.curve(
      to: point(233.295, 152.53),
      c1: point(242.926, 136.491),
      c2: point(241.105, 147.23)
    )
    builder.curve(
      to: point(209.999, 147.736),
      c1: point(225.565, 157.776),
      c2: point(215.03, 155.608)
    )
    builder.line(to: point(194.154, 122.941))
    builder.close()
  }

  static func outlineWidth(in rect: CGRect) -> CGFloat {
    outlineWidth * (min(rect.width, rect.height) / designSize)
  }
}

protocol BrandMarkPathBuilder {
  func point(x: CGFloat, y: CGFloat, boxHeight: CGFloat, boxMinY: CGFloat) -> CGPoint
  mutating func move(to point: CGPoint)
  mutating func line(to point: CGPoint)
  mutating func curve(to point: CGPoint, c1: CGPoint, c2: CGPoint)
  mutating func close()
}

// MARK: - AppKit

extension NSBezierPath {
  static func bolttyBrandOutline(in rect: CGRect) -> NSBezierPath {
    var builder = AppKitBrandMarkBuilder()
    BolttyBrandMark.emitOutline(into: &builder, rect: rect)
    builder.path.lineWidth = BolttyBrandMark.outlineWidth(in: rect)
    builder.path.lineCapStyle = .round
    builder.path.lineJoinStyle = .round
    return builder.path
  }

  static func bolttyBrandEyes(in rect: CGRect) -> NSBezierPath {
    var builder = AppKitBrandMarkBuilder()
    BolttyBrandMark.emitEyes(into: &builder, rect: rect)
    return builder.path
  }
}

private struct AppKitBrandMarkBuilder: BrandMarkPathBuilder {
  let path = NSBezierPath()

  func point(x: CGFloat, y: CGFloat, boxHeight: CGFloat, boxMinY: CGFloat) -> CGPoint {
    CGPoint(x: x, y: boxMinY + boxHeight - (y - boxMinY))
  }

  mutating func move(to point: CGPoint) { path.move(to: point) }
  mutating func line(to point: CGPoint) { path.line(to: point) }

  mutating func curve(to point: CGPoint, c1: CGPoint, c2: CGPoint) {
    path.curve(to: point, controlPoint1: c1, controlPoint2: c2)
  }

  mutating func close() { path.close() }
}
