import XCTest
@testable import Boltty

final class MascotPaletteTests: XCTestCase {

  // MARK: - Catalog hygiene

  func testCatalogIDsAreUnique() {
    let ids = MascotPalette.catalog.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count, "two palettes share an id")
  }

  func testThePickerOffersTheThreeReferencesDaybreakAndTwoSoftGradients() {
    XCTAssertEqual(
      MascotPalette.catalog.map(\.id),
      ["daybreak", "citrus", "candy", "ember", "lagoon", "slate"]
    )
    XCTAssertEqual(MascotPalette.palette(withID: "lagoon")?.displayName, "Mist")
    XCTAssertEqual(MascotPalette.palette(withID: "slate")?.displayName, "Lilac")
  }

  func testEveryPaletteHasSixParsableStops() {
    for palette in MascotPalette.catalog {
      XCTAssertEqual(palette.hexes.count, Int(MASCOT_STOP_COUNT), "\(palette.id) is not six stops")
      for hex in palette.hexes {
        XCTAssertTrue(hex.hasPrefix("#"), "\(palette.id): \(hex) has no #")
        XCTAssertEqual(hex.count, 7, "\(palette.id): \(hex) is not 6 digits")
        XCTAssertNotNil(
          UInt64(hex.dropFirst(), radix: 16),
          "\(palette.id): \(hex) is not hexadecimal"
        )
      }
    }
    for palette in MascotPalette.catalog {
      let positions = palette.stopPlaces
      XCTAssertEqual(positions.count, Int(MASCOT_STOP_COUNT), palette.id)
      XCTAssertEqual(positions.first, 0, "\(palette.id): the first stop starts the run")
      XCTAssertEqual(positions.last, 1, "\(palette.id): the last ends it")
      XCTAssertEqual(positions, positions.sorted(), palette.id)
      XCTAssertEqual(Set(positions).count, positions.count, "\(palette.id): two stops share a place")
    }
  }

  func testTheReferenceGradientsRunDownTheBody() {
    XCTAssertTrue(MascotPalette.catalog.allSatisfy { $0.style == .sunrise })
  }

  @MainActor
  func testEveryReferencePaletteCarriesColourWithoutABlackBodyStop() {
    for palette in MascotPalette.catalog {
      let stops = palette.colors.map(MascotRenderer.oklab)
      let lightest = stops.map(\.x)
      XCTAssertGreaterThanOrEqual(lightest.min() ?? 0, 0.42, "\(palette.id) has a black body stop")
      let chroma = stops.map { ($0.y * $0.y + $0.z * $0.z).squareRoot() }
      XCTAssertGreaterThanOrEqual(chroma.max() ?? 0, 0.07, "\(palette.id) has lost its colour")
    }
  }

  func testCitrusRunsFromWarmYellowIntoLimeWithoutAWhiteBand() throws {
    let stops = try XCTUnwrap(MascotPalette.palette(withID: "citrus")).colors
      .map { $0.usingColorSpace(.sRGB)! }
    XCTAssertGreaterThan(stops[0].redComponent, stops[0].greenComponent)
    XCTAssertGreaterThan(stops[0].greenComponent, stops[0].blueComponent)
    XCTAssertGreaterThan(stops[5].greenComponent, stops[5].redComponent)
    XCTAssertGreaterThan(stops[5].redComponent, stops[5].blueComponent)
    XCTAssertTrue(stops.allSatisfy { $0.blueComponent < 0.6 }, "the reference stays yellow/lime")
  }

  @MainActor
  func testCandyRunsFromPinkThroughACoolPaleBandIntoTurquoise() throws {
    let palette = try XCTUnwrap(MascotPalette.palette(withID: "candy"))
    let stops = palette.colors.map { $0.usingColorSpace(.sRGB)! }
    XCTAssertGreaterThan(stops[0].redComponent, stops[0].blueComponent)
    XCTAssertGreaterThan(stops[0].blueComponent, stops[0].greenComponent)
    XCTAssertGreaterThan(MascotRenderer.oklab(stops[3]).x, 0.9)
    XCTAssertGreaterThan(stops[3].blueComponent, stops[3].redComponent)
    XCTAssertGreaterThan(stops[5].greenComponent, stops[5].redComponent)
    XCTAssertGreaterThan(stops[5].blueComponent, stops[5].redComponent)
    XCTAssertGreaterThan(palette.stopPlaces[3], 0.5, "the pale band is below the eyes")
  }

  func testEmberRunsFromCoralIntoApricotWithoutAWhiteBand() throws {
    let stops = try XCTUnwrap(MascotPalette.palette(withID: "ember")).colors
      .map { $0.usingColorSpace(.sRGB)! }
    XCTAssertGreaterThan(stops[0].redComponent, stops[0].greenComponent * 2)
    XCTAssertGreaterThan(stops[5].redComponent, stops[5].greenComponent)
    XCTAssertGreaterThan(stops[5].greenComponent, stops[5].blueComponent)
    XCTAssertTrue(stops.allSatisfy { $0.blueComponent < 0.5 }, "the reference stays coral/apricot")
  }

  func testEveryRetiredGradientRemainsReadableButIsNotOffered() throws {
    let retired = [
      "electric", "dusk", "moss", "orchid", "sand", "abyss", "aurora", "sunset",
      "fjord", "cotton", "solar", "frost", "lime", "rose", "ultraviolet", "tide",
    ]
    let offered = Set(MascotPalette.catalog.map(\.id))
    for id in retired {
      let palette = try XCTUnwrap(MascotPalette.palette(withID: id), id)
      XCTAssertEqual(palette.id, id)
      XCTAssertEqual(palette.hexes.count, Int(MASCOT_STOP_COUNT))
      XCTAssertFalse(offered.contains(id), "\(id) is retained for a stored choice")
    }
  }

  func testTheApprovedPresetsCoverEveryConversationColour() {
    let pool = Set(MascotPalette.catalog.map(\.id)).subtracting([MascotPalette.standard.id])
    XCTAssertEqual(pool.count, MascotPalette.catalog.count - 1)
    XCTAssertFalse(pool.isEmpty, "a chat with no colour to wear falls back to Boltty's own")
  }

  // MARK: - Boltty's own face

  func testTheStandardMascotIsTheBlueSunriseAndIsPinnedByID() throws {
    XCTAssertEqual(MascotPalette.standard.id, "daybreak")
    XCTAssertEqual(
      MascotPalette.standard.hexes,
      ["#3f73e6", "#7eaaf2", "#eef0f4", "#ffe98a", "#ffc24f", "#ff6f61"]
    )
    let top = try XCTUnwrap(MascotPalette.standard.colors.first?.usingColorSpace(.sRGB))
    let bottom = try XCTUnwrap(MascotPalette.standard.colors.last?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(top.blueComponent, top.redComponent, "blue at the top")
    XCTAssertGreaterThan(bottom.redComponent, bottom.blueComponent, "warm at the bottom")
    XCTAssertEqual(
      MascotPalette.fallback.id,
      MascotPalette.standard.id,
      "a failed lookup lands on the same face Boltty wears deliberately"
    )
  }

  // MARK: - forConversation

  func testAConversationsColourIsStableAndDerivedFromItsID() {
    let id = UUID()
    XCTAssertEqual(MascotPalette.forConversation(id).id, MascotPalette.forConversation(id).id)
  }

  func testNoConversationEverWearsBolttysOwnFace() {
    for _ in 0..<2_000 {
      XCTAssertNotEqual(MascotPalette.forConversation(UUID()).id, MascotPalette.standard.id)
    }
  }

  func testColoursSpreadAcrossTheWholePool() {
    let drawn = Set((0..<5_000).map { _ in MascotPalette.forConversation(UUID()).id })
    XCTAssertEqual(
      drawn.count,
      MascotPalette.catalog.count - 1,
      "every palette but Boltty's own should come up in five thousand chats"
    )
  }

}


