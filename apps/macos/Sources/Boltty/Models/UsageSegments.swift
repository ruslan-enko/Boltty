import CoreGraphics

struct UsageSegments: Equatable {
  static let maxGap: CGFloat = 3
  static let minGap: CGFloat = 1.5
  static let minSegment: CGFloat = 3
  static let gapShare: CGFloat = 0.3
  static let minLength: CGFloat = 2
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
    let count = fitting(count, in: rect)
    guard count > 1 else { return [rect] }
    let gap = gap(count: count, width: rect.width)
    if closed {
      let pitch = rect.width / CGFloat(count)
      return (0..<count).map { index in
        CGRect(x: rect.minX + CGFloat(index) * pitch + gap / 2, y: rect.minY, width: pitch - gap, height: rect.height)
      }
    }
    let side = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
    return (0..<count).map { index in
      CGRect(x: rect.minX + CGFloat(index) * (side + gap), y: rect.minY, width: side, height: rect.height)
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

  private static func gap(count: Int, width: CGFloat) -> CGFloat {
    min(max(width / CGFloat(count) * gapShare, minGap), maxGap)
  }

  private static func fitting(_ count: Int, in rect: CGRect) -> Int {
    guard count > 1 else { return 1 }
    let gap = gap(count: count, width: rect.width)
    let side = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
    return side >= max(minSegment, rect.height * minLength) ? count : 1
  }
}
