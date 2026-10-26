import AppKit
import XCTest
import simd
@testable import Boltty

@MainActor
final class MascotRendererTests: XCTestCase {
  private func stillFace(
    _ palette: MascotPalette = .standard, size: CGFloat = 64, shape: MascotShape = .hex
  ) -> MascotNSView {
    let view = MascotNSView(
      conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
      palette: palette,
      shape: shape
    )
    view.frame = CGRect(x: 0, y: 0, width: size, height: size)
    view.reduceMotion = true
    view.layoutSubtreeIfNeeded()
    return view
  }

  private func image(_ frame: MascotRenderer.Frame) throws -> Pixels {
    let renderer = try XCTUnwrap(MascotRenderer.shared)
    var boxed = frame
    boxed.overscan = 0
    return try Pixels(XCTUnwrap(renderer.image(of: MascotRenderer.uniforms(for: boxed), scale: 2)))
  }

  func testThereIsAGPUToDrawWith() {
    XCTAssertNotNil(MascotRenderer.shared, "no pipeline — every face in the app is a blank box")
  }

  func testTheBodyFillsTheMiddleAndLeavesTheCornersClear() throws {
    let pixels = try Pixels(XCTUnwrap(stillFace().snapshot()))
    XCTAssertEqual(pixels.alpha(x: 64, y: 100), 1, accuracy: 0.01, "solid below the eyes")
    XCTAssertEqual(pixels.alpha(x: 2, y: 2), 0, "nothing in the corner")
    XCTAssertEqual(pixels.alpha(x: 125, y: 125), 0)
  }

  func testDaybreakIsBlueAtTheTopAndWarmAtTheBottom() throws {
    let pixels = try Pixels(XCTUnwrap(stillFace().snapshot()))
    let top = pixels.color(x: 64, y: 26)
    let bottom = pixels.color(x: 64, y: 110)
    XCTAssertGreaterThan(top.z, top.x + 0.2, "blue at the top: \(top)")
    XCTAssertGreaterThan(bottom.x, bottom.z + 0.2, "warm at the bottom: \(bottom)")
  }

  func testTheEyesAreBlack() throws {
    let face = stillFace()
    let frame = try XCTUnwrap(face.lastFrame)
    let pixels = try Pixels(XCTUnwrap(face.snapshot()))
    let eye = frame.eyes[0].centre
    let pointsPerUnit = 64 / MascotSpec.designBox * MascotRenderer.fill
    let x = (32 + eye.x * pointsPerUnit) * 2
    let y = (32 - eye.y * pointsPerUnit) * 2
    let pixelX = Int(x.rounded())
    let pixelY = Int(y.rounded())
    XCTAssertGreaterThan(pixels.alpha(x: pixelX, y: pixelY), 0.99)
    XCTAssertGreaterThan(
      pixels.blackPixelCount(nearX: pixelX, y: pixelY, radius: 3), 0,
      "the eye needs a black core beside its glossy centre"
    )
  }

  func testTheMatteBodyKeepsItsPigmentUnderTheSoftbox() throws {
    let blue = MascotPalette(
      id: "renderer-test-matte-blue", displayName: "Matte blue",
      hexes: Array(repeating: "#4885C7", count: Int(MASCOT_STOP_COUNT))
    )
    let frame = try XCTUnwrap(stillFace(blue, size: 96).lastFrame)
    let pixels = try image(movingEyesOffTheBody(frame))
    var brightestRed = 0.0
    var darkestBlue = 1.0
    var brightestBlue = 0.0
    let centre = Double(pixels.width) / 2
    for y in 0..<pixels.height {
      for x in 0..<pixels.width where pixels.alpha(x: x, y: y) > 0.99 {
        let c = pixels.color(x: x, y: y)
        if hypot(Double(x) - centre, Double(y) - centre) < centre * 0.55 {
          brightestRed = max(brightestRed, c.x)
        }
        darkestBlue = min(darkestBlue, c.z)
        brightestBlue = max(brightestBlue, c.z)
      }
    }
    XCTAssertLessThan(brightestRed, 0.42, "a white glossy patch washed out the pigment")
    XCTAssertGreaterThan(brightestBlue - darkestBlue, 0.08, "matte still needs readable volume")
  }

