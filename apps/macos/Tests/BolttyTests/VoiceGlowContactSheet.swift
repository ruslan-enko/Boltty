import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Boltty

@MainActor
final class VoiceGlowContactSheet: XCTestCase {
  private let size = CGSize(width: 520, height: 74.5)

  func testRenderTheStates() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let renderer = try XCTUnwrap(VoiceGlowRenderer(pixelFormat: .bgra8Unorm))
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let states: [(String, VoiceGlowRenderer.Frame)] = [
      ("orb-idle", orb(intensity: AgentPaletteMetrics.voiceGlowIdle)),
      ("orb-quiet", orb(intensity: 0.35, clock: 2)),
      ("orb-loud", orb(intensity: 1.0, clock: 5)),
      ("orb-processing", orb(intensity: 0.74, beam: 1, clock: 0.6)),
      ("capsule-words", orb(intensity: 0.6, clock: 3, width: 420)),
      ("capsule-long", orb(intensity: 1.0, clock: 7, width: AgentPaletteMetrics.listeningMaxWidth)),
      ("wide-quiet", frame(intensity: 0.35)),
      ("wide-loud", frame(intensity: 1.0)),
      ("wide-processing", frame(intensity: 0.74, beam: 1, clock: 0.95)),
      ("completed-half", frame(intensity: 0.8, opacity: 0.5)),
    ]

    // The light under the glass, and the orb's surface laid over it as the
    // panel lays it over the glass. No glass here: it does not draw offscreen,
    // and it frosts the under layer — judge the orb in the running app.
    for (name, input) in states {
      var under = VoiceGlowRenderer.uniforms(for: input)
      under.layer = 0
      var over = under
      over.layer = 1
      let image = try XCTUnwrap(renderer.image(of: under), "\(name) did not render")
      let sheen = over.orb > 0 ? renderer.image(of: over) : nil
      try write(composite(image, sheen), to: directory.appendingPathComponent("glow-\(name).png"))
    }

    print("BOLTTY_GLOW_SHEET \(directory.path)")
  }

  private func composite(_ glow: CGImage, _ sheen: CGImage?) -> CGImage {
    let width = glow.width
    let height = glow.height
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    )!
    context.setFillColor(NSColor(srgbRed: 0.06, green: 0.06, blue: 0.075, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(glow, in: CGRect(x: 0, y: 0, width: width, height: height))
    if let sheen { context.draw(sheen, in: CGRect(x: 0, y: 0, width: width, height: height)) }
    return context.makeImage()!
  }

  private func write(_ image: CGImage, to url: URL) throws {
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }

  /// The orb, or the capsule it grows into round the words when `width` is
  /// wider than it is tall.
  private func orb(
    intensity: CGFloat,
    beam: CGFloat = 0,
    clock: CGFloat = 0,
    width: CGFloat = AgentPaletteMetrics.listeningOrbDiameter
  ) -> VoiceGlowRenderer.Frame {
    var input = frame(intensity: intensity, beam: beam, clock: clock)
    input.flow = clock
    input.orb = 1
    let side = AgentPaletteMetrics.listeningOrbDiameter
    input.size = CGSize(width: width, height: side)
    input.cornerRadius = side / 2
    input.cornerIsContinuous = false
    return input
  }

  private func frame(
    intensity: CGFloat,
    beam: CGFloat = 0,
    clock: CGFloat = 0,
    opacity: CGFloat = 1
  ) -> VoiceGlowRenderer.Frame {
    let colors = VoiceEdgeGlowLayout.rayColors(from: .standard)
    return VoiceGlowRenderer.Frame(
      size: size,
      pixelSize: 0.5,
      cornerRadius: 37.25,
      cornerIsContinuous: true,
      intensity: intensity,
      beam: beam,
      clock: clock,
      opacity: opacity,
      isLightAppearance: false,
      reduceMotion: false,
      colors: colors
    )
  }
}