@MainActor
final class MascotMotionTests: XCTestCase {
  private func motion(_ emotion: MascotEmotion) -> MascotMotion {
    MascotMotion(random: MascotRandom(seed: 42), emotion: emotion)
  }

  private func run(_ motion: inout MascotMotion, seconds: Double, _ each: (MascotMotionPose) -> Void = { _ in }) {
    for _ in 0..<Int(seconds * 60) {
      motion.update(1.0 / 60.0)
      each(motion.pose)
    }
  }

  func testThinkingBopsAndSpins() {
    var working = motion(.thinking)
    var highest = 0.0, turned = 0.0, squinted = 0.0
    run(&working, seconds: 6) { pose in
      highest = max(highest, pose.rise)
      turned = max(turned, abs(pose.yaw))
      squinted = max(squinted, pose.eyes[0].happy)
    }
    XCTAssertGreaterThan(highest, 2.5, "it leaves the ground")
    XCTAssertGreaterThan(turned, .pi, "and one bop goes all the way round")
    XCTAssertGreaterThan(squinted, 0.8, "with a squint of pleasure")
  }

  func testOnlyCuriosityHops() {
    for (emotion, hops) in [(MascotEmotion.curious, true), (.listening, false), (.focused, false), (.concerned, false)] {
      var face = motion(emotion)
      var highest = 0.0
      run(&face, seconds: 25) { highest = max(highest, $0.rise) }
      XCTAssertEqual(highest > 4, hops, "\(emotion)")
    }
  }

