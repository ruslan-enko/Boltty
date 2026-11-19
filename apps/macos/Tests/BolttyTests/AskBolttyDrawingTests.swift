import XCTest
@testable import Boltty

final class AskBolttyDrawingTests: XCTestCase {
  func testShapesParseInThePicturesScale() {
    XCTAssertEqual(
      AskBolttyShape.parse(#"<circle x="300" y="330" r="90" label="the subject"/>"#),
      AskBolttyShape(kind: .circle(center: CGPoint(x: 300, y: 330), radius: 90), label: "the subject"))
    XCTAssertEqual(
      AskBolttyShape.parse(#"<box x1="900" y1="860" x2="560" y2="560"/>"#)?.kind,
      .box(CGRect(x: 560, y: 560, width: 340, height: 300)))
    XCTAssertEqual(
      AskBolttyShape.parse(#"<arrow x1="700" y1="150" x2="1400" y2="300"/>"#)?.kind,
      .arrow(from: CGPoint(x: 700, y: 150), to: CGPoint(x: 1000, y: 300)))
    XCTAssertNil(AskBolttyShape.parse(#"<circle x="300" y="330"/>"#))
    XCTAssertNil(AskBolttyShape.parse(#"<label x="1" y="2"/>"#))
  }

  func testAPathReadsAbsoluteAndRelativeSteps() {
    XCTAssertEqual(AskBolttyShape.pathSegments("M 100 100 l 50 0 V 200 Z"), [
      .move(CGPoint(x: 100, y: 100)), .line(CGPoint(x: 150, y: 100)),
      .line(CGPoint(x: 150, y: 200)), .close,
    ])
    XCTAssertEqual(AskBolttyShape.pathSegments("M10,10 20,20"), [
      .move(CGPoint(x: 10, y: 10)), .line(CGPoint(x: 20, y: 20)),
    ])
  }

  func testMarksKeepTheirOrderAndABoardIsOneMark() {
    let answer = """
      <point x="10" y="10"/>Here. <circle x="5" y="5" r="3"/>And this.
      <board><line x1="0" y1="0" x2="10" y2="10"/><label x="5" y="5" text="a"/></board>Done.
      """
    let marks = AskBolttyMark.all(in: answer)
    XCTAssertEqual(marks.count, 3)
    guard case .board(let shapes) = marks[2] else { return XCTFail("\(marks)") }
    XCTAssertEqual(shapes.count, 2)
    XCTAssertEqual(AskBolttyMark.stripped(answer), "Here. And this.\nDone.")
  }

  func testTheVoiceCarriesAMarkerForEveryMark() {
    let spoken = SpokenText.speakable(
      #"One <circle x="5" y="5" r="3"/>two. <board><line x1="0" y1="0" x2="9" y2="9"/></board>Three."#,
      keepingPoints: true)
    XCTAssertTrue(spoken.contains(AskBolttyPoint.marker(0)))
    XCTAssertTrue(spoken.contains(AskBolttyPoint.marker(1)))
    XCTAssertFalse(spoken.contains("board"))
  }

  func testAMarkStillArrivingIsHeldBack() {
    XCTAssertEqual(AskBolttyMark.withoutUnfinished("Look <arr"), "Look ")
    XCTAssertEqual(AskBolttyMark.withoutUnfinished(#"Look <board><line x1="0"/>"#), "Look ")
    XCTAssertEqual(AskBolttyMark.withoutUnfinished("a < b"), "a < b")
  }
}

final class ScreenTextTests: XCTestCase {
  private func line(_ text: String, x: CGFloat, y: CGFloat) -> ScreenText {
    var words: [ScreenText.Word] = []
    var left = x
    for word in text.split(separator: " ") {
      let width = CGFloat(word.count) * 6
      words.append(ScreenText.Word(text: String(word), box: CGRect(x: left, y: y, width: width, height: 10)))
      left += width + 4
    }
    return ScreenText(text: text, box: CGRect(x: x, y: y, width: left - x, height: 10), words: words)
  }

  func testWordsAreFoundWholeAndNeverInsideAnother() throws {
    let lines = [line("Saved", x: 100, y: 100), line("File Edit Save As…", x: 10, y: 5)]
    let box = try XCTUnwrap(ScreenText.find("Save As", near: nil, in: lines))
    XCTAssertEqual(box.minY, 5)
    XCTAssertNil(ScreenText.find("Sav", near: nil, in: lines))
  }

  func testOfTwoAlikeTheNearestIsChosenAndNoneTooFar() throws {
    let lines = [line("Export", x: 10, y: 10), line("Export", x: 900, y: 900)]
    let box = try XCTUnwrap(ScreenText.find("export…", near: CGPoint(x: 880, y: 880), in: lines))
    XCTAssertEqual(box.minX, 900)
    XCTAssertNil(ScreenText.find("Export", near: CGPoint(x: 500, y: 500), in: lines, reach: 100))
  }

  func testAPointNamingWordsLandsOnThem() throws {
    let point = try XCTUnwrap(AskBolttyPoint.parse(#"<point x="100" y="100" text="Export"/>"#))
    let placed = try XCTUnwrap(point.placed(among: [line("Export", x: 120, y: 120)]))
    XCTAssertEqual(placed.y * 1000, 125, accuracy: 0.5)
    let wordsOnly = try XCTUnwrap(AskBolttyPoint.parse(#"<point text="Missing"/>"#))
    XCTAssertFalse(wordsOnly.hasPosition)
    XCTAssertNil(wordsOnly.placed(among: []))
  }

  func testAStepIsAMarkOfItsOwn() {
    let marks = AskBolttyMark.all(in: #"<step text="File"/>Open File. <step text="Export…"/>Choose Export."#)
    XCTAssertEqual(marks.count, 2)
    guard case let .step(first) = marks[0] else { return XCTFail("\(marks)") }
    XCTAssertEqual(first.text, "File")
    XCTAssertEqual(AskBolttyMark.stripped(#"<step text="File"/>Open File."#), "Open File.")
  }

  func testTheListingKeepsTheMenuBarAndWhatIsNearTheArea() throws {
    let lines = [line("File Edit", x: 0, y: 5)]
      + (0..<50).map { line("Far away line number \($0)", x: 10, y: 100 + CGFloat($0)) }
      + [line("Right here", x: 600, y: 600)]
    let listing = try XCTUnwrap(
      ScreenText.listing(lines, byteLimit: 120, near: CGRect(x: 580, y: 580, width: 60, height: 60)))
    XCTAssertTrue(listing.contains("File Edit"))
    XCTAssertTrue(listing.contains("Right here"))
    XCTAssertLessThanOrEqual(listing.utf8.count, 120)
    XCTAssertTrue(listing.hasPrefix("0 5"), "reading order")
  }
}
