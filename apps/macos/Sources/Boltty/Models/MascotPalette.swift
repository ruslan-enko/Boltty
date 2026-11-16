import AppKit

struct MascotPalette: Identifiable, Equatable, Hashable, Sendable {
  let id: String
  let displayName: String
  let stops: [OKLCH]
  let style: MascotGradientStyle
  let positions: [CGFloat]?

  init(
    id: String, displayName: String, stops: [OKLCH],
    style: MascotGradientStyle = .sunrise, positions: [CGFloat]? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.stops = stops
    self.style = style
    self.positions = positions
  }

  var colors: [NSColor] { stops.map(\.color) }

  var stopPlaces: [CGFloat] { positions ?? Self.stopPositions }

  static let stopPositions: [CGFloat] = [0, 0.34, 0.6, 0.7, 0.84, 1]

  var glowColors: [NSColor] {
    let stops = colors
    return [stops[0], stops[4], stops[2]]
  }

  var arrivalLight: [NSColor] {
    let stops = colors.map(Oklab.init)
    let hues = stops.map(\.hue)
    let centre = Self.circularMean(hues)
    let offsets = hues.map { Self.signedAngle(from: centre, to: $0) }
    guard let low = offsets.min(), let high = offsets.max(),
          high - low < Self.arrivalHueSpread, stops.count > 1
    else { return light(atLeast: Self.arrivalLightness) }
    let drift: Double = offsets.last! >= offsets.first! ? 1 : -1
    return stops.enumerated().map { index, stop in
      let place = Double(index) / Double(stops.count - 1) - 0.5
      return Oklab(
        hue: centre + drift * place * Self.arrivalHueSpread,
        chroma: max(stop.chroma, Self.arrivalMinimumChroma), l: max(stop.l, Self.arrivalLightness)
      ).color(fitting: true)
    }
  }

  static let arrivalHueSpread = 80.0
  private static let arrivalMinimumChroma = 0.09

  private static func circularMean(_ degrees: [Double]) -> Double {
    let x = degrees.reduce(0) { $0 + cos($1 * .pi / 180) }
    let y = degrees.reduce(0) { $0 + sin($1 * .pi / 180) }
    return atan2(y, x) * 180 / .pi
  }

  private static func signedAngle(from: Double, to: Double) -> Double {
    var delta = (to - from).truncatingRemainder(dividingBy: 360)
    if delta > 180 { delta -= 360 }
    if delta < -180 { delta += 360 }
    return delta
  }

  func light(atLeast lightness: Double) -> [NSColor] {
    colors.map { Self.lifted($0, to: lightness) }
  }

  static let arrivalLightness = 0.8

  static func mix(_ from: NSColor, _ to: NSColor, _ t: CGFloat) -> NSColor {
    let a = Oklab(from), b = Oklab(to), t = Double(min(1, max(0, t)))
    return Oklab(l: a.l + (b.l - a.l) * t, a: a.a + (b.a - a.a) * t, b: a.b + (b.b - a.b) * t)
      .color(fitting: true)
  }

  private static func lifted(_ color: NSColor, to lightness: Double) -> NSColor {
    var lab = Oklab(color)
    guard lab.l < lightness else { return color }
    lab.l = lightness
    return lab.color(fitting: true)
  }

  static let catalog: [MascotPalette] = [
    MascotPalette(id: "daybreak", displayName: "Daybreak",
                  stops: [
                    OKLCH(0.583, 0.183, 263.5), OKLCH(0.735, 0.115, 259.9), OKLCH(0.955, 0.006, 264.5),
                    OKLCH(0.932, 0.118, 96.7), OKLCH(0.849, 0.146, 80.1), OKLCH(0.715, 0.178, 28)
                  ]),
    MascotPalette(id: "citrus", displayName: "Citrus",
                  stops: [
                    OKLCH(0.886, 0.138, 88.3), OKLCH(0.899, 0.135, 90.9), OKLCH(0.911, 0.137, 94.3),
                    OKLCH(0.892, 0.19, 106.4), OKLCH(0.853, 0.197, 117.4), OKLCH(0.818, 0.199, 122.2)
                  ],
                  positions: [0, 0.3, 0.57, 0.67, 0.78, 1]),
    MascotPalette(id: "candy", displayName: "Candy",
                  stops: [
                    OKLCH(0.743, 0.169, 351.4), OKLCH(0.766, 0.157, 348.9), OKLCH(0.878, 0.079, 341.5),
                    OKLCH(0.915, 0.035, 320.1), OKLCH(0.838, 0.122, 197.7), OKLCH(0.784, 0.133, 198.5)
                  ],
                  positions: [0, 0.3, 0.5, 0.6, 0.72, 1]),
    MascotPalette(id: "ember", displayName: "Ember",
                  stops: [
                    OKLCH(0.674, 0.215, 18.8), OKLCH(0.663, 0.225, 20.6), OKLCH(0.704, 0.188, 27.1),
                    OKLCH(0.78, 0.141, 49.1), OKLCH(0.83, 0.129, 66.9), OKLCH(0.821, 0.124, 60.8)
                  ],
                  positions: [0, 0.32, 0.48, 0.66, 0.84, 1]),
    MascotPalette(id: "lagoon", displayName: "Mist",
                  stops: [
                    OKLCH(0.872, 0.067, 246.6), OKLCH(0.784, 0.112, 254.3), OKLCH(0.695, 0.158, 258.5),
                    OKLCH(0.659, 0.175, 259.3), OKLCH(0.696, 0.158, 257.6), OKLCH(0.769, 0.119, 255.2)
                  ],
                  positions: [0, 0.2, 0.42, 0.62, 0.82, 1]),
    MascotPalette(id: "slate", displayName: "Lilac",
                  stops: [
                    OKLCH(0.855, 0.034, 315.2), OKLCH(0.784, 0.053, 308.3), OKLCH(0.682, 0.08, 303.3),
                    OKLCH(0.576, 0.112, 301.5), OKLCH(0.499, 0.138, 300.9), OKLCH(0.446, 0.142, 302.2)
                  ],
                  positions: [0, 0.24, 0.46, 0.65, 0.83, 1]),
  ]

