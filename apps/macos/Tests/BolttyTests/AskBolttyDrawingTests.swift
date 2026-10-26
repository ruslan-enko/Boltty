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