  func testEveryShapeCarriesTheSmallBlackSmile() throws {
    for shape in MascotShape.allCases {
      let face = stillFace(shape: shape)
      let frame = try XCTUnwrap(face.lastFrame)
      let pixels = try image(frame)
      let build = shape.build
      let centre = CGPoint(
        x: (frame.eyes[0].centre.x + frame.eyes[1].centre.x) / 2,
        y: (frame.eyes[0].centre.y + frame.eyes[1].centre.y) / 2 - 4.0
      )
      let pointsPerUnit = 64 / MascotSpec.designBox * MascotRenderer.fill
      let x = build.eyeOffset.x + centre.x * build.eyeScale
      let y = build.eyeOffset.y + centre.y * build.eyeScale
      let pixelX = Int(((32 + x * pointsPerUnit) * 2).rounded())
      let pixelY = Int(((32 - y * pointsPerUnit) * 2).rounded())
      XCTAssertGreaterThan(pixels.blackPixelCount(nearX: pixelX, y: pixelY, radius: 2), 0,
        "\(shape): the smile is missing below the eyes")
    }
  }

  func testTurningTheBodyCarriesTheEyesWithIt() throws {
    let still = try XCTUnwrap(stillFace().lastFrame)
    var turned = still
    turned.pose.yaw = 0.3
    let rows = 36..<64
    let ahead = try image(still).blackCentroidX(rows: rows)
    let aside = try image(turned).blackCentroidX(rows: rows)
    XCTAssertGreaterThan(aside, ahead + 4, "the eyes moved right with the face")
  }

  func testTheEyesAreSetIntoTheBodyNotStoodOnIt() throws {
    let bright = MascotPalette(
      id: "renderer-test-solid-bright", displayName: "Solid bright",
      hexes: Array(repeating: "#F5F2D7", count: Int(MASCOT_STOP_COUNT))
    )
    for shape in MascotShape.allCases {
      var profile = try XCTUnwrap(stillFace(bright, size: 128, shape: shape).lastFrame)
      profile.pose.yaw = .pi / 2
      let withEyes = try image(profile)
      let bodyOnly = try image(movingEyesOffTheBody(profile))
      XCTAssertLessThan(
        withEyes.addedBlackSilhouettePixels(comparedTo: bodyOnly), 4,
        "\(shape): an eye stands out past the profile"
      )
    }
  }

  func testFurIsACoatThatLeavesTheEyesClear() throws {
    var velvet = try XCTUnwrap(stillFace(size: 96).lastFrame)
    velvet.finish = .velvet
    var fur = velvet
    fur.finish = .fur
    let bare = try image(velvet)
    let coated = try image(fur)
    var strands = 0
    for y in 0..<coated.height {
      for x in 0..<coated.width where bare.alpha(x: x, y: y) < 0.01 {
        let alpha = coated.alpha(x: x, y: y)
        if alpha > 0.05 && alpha < 0.95 { strands += 1 }
      }
    }
    XCTAssertGreaterThan(strands, 200, "the coat stands past the body in strands")
    XCTAssertGreaterThan(
      Double(coated.blackPixelCount()), Double(bare.blackPixelCount()) * 0.8,
      "fur grew over the eyes"
    )
  }

