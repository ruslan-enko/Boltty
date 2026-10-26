import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import Boltty

@MainActor
final class PaletteEffectsTests: XCTestCase {
  private let tile = CGSize(width: 36, height: 36)

  private func reveal(_ progress: CGFloat) -> PaletteRevealUniforms {
    PaletteEffects.revealUniforms(
      progress: progress, size: tile, imageAspect: 1, pixelSize: 0.5,
      cornerRadius: AgentPaletteMetrics.previewFileIconTileCornerRadius, cornerIsContinuous: true)
  }

  func testTheRevealResolvesToThePictureAsItIs() {
    let start = reveal(0)
    let end = reveal(1)
    XCTAssertEqual(CGFloat(start.blur), 36 * AgentPaletteMetrics.revealBlurFraction, accuracy: 0.01)
    XCTAssertGreaterThan(start.aberration, 0)
    XCTAssertGreaterThan(start.zoom, 1)
    XCTAssertEqual(start.opacity, 0)
    XCTAssertEqual(end.blur, 0)
    XCTAssertEqual(end.aberration, 0)
    XCTAssertEqual(end.zoom, 1)
    XCTAssertEqual(end.opacity, 1)
    let steps = stride(from: 0.0, through: 1.0, by: 0.1).map { reveal(CGFloat($0)) }
    for (a, b) in zip(steps, steps.dropFirst()) {
      XCTAssertGreaterThanOrEqual(a.blur, b.blur, "the blur only ever clears")
      XCTAssertLessThanOrEqual(a.opacity, b.opacity)
    }
  }

  func testTheWhipsTailIsBoundedByThePicture() {
    let frame = CGRect(x: 40, y: 40, width: 60, height: 26)
    func lag(_ speed: CGFloat) -> CGFloat {
      CGFloat(PaletteEffects.whipUniforms(
        size: CGSize(width: 200, height: 200), frame: frame,
        velocity: CGVector(dx: 0, dy: speed), pixelSize: 0.5, opacity: 1).lag)
    }
    XCTAssertEqual(lag(0), 0)
    XCTAssertLessThan(lag(200), lag(1_000))
    XCTAssertLessThanOrEqual(lag(100_000), 26 * AgentPaletteMetrics.whipMaxLagHeights + 0.01)
  }

  func testTheWhipFliesOnMotionsCurve() throws {
    let curve = TimingCurve(Motion.emphasizedCurve)
    XCTAssertEqual(curve.value(at: 0), 0, accuracy: 0.001)
    XCTAssertEqual(curve.value(at: 1), 1, accuracy: 0.001)
    XCTAssertGreaterThan(curve.value(at: 0.25), 0.6, "fast out of the gate")
    var last: CGFloat = 0
    for step in 1...20 {
      let value = curve.value(at: CGFloat(step) / 20)
      XCTAssertGreaterThanOrEqual(value, last - 0.0001)
      last = value
    }

    let picture = try XCTUnwrap(Self.halves(width: 8, height: 8))
    let from = CGRect(x: 10, y: 10, width: 60, height: 26)
    let to = CGRect(x: 30, y: 300, width: 300, height: 52)
    guard let whip = PaletteWhipView.make(image: picture, from: from, to: to, duration: 0.45) else {
      throw XCTSkip("no Metal device")
    }
    XCTAssertEqual(whip.flight(at: 0).frame, from)
    XCTAssertEqual(whip.flight(at: 1).frame.minY, to.minY, accuracy: 0.01)
    XCTAssertGreaterThan(whip.flight(at: 0.05).velocity.dy, whip.flight(at: 0.8).velocity.dy * 5)
  }