  private static let legacyCatalog: [MascotPalette] = [
    MascotPalette(id: "electric", displayName: "Electric",
                  stops: [
                    OKLCH(0.593, 0.23, 315.6), OKLCH(0.764, 0.137, 316.7), OKLCH(0.967, 0.022, 314.7),
                    OKLCH(0.889, 0.068, 54.5), OKLCH(0.786, 0.135, 47.6), OKLCH(0.695, 0.196, 29.1)
                  ]),
    MascotPalette(id: "dusk", displayName: "Dusk",
                  stops: [
                    OKLCH(0.603, 0.209, 28.1), OKLCH(0.74, 0.126, 26.5), OKLCH(0.968, 0.016, 32),
                    OKLCH(0.892, 0.071, 345.2), OKLCH(0.789, 0.154, 345.9), OKLCH(0.669, 0.226, 316.1)
                  ]),
    MascotPalette(id: "moss", displayName: "Moss",
                  stops: [
                    OKLCH(0.649, 0.136, 163.2), OKLCH(0.801, 0.107, 165.1), OKLCH(0.979, 0.017, 168.5),
                    OKLCH(0.909, 0.053, 355.7), OKLCH(0.786, 0.137, 358.4), OKLCH(0.679, 0.18, 6.5)
                  ]),
    MascotPalette(id: "orchid", displayName: "Orchid",
                  stops: [
                    OKLCH(0.609, 0.217, 341.3), OKLCH(0.758, 0.14, 338.1), OKLCH(0.964, 0.021, 337.7),
                    OKLCH(0.911, 0.053, 230.9), OKLCH(0.791, 0.117, 241.6), OKLCH(0.636, 0.178, 261.5)
                  ]),
    MascotPalette(id: "sand", displayName: "Sand",
                  stops: [
                    OKLCH(0.711, 0.145, 80.5), OKLCH(0.839, 0.119, 86.5), OKLCH(0.98, 0.022, 87.1),
                    OKLCH(0.882, 0.068, 0), OKLCH(0.765, 0.152, 0.3), OKLCH(0.645, 0.19, 357.2)
                  ]),
    MascotPalette(id: "abyss", displayName: "Abyss",
                  stops: [
                    OKLCH(0.658, 0.129, 229.4), OKLCH(0.788, 0.107, 223), OKLCH(0.973, 0.017, 225.2),
                    OKLCH(0.929, 0.088, 141.5), OKLCH(0.833, 0.155, 146.4), OKLCH(0.726, 0.144, 163.1)
                  ]),

    MascotPalette(id: "aurora", displayName: "Aurora",
                  stops: [
                    OKLCH(0.8, 0.151, 167.6), OKLCH(0.776, 0.122, 209.2), OKLCH(0.683, 0.155, 254.4),
                    OKLCH(0.653, 0.173, 286.3), OKLCH(0.684, 0.197, 313.7), OKLCH(0.737, 0.171, 344.1)
                  ],
                  style: .sweep(degrees: 35), positions: evenStops),
    MascotPalette(id: "sunset", displayName: "Sunset",
                  stops: [
                    OKLCH(0.891, 0.159, 93.2), OKLCH(0.786, 0.157, 62.6), OKLCH(0.715, 0.179, 29.1),
                    OKLCH(0.672, 0.208, 356.4), OKLCH(0.633, 0.214, 311.7), OKLCH(0.591, 0.205, 284.3)
                  ],
                  style: .sweep(degrees: 35), positions: evenStops),
    MascotPalette(id: "fjord", displayName: "Fjord",
                  stops: [
                    OKLCH(0.913, 0.177, 118.9), OKLCH(0.813, 0.184, 136.7), OKLCH(0.761, 0.158, 159.5),
                    OKLCH(0.749, 0.118, 198.4), OKLCH(0.675, 0.154, 248.4), OKLCH(0.593, 0.195, 272.4)
                  ],
                  style: .sweep(degrees: 35), positions: evenStops),
    MascotPalette(id: "cotton", displayName: "Cotton",
                  stops: [
                    OKLCH(0.809, 0.125, 353.4), OKLCH(0.785, 0.149, 310.7), OKLCH(0.779, 0.112, 272.9),
                    OKLCH(0.84, 0.092, 236.7), OKLCH(0.886, 0.103, 170.7), OKLCH(0.905, 0.131, 127.1)
                  ],
                  style: .sweep(degrees: -35), positions: evenStops),
    MascotPalette(id: "solar", displayName: "Solar",
                  stops: [
                    OKLCH(0.686, 0.205, 34), OKLCH(0.751, 0.162, 47.3), OKLCH(0.854, 0.137, 79.2),
                    OKLCH(0.924, 0.115, 93.9), OKLCH(0.956, 0.074, 95.9), OKLCH(0.79, 0.134, 48.9)
                  ],
                  style: .glow, positions: glowStops),
    MascotPalette(id: "frost", displayName: "Frost",
                  stops: [
                    OKLCH(0.739, 0.152, 238.7), OKLCH(0.813, 0.118, 229.6), OKLCH(0.912, 0.061, 221.5),
                    OKLCH(0.985, 0.022, 196.8), OKLCH(0.862, 0.077, 296.4), OKLCH(0.742, 0.142, 288.9)
                  ],
                  style: .glow, positions: glowStops),
    MascotPalette(id: "lime", displayName: "Lime",
                  stops: [
                    OKLCH(0.734, 0.208, 145), OKLCH(0.809, 0.189, 137.8), OKLCH(0.919, 0.164, 121.6),
                    OKLCH(0.958, 0.113, 102.9), OKLCH(0.91, 0.144, 95.1), OKLCH(0.826, 0.153, 75.1)
                  ],
                  style: .glow, positions: glowStops),
    MascotPalette(id: "rose", displayName: "Rosé",
                  stops: [
                    OKLCH(0.692, 0.22, 358.6), OKLCH(0.768, 0.156, 355.3), OKLCH(0.88, 0.074, 352.5),
                    OKLCH(0.969, 0.018, 351.1), OKLCH(0.902, 0.068, 64.6), OKLCH(0.822, 0.116, 54.7)
                  ],
                  style: .glow, positions: glowStops),
    MascotPalette(id: "ultraviolet", displayName: "Ultraviolet",
                  stops: [
                    OKLCH(0.592, 0.247, 293), OKLCH(0.693, 0.19, 300), OKLCH(0.852, 0.091, 304.8),
                    OKLCH(0.949, 0.034, 312.4), OKLCH(0.876, 0.088, 340.7), OKLCH(0.779, 0.158, 348.4)
                  ],
                  style: .glow, positions: glowStops),
    MascotPalette(id: "tide", displayName: "Tide",
                  stops: [
                    OKLCH(0.703, 0.124, 184.6), OKLCH(0.799, 0.118, 185.5), OKLCH(0.902, 0.073, 186.3),
                    OKLCH(0.986, 0.019, 180.3), OKLCH(0.865, 0.079, 234), OKLCH(0.651, 0.188, 258.2)
                  ],
                  style: .glow, positions: glowStops)
  ]

