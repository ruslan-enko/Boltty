import AppKit

struct MascotPalette: Identifiable, Equatable, Hashable, Sendable {
  let id: String
  let displayName: String
  let hexes: [String]
  let style: MascotGradientStyle
  let positions: [CGFloat]?

  init(
    id: String, displayName: String, hexes: [String],
    style: MascotGradientStyle = .sunrise, positions: [CGFloat]? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.hexes = hexes
    self.style = style
    self.positions = positions
  }

  var colors: [NSColor] { hexes.map(HexColor.nsColor) }

  var stopPlaces: [CGFloat] { positions ?? Self.stopPositions }

  static let stopPositions: [CGFloat] = [0, 0.34, 0.6, 0.7, 0.84, 1]

  var glowColors: [NSColor] {
    let stops = colors
    return [stops[0], stops[4], stops[2]]
  }

  var arrivalLight: [NSColor] {
    light(atLeast: Self.arrivalLightness)
  }

  func light(atLeast lightness: Double) -> [NSColor] {
    colors.map { Self.lifted($0, to: lightness) }
  }

  static let arrivalLightness = 0.8

  /// The gradient as ink for a meter or a chart: near-grey stops dropped (a
  /// face's pale middle vanishes on a white track), the rest kept within a
  /// lightness band that reads on the window — darker in Light, lighter in Dark.
  var meterInk: [NSColor] {
    let vivid = colors.filter { Oklab($0).chroma >= Self.meterMinimumChroma }
    let stops = vivid.count >= 2 ? vivid : colors
    return stops.map { stop in
      NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var lab = Oklab(stop)
        lab.l = isDark ? max(lab.l, Self.meterDarkFloor) : min(lab.l, Self.meterLightCeiling)
        return lab.color(fitting: true)
      }
    }
  }

  private static let meterMinimumChroma = 0.05
  private static let meterLightCeiling = 0.72
  private static let meterDarkFloor = 0.62

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

  private struct Oklab {
    var l, a, b: Double

    init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }

    var chroma: Double { (a * a + b * b).squareRoot() }

    init(_ color: NSColor) {
      let srgb = color.usingColorSpace(.sRGB) ?? color
      func linear(_ c: CGFloat) -> Double {
        let v = Double(c)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      let r = linear(srgb.redComponent), g = linear(srgb.greenComponent), b = linear(srgb.blueComponent)
      let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
      let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
      let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
      self.l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
      self.a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
      self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    private func linearRGB(chroma scale: Double) -> (Double, Double, Double) {
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
      func inside(_ c: (Double, Double, Double)) -> Bool {
        [c.0, c.1, c.2].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 }
      }
      var scale = 1.0
      if fitting, !inside(linearRGB(chroma: 1)) {
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
          let mid = (low + high) / 2
          if inside(linearRGB(chroma: mid)) { low = mid } else { high = mid }
        }
        scale = low
      }
      func encode(_ v: Double) -> Int {
        let c = min(1, max(0, v))
        return Int(((c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255).rounded())
      }
      let (r, g, b) = linearRGB(chroma: scale)
      return HexColor.nsColor(String(format: "#%02X%02X%02X", encode(r), encode(g), encode(b)))
    }
  }

  static let catalog: [MascotPalette] = [
    MascotPalette(id: "daybreak", displayName: "Daybreak",
                  hexes: ["#3f73e6", "#7eaaf2", "#eef0f4", "#ffe98a", "#ffc24f", "#ff6f61"]),
    MascotPalette(id: "citrus", displayName: "Citrus",
                  hexes: ["#ffd464", "#ffda6c", "#ffe06e", "#ece208", "#c6de04", "#aed600"],
                  positions: [0, 0.3, 0.57, 0.67, 0.78, 1]),
    MascotPalette(id: "candy", displayName: "Candy",
                  hexes: ["#f97ab8", "#fb86c3", "#fcc3e6", "#eedcf2", "#4fe2e6", "#06d2d8"],
                  positions: [0, 0.3, 0.5, 0.6, 0.72, 1]),
    MascotPalette(id: "ember", displayName: "Ember",
                  hexes: ["#ff4b60", "#ff4054", "#ff675c", "#ff9a61", "#ffb666", "#ffb16d"],
                  positions: [0, 0.32, 0.48, 0.66, 0.84, 1]),
    MascotPalette(id: "lagoon", displayName: "Mist",
                  hexes: ["#b2daff", "#86bcff", "#5c9cfd", "#4b8ffb", "#5a9dfd", "#7fb7ff"],
                  positions: [0, 0.2, 0.42, 0.62, 0.82, 1]),
    MascotPalette(id: "slate", displayName: "Lilac",
                  hexes: ["#d8c9df", "#c2b0d3", "#a38dc2", "#8568b0", "#714ca4", "#643b94"],
                  positions: [0, 0.24, 0.46, 0.65, 0.83, 1]),
  ]

  private static let legacyCatalog: [MascotPalette] = [
    MascotPalette(id: "electric", displayName: "Electric",
                  hexes: ["#b040d8", "#d596ec", "#faf0ff", "#ffcfb0", "#ff9d6a", "#ff6150"]),
    MascotPalette(id: "dusk", displayName: "Dusk",
                  hexes: ["#e3372f", "#f08a80", "#fff1ee", "#ffc9e6", "#ff8fcf", "#c95cf0"]),
    MascotPalette(id: "moss", displayName: "Moss",
                  hexes: ["#16a877", "#76d4ad", "#eefcf6", "#ffd3e2", "#ff92b8", "#ef5f86"]),
    MascotPalette(id: "orchid", displayName: "Orchid",
                  hexes: ["#d23aa8", "#e98ccf", "#fdeef8", "#bfe9ff", "#72c4ff", "#4a86f5"]),
    MascotPalette(id: "sand", displayName: "Sand",
                  hexes: ["#d0960a", "#ecc56a", "#fff8e8", "#ffc6d6", "#ff86ae", "#e2508f"]),
    MascotPalette(id: "abyss", displayName: "Abyss",
                  hexes: ["#0a9fd0", "#62c9ec", "#ebf9ff", "#c7f7c0", "#7fe38a", "#2fc28c"]),

    MascotPalette(id: "aurora", displayName: "Aurora",
                  hexes: ["#34dcaa", "#36cbe0", "#4f9bf6", "#8a7bf3", "#c46ded", "#f279c4"],
                  style: .sweep(degrees: 35), positions: evenStops),
    MascotPalette(id: "sunset", displayName: "Sunset",
                  hexes: ["#ffd84a", "#ffa03c", "#ff6f5e", "#f24f99", "#b458e6", "#7562f0"],
                  style: .sweep(degrees: 35), positions: evenStops),
    MascotPalette(id: "fjord", displayName: "Fjord",
                  hexes: ["#d6f25a", "#86dc5c", "#37cf8d", "#2ec4c9", "#3a9cf0", "#5a6ef0"],
                  style: .sweep(degrees: 35), positions: evenStops),
    MascotPalette(id: "cotton", displayName: "Cotton",
                  hexes: ["#ff9ec7", "#d79cff", "#9fb2ff", "#8fd4ff", "#8ff0d0", "#c8f08f"],
                  style: .sweep(degrees: -35), positions: evenStops),
    MascotPalette(id: "solar", displayName: "Solar",
                  hexes: ["#ff5c38", "#ff8a4a", "#ffc45c", "#ffe58a", "#fff1b8", "#ff9f6a"],
                  style: .glow, positions: glowStops),
    MascotPalette(id: "frost", displayName: "Frost",
                  hexes: ["#2fb6ff", "#66d0ff", "#b6ecff", "#eaffff", "#d6c8ff", "#a99bff"],
                  style: .glow, positions: glowStops),
    MascotPalette(id: "lime", displayName: "Lime",
                  hexes: ["#36c94a", "#7fdc5a", "#d3f570", "#fff59a", "#ffe066", "#ffb640"],
                  style: .glow, positions: glowStops),
    MascotPalette(id: "rose", displayName: "Rosé",
                  hexes: ["#ff4f9a", "#ff86b8", "#ffc4dc", "#fff0f6", "#ffd6b0", "#ffb07a"],
                  style: .glow, positions: glowStops),
    MascotPalette(id: "ultraviolet", displayName: "Ultraviolet",
                  hexes: ["#8a4dff", "#b07bff", "#dcc0ff", "#f6e8ff", "#ffc0e8", "#ff8ac8"],
                  style: .glow, positions: glowStops),
    MascotPalette(id: "tide", displayName: "Tide",
                  hexes: ["#00b8a9", "#4fd6c8", "#a6efe6", "#eefffb", "#9fdcff", "#3d8cff"],
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