  func testAnAppKitPictureLoads() throws {
    try XCTSkipIf(PaletteEffects.shared == nil, "no Metal device")
    let picture = NSImage(size: NSSize(width: 64, height: 26), flipped: false) { rect in
      NSColor.systemGreen.setFill()
      rect.fill()
      return true
    }
    let image = try XCTUnwrap(picture.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertNotNil(PaletteWhipView.make(image: image, from: .zero, to: .zero, duration: 1))
  }

  // MARK: - Pixels

  static func halves(width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    return context.makeImage()
  }

  static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
    let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    let data = context.data!.assumingMemoryBound(to: UInt8.self)
    return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255, Double(data[3]) / 255)
  }

  func testTheRevealDrawsThePictureWholeAndInItsCornerAtTheEnd() throws {
    guard let effects = PaletteEffects.shared else { throw XCTSkip("no Metal device") }
    let source = try XCTUnwrap(Self.halves(width: 64, height: 64))
    let texture = try XCTUnwrap(effects.texture(for: source))

    let end = try XCTUnwrap(effects.image(of: reveal(1), texture: texture, scale: 2))
    let left = Self.pixel(end, 18, 36)
    let right = Self.pixel(end, 54, 36)
    XCTAssertGreaterThan(left.r, 0.95)
    XCTAssertLessThan(left.b, 0.05)
    XCTAssertGreaterThan(right.b, 0.95)
    XCTAssertLessThan(Self.pixel(end, 0, 0).a, 0.05, "the tile's corner is cut by the shader")

    let early = try XCTUnwrap(effects.image(of: reveal(0.3), texture: texture, scale: 2))
    let seam = Self.pixel(early, 36, 36)
    XCTAssertGreaterThan(seam.r, 0.1, "the seam is still soft")
    XCTAssertGreaterThan(seam.b, 0.1)
  }

  func testTheWhipBendsBehindAMovingPictureAndNowhereElse() throws {
    guard let effects = PaletteEffects.shared else { throw XCTSkip("no Metal device") }
    let texture = try XCTUnwrap(effects.texture(for: try XCTUnwrap(Self.halves(width: 16, height: 8))))
    let size = CGSize(width: 120, height: 120)
    let frame = CGRect(x: 30, y: 60, width: 60, height: 26)
    func draw(_ velocity: CGVector) throws -> CGImage {
      try XCTUnwrap(effects.image(of: PaletteEffects.whipUniforms(
        size: size, frame: frame, velocity: velocity, pixelSize: 0.5, opacity: 1),
        texture: texture, scale: 1))
    }
    func alpha(_ image: CGImage, x: CGFloat, y: CGFloat) -> Double {
      Self.pixel(image, Int(x), image.height - 1 - Int(y)).a
    }

    let still = try draw(.zero)
    XCTAssertGreaterThan(alpha(still, x: frame.midX, y: frame.midY), 0.95)
    XCTAssertLessThan(alpha(still, x: frame.midX, y: frame.minY - 10), 0.05, "no tail at rest")

    let rising = try draw(CGVector(dx: 0, dy: 2_000))
    XCTAssertGreaterThan(alpha(rising, x: frame.midX, y: frame.minY - 10), 0.5,
                         "the tail hangs below a picture flying up")
    XCTAssertLessThan(alpha(rising, x: frame.midX, y: frame.maxY + 4), 0.05,
                      "the leading edge stays where the curve puts it")
  }

  func testTheSelectionGlowLightsItsBorderInwardInTheMascotsColours() throws {
    guard let effects = PaletteEffects.shared else { throw XCTSkip("no Metal device") }
    let size = CGSize(width: 260, height: 200)
    let region = CGRect(x: 30, y: 30, width: 200, height: 140)
    let colors = PaletteEffects.glowColors([.systemBlue, .systemOrange])
    let image = try XCTUnwrap(effects.image(of: PaletteEffects.selectionGlowUniforms(
      size: size, region: region, pixelSize: 1, clock: 0, colors: colors), scale: 1))
    func pixel(_ x: CGFloat, _ y: CGFloat) -> (r: Double, g: Double, b: Double, a: Double) {
      Self.pixel(image, Int(x), image.height - 1 - Int(y))
    }

    XCTAssertGreaterThan(pixel(region.midX, region.maxY).a, 0.9, "the line")
    XCTAssertGreaterThan(pixel(region.midX, region.maxY - 8).a, 0.2, "its light, inside")
    XCTAssertGreaterThan(pixel(region.midX, region.maxY - 8).a, pixel(region.midX, region.maxY - 24).a,
                         "fading away from the line")
    XCTAssertLessThan(pixel(region.midX, region.midY).a, 0.02, "nothing in the middle")
    XCTAssertGreaterThan(pixel(region.midX, region.maxY + 4).a, 0.02, "a halo outside")
    XCTAssertLessThan(pixel(region.midX, region.maxY + 20).a, 0.02, "and nothing past it")

    let top = pixel(region.midX, region.maxY)
    let foot = pixel(region.midX, region.minY)
    XCTAssertGreaterThan(top.b, top.r, "blue along the top")
    XCTAssertGreaterThan(foot.r, foot.b, "orange along the foot")
  }

  func testTheSelectionGlowsEdgesAddWithNoSeamAtTheCorners() throws {
    guard let effects = PaletteEffects.shared else { throw XCTSkip("no Metal device") }
    let size = CGSize(width: 260, height: 200)
    let region = CGRect(x: 30, y: 30, width: 200, height: 140)
    let colors = PaletteEffects.glowColors([.white])
    let image = try XCTUnwrap(effects.image(of: PaletteEffects.selectionGlowUniforms(
      size: size, region: region, pixelSize: 1, clock: 0, colors: colors), scale: 1))
    func alpha(_ x: CGFloat, _ y: CGFloat) -> Double {
      Self.pixel(image, Int(x), image.height - 1 - Int(y)).a
    }
    let inset: CGFloat = 14

    let corner = alpha(region.minX + inset, region.maxY - inset)
    let side = alpha(region.midX, region.maxY - inset)
    XCTAssertGreaterThan(side, 0.02, "the light reaches this far in")
    XCTAssertGreaterThan(corner, side + 0.02, "two edges' light adds near the corner")
  }

  func testTheSelectionGlowsColoursMoveWithTheClock() throws {
    guard let effects = PaletteEffects.shared else { throw XCTSkip("no Metal device") }
    let size = CGSize(width: 260, height: 200)
    let region = CGRect(x: 30, y: 30, width: 200, height: 140)
    let colors = PaletteEffects.glowColors([.systemBlue, .systemYellow, .systemPink])
    func side(at clock: Double) throws -> (r: Double, g: Double, b: Double, a: Double) {
      let image = try XCTUnwrap(effects.image(of: PaletteEffects.selectionGlowUniforms(
        size: size, region: region, pixelSize: 1, clock: clock, colors: colors), scale: 1))
      return Self.pixel(image, Int(region.minX), image.height - 1 - Int(region.midY))
    }

    let now = try side(at: 0)
    let later = try side(at: 2)
    let change = abs(now.r - later.r) + abs(now.g - later.g) + abs(now.b - later.b)
    XCTAssertGreaterThan(change, 0.08, "the colour at one point of the line moves")
  }

}

