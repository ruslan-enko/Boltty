import AppKit

@testable import Boltty

@MainActor
final class SunsetView: NSView {
  static let colours = [
    OKLCH(0.411, 0.128, 262.5), OKLCH(0.532, 0.119, 256), OKLCH(0.622, 0.097, 252.3),
    OKLCH(0.72, 0.03, 305.9), OKLCH(0.779, 0.096, 53.3), OKLCH(0.778, 0.139, 63.7),
    OKLCH(0.613, 0.199, 35.2)
  ]
  static let locations: [NSNumber] = [0, 0.3, 0.46, 0.6, 0.72, 0.84, 1]
  static let drifted: [NSNumber] = [0, 0.25, 0.41, 0.55, 0.69, 0.82, 1]

  static func skyLocations(_ places: [NSNumber]) -> [NSNumber] {
    OklabGradient.numbers(places.map { CGFloat(truncating: $0) })
  }

  private let sky = CAGradientLayer()
  private let horizon = CAGradientLayer()
  private let night = CAGradientLayer()
  private var lights: [CAGradientLayer] = []
  private static let lightColours: [(colour: OKLCH, alpha: CGFloat, centre: CGPoint, period: Double)] = [
    (OKLCH(0.825, 0.125, 63.1), 0.38, CGPoint(x: 0.28, y: 0.3), 26),
    (OKLCH(0.765, 0.153, 359.3), 0.26, CGPoint(x: 0.74, y: 0.42), 33),
    (OKLCH(0.821, 0.091, 254.3), 0.30, CGPoint(x: 0.55, y: 0.78), 29),
  ]

  override init(frame: CGRect) {
    super.init(frame: frame)
    wantsLayer = true
    build()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private static let dark = OKLCH(0.179, 0.026, 266.5).color.cgColor
  private static let ember = OKLCH(0.267, 0.054, 51.5).color.cgColor

  private func build() {
    guard let root = layer else { return }
    sky.frame = bounds
    sky.colors = OklabGradient.cgColors(Self.colours.map(\.color))
    sky.locations = Self.skyLocations(Self.locations)
    sky.startPoint = CGPoint(x: 0.5, y: 1)
    sky.endPoint = CGPoint(x: 0.5, y: 0)
    root.addSublayer(sky)

    let ember = OKLCH(0.725, 0.182, 46.2).color.cgColor
    horizon.type = .radial
    horizon.frame = bounds
    horizon.colors = [ember, ember.copy(alpha: 0) ?? ember]
    horizon.startPoint = CGPoint(x: 0.5, y: 0)
    horizon.endPoint = CGPoint(x: 1.1, y: 0.5)
    horizon.opacity = 0.3
    horizon.compositingFilter = "screenBlendMode"
    root.addSublayer(horizon)

    for light in Self.lightColours {
      let glow = CAGradientLayer()
      glow.type = .radial
      let colour = light.colour.cgColor
      glow.colors = [colour.copy(alpha: light.alpha) ?? colour, colour.copy(alpha: 0) ?? colour]
      glow.startPoint = CGPoint(x: 0.5, y: 0.5)
      glow.endPoint = CGPoint(x: 1, y: 1)
      let side = max(bounds.width, bounds.height) * 0.75
      glow.bounds = CGRect(x: 0, y: 0, width: side, height: side)
      glow.position = CGPoint(x: bounds.width * light.centre.x, y: bounds.height * light.centre.y)
      glow.compositingFilter = "screenBlendMode"
      root.addSublayer(glow)
      lights.append(glow)
    }

    night.frame = bounds
    night.colors = [Self.dark, Self.dark, Self.dark]
    night.locations = [0, 0.7, 1]
    night.startPoint = CGPoint(x: 0.5, y: 1)
    night.endPoint = CGPoint(x: 0.5, y: 0)
    root.addSublayer(night)
  }

  func dawn() {
    let now = CACurrentMediaTime()
    let warm = CABasicAnimation(keyPath: "colors")
    warm.fromValue = [Self.dark, Self.dark, Self.dark]
    warm.toValue = [Self.dark, Self.dark, Self.ember]
    warm.duration = 0.4
    warm.beginTime = now
    warm.fillMode = .both
    warm.timingFunction = Motion.standardCurve
    night.colors = [Self.dark, Self.dark, Self.ember]
    night.add(warm, forKey: "boltty.sunset.warm")

    let lift = CABasicAnimation(keyPath: "opacity")
    lift.fromValue = 1
    lift.toValue = 0
    lift.duration = 0.7
    lift.beginTime = now + 0.2
    lift.fillMode = .both
    lift.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    night.opacity = 0
    night.add(lift, forKey: "boltty.sunset.dawn")

    for (index, glow) in lights.enumerated() {
      let light = Self.lightColours[index]
      let centre = glow.position
      let reach = CGSize(width: bounds.width * 0.16, height: bounds.height * 0.12)
      let path = CGMutablePath()
      path.addEllipse(in: CGRect(x: centre.x - reach.width, y: centre.y - reach.height,
                                 width: reach.width * 2, height: reach.height * 2))
      let wander = CAKeyframeAnimation(keyPath: "position")
      wander.path = path
      wander.duration = light.period
      wander.repeatCount = .infinity
      wander.calculationMode = .paced
      wander.timeOffset = light.period * Double(index) / 3
      glow.add(wander, forKey: "boltty.sunset.wander")
      let breathe = CABasicAnimation(keyPath: "opacity")
      breathe.fromValue = 0.65
      breathe.toValue = 1
      breathe.duration = light.period / 3
      breathe.autoreverses = true
      breathe.repeatCount = .infinity
      breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      glow.add(breathe, forKey: "boltty.sunset.breathe")
    }

    let drift = CABasicAnimation(keyPath: "locations")
    drift.fromValue = Self.skyLocations(Self.locations)
    drift.toValue = Self.skyLocations(Self.drifted)
    drift.duration = 14
    drift.autoreverses = true
    drift.repeatCount = .infinity
    drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    sky.add(drift, forKey: "boltty.sunset.drift")
    let glow = CABasicAnimation(keyPath: "opacity")
    glow.fromValue = 0.22
    glow.toValue = 0.38
    glow.duration = 7
    glow.autoreverses = true
    glow.repeatCount = .infinity
    glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    horizon.add(glow, forKey: "boltty.sunset.glow")
  }
}
