import AppKit
import QuartzCore

@MainActor
enum ScrollEdgeBlur {
  struct Stop: Equatable {
    var y: CGFloat
    var strength: CGFloat
  }

  static let smoothstep: [(t: CGFloat, s: CGFloat)] = [
    (0, 0), (0.25, 0.156), (0.5, 0.5), (0.75, 0.844), (1, 1),
  ]

  static func ramp(from: CGFloat, to: CGFloat, strength a: CGFloat, _ b: CGFloat) -> [Stop] {
    smoothstep.map { Stop(y: from + (to - from) * $0.t, strength: a + (b - a) * $0.s) }
  }

  static func apply(to layer: CALayer?, stops: [Stop], height: CGFloat, radius: CGFloat) {
    guard let layer else { return }
    let wanted = !stops.isEmpty && height > 0 && radius > 0
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    guard wanted, let filter = makeFilter() else {
      if layer.value(forKey: stateKey) != nil {
        layer.filters = nil
        layer.setValue(nil, forKey: stateKey)
      }
      return
    }
    let flipped = layer.isGeometryFlipped
    let key = "\(height)|\(radius)|\(flipped)|" + stops.map { "\($0.y):\($0.strength)" }.joined(separator: ",")
    guard (layer.value(forKey: stateKey) as? String) != key else { return }
    guard let mask = maskImage(stops: stops, height: height, topFirst: flipped) else { return }
    filter.setValue(radius, forKey: "inputRadius")
    filter.setValue(mask, forKey: "inputMaskImage")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.filters = [filter]
    CATransaction.commit()
    layer.setValue(key, forKey: stateKey)
  }

  static var isAvailable: Bool { makeFilter() != nil }

  private static let stateKey = "boltty.scrollEdgeBlur"

  private static func makeFilter() -> NSObject? {
    guard let type = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
    let make = NSSelectorFromString("filterWithType:")
    guard type.responds(to: make),
      let filter = type.perform(make, with: "variableBlur")?.takeUnretainedValue() as? NSObject
    else { return nil }
    // Never inputNormalizeEdges: it writes every pixel opaque.
    filter.setValue(false, forKey: "inputNormalizeEdges")
    return filter
  }

  private static func maskImage(stops: [Stop], height: CGFloat, topFirst: Bool) -> CGImage? {
    let rows = max(1, Int(ceil(height)))
    var bytes = [UInt8](repeating: 0, count: rows * 4)
    let sorted = stops.sorted { $0.y < $1.y }
    for row in 0..<rows {
      let y = CGFloat(row) + 0.5
      let s = strength(at: y, in: sorted)
      bytes[(topFirst ? row : rows - 1 - row) * 4 + 3] = UInt8(max(0, min(255, (s * 255).rounded())))
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: 1, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )
  }

  private static func strength(at y: CGFloat, in stops: [Stop]) -> CGFloat {
    guard let first = stops.first, let last = stops.last else { return 0 }
    if y <= first.y { return first.strength }
    if y >= last.y { return last.strength }
    for (a, b) in zip(stops, stops.dropFirst()) where y >= a.y && y <= b.y {
      let span = b.y - a.y
      return span > 0 ? a.strength + (b.strength - a.strength) * (y - a.y) / span : b.strength
    }
    return last.strength
  }
}
