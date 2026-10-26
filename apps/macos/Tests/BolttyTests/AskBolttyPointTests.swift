import AppKit
import XCTest
@testable import Boltty

final class AskBolttyPointTests: XCTestCase {
  func testATagIsReadInTheThousandsAcrossThePicture() {
    let point = AskBolttyPoint.parse(#"<point x="420" y="310" label="Share"/>"#)
    XCTAssertEqual(point, AskBolttyPoint(x: 0.42, y: 0.31, label: "Share"))
  }

  func testUnquotedValuesSingleQuotesAndFractionsAreReadToo() {
    XCTAssertEqual(AskBolttyPoint.parse("<point x=250 y=750/>"), AskBolttyPoint(x: 0.25, y: 0.75, label: nil))
    XCTAssertEqual(AskBolttyPoint.parse("<point x='100' y='900' label='Mail'>"),
                   AskBolttyPoint(x: 0.1, y: 0.9, label: "Mail"))
    XCTAssertEqual(AskBolttyPoint.parse(#"<point x="0.5" y="0.25"/>"#), AskBolttyPoint(x: 0.5, y: 0.25, label: nil))
  }

  func testATagThatDoesNotSayWhereIsNoPointAndOneOffThePictureIsKeptOnIt() {
    XCTAssertNil(AskBolttyPoint.parse(#"<point label="Share"/>"#))
    XCTAssertNil(AskBolttyPoint.parse(#"<point x="here" y="1"/>"#))
    XCTAssertEqual(AskBolttyPoint.parse(#"<point x="1400" y="-20"/>"#)?.x, 1)
    XCTAssertEqual(AskBolttyPoint.parse(#"<point x="1400" y="-20"/>"#)?.y, 0)
  }

  func testEveryTagIsFoundInOrderAndOnlyThoseThatSayWhere() {
    let answer = #"<point x="100" y="100"/>Open File. <point label="nowhere"/>Then <point x="900" y="50"/>Export."#
    XCTAssertEqual(AskBolttyPoint.all(in: answer).map(\.x), [0.1, 0.9])
  }

  func testAPointLandsOnTheScreenThePictureWasTakenOf() {
    // A 1000 × 500 display whose bottom left is at (200, 100) in AppKit's space.
    let frame = CGRect(x: 200, y: 100, width: 1000, height: 500)
    XCTAssertEqual(AskBolttyPoint(x: 0, y: 0).location(in: frame), CGPoint(x: 200, y: 600))
    XCTAssertEqual(AskBolttyPoint(x: 0.5, y: 0.5).location(in: frame), CGPoint(x: 700, y: 350))
    XCTAssertEqual(AskBolttyPoint(x: 1, y: 1).location(in: frame), CGPoint(x: 1200, y: 100))
  }

  func testTheCardShowsTheAnswerWithoutItsTags() {
    XCTAssertEqual(
      AskBolttyPoint.stripped(#"<point x="10" y="20" label="Share"/>Click Share. <point x="1" y="2"/>Then Mail."#),
      "Click Share. Then Mail.")
    let message = ConversationMessage(
      id: "a", role: .agent, createdAt: Date(),
      parts: [.text(TextPart(id: "t", kind: .text, text: #"Click <point x="10" y="20"/>Share."#))])
    XCTAssertEqual(message.copyableText, "Click Share.")
  }

  func testAPieceGivesBackItsWordsAndTheTagsItCarried() {
    let piece = AskBolttyPoint.marker(0) + "Click Share in the top right."
    XCTAssertEqual(AskBolttyPoint.split(piece).text, "Click Share in the top right.")
    XCTAssertEqual(AskBolttyPoint.split(piece).points, [0])
    XCTAssertEqual(AskBolttyPoint.split(AskBolttyPoint.marker(3)).text, "")
    XCTAssertEqual(AskBolttyPoint.split(AskBolttyPoint.marker(3)).points, [3])
    XCTAssertEqual(AskBolttyPoint.split("No tags.").points, [])
  }

  func testSpeakableTextKeepsAMarkerWhereEachTagStoodAndSaysNoneOfIt() {
    let answer = #"<point x="900" y="40" label="Share"/>Click Share. <point x="500" y="500"/>Then pick Mail."#
    XCTAssertEqual(SpokenText.speakable(answer), "Click Share. Then pick Mail.")
    let kept = SpokenText.speakable(answer, keepingPoints: true)
    var chunker = SentenceChunker()
    let pieces = (chunker.append(kept + "\n") + chunker.finish()).map(AskBolttyPoint.split)
    XCTAssertEqual(pieces.map(\.text), ["Click Share.", "Then pick Mail."])
    XCTAssertEqual(pieces.map(\.points), [[0], [1]], "each sentence carries the tag before it")
  }

  func testATagStillArrivingIsNotSaid() {
    XCTAssertEqual(SpokenText.speakable(#"Click Share. <point x="9"#), "Click Share.")
    XCTAssertEqual(SpokenText.speakable("Click Share. <poi"), "Click Share.")
    XCTAssertEqual(SpokenText.speakable("Click Share. <"), "Click Share.")
    XCTAssertEqual(SpokenText.speakable("If a < b"), "If a < b", "a less-than is not a tag")
  }

  // MARK: - The picture

  func testTheTracedLineIsDrawnOnThePictureInRed() throws {
    let context = try XCTUnwrap(CGContext(
      data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
    let frozen = FrozenScreen(
      image: try XCTUnwrap(context.makeImage()), displayFrame: CGRect(x: 0, y: 0, width: 400, height: 200),
      windows: [])
    // AppKit's y runs up: 150 on a 200-high primary screen is the picture's row 50.
    let shot = try XCTUnwrap(ScreenRegionCapture.wholeScreen(
      frozen, pointer: nil, trail: [CGPoint(x: 50, y: 150), CGPoint(x: 350, y: 150)],
      primaryScreenHeight: 200))
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: shot.png))
    let onTheLine = try XCTUnwrap(bitmap.colorAt(x: 200, y: 50)?.usingColorSpace(.sRGB))
    let offIt = try XCTUnwrap(bitmap.colorAt(x: 200, y: 150)?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(onTheLine.redComponent, 0.8)
    XCTAssertLessThan(onTheLine.blueComponent, 0.4)
    XCTAssertGreaterThan(offIt.blueComponent, 0.8)
  }
}

final class SmoothLineTests: XCTestCase {
  func testTheCurvePassesThroughTheMiddlesAndTurnsAtTheSamples() {
    var line = SmoothLine()
    XCTAssertNil(line.add(CGPoint(x: 0, y: 0)))
    XCTAssertEqual(line.add(CGPoint(x: 100, y: 0)),
                   SmoothLine.Piece(from: .zero, to: CGPoint(x: 50, y: 0), control: .zero))
    // The corner the hand turned at is a control point, not a point on the line.
    XCTAssertEqual(line.add(CGPoint(x: 100, y: 100)),
                   SmoothLine.Piece(from: CGPoint(x: 50, y: 0), to: CGPoint(x: 100, y: 50),
                                    control: CGPoint(x: 100, y: 0)))
    XCTAssertEqual(line.pen, CGPoint(x: 100, y: 50))
  }

  func testAWholeLineEndsAtItsLastSample() {
    let path = SmoothLine.path(through: [.zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)])
    XCTAssertEqual(path.currentPoint, CGPoint(x: 100, y: 100))
    XCTAssertTrue(SmoothLine.path(through: [.zero]).isEmpty)
  }
}

final class SpeechLanguagesTests: XCTestCase {
  func testBolttySpeaksSirisLanguagesAndNoOthers() {
    XCTAssertEqual(SpeechLanguages.spoken.count, 19)
    for tag in ["en-US", "en_GB", "de", "fr-CA", "zh-Hans", "zh-HK", "ja", "no", "nb-NO", "vi"] {
      XCTAssertTrue(SpeechLanguages.speaks(tag), tag)
    }
    for tag in ["uk", "uk-UA", "pl", "he", "ms", ""] {
      XCTAssertFalse(SpeechLanguages.speaks(tag), tag)
    }
    XCTAssertFalse(SpeechLanguages.speaks(nil))
  }
}

@MainActor
final class AskBolttyOverlayGeometryTests: XCTestCase {
  func testANewCaptionTypesOnlyWhatIsNew() {
    XCTAssertEqual(AskBolttyOverlayController.carried(from: "", into: "Open it."), 0)
    XCTAssertEqual(AskBolttyOverlayController.carried(from: "Open it.", into: "Open it. Then Share."), 8)
    XCTAssertEqual(AskBolttyOverlayController.carried(from: "Open it. Then Share.", into: "Then Share. Pick Mail."), 11,
                   "the sentence carried over is not typed again")
    XCTAssertEqual(AskBolttyOverlayController.basePitch(for: .claude), AskBolttyOverlayController.basePitch(for: .claude))
  }

  func testAShownSentenceStaysLongEnoughToRead() {
    XCTAssertEqual(AskBolttyReader.readingTime(of: "Ok."), 1.4, "a beat at least")
    XCTAssertGreaterThan(AskBolttyReader.readingTime(of: String(repeating: "a", count: 100)), 6)
  }

  func testEveryTabsNameIsGreyAtRestAndBrightUnderThePointerOrChosen() {
    let empty = AgentHistoryTabView(agent: .grok, title: "Grok", isEmpty: true)
    let full = AgentHistoryTabView(agent: .claude, title: "Claude", isEmpty: false)
    XCTAssertEqual(empty.titleColorForTesting, PaletteInk.secondary)
    XCTAssertEqual(full.titleColorForTesting, PaletteInk.secondary, "a tab with chats is no brighter")
    empty.hoverForTesting(true)
    XCTAssertEqual(empty.titleColorForTesting, PaletteInk.primary)
    empty.hoverForTesting(false)
    XCTAssertEqual(empty.titleColorForTesting, PaletteInk.secondary)
    full.apply(title: "Claude", isEmpty: false, isActive: true)
    XCTAssertEqual(full.titleColorForTesting, PaletteInk.primary)
  }

  private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

  func testTheFaceRidesPastTheArrowAndTurnsBackAtAnEdge() {
    let middle = AskBolttyOverlayController.followGoal(for: CGPoint(x: 700, y: 450), in: screen)
    XCTAssertGreaterThan(middle.x, 700)
    XCTAssertLessThan(middle.y, 450, "under the arrow")

    let corner = AskBolttyOverlayController.followGoal(for: CGPoint(x: 1435, y: 5), in: screen)
    XCTAssertLessThan(corner.x, 1435, "to the arrow's left at the right edge")
    XCTAssertGreaterThan(corner.y, 5, "above it at the foot")
    let reach = AskBolttyOverlayController.faceSide / 2
    XCTAssertTrue(screen.insetBy(dx: reach, dy: reach).contains(corner))
  }

  func testTheFaceLandsBesideTheSpotNeverOnIt() {
    let spot = CGPoint(x: 400, y: 600)
    let landing = AskBolttyOverlayController.landing(beside: spot, in: screen)
    let face = CGRect(x: landing.x - AskBolttyOverlayController.faceSide / 2,
                      y: landing.y - AskBolttyOverlayController.faceSide / 2,
                      width: AskBolttyOverlayController.faceSide, height: AskBolttyOverlayController.faceSide)
    XCTAssertFalse(face.contains(spot))
  }

  func testTheBubbleStandsRightOfTheFaceUnlessThereIsNoRoom() {
    let size = CGSize(width: 200, height: 40)
    let face = CGRect(x: 100, y: 400, width: 40, height: 40)
    let right = AskBolttyOverlayController.bubbleFrame(size: size, beside: face, in: screen)
    XCTAssertGreaterThan(right.minX, face.maxX)
    XCTAssertEqual(right.midY, face.midY, accuracy: 1)

    let nearEdge = CGRect(x: 1300, y: 400, width: 40, height: 40)
    let left = AskBolttyOverlayController.bubbleFrame(size: size, beside: nearEdge, in: screen)
    XCTAssertLessThan(left.maxX, nearEdge.minX)
  }

  func testAFlightArcsAboveTheLineAndEndsWhereItWasAimed() {
    let from = CGPoint(x: 100, y: 100), to = CGPoint(x: 700, y: 100)
    XCTAssertEqual(AskBolttyOverlayController.flightPoint(from: from, to: to, progress: 0), from)
    XCTAssertEqual(AskBolttyOverlayController.flightPoint(from: from, to: to, progress: 1), to)
    XCTAssertGreaterThan(AskBolttyOverlayController.flightPoint(from: from, to: to, progress: 0.5).y, 150)
    XCTAssertGreaterThan(AskBolttyOverlayController.flightDuration(from: from, to: to),
                         AskBolttyOverlayController.flightDuration(from: from, to: CGPoint(x: 120, y: 100)))
  }

  func testTheTrailWalksTheFacesGradientAndBack() {
    let stops: [NSColor] = [.red, .blue]
    let period = AskBolttyTrailLayer.colourPeriod
    let start = AskBolttyTrailLayer.colour(at: 0, stops: stops).usingColorSpace(.sRGB)!
    let half = AskBolttyTrailLayer.colour(at: period / 2, stops: stops).usingColorSpace(.sRGB)!
    let round = AskBolttyTrailLayer.colour(at: period, stops: stops).usingColorSpace(.sRGB)!
    XCTAssertGreaterThan(start.redComponent, 0.9)
    XCTAssertGreaterThan(half.blueComponent, 0.9)
    XCTAssertGreaterThan(round.redComponent, 0.9)
  }

  func testALongScribbleIsDrawnInRunsNotAStepAtATime() {
    let trail = AskBolttyTrailLayer()
    trail.colours = [.red, .blue]
    // 3 000 points of line in 4-point steps: 750 steps.
    for i in 0...750 { trail.extend(to: CGPoint(x: CGFloat(i % 2 == 0 ? i * 4 : i * 4), y: 100)) }
    XCTAssertEqual(trail.length, 3_000, accuracy: 1)
    let expected = Int(3_000 / AskBolttyTrailLayer.runLength) + 1
    XCTAssertLessThanOrEqual(trail.runCount, expected, "one layer per run, not per step (\(trail.runCount))")
    XCTAssertGreaterThan(trail.runCount, 100, "short enough runs for the gradient to read")
  }

  func testTheLineIsGoneAMomentAfterItIsDrawn() {
    var now: CFTimeInterval = 100
    let trail = AskBolttyTrailLayer()
    trail.clock = { now }
    for x in stride(from: 0, through: 200, by: 10) { trail.extend(to: CGPoint(x: CGFloat(x), y: 0)) }
    XCTAssertFalse(trail.isEmpty)
    now += AskBolttyTrailLayer.life / 2
    trail.sweep()
    XCTAssertFalse(trail.isEmpty, "still there while it fades")
    now += AskBolttyTrailLayer.life
    trail.sweep()
    XCTAssertTrue(trail.isEmpty, "and gone after")
    XCTAssertEqual(trail.sublayers?.count ?? 0, 0)
  }

  func testAHandAtRestAddsNothingAndANewLineClearsAFadingOne() {
    let trail = AskBolttyTrailLayer()
    trail.extend(to: CGPoint(x: 10, y: 10))
    trail.extend(to: CGPoint(x: 11, y: 11))
    XCTAssertTrue(trail.isEmpty)
    trail.extend(to: CGPoint(x: 40, y: 10))
    XCTAssertFalse(trail.isEmpty)
    trail.clear()
    XCTAssertEqual(trail.runCount, 0)
    XCTAssertEqual(trail.opacity, 1)
  }

  func testTheBubbleIsOneLineWhileListeningAndAtMostThreeOtherwise() {
    let long = String(repeating: "and then the next word ", count: 30)
    let line = AskBolttyOverlayController.bubbleLineHeight
    let padding = AskBolttyOverlayController.bubblePadding.height * 2
    XCTAssertEqual(AskBolttyOverlayController.bubbleSize(for: long, lines: 1).height, line + padding)
    let most = AskBolttyOverlayController.bubbleMaxLines
    XCTAssertEqual(AskBolttyOverlayController.bubbleSize(for: long, lines: most).height,
                   line * CGFloat(most) + padding, accuracy: 1)
    XCTAssertLessThanOrEqual(
      AskBolttyOverlayController.bubbleSize(for: long, lines: most).width,
      AskBolttyOverlayController.bubbleMaxTextWidth + AskBolttyOverlayController.bubblePadding.width * 2)
    let short = AskBolttyOverlayController.bubbleSize(for: "Thinking…", lines: 3)
    XCTAssertEqual(short.height, line + padding, "a short line is one line tall")
    XCTAssertEqual(AskBolttyOverlayController.bubbleSize(for: "", lines: 3), .zero)
  }

}
