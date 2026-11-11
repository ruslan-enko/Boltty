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
      ("wide-quiet", frame(intensity: 0.35)),
      ("wide-loud", frame(intensity: 1.0)),
      ("wide-processing", frame(intensity: 0.74, beam: 1, clock: 0.95)),
      ("completed-half", frame(intensity: 0.8, opacity: 0.5)),
    ]

    for (name, input) in states {
      let image = try XCTUnwrap(
        renderer.image(of: VoiceGlowRenderer.uniforms(for: input)), "\(name) did not render")
      try write(composite(image), to: directory.appendingPathComponent("glow-\(name).png"))
    }

    print("BOLTTY_GLOW_SHEET \(directory.path)")
  }

  private func composite(_ glow: CGImage) -> CGImage {
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
    return context.makeImage()!
  }

  private func write(_ image: CGImage, to url: URL) throws {
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
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