  func testAHopCrouchesBeforeItLeaves() {
    var face = motion(.focused)
    face.poke(.spinHop)
    var lowest = 0.0, widest = 1.0
    run(&face, seconds: 0.12) { pose in
      lowest = min(lowest, pose.rise)
      widest = max(widest, pose.sx)
    }
    XCTAssertLessThan(lowest, -0.3)
    XCTAssertGreaterThan(widest, 1.05)
  }

  func testAPokeJumpsAndTurnsWhateverTheEmotion() {
    var face = motion(.concerned)
    face.poke(.spinHop)
    var highest = 0.0, turned = 0.0
    run(&face, seconds: 1.3) { pose in
      highest = max(highest, pose.rise)
      turned = max(turned, abs(pose.yaw))
    }
    XCTAssertGreaterThan(highest, 5)
    XCTAssertGreaterThan(turned, .pi)
  }

  func testEveryPokeIsADifferentReaction() {
    var face = motion(.listening)
    var seen: [MascotReaction] = []
    for _ in 0..<40 {
      face.poke()
      if let reaction = face.lastReaction { seen.append(reaction) }
      run(&face, seconds: 2)
    }
    XCTAssertEqual(seen.count, 40)
    for (a, b) in zip(seen, seen.dropFirst()) { XCTAssertNotEqual(a, b, "the same reaction twice running") }
    XCTAssertEqual(Set(seen.map { "\($0)" }).count, MascotReaction.allCases.count)
  }

  func testEveryReactionMovesAndComesBackToRest() {
    for reaction in MascotReaction.allCases {
      var face = motion(.listening)
      run(&face, seconds: 1)
      let before = face.pose
      face.poke(reaction)
      var moved = 0.0
      run(&face, seconds: 1.6) { pose in
        moved = max(
          moved, abs(pose.rise - before.rise), abs(pose.pitch - before.pitch),
          abs(pose.roll - before.roll), abs(pose.yaw - before.yaw), abs(pose.sy - before.sy) * 10
        )
      }
      XCTAssertGreaterThan(moved, 0.8, "\(reaction) is not seen")
      run(&face, seconds: 2)
      XCTAssertLessThan(abs(face.pose.pitch - before.pitch), 0.3, "\(reaction) ends tipped")
      XCTAssertLessThan(abs(face.pose.roll - before.roll), 0.3, "\(reaction) ends rolled")
    }
  }

