import XCTest
@testable import Boltty

final class SpokenTextTests: XCTestCase {
  func testPlainProseIsLeftAlone() {
    XCTAssertEqual(SpokenText.speakable("Click Save. Then close the window."),
                   "Click Save. Then close the window.")
  }

  func testEmphasisAndInlineCodeLoseTheirMarks() {
    XCTAssertEqual(SpokenText.speakable("Press **Save** and run `git status` _now_."),
                   "Press Save and run git status now.")
  }

  func testALinkIsSaidByItsWordsAndABareAddressIsNotSpelledOut() {
    XCTAssertEqual(SpokenText.speakable("See [the docs](https://example.com/a?b=1)."), "See the docs.")
    XCTAssertEqual(SpokenText.speakable("Open https://example.com/x/y now."), "Open example.com now.")
  }

  func testAFencedBlockIsLeftToTheScreen() {
    let text = "Run this:\n\n```bash\nnpm install\nnpm test\n```\n\nThen reload."
    XCTAssertEqual(SpokenText.speakable(text), "Run this:\n\nThen reload.")
  }

  func testHeadingsAndListItemsBecomeSentences() {
    let text = "## Steps\n\n- open Settings\n- choose Sound\n1. pick Glass"
    XCTAssertEqual(SpokenText.speakable(text), "Steps.\n\nOpen Settings.\nChoose Sound.\nPick Glass.")
  }

  func testAPointTagAndEmojiAreNotRead() {
    XCTAssertEqual(SpokenText.speakable("It is here 👉 the Share button.\n<point x=\"859\" y=\"106\"/>"),
                   "It is here the Share button.")
  }

  func testATableIsReadRowByRow() {
    let text = "| Name | Size |\n|---|---|\n| a.txt | 2 KB |"
    XCTAssertEqual(SpokenText.speakable(text), "Name, Size.\na.txt, 2 KB.")
  }

  func testAPictureIsSaidByItsDescription() {
    XCTAssertEqual(SpokenText.speakable("![a red square](/tmp/x.png)"), "a red square")
  }

  func testUkrainianSurvives() {
    XCTAssertEqual(SpokenText.speakable("Натисни **Зберегти**."), "Натисни Зберегти.")
  }
}

final class SentenceChunkerTests: XCTestCase {
  func testWholeSentencesComeOutAsTheyClose() {
    var chunker = SentenceChunker()
    XCTAssertEqual(chunker.append("Click the Share"), [])
    XCTAssertEqual(chunker.append(" button. Then pick"), ["Click the Share button."])
    XCTAssertEqual(chunker.append(" Mail!"), [])
    XCTAssertEqual(chunker.finish(), ["Then pick Mail!"])
  }

  func testAPointInsideANumberOrAnAbbreviationDoesNotEndASentence() {
    var chunker = SentenceChunker()
    XCTAssertEqual(chunker.append("Version 3.5 is out, e.g. on macOS 27. Next one "),
                   ["Version 3.5 is out, e.g. on macOS 27."])
    XCTAssertEqual(chunker.finish(), ["Next one"])
  }

  func testALineBreakEndsAPiece() {
    var chunker = SentenceChunker()
    XCTAssertEqual(chunker.append("Steps:\nOpen Settings\n"), ["Steps:", "Open Settings"])
  }

  func testAnEllipsisAndQuotesStayWithTheirSentence() {
    var chunker = SentenceChunker()
    XCTAssertEqual(chunker.append("Wait… “Done.” Next"), ["Wait…", "“Done.”"])
    XCTAssertEqual(chunker.finish(), ["Next"])
  }

  func testUkrainianAbbreviations() {
    var chunker = SentenceChunker()
    XCTAssertEqual(chunker.append("Файли, папки тощо, напр. звіти. Далі "), ["Файли, папки тощо, напр. звіти."])
  }

  func testNothingButSpaceIsNotASentence() {
    var chunker = SentenceChunker()
    XCTAssertEqual(chunker.append("\n\n  \n"), [])
    XCTAssertEqual(chunker.finish(), [])
  }

  func testAVeryLongRunWithoutAStopIsCutAtASpace() {
    var chunker = SentenceChunker()
    let words = Array(repeating: "word", count: 120).joined(separator: " ")
    let pieces = chunker.append(words + " ")
    XCTAssertFalse(pieces.isEmpty)
    XCTAssertTrue(pieces.allSatisfy { $0.count <= SentenceChunker.longestPiece })
  }
}

final class SpeechVoiceTests: XCTestCase {
  private let voices = [
    SpeechVoice(id: "karen", name: "Karen", language: "en-AU", quality: .standard),
    SpeechVoice(id: "samantha", name: "Samantha", language: "en-US", quality: .standard),
    SpeechVoice(id: "damon", name: "Voice 3", language: "en-US", quality: .enhanced),
    SpeechVoice(id: "lesya", name: "Lesya", language: "uk-UA", quality: .standard),
  ]

  func testTheBestVoiceForALanguageIsTheHighestQuality() {
    XCTAssertEqual(SpeechVoice.choose(language: "en", among: voices, chosen: nil, region: "AU")?.id, "damon")
  }

  func testAmongEqualsThePersonsRegionWins() {
    let plain = voices.filter { $0.quality == .standard }
    XCTAssertEqual(SpeechVoice.choose(language: "en", among: plain, chosen: nil, region: "AU")?.id, "karen")
    XCTAssertEqual(SpeechVoice.choose(language: "en", among: plain, chosen: nil, region: "US")?.id, "samantha")
  }

  func testAChosenVoiceWinsOnlyForItsOwnLanguageAndWhileItIsInstalled() {
    XCTAssertEqual(SpeechVoice.choose(language: "en", among: voices, chosen: "karen", region: nil)?.id, "karen")
    XCTAssertEqual(SpeechVoice.choose(language: "uk", among: voices, chosen: "karen", region: nil)?.id, "lesya")
    XCTAssertEqual(SpeechVoice.choose(language: "en", among: voices, chosen: "gone", region: nil)?.id, "damon")
  }

  func testALanguageWithNoVoiceHasNone() {
    XCTAssertNil(SpeechVoice.choose(language: "ja", among: voices, chosen: nil, region: nil))
  }

  func testTheLanguageOfAnAnswerIsRecognised() {
    XCTAssertEqual(SpeechOutput.language(of: "Натисни кнопку «Поділитися» у верхньому правому куті."), "uk")
    XCTAssertEqual(SpeechOutput.language(of: "Click the Share button in the top right corner."), "en")
  }
}