  func testEveryBodyIsACushionInProfile() throws {
    let bright = MascotPalette(
      id: "renderer-test-solid-bright", displayName: "Solid bright",
      hexes: Array(repeating: "#F5F2D7", count: Int(MASCOT_STOP_COUNT))
    )
    for shape in MascotShape.allCases {
      var side = try XCTUnwrap(stillFace(bright, size: 128, shape: shape).lastFrame)
      side.pose.yaw = .pi / 2
      let pixels = try image(movingEyesOffTheBody(side))
      var columns = Set<Int>()
      var rows = Set<Int>()
      for y in 0..<pixels.height {
        for x in 0..<pixels.width where pixels.alpha(x: x, y: y) > 0.5 {
          columns.insert(x)
          rows.insert(y)
        }
      }
      let deep = try Double(XCTUnwrap(columns.max()) - XCTUnwrap(columns.min()))
      let tall = try Double(XCTUnwrap(rows.max()) - XCTUnwrap(rows.min()))
      XCTAssertLessThan(deep / tall, 0.75, "\(shape): as deep as a block")
      XCTAssertGreaterThan(deep / tall, 0.3, "\(shape): as thin as a sticker")
    }
  }

  func testTheBodyOccludesTheEyesWhenViewedFromBehind() throws {
    let bright = MascotPalette(
      id: "renderer-test-solid-bright", displayName: "Solid bright",
      hexes: Array(repeating: "#F5F2D7", count: Int(MASCOT_STOP_COUNT))
    )
    for shape: MascotShape in [.bloom, .daisy, .hex] {
      var back = try XCTUnwrap(stillFace(bright, size: 128, shape: shape).lastFrame)
      back.pose.yaw = .pi
      let withEyes = try image(back)
      let bodyOnly = try image(movingEyesOffTheBody(back))

      XCTAssertEqual(withEyes.blackPixelCount(), 0, "\(shape): an eye shows through the back")
      XCTAssertLessThanOrEqual(
        withEyes.maximumChannelDifference(from: bodyOnly), 1.0 / 255,
        "\(shape): hidden eyes changed the back's colour or contour"
      )
    }
  }

  private func movingEyesOffTheBody(_ frame: MascotRenderer.Frame) -> MascotRenderer.Frame {
    var result = frame
    for index in result.eyes.indices { result.eyes[index].centre.x += 60 }
    return result
  }

  func testThePoseTurnsTheWayTheEmotionsExpect() {
    let forward = simd_float3(0, 0, 1)
    XCTAssertGreaterThan((MascotRenderer.rotation(for: .init(yaw: 0.3)) * forward).x, 0.2)
    XCTAssertGreaterThan((MascotRenderer.rotation(for: .init(pitch: 0.3)) * forward).y, 0.2)
    let rightward = MascotRenderer.rotation(for: .init(roll: 0.3)) * simd_float3(1, 0, 0)
    XCTAssertLessThan(rightward.y, -0.2, "clockwise: the right side goes down")
  }

  func testTheUniformsCarryEverySixStopsTopToBottom() throws {
    let frame = try XCTUnwrap(stillFace().lastFrame)
    let uniforms = MascotRenderer.uniforms(for: frame)
    XCTAssertEqual(uniforms.shape.x, Float(MASCOT_STOP_COUNT))
    let positions = withUnsafeBytes(of: uniforms.stops) { raw in
      Array(raw.bindMemory(to: simd_float4.self)).map(\.w)
    }
    XCTAssertEqual(positions, MascotPalette.stopPositions.map(Float.init))
  }

  func testRecolouringKeepsTheFaceWhereItWas() throws {
    let face = stillFace()
    let before = try XCTUnwrap(face.lastFrame)
    face.apply(palette: try XCTUnwrap(MascotPalette.palette(withID: "ember")))
    let after = try XCTUnwrap(face.lastFrame)
    XCTAssertEqual(after.palette.id, "ember")
    XCTAssertEqual(after.pose, before.pose)
    XCTAssertEqual(after.eyes, before.eyes)
    XCTAssertEqual(after.phase, before.phase)
  }

  func testTheSurfaceNeverForcesAnOffscreenPass() {
    XCTAssertTrue(stillFace().canvasAvoidsOffscreenPassForTesting)
  }

  // MARK: - Outlines