  func testAWinkShutsOneEye() {
    var face = motion(.listening)
    face.poke(.wink)
    var shut = 1.0, other = 0.0
    run(&face, seconds: 0.5) { pose in
      let eyes = pose.eyes.map(\.open).sorted()
      shut = min(shut, eyes[0])
      other = max(other, eyes[1])
    }
    XCTAssertLessThan(shut, 0.2)
    XCTAssertGreaterThan(other, 0.7)
  }

  func testSleepingShutsTheEyesIntoArcsAndDropsTheHead() {
    var asleep = motion(.sleeping)
    run(&asleep, seconds: 3)
    XCTAssertLessThan(asleep.pose.pitch, -0.2)
    XCTAssertGreaterThan(asleep.pose.eyes[0].sleepy, 0.95)
    XCTAssertLessThan(asleep.pose.eyes[0].open, 0.05)
  }

  func testSadAndConcernedAreInTheLids() {
    var sad = motion(.sad)
    var concerned = motion(.concerned)
    run(&sad, seconds: 2)
    run(&concerned, seconds: 2)
    XCTAssertGreaterThan(sad.pose.eyes[0].droop, 0.4)
    XCTAssertGreaterThan(concerned.pose.eyes[0].droop, 0.1)
    XCTAssertLessThan(concerned.pose.eyes[0].open, concerned.pose.eyes[1].open, "one lid lower")
  }

  func testChangingEmotionGlidesRatherThanCuts() {
    var face = motion(.curious)
    run(&face, seconds: 1)
    let before = face.pose
    face.setEmotion(.sleeping)
    run(&face, seconds: 1.0 / 60.0)
    XCTAssertEqual(face.pose.pitch, before.pitch, accuracy: 0.05)
    XCTAssertEqual(face.pose.eyes[1].sleepy, 0, accuracy: 0.05)
  }

  func testAStalledFrameCannotExplodeTheMotion() {
    var face = motion(.curious)
    face.update(300)
    XCTAssertTrue(face.pose.yaw.isFinite)
    XCTAssertLessThan(abs(face.pose.rise), 10)
  }

  func testReducedMotionKeepsDistinctExpressionsAndFreezesTheBody() throws {
    let view = MascotNSView(conversationID: UUID(), palette: .fallback)
    view.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
    view.reduceMotion = true
    view.layoutSubtreeIfNeeded()
    view.emotion = .listening
    let listening = try XCTUnwrap(view.lastFrame)
    view.emotion = .sleeping
    let sleeping = try XCTUnwrap(view.lastFrame)
    XCTAssertGreaterThan(listening.eyes[0].shape.scale, 1, "listening eyes are taller")
    XCTAssertEqual(sleeping.eyes[0].shape.sleepy, 1, accuracy: 0.001)
    XCTAssertLessThan(sleeping.pose.pitch, -0.2, "with the head down")
    view.advance(1)
    XCTAssertEqual(view.lastFrame?.pose, sleeping.pose, "the body keeps still")
  }

  @MainActor
  func testNoTwoPalettesShareAFace() {
    let gradients = MascotPalette.catalog.map { palette in
      (palette.id, palette.colors.map(MascotRenderer.oklab))
    }
    for (i, a) in gradients.enumerated() {
      for b in gradients[(i + 1)...] {
        let distances = zip(a.1, b.1).map { left, right in
          let delta = left - right
          return (delta.x * delta.x + delta.y * delta.y + delta.z * delta.z).squareRoot()
        }
        let difference = distances.reduce(0, +) / Float(distances.count)
        XCTAssertGreaterThanOrEqual(difference, 0.06, "\(a.0) and \(b.0) share a face")
      }
    }
  }
}