  private static let evenStops: [CGFloat] = [0, 0.2, 0.4, 0.6, 0.8, 1]
  private static let glowStops: [CGFloat] = [0, 0.3, 0.55, 0.72, 0.88, 1]

  static func palette(withID id: String) -> MascotPalette? {
    catalog.first { $0.id == id } ?? legacyCatalog.first { $0.id == id }
  }

  static var standard: MascotPalette {
    palette(withID: "daybreak") ?? catalog[0]
  }

  static var fallback: MascotPalette { standard }
}

extension MascotPalette {
  static func forConversation(_ id: UUID) -> MascotPalette {
    let pool = catalog.filter { $0.id != standard.id }
    guard !pool.isEmpty else { return standard }
    return pool[Int(fingerprint(id) % UInt32(pool.count))]
  }

  static func fingerprint(_ id: UUID) -> UInt32 {
    withUnsafeBytes(of: id.uuid) { bytes in
      bytes.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }
  }
}

enum MascotGradientStyle: Equatable, Hashable, Sendable {
  case sunrise
  case sweep(degrees: Double)
  case glow

  var shaderID: MascotGradientID {
    switch self {
    case .sunrise: MascotGradientSunrise
    case .sweep: MascotGradientSweep
    case .glow: MascotGradientGlow
    }
  }

  var turn: Double {
    if case let .sweep(degrees) = self { return degrees * .pi / 180 }
    return 0
  }
}