  func testEveryShapeIsNamedOnceAndReachesTheShaderUnderItsOwnID() {
    XCTAssertEqual(MascotShape.allCases.count, 6)
    XCTAssertEqual(Set(MascotShape.allCases.map(\.rawValue)).count, 6)
    XCTAssertEqual(Set(MascotShape.allCases.map(\.displayName)).count, 6)
    let ids = MascotShape.allCases.map { $0.shaderID.rawValue }
    XCTAssertEqual(Set(ids).count, 6, "two outlines share a shader case")
    XCTAssertEqual(MascotShape.hex.shaderID.rawValue, MascotShapeHex.rawValue)
  }

  func testTheUniformsCarryTheOutlineItsBuildAndWhereTheEyesStand() throws {
    for shape in MascotShape.allCases {
      let frame = try XCTUnwrap(stillFace(shape: shape).lastFrame)
      let u = MascotRenderer.uniforms(for: frame)
      let build = shape.build
      XCTAssertEqual(u.shape.y, Float(shape.shaderID.rawValue), "\(shape)")
      XCTAssertEqual(u.build.x, Float(build.thickness), "\(shape)")
      XCTAssertEqual(u.build.y, Float(build.profile), "\(shape)")
      XCTAssertEqual(u.face.z, Float(build.eyeScale), "\(shape)")
      XCTAssertEqual(u.face.w, Float(MascotSpec.eyeSize), "\(shape)")
      XCTAssertEqual(u.extent.x, Float(build.top), "\(shape)")
      XCTAssertEqual(u.extent.y, Float(build.bottom), "\(shape)")
    }
  }

  func testEveryBuildIsSane() {
    for shape in MascotShape.allCases {
      let b = shape.build
      XCTAssertGreaterThan(b.thickness, 3, "\(shape): a body this thin is a sticker")
      XCTAssertLessThan(b.thickness, 12, "\(shape): a body this thick is a ball")
      XCTAssertGreaterThan(b.profile, 0.25, "\(shape): a cushion this full is a slab")
      XCTAssertLessThanOrEqual(b.profile, 1, "\(shape): past 1 the seam is a blade")
      XCTAssertGreaterThan(b.top, 0, "\(shape)")
      XCTAssertLessThan(b.bottom, 0, "\(shape)")
      XCTAssertGreaterThan(b.eyeScale, 0.6, "\(shape)")
      XCTAssertLessThanOrEqual(b.eyeScale, 1.2, "\(shape)")
      XCTAssertGreaterThan(b.step, 0.4, "\(shape)")
      XCTAssertLessThanOrEqual(b.step, 1, "\(shape)")
    }
  }

  func testTheHexagonIsStuffedAndKeepsItsIdentity() {
    let b = MascotShape.hex.build
    XCTAssertGreaterThan(b.thickness, 6)
    XCTAssertLessThanOrEqual(b.profile, 0.6, "the seam is round, not a wall")
    XCTAssertGreaterThan(b.top, 14)
    XCTAssertLessThan(abs(b.top + b.bottom), 0.1, "the broad badge keeps balanced height")
    XCTAssertEqual(b.eyeOffset.x, 0)
    XCTAssertGreaterThan(b.eyeOffset.y, -1)
    XCTAssertEqual(b.eyeScale, 1)
  }

  func testEveryShapeIsSolidInTheMiddleAndFitsItsBox() throws {
    for shape in MascotShape.allCases {
      let pixels = try Pixels(XCTUnwrap(stillFace(shape: shape).snapshot()))
      XCTAssertGreaterThan(pixels.alpha(x: 64, y: 70), 0.99, "\(shape): a hole in the middle")
      XCTAssertEqual(pixels.alpha(x: 1, y: 1), 0, "\(shape): paint in the corner")
      XCTAssertEqual(pixels.alpha(x: 126, y: 126), 0, "\(shape)")
      for i in 0..<pixels.width {
        XCTAssertEqual(pixels.alpha(x: i, y: 0), 0, "\(shape): cut at the top")
        XCTAssertEqual(pixels.alpha(x: i, y: pixels.height - 1), 0, "\(shape): cut at the bottom")
        XCTAssertEqual(pixels.alpha(x: 0, y: i), 0, "\(shape): cut at the left")
        XCTAssertEqual(pixels.alpha(x: pixels.width - 1, y: i), 0, "\(shape): cut at the right")
      }
    }
  }

