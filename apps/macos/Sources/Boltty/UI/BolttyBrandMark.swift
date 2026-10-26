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

    builder.move(to: point(71.1565, 93.4236))
    builder.curve(
      to: point(84.5813, 71.9531),
      c1: point(76.7966, 81.6733),
      c2: point(79.6166, 75.7981)
    )
    builder.curve(
      to: point(108.611, 64.3563),
      c1: point(89.546, 68.1081),
      c2: point(95.901, 66.8575)
    )
    builder.curve(
      to: point(146.209, 57.0982),
      c1: point(120.709, 61.9755),
      c2: point(134.893, 59.2145)
    )
    builder.curve(
      to: point(182.073, 50.6007),
      c1: point(156.966, 55.0866),
      c2: point(170.349, 52.6819)
    )
    builder.curve(
      to: point(208.968, 49.1161),
      c1: point(195.728, 48.1768),
      c2: point(202.555, 46.9649)
    )
    builder.curve(
      to: point(229.386, 66.3613),
      c1: point(215.38, 51.2674),
      c2: point(220.049, 56.2987)
    )
    builder.curve(
      to: point(259.776, 100.107),
      c1: point(239.298, 77.0436),
      c2: point(251.071, 89.9363)
    )
    builder.curve(
      to: point(284.879, 130.919),
      c1: point(267.722, 109.391),
      c2: point(277.016, 120.952)
    )
    builder.curve(
      to: point(298.704, 153.658),
      c1: point(293.334, 141.634),
      c2: point(297.561, 146.992)
    )
    builder.curve(
      to: point(293.133, 180.044),
      c1: point(299.847, 160.323),
      c2: point(297.609, 166.897)
    )
    builder.curve(
      to: point(279.882, 218.788),
      c1: point(288.884, 192.523),
      c2: point(283.892, 207.148)
    )
    builder.curve(
      to: point(268.16, 252.597),
      c1: point(276.386, 228.937),
      c2: point(272.082, 241.333)
    )
    builder.curve(
      to: point(253.924, 280.567),
      c1: point(262.786, 268.033),
      c2: point(260.099, 275.751)
    )
    builder.curve(
      to: point(223.771, 287.512),
      c1: point(247.75, 285.383),
      c2: point(239.757, 286.092)
    )
    builder.curve(
      to: point(184.848, 290.314),
      c1: point(210.927, 288.652),
      c2: point(196.547, 289.781)
    )
    builder.curve(
      to: point(125.535, 290.854),
      c1: point(166.86, 291.134),
      c2: point(143.486, 291.083)
    )
    builder.curve(
      to: point(99.805, 287.405),
      c1: point(112.257, 290.685),
      c2: point(105.618, 290.601)
    )
    builder.curve(
      to: point(83.0174, 267.4),
      c1: point(93.9925, 284.209),
      c2: point(90.3341, 278.606)
    )
    builder.curve(
      to: point(64.4494, 238.444),
      c1: point(76.8549, 257.961),
      c2: point(69.9093, 247.209)
    )
    builder.curve(
      to: point(43.7216, 204.036),
      c1: point(58.0647, 228.196),
      c2: point(50.3057, 215.199)
    )
    builder.curve(
      to: point(33.017, 179.679),
      c1: point(36.7673, 192.245),
      c2: point(33.2901, 186.35)
    )
    builder.curve(
      to: point(41.7997, 154.31),
      c1: point(32.7439, 173.008),
      c2: point(35.7625, 166.775)
    )
    builder.curve(
      to: point(56.4616, 123.986),
      c1: point(46.6372, 144.323),
      c2: point(52.0717, 133.09)
    )
    builder.curve(
      to: point(71.1565, 93.4236),
      c1: point(60.8833, 114.815),
      c2: point(66.3591, 103.418)
    )
    builder.close()
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
