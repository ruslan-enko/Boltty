import XCTest
@testable import Boltty

final class SupertonicTextTests: XCTestCase {
  // MARK: - Scripts

  func testLatinWordsInAUkrainianSentenceAreReadAsEnglish() {
    let runs = SupertonicText.runs("Я оновив файл README і запустив тести у Codex.", language: "uk")
    XCTAssertEqual(runs, [
      .init(text: "Я оновив файл ", language: "uk"),
      .init(text: "README ", language: "en"),
      .init(text: "і запустив тести у ", language: "uk"),
      .init(text: "Codex.", language: "en"),
    ])
  }

  func testDigitsAndSignsStayWithTheWordBefore() {
    let runs = SupertonicText.runs("Swift 6 вийшов — 2 дні тому.", language: "uk")
    XCTAssertEqual(runs.map(\.language), ["en", "uk"])
    XCTAssertEqual(runs.first?.text, "Swift 6 ")
  }

  func testOnlyCyrillicLanguagesAreCut() {
    let text = "Öffne die Datei README jetzt."
    XCTAssertEqual(SupertonicText.runs(text, language: "de"), [.init(text: text, language: "de")])
    XCTAssertEqual(SupertonicText.runs("Привіт.", language: "uk"), [.init(text: "Привіт.", language: "uk")])
  }

  // MARK: - Tags

  func testTheLastRunEndsOnAStopAndTheOthersOnAComma() {
    XCTAssertEqual(SupertonicText.tagged("Я оновив файл ", language: "uk", last: false), "<uk>Я оновив файл,</uk>")
    XCTAssertEqual(SupertonicText.tagged("README", language: "en", last: true), "<en>README.</en>")
    XCTAssertEqual(SupertonicText.tagged("Готово?", language: "uk", last: true), "<uk>Готово?</uk>")
    XCTAssertEqual(SupertonicText.tagged("  ", language: "uk", last: true), "")
  }

  func testCleaningFollowsTheReference() {
    XCTAssertEqual(SupertonicText.clean("a — b"), "a - b")
    XCTAssertEqual(SupertonicText.clean("mail me@home"), "mail me at home")
    XCTAssertEqual(SupertonicText.clean("“quoted”  text 🙂"), "\"quoted\" text")
    XCTAssertEqual(SupertonicText.clean("done , then"), "done, then")
  }

  // MARK: - Passes

  func testAShortPieceIsOnePass() {
    XCTAssertEqual(SupertonicText.passes("Готово.", limit: 70), ["Готово."])
  }

  func testALongPieceIsCutAtSentencesThenCommasThenSpaces() {
    let piece = "Я переглянув усі файли в папці проєкту, знайшов три місця з помилками, виправив кожне з них і запустив тести ще раз. Усе пройшло."
    let passes = SupertonicText.passes(piece, limit: 70)
    XCTAssertGreaterThan(passes.count, 1)
    XCTAssertTrue(passes.allSatisfy { $0.count <= 70 }, "\(passes)")
    XCTAssertEqual(
      passes.joined(separator: " ").split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) },
      piece.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) })
  }

  func testAnAbbreviationDoesNotEndASentence() {
    let piece = String(repeating: "word ", count: 10) + "Ask Dr. Smith about it. " + String(repeating: "more ", count: 10)
    let passes = SupertonicText.passes(piece, limit: 70)
    XCTAssertTrue(passes.contains { $0.contains("Dr. Smith") }, "\(passes)")
  }

  func testTheWindowLengthDependsOnTheScript() {
    XCTAssertEqual(SupertonicText.passLength(for: "uk"), 70)
    XCTAssertEqual(SupertonicText.passLength(for: "ja"), 57)
  }

  // MARK: - Encoding

  func testEncodingPadsToTheWindowAndMarksUnknownScalars() {
    let indexer: [Int32] = (0..<128).map { Int32($0) }
    let (ids, mask) = SupertonicText.encode("<en>Hi.</en>я", indexer: indexer)
    XCTAssertEqual(ids.count, SupertonicText.window)
    XCTAssertEqual(mask.count, SupertonicText.window)
    XCTAssertEqual(Array(ids.prefix(4)), [60, 101, 110, 62])
    XCTAssertEqual(ids[12], -1, "я is past the indexer")
    XCTAssertEqual(mask.reduce(0, +), 13)
  }

  // MARK: - Sound

  func testAJointKeepsABreathOfItsQuietEdge() {
    let rate = SupertonicSynthesizer.sampleRate
    let sound = [Float](repeating: 0, count: rate / 10)
      + [Float](repeating: 0.5, count: rate / 10)
      + [Float](repeating: 0, count: rate / 2)
    let both = SupertonicSynthesizer.joint(sound, trimStart: true, trimEnd: true)
    XCTAssertEqual(both.count, rate / 10 + rate * 15 / 1000 + rate * 70 / 1000)
    XCTAssertEqual(SupertonicSynthesizer.joint(sound, trimStart: false, trimEnd: false), sound)
    XCTAssertEqual(SupertonicSynthesizer.joint([0, 0, 0], trimStart: true, trimEnd: true), [0, 0, 0])
  }

  func testNoiseFillsOnlyTheTrueLength() {
    let noise = SupertonicSynthesizer.noise(channels: 2, length: 3, padded: 5, uniform: { 0.3 })
    XCTAssertEqual(noise.count, 10)
    XCTAssertEqual(Array(noise[3..<5]), [0, 0])
    XCTAssertEqual(Array(noise[8..<10]), [0, 0])
    XCTAssertNotEqual(noise[0], 0)
  }

  func testTrimmingKeepsEachChannelsFirstFrames() {
    let padded: [Float] = [1, 2, 3, 0, 4, 5, 6, 0]
    XCTAssertEqual(SupertonicSynthesizer.trim(padded, channels: 2, from: 4, to: 3), [1, 2, 3, 4, 5, 6])
  }
}