  func testEveryShapesEyesAreBlackWhereItPutsThem() throws {
    for shape in MascotShape.allCases {
      let face = stillFace(shape: shape)
      let frame = try XCTUnwrap(face.lastFrame)
      let pixels = try Pixels(XCTUnwrap(face.snapshot()))
      let build = shape.build
      let pointsPerUnit = 64 / MascotSpec.designBox * MascotRenderer.fill
      for eye in frame.eyes {
        let x = build.eyeOffset.x + build.eyeScale * eye.centre.x
        let y = build.eyeOffset.y + build.eyeScale * eye.centre.y
        let pixelX = Int(((32 + x * pointsPerUnit) * 2).rounded())
        let pixelY = Int(((32 - y * pointsPerUnit) * 2).rounded())
        XCTAssertGreaterThan(pixels.alpha(x: pixelX, y: pixelY), 0.99, "\(shape): an eye is off the body")
        XCTAssertGreaterThan(
          pixels.blackPixelCount(nearX: pixelX, y: pixelY, radius: 3), 0,
          "\(shape): an eye has no black core beside its reflection"
        )
      }
    }
  }

  func testAnotherOutlineKeepsTheDriftTheMoodAndThePose() throws {
    let face = stillFace()
    let before = try XCTUnwrap(face.lastFrame)
    face.apply(look: MascotLook(shape: .triangle, palette: .standard))
    let after = try XCTUnwrap(face.lastFrame)
    XCTAssertEqual(after.shape, .triangle)
    XCTAssertEqual(after.pose, before.pose)
    XCTAssertEqual(after.phase, before.phase)
    XCTAssertEqual(after.palette, before.palette)
  }

  // MARK: - Gradients

  func testASunriseIsTheSameAcrossARowAndChangesDownIt() throws {
    let pixels = try Pixels(XCTUnwrap(stillFace(shape: .orb).snapshot()))
    let left = pixels.color(x: 44, y: 100)
    let right = pixels.color(x: 84, y: 100)
    let high = pixels.color(x: 64, y: 40)
    XCTAssertLessThan(simd_distance(chromaticity(left), chromaticity(right)), 0.10,
      "the same pigment across a row despite directional light")
    XCTAssertGreaterThan(simd_distance(left, high), 0.3, "and another further up")
  }

  func testASweepRunsFromOneCornerToTheOther() throws {
    let aurora = try XCTUnwrap(MascotPalette.palette(withID: "aurora"))
    let pixels = try Pixels(XCTUnwrap(stillFace(aurora, shape: .orb).snapshot()))
    let topLeft = pixels.color(x: 38, y: 40)
    let bottomRight = pixels.color(x: 92, y: 96)
    let topRight = pixels.color(x: 92, y: 40)
    XCTAssertGreaterThan(simd_distance(topLeft, bottomRight), 0.4, "opposite corners: \(topLeft) \(bottomRight)")
    XCTAssertGreaterThan(simd_distance(topLeft, topRight), 0.15, "a row is not one colour")
  }

  func testAGlowRunsOutFromBetweenTheEyes() throws {
    let solar = try XCTUnwrap(MascotPalette.palette(withID: "solar"))
    let pixels = try Pixels(XCTUnwrap(stillFace(solar, shape: .orb).snapshot()))
    let core = pixels.color(x: 64, y: 62)
    let rim = pixels.color(x: 64, y: 108)
    let side = pixels.color(x: 26, y: 64)
    XCTAssertGreaterThan(simd_distance(core, rim), 0.2, "core and rim: \(core) \(rim)")
    XCTAssertGreaterThan(simd_distance(core, side), 0.15, "and out to the side too: \(core) \(side)")
    XCTAssertLessThan(simd_distance(chromaticity(rim), chromaticity(side)),
      simd_distance(chromaticity(core), chromaticity(rim)), "the rim pigment is one colour all round")
  }