@MainActor
final class PaletteEffectsContactSheet: XCTestCase {
  func testRenderTheEffects() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    guard let effects = PaletteEffects.shared else { throw XCTSkip("no Metal device") }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let icon = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("AppIcon.icon/Assets/Icon.png")
    let source = try XCTUnwrap(
      NSImage(contentsOf: icon)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let picture = try XCTUnwrap(effects.texture(for: source))
    let tile = CGSize(width: 108, height: 108)
    let curve = TimingCurve(Motion.emphasizedCurve)
    let reveal = try [0, 0.05, 0.1, 0.2, 0.35, 0.6, 1].map { time -> CGImage in
      try XCTUnwrap(effects.image(of: PaletteEffects.revealUniforms(
        progress: curve.value(at: time), size: tile,
        imageAspect: CGFloat(source.width) / CGFloat(source.height), pixelSize: 0.5,
        cornerRadius: AgentPaletteMetrics.previewFileIconTileCornerRadius * 3,
        cornerIsContinuous: true), texture: picture))
    }
    try write(strip(reveal), to: directory.appendingPathComponent("effects-reveal.png"))

    let chip = try XCTUnwrap(Self.chip())
    let chipTexture = try XCTUnwrap(effects.texture(for: chip))
    let from = CGRect(x: 60, y: 30, width: 70, height: 26)
    let to = CGRect(x: 40, y: 420, width: 300, height: 52)
    let whip = try XCTUnwrap(PaletteWhipView.make(image: chip, from: from, to: to, duration: 0.45))
    let flight = try [0, 0.03, 0.06, 0.1, 0.15, 0.25, 0.35].map { time -> CGImage in
      let (frame, velocity) = whip.flight(at: time)
      return try XCTUnwrap(effects.image(of: PaletteEffects.whipUniforms(
        size: CGSize(width: 380, height: 500), frame: frame, velocity: velocity,
        pixelSize: 0.5, opacity: 1 - min(1, time / AgentPaletteMetrics.whipFadeOutAt)),
        texture: chipTexture))
    }
    try write(strip(flight), to: directory.appendingPathComponent("effects-whip.png"))

    for id in ["citrus", "ember", "slate"] {
      let palette = try XCTUnwrap(MascotPalette.palette(withID: id))
        .light(atLeast: AgentPaletteMetrics.screenSelectionLightness)
      for dark in [false, true] {
        let frames = try [0.0, 1.5, 3.0, 4.5].map { clock in
          try Self.selectionFrame(effects, palette: palette, clock: clock, dark: dark)
        }
        try write(strip(frames), to: directory.appendingPathComponent(
          "effects-selection-\(id)\(dark ? "-dark" : "").png"))
      }
    }

    print("BOLTTY_EFFECTS_SHEET \(directory.path)")
  }

