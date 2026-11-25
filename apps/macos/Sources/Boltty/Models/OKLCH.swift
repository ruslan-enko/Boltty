import AppKit

struct OKLCH: Hashable, Sendable {
  var l, c, h: Double

  init(_ l: Double, _ c: Double, _ h: Double) {
    self.l = l
    self.c = c
    self.h = h
  }

  var oklab: Oklab { Oklab(hue: h, chroma: c, l: l) }

  var color: NSColor { NSColor(oklch: l, c, h) }

  func color(alpha: CGFloat) -> NSColor { NSColor(oklch: l, c, h, alpha: alpha) }

  var cgColor: CGColor { color.cgColor }
}

struct Oklab: Hashable, Sendable {
  var l, a, b: Double

  init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }

  var chroma: Double { (a * a + b * b).squareRoot() }

  var hue: Double { atan2(b, a) * 180 / .pi }

  init(hue: Double, chroma: Double, l: Double) {
    self.l = l
    self.a = chroma * cos(hue * .pi / 180)
    self.b = chroma * sin(hue * .pi / 180)
  }

  init(_ color: NSColor) {
    // Extended, so a Display P3 colour past sRGB is read whole, not clipped.
    let srgb = color.usingColorSpace(.extendedSRGB) ?? color
    let (r, g, b) = (
      Self.decode(Double(srgb.redComponent)),
      Self.decode(Double(srgb.greenComponent)),
      Self.decode(Double(srgb.blueComponent))
    )
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    self.l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    self.a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
  }

  var oklch: OKLCH {
    var hue = self.hue.truncatingRemainder(dividingBy: 360)
    if hue < 0 { hue += 360 }
    return OKLCH(l, chroma, hue)
  }

  func linearSRGB(chroma scale: Double = 1) -> (Double, Double, Double) {
    let a = self.a * scale, b = self.b * scale
    let l = pow(self.l + 0.3963377774 * a + 0.2158037573 * b, 3)
    let m = pow(self.l - 0.1055613458 * a - 0.0638541728 * b, 3)
    let s = pow(self.l - 0.0894841775 * a - 1.2914855480 * b, 3)
    return (
      4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    )
  }

  func color(fitting: Bool) -> NSColor {
    let scale = fitting ? Self.largestScale { Self.isInside(linearSRGB(chroma: $0)) } : 1
    let (r, g, b) = linearSRGB(chroma: scale)
    return NSColor(
      srgbRed: Self.encode(r), green: Self.encode(g), blue: Self.encode(b), alpha: 1
    )
  }

  static func isInside(_ v: (Double, Double, Double)) -> Bool {
    [v.0, v.1, v.2].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 }
  }

  static func largestScale(fits: (Double) -> Bool) -> Double {
    guard !fits(1) else { return 1 }
    var low = 0.0, high = 1.0
    for _ in 0..<20 {
      let mid = (low + high) / 2
      if fits(mid) { low = mid } else { high = mid }
    }
    return low
  }

  static func decode(_ v: Double) -> Double {
    let x = abs(v)
    let linear = x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    return v < 0 ? -linear : linear
  }

  static func encode(_ v: Double) -> CGFloat {
    let v = min(1, max(0, v))
    return CGFloat(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
  }
}

extension NSColor {
  convenience init(oklch l: Double, _ c: Double, _ h: Double, alpha: CGFloat = 1) {
    let lab = Oklab(hue: h, chroma: c, l: l)
    func linearP3(_ scale: Double) -> (Double, Double, Double) {
      let (r, g, b) = lab.linearSRGB(chroma: scale)
      return (
        0.8224621 * r + 0.1775380 * g,
        0.0331941 * r + 0.9668058 * g,
        0.0170827 * r + 0.0723974 * g + 0.9105199 * b
      )
    }
    let (r, g, b) = linearP3(Oklab.largestScale { Oklab.isInside(linearP3($0)) })
    self.init(
      displayP3Red: Oklab.encode(r), green: Oklab.encode(g), blue: Oklab.encode(b), alpha: alpha
    )
  }
}

extension Oklab {
  static func mix(_ from: Oklab, _ to: Oklab, _ t: Double) -> Oklab {
    Oklab(l: from.l + (to.l - from.l) * t, a: from.a + (to.a - from.a) * t, b: from.b + (to.b - from.b) * t)
  }
}

enum OklabGradient {
  static let steps = 4

  static func mix(_ from: NSColor, _ to: NSColor, _ t: CGFloat) -> NSColor {
    let t = min(1, max(0, t))
    let alpha = from.alphaComponent + (to.alphaComponent - from.alphaComponent) * t
    // A clear end takes the other's colour, so the fade does not pass through black.
    let start = from.alphaComponent == 0 ? to : from
    let end = to.alphaComponent == 0 ? from : to
    return Oklab.mix(Oklab(start), Oklab(end), Double(t)).color(fitting: true)
      .withAlphaComponent(alpha)
  }

  static func colors(_ colors: [NSColor], steps: Int = steps) -> [NSColor] {
    guard colors.count > 1, steps > 1 else { return colors }
    var out: [NSColor] = []
    for (from, to) in zip(colors, colors.dropFirst()) {
      for k in 0..<steps { out.append(mix(from, to, CGFloat(k) / CGFloat(steps))) }
    }
    out.append(colors[colors.count - 1])
    return out
  }

  static func locations(_ places: [CGFloat], steps: Int = steps) -> [CGFloat] {
    guard places.count > 1, steps > 1 else { return places }
    var out: [CGFloat] = []
    for (from, to) in zip(places, places.dropFirst()) {
      for k in 0..<steps { out.append(from + (to - from) * CGFloat(k) / CGFloat(steps)) }
    }
    out.append(places[places.count - 1])
    return out
  }

  static func cgColors(_ colors: [NSColor], steps: Int = steps) -> [CGColor] {
    Self.colors(colors, steps: steps).map(\.cgColor)
  }

  static func numbers(_ places: [CGFloat], steps: Int = steps) -> [NSNumber] {
    locations(places, steps: steps).map { NSNumber(value: Double($0)) }
  }
}
