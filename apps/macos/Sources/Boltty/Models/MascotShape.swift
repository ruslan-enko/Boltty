import CoreGraphics

enum MascotShape: String, CaseIterable, Codable, Identifiable, Sendable {
  case bloom
  case capsule
  case daisy
  case hex
  case orb
  case triangle

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .bloom: "Blossom"
    case .capsule: "Hotdog"
    case .daisy: "Spotty"
    case .hex: "Boltty"
    case .orb: "Pampuh"
    case .triangle: "Onigiri"
    }
  }

  var shaderID: MascotShapeID {
    switch self {
    case .bloom: MascotShapeBloom
    case .capsule: MascotShapeCapsule
    case .daisy: MascotShapeDaisy
    case .hex: MascotShapeHex
    case .orb: MascotShapeOrb
    case .triangle: MascotShapeTriangle
    }
  }

  struct Build: Equatable, Sendable {
    var thickness: Double
    var profile: Double
    var eyeOffset: CGPoint
    var eyeScale: Double
    var top: Double
    var bottom: Double
    var halfWidth: Double
    var step: Double
  }

  var build: Build {
    switch self {
    case .bloom:
      Build(thickness: 6.5, profile: 0.45,
            eyeOffset: CGPoint(x: -0.225, y: -1.544), eyeScale: 1,
            top: 15.453, bottom: -15.490, halfWidth: 16.101, step: 0.6)
    case .capsule:
      Build(thickness: 7.5, profile: 0.45,
            eyeOffset: CGPoint(x: 0.569, y: -0.006), eyeScale: 1,
            top: 9.865, bottom: -9.905, halfWidth: 16.107, step: 0.75)
    case .daisy:
      Build(thickness: 7.5, profile: 0.45,
            eyeOffset: CGPoint(x: 0.754, y: -1.774), eyeScale: 0.9,
            top: 16.080, bottom: -16.033, halfWidth: 15.781, step: 0.55)
    case .hex:
      Build(thickness: 7.5, profile: 0.45,
            eyeOffset: CGPoint(x: 0.000, y: -0.400), eyeScale: 1,
            top: 14.235, bottom: -14.259, halfWidth: 16.103, step: 0.75)
    case .orb:
      Build(thickness: 7.5, profile: 0.45,
            eyeOffset: CGPoint(x: 0.000, y: -0.666), eyeScale: 1,
            top: 14.714, bottom: -14.753, halfWidth: 15.089, step: 0.75)
    case .triangle:
      Build(thickness: 7.5, profile: 0.45,
            eyeOffset: CGPoint(x: 0.965, y: -2.111), eyeScale: 1,
            top: 13.910, bottom: -13.961, halfWidth: 16.084, step: 0.75)
    }
  }
}