  private static func selectionFrame(
    _ effects: PaletteEffects, palette: [NSColor], clock: Double, dark: Bool
  ) throws -> CGImage {
    let size = CGSize(width: 420, height: 300)
    let region = CGRect(x: 60, y: 60, width: 300, height: 180)
    let scale: CGFloat = 2
    let context = try XCTUnwrap(CGContext(
      data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(dark
      ? CGColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 1)
      : CGColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(dark
      ? CGColor(srgbRed: 0.55, green: 0.56, blue: 0.6, alpha: 1)
      : CGColor(srgbRed: 0.35, green: 0.36, blue: 0.4, alpha: 1))
    for row in 0..<12 {
      context.fill(CGRect(x: 30, y: 30 + CGFloat(row) * 20, width: CGFloat(140 + (row * 37) % 200), height: 6))
    }
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.45, blue: 0.85, alpha: 1))
    context.fill(CGRect(x: 250, y: 150, width: 130, height: 110))
    let dim = CGMutablePath()
    dim.addRect(CGRect(origin: .zero, size: size))
    dim.addPath(CGPath(
      roundedRect: region, cornerWidth: AgentPaletteMetrics.screenSelectionCornerRadius,
      cornerHeight: AgentPaletteMetrics.screenSelectionCornerRadius, transform: nil))
    context.addPath(dim)
    context.setFillColor(CGColor(gray: 0, alpha: AgentPaletteMetrics.screenSelectionDim))
    context.fillPath(using: .evenOdd)
    let glow = try XCTUnwrap(effects.image(of: PaletteEffects.selectionGlowUniforms(
      size: size, region: region, pixelSize: 1 / scale, clock: clock,
      colors: PaletteEffects.glowColors(palette)), scale: scale))
    context.draw(glow, in: CGRect(origin: .zero, size: size))
    return try XCTUnwrap(context.makeImage())
  }

  private static func chip() -> CGImage? {
    let size = CGSize(width: 140, height: 52)
    guard let context = CGContext(
      data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let colour = PromptAttachmentKind.image.chipColor
    context.setFillColor(colour.withAlphaComponent(0.2).cgColor)
    context.addPath(CGPath(
      roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 26, cornerHeight: 26,
      transform: nil))
    context.fillPath()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let label = NSAttributedString(string: "image1", attributes: [
      .font: roundedAppFont(size: 26), .foregroundColor: colour,
    ])
    let bounds = label.size()
    label.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
  }

  private func strip(_ frames: [CGImage]) -> CGImage {
    let gap = 12
    let width = frames.reduce(gap) { $0 + $1.width + gap }
    let height = (frames.map(\.height).max() ?? 1) + gap * 2
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0.06, green: 0.06, blue: 0.075, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var x = gap
    for frame in frames {
      context.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
      context.stroke(CGRect(x: x, y: gap, width: frame.width, height: frame.height))
      context.draw(frame, in: CGRect(x: x, y: gap, width: frame.width, height: frame.height))
      x += frame.width + gap
    }
    return context.makeImage()!
  }

  private func write(_ image: CGImage, to url: URL) throws {
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }
}