  func testDetailFollowsTheFacesSize() throws {
    var large = try XCTUnwrap(stillFace(size: 60).lastFrame)
    var small = try XCTUnwrap(stillFace(size: 26).lastFrame)
    XCTAssertEqual(MascotRenderer.rays(for: large), 4)
    XCTAssertEqual(MascotRenderer.rays(for: small), 2)
    XCTAssertEqual(MascotRenderer.uniforms(for: small).finish.z, 2)
    XCTAssertEqual(MascotRenderer.uniforms(for: small, rays: 4).finish.z, 4, "a picture keeps four")
    large.finish = .fur
    small.finish = .fur
    XCTAssertEqual(MascotRenderer.rays(for: large), 2)
    XCTAssertEqual(MascotRenderer.rays(for: small), 2)
  }

  private func chromaticity(_ color: SIMD3<Double>) -> SIMD3<Double> {
    color / max(color.x + color.y + color.z, 0.001)
  }
}

private struct Pixels {
  let width: Int
  let height: Int
  private let bytes: [UInt8]

  init(_ image: CGImage) throws {
    let w = image.width
    let h = image.height
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
      guard let context = CGContext(
        data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { throw XCTSkip("no bitmap context") }
    width = w
    height = h
    bytes = buffer
  }

  func alpha(x: Int, y: Int) -> CGFloat {
    CGFloat(bytes[(y * width + x) * 4 + 3]) / 255
  }

  func color(x: Int, y: Int) -> SIMD3<Double> {
    let index = (y * width + x) * 4
    let a = max(Double(bytes[index + 3]) / 255, 1 / 255)
    return SIMD3(
      Double(bytes[index]) / 255 / a,
      Double(bytes[index + 1]) / 255 / a,
      Double(bytes[index + 2]) / 255 / a
    )
  }

  func blackCentroidX(rows: Range<Int>) -> CGFloat {
    var total: CGFloat = 0
    var count: CGFloat = 0
    for y in rows {
      for x in 0..<width where alpha(x: x, y: y) > 0.99 {
        let c = color(x: x, y: y)
        if max(c.x, c.y, c.z) < 0.1 {
          total += CGFloat(x)
          count += 1
        }
      }
    }
    return count > 0 ? total / count : 0
  }

  func blackPixelCount() -> Int {
    var count = 0
    for y in 0..<height {
      for x in 0..<width where alpha(x: x, y: y) > 0.99 {
        let c = color(x: x, y: y)
        if max(c.x, c.y, c.z) < 0.15 { count += 1 }
      }
    }
    return count
  }

  func blackPixelCount(nearX centreX: Int, y centreY: Int, radius: Int) -> Int {
    var count = 0
    for y in max(0, centreY - radius)...min(height - 1, centreY + radius) {
      for x in max(0, centreX - radius)...min(width - 1, centreX + radius)
        where alpha(x: x, y: y) > 0.99
      {
        let c = color(x: x, y: y)
        if max(c.x, c.y, c.z) < 0.15 { count += 1 }
      }
    }
    return count
  }

  func addedBlackSilhouettePixels(comparedTo body: Pixels) -> Int {
    precondition(width == body.width && height == body.height)
    var count = 0
    for y in 0..<height {
      for x in 0..<width where alpha(x: x, y: y) > 0.99 && body.alpha(x: x, y: y) < 0.01 {
        let c = color(x: x, y: y)
        if max(c.x, c.y, c.z) < 0.15 { count += 1 }
      }
    }
    return count
  }

  func maximumChannelDifference(from other: Pixels) -> Double {
    precondition(width == other.width && height == other.height)
    return zip(bytes, other.bytes)
      .map { abs(Double($0) - Double($1)) / 255 }.max() ?? 0
  }
}
