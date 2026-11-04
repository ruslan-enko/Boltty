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

  func testAFaceAtRestShowsWhatCanBeDone() async throws {
    let overlay = AskBolttyOverlayController()
    defer { overlay.hide() }
    overlay.restHint = { "⌥Space to ask more · Esc to close" }
    overlay.pointer = { CGPoint(x: 400, y: 400) }
    overlay.show(.speaking, caption: "Hello there.", agent: .claude)
    try await Task.sleep(for: .seconds(0.6))
    overlay.show(.idle, caption: "", agent: .claude)
    // The answer's linger, its words going back into the face, the line growing.
    try await Task.sleep(for: .seconds(2))

    let bubble = overlay.bubbleForTesting
    XCTAssertEqual(overlay.textForTesting, "⌥Space to ask more · Esc to close")
    XCTAssertFalse(bubble.isHidden)
    XCTAssertEqual(bubble.alpha, 1)
    XCTAssertEqual(bubble.wordsAlpha, 1)
    XCTAssertGreaterThan(bubble.frame.width, 100)
  }

  func testThePointerMarksTailLiesTowardTheFaceWhicheverSideItLanded() {
    XCTAssertEqual(
      AskBolttyOverlayController.pointerTurn(reach: AskBolttyOverlayController.landingOffset), 0,
      accuracy: 0.001, "beside the spot as usual it needs no turn")
    XCTAssertEqual(
      AskBolttyOverlayController.pointerTurn(reach: CGVector(dx: -30, dy: -30)), -.pi / 2,
      accuracy: 0.001, "the face to the left at a right edge")
  }

  private func bubble(
    size: CGSize, whole: CGSize, on side: AskBolttyOverlayController.BubbleSide, beside face: CGRect
  ) -> CGRect {
    AskBolttyOverlayController.bubbleFrame(
      size: size, whole: whole,
      lead: AskBolttyOverlayController.bubbleLead(on: side, wholeWidth: whole.width),
      beside: face, in: screen)
  }

  func testTheBubbleStandsRightOfTheFaceUnlessThereIsNoRoom() {
    let size = CGSize(width: 200, height: AskBolttyOverlayController.bubbleFirstLineHeight)
    let face = CGRect(x: 100, y: 400, width: 40, height: 40)
    let right = bubble(size: size, whole: size, on: .right, beside: face)
    XCTAssertGreaterThan(right.minX, face.maxX)
    XCTAssertEqual(right.midY, face.midY, accuracy: 1)

    let nearEdge = CGRect(x: 1300, y: 400, width: 40, height: 40)
    XCTAssertEqual(
      AskBolttyOverlayController.bubbleSide(current: .right, beside: nearEdge, in: screen), .left)
    let left = bubble(size: size, whole: size, on: .left, beside: nearEdge)
    XCTAssertLessThan(left.maxX, nearEdge.minX)
  }

  func testTheBubbleKeepsItsSideWhileItStillFits() {
    let middle = CGRect(x: 600, y: 400, width: 40, height: 40)
    XCTAssertEqual(
      AskBolttyOverlayController.bubbleSide(current: .left, beside: middle, in: screen), .left)
    XCTAssertEqual(
      AskBolttyOverlayController.bubbleSide(current: .right, beside: middle, in: screen), .right)
    let nearLeft = CGRect(x: 100, y: 400, width: 40, height: 40)
    XCTAssertEqual(
      AskBolttyOverlayController.bubbleSide(current: .left, beside: nearLeft, in: screen), .right)
  }

  func testWordsHoldStillAsTheBubbleGrows() {
    let face = CGRect(x: 600, y: 400, width: 40, height: 40)
    let whole = CGSize(width: 368, height: 120)
    let first = CGSize(width: 90, height: AskBolttyOverlayController.bubbleFirstLineHeight)
    let later = CGSize(width: 368, height: 120)
    for side in [AskBolttyOverlayController.BubbleSide.right, .left] {
      let start = bubble(size: first, whole: whole, on: side, beside: face)
      let end = bubble(size: later, whole: whole, on: side, beside: face)
      XCTAssertEqual(start.minX, end.minX, "the words hang from this edge")
      XCTAssertEqual(start.maxY, end.maxY, "and from this one")
    }
  }

  func testAWholeSentenceThatWouldReachTheFootMovesUpBeforeItsWordsCome() {
    let low = CGRect(x: 600, y: screen.minY + 10, width: 40, height: 40)
    let whole = CGSize(width: 368, height: 120)
    let first = CGSize(width: 90, height: AskBolttyOverlayController.bubbleFirstLineHeight)
    let start = bubble(size: first, whole: whole, on: .right, beside: low)
    let end = bubble(size: whole, whole: whole, on: .right, beside: low)
    XCTAssertEqual(start.maxY, end.maxY)
    XCTAssertGreaterThanOrEqual(end.minY, screen.minY)
  }

  func testAFlightArcsAboveTheLineAndEndsWhereItWasAimed() {
    let from = CGPoint(x: 100, y: 100), to = CGPoint(x: 700, y: 100)
    XCTAssertEqual(AskBolttyOverlayController.flightPoint(from: from, to: to, progress: 0), from)
    XCTAssertEqual(AskBolttyOverlayController.flightPoint(from: from, to: to, progress: 1), to)
    XCTAssertGreaterThan(AskBolttyOverlayController.flightPoint(from: from, to: to, progress: 0.5).y, 125)
    XCTAssertGreaterThan(AskBolttyOverlayController.flightDuration(from: from, to: to),
                         AskBolttyOverlayController.flightDuration(from: from, to: CGPoint(x: 120, y: 100)))
  }

  func testTheBubbleIsAtMostItsLinesAndAShortLineIsOne() {
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
