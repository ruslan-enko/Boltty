import CoreGraphics

struct UsageSegments: Equatable {
  static let maxGap: CGFloat = 3
  static let minGap: CGFloat = 1.5
  static let minSegment: CGFloat = 3
  static let gapShare: CGFloat = 0.3
  static let grid: CGFloat = 0.5
  static let fadeShare: CGFloat = 0.3
  static let maxFade: CGFloat = 48
  static let fadeStops = 24

  static func count(for kind: AgentUsageWindow.Kind) -> Int {
    let count: Int = switch kind {
    case .session: 5
    case .weekly: 7
    case let .other(minutes): minutes % 1_440 == 0 ? minutes / 1_440 : max(minutes / 60, 1)
    case .named: 1
    }
    return min(max(count, 1), 31)
  }

  static func rects(in rect: CGRect, count: Int, closed: Bool = false) -> [CGRect] {
    let count = fitting(count, width: rect.width)
    guard count > 1 else { return [rect] }
    if closed {
      let pitch = rect.width / CGFloat(count)
      let gap = gap(count: count, width: rect.width)
      return (0..<count).map { index in
        CGRect(x: rect.minX + CGFloat(index) * pitch + gap / 2, y: rect.minY, width: pitch - gap, height: rect.height)
      }
    }
    let gap = snapped(gap(count: count, width: rect.width))
    let pitch = (rect.width + gap) / CGFloat(count)
    return (0..<count).map { index in
      let start = snapped(rect.minX + CGFloat(index) * pitch)
      let end = index == count - 1 ? rect.maxX : snapped(rect.minX + CGFloat(index + 1) * pitch - gap)
      return CGRect(x: start, y: rect.minY, width: end - start, height: rect.height)
    }
  }

  static func fade(reach: CGFloat, length: CGFloat) -> CGFloat {
    guard reach > 0, reach < length else { return 0 }
    return min(reach, length * fadeShare, maxFade)
  }

  static func opacity(at t: CGFloat) -> CGFloat {
    let t = min(max(t, 0), 1)
    let eased = t * t * t * (t * (6 * t - 15) + 10)
    return 1 - eased
  }

  static var fadeLocations: [CGFloat] {
    (0...fadeStops).map { CGFloat($0) / CGFloat(fadeStops) }
  }

  static func cornerRadius(of rect: CGRect) -> CGFloat {
    min(rect.width, rect.height) / 2
  }

  private static func snapped(_ value: CGFloat) -> CGFloat {
    (value / grid).rounded() * grid
  }

  private static func gap(count: Int, width: CGFloat) -> CGFloat {
    min(max(width / CGFloat(count) * gapShare, minGap), maxGap)
  }

  private static func fitting(_ count: Int, width: CGFloat) -> Int {
    guard count > 1 else { return 1 }
    let gap = gap(count: count, width: width)
    let side = (width - gap * CGFloat(count - 1)) / CGFloat(count)
    return side >= minSegment ? count : 1
  }
}
