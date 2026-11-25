import XCTest
@testable import Boltty

final class ListeningWordsTests: XCTestCase {
  private func pieces(_ text: String) -> [String] { ListeningWordsView.pieces(of: text).map(\.text) }

  func testWordsBreakAtSpaces() {
    XCTAssertEqual(pieces("Select the heading"), ["Select", "the", "heading"])
    XCTAssertFalse(ListeningWordsView.pieces(of: "Select the heading").contains { $0.isJoined })
  }

  func testJapaneseBreaksInsideASentenceAndKeepsItsPunctuation() {
    let pieces = ListeningWordsView.pieces(of: "「編集」を押す。")
    XCTAssertEqual(pieces.map(\.text).joined(), "「編集」を押す。")
    XCTAssertEqual(pieces.first?.text, "「編")
    XCTAssertEqual(pieces.last?.text, "す。")
    XCTAssertEqual(pieces.map(\.isJoined), [false] + Array(repeating: true, count: pieces.count - 1))
  }

  func testLatinInsideJapaneseStaysWhole() {
    XCTAssertEqual(pieces("READMEを開く"), ["README", "を", "開", "く"])
  }

  func testALongLinkBreaks() {
    let link = "https://example.com/a/very/long/path/that/goes/on/and/on.html"
    XCTAssertEqual(pieces(link).joined(), link)
    XCTAssertTrue(pieces(link).allSatisfy { $0.count <= ListeningWordsView.longestPiece })
  }
}
