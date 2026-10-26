import XCTest

@testable import Boltty

/// The timelines are the ones measured with `say`'s voices (see `BilingualTranscript`):
/// English in `SpeechTranscriber`, which reports confidence on a final result,
/// Ukrainian in `DictationTranscriber`, which reports none.
final class BilingualTranscriptTests: XCTestCase {
  private func makeTranscript() -> BilingualTranscript {
    BilingualTranscript(primary: Locale(identifier: "uk-UA"), secondary: Locale(identifier: "en-US"))
  }

  private func piece(
    _ start: Double, _ end: Double, _ text: String, _ confidence: Double? = nil
  ) -> BilingualTranscript.Piece {
    BilingualTranscript.Piece(start: start, end: end, text: text, confidence: confidence)
  }

  func testAPhraseInThePrimaryLanguageKeepsItsWordsOverTheOthersGuess() {
    var transcript = makeTranscript()
    transcript.add(piece(0, 6.1, "With Alaska, with cravic, no, no, no.", 0.14),
                   isFinal: true, finalizedThrough: 6.3, to: .secondary)
    transcript.add(piece(0, 6.1, "Будь ласка відкрий вікно налаштувань", nil),
                   isFinal: true, finalizedThrough: 7.9, to: .primary)

    XCTAssertEqual(transcript.text, "Будь ласка відкрий вікно налаштувань")
  }

  func testAPhraseInTheSecondLanguageWinsOnItsConfidence() {
    var transcript = makeTranscript()
    transcript.add(piece(8, 11.9, " Please open the settings window", 0.97),
                   isFinal: true, finalizedThrough: 11.9, to: .secondary)
    transcript.add(piece(8, 11.9, " Open", nil),
                   isFinal: true, finalizedThrough: 11.9, to: .primary)

    XCTAssertEqual(transcript.text, "Please open the settings window")
  }

  func testAShortSecondLanguagePhraseBeatsTheTransliteration() {
    var transcript = makeTranscript()
    transcript.add(piece(0.1, 1.5, "Okay, thanks.", 0.80),
                   isFinal: true, finalizedThrough: 1.5, to: .secondary)
    transcript.add(piece(0, 1.5, "Окей", nil),
                   isFinal: true, finalizedThrough: 1.5, to: .primary)

    XCTAssertEqual(transcript.text, "Okay, thanks.")
  }

  func testAnUnsureSecondLanguageLosesToWordsThatFitThePrimary() {
    var transcript = makeTranscript()
    transcript.add(piece(0.1, 1.6, "Harassed, Diakoyo.", 0.46),
                   isFinal: true, finalizedThrough: 1.6, to: .secondary)
    transcript.add(piece(0, 1.6, "Гаразд дякую", nil),
                   isFinal: true, finalizedThrough: 1.6, to: .primary)

    XCTAssertEqual(transcript.text, "Гаразд дякую")
  }

  func testEachPhraseOfATakeGoesToItsOwnLanguage() {
    var transcript = makeTranscript()
    // Ukrainian, English, Ukrainian, as the two recognizers wrote them.
    transcript.add(piece(0, 6.3, "With Alaska, with cravic, no, no.", 0.15),
                   isFinal: true, finalizedThrough: 6.3, to: .secondary)
    transcript.add(piece(0, 7.9, "Будь ласка відкрий вікно", nil),
                   isFinal: true, finalizedThrough: 7.9, to: .primary)
    transcript.add(piece(8, 11.9, " Please open the settings window.", 0.95),
                   isFinal: true, finalizedThrough: 11.9, to: .secondary)
    transcript.add(piece(14.2, 18.1, " Do they novuk nubko do panelitaza.", 0.11),
                   isFinal: true, finalizedThrough: 18.1, to: .secondary)
    transcript.add(piece(14.4, 18.1, " додай нову кнопку до панелі", nil),
                   isFinal: true, finalizedThrough: 18.1, to: .primary)
    transcript.end(.primary)
    transcript.end(.secondary)

    XCTAssertTrue(transcript.isComplete)
    XCTAssertEqual(
      transcript.text,
      "Будь ласка відкрий вікно Please open the settings window. додай нову кнопку до панелі",
      "each phrase keeps the space it came with; two voices meeting are given one"
    )
  }

  func testNoiseOnlyOneRecognizerHeardIsDropped() {
    var transcript = makeTranscript()
    transcript.add(piece(4.1, 4.9, ".", 0.52),
                   isFinal: true, finalizedThrough: 4.9, to: .secondary)
    transcript.add(piece(0, 4.9, "Привіт", nil),
                   isFinal: true, finalizedThrough: 4.9, to: .primary)
    transcript.add(piece(10, 11, "mm", 0.2),
                   isFinal: true, finalizedThrough: 11, to: .secondary)
    transcript.add(piece(11, 12, " ще", nil),
                   isFinal: true, finalizedThrough: 12, to: .primary)

    XCTAssertEqual(transcript.text, "Привіт ще")
  }

  func testLiveWordsAreThePrimaryLanguagesUntilTheOtherIsClearlyAhead() {
    var transcript = makeTranscript()
    transcript.add(piece(0, 1, "Будь"), isFinal: false, finalizedThrough: 0, to: .primary)
    transcript.add(piece(0, 1, "Al"), isFinal: false, finalizedThrough: 0, to: .secondary)
    XCTAssertEqual(transcript.text, "Будь")

    transcript.add(piece(0, 2, "Alaska with c ev"), isFinal: false, finalizedThrough: 0, to: .secondary)
    XCTAssertEqual(transcript.text, "Alaska with c ev", "the other one has written clearly more")

    transcript.add(piece(0, 4, "Будь ласка відкрий вікно налаштувань і"),
                   isFinal: false, finalizedThrough: 0, to: .primary)
    XCTAssertEqual(transcript.text, "Будь ласка відкрий вікно налаштувань і")
  }

  func testAGuessTheOtherRecognizerCouldStillBeatIsHeldBack() {
    var transcript = makeTranscript()
    transcript.add(piece(0, 6.3, "With Alaska, with cravic, no, no.", 0.45),
                   isFinal: true, finalizedThrough: 6.3, to: .secondary)

    XCTAssertEqual(transcript.text, "", "the Ukrainian one has not finished this stretch")

    transcript.add(piece(0, 7.9, "Будь ласка відкрий вікно", nil),
                   isFinal: true, finalizedThrough: 7.9, to: .primary)
    XCTAssertEqual(transcript.text, "Будь ласка відкрий вікно")
  }

  func testAGuessIsShownOnceTheOtherRecognizerHasPassedItWithNothing() {
    var transcript = makeTranscript()
    transcript.add(piece(8, 11.9, " Please open the settings", 0.45),
                   isFinal: true, finalizedThrough: 11.9, to: .secondary)
    XCTAssertEqual(transcript.text, "")

    // The Ukrainian one finalizes a later phrase, so it has been past this one
    // and wrote nothing for it.
    transcript.add(piece(14.4, 18.1, " додай кнопку", nil),
                   isFinal: true, finalizedThrough: 18.1, to: .primary)
    XCTAssertEqual(transcript.text, "Please open the settings додай кнопку")
  }

  func testASureLonePhraseIsShownAtOnce() {
    var transcript = makeTranscript()
    transcript.add(piece(8, 11.9, " Please open the settings window", 0.97),
                   isFinal: true, finalizedThrough: 11.9, to: .secondary)

    XCTAssertEqual(transcript.text, "Please open the settings window")
  }

  func testAFinalReplacesTheVolatileWordsItCovers() {
    var transcript = makeTranscript()
    transcript.add(piece(0, 4, "Будь ласка відкр"), isFinal: false, finalizedThrough: 0, to: .primary)
    XCTAssertEqual(transcript.text, "Будь ласка відкр")

    transcript.add(piece(0, 4, "Будь ласка відкрий", nil),
                   isFinal: true, finalizedThrough: 4, to: .primary)
    XCTAssertEqual(transcript.text, "Будь ласка відкрий")
  }

  func testWhenOneRecognizerEndsNothingIsWaitedFromIt() {
    var transcript = makeTranscript()
    transcript.add(piece(0, 4, "Привіт, світе", nil),
                   isFinal: true, finalizedThrough: 4, to: .primary)
    transcript.end(.secondary)
    XCTAssertFalse(transcript.isComplete)

    transcript.end(.primary)
    XCTAssertTrue(transcript.isComplete)
    XCTAssertEqual(transcript.text, "Привіт, світе")
  }

  func testTwoModelsThatBothReportGoByTheHigherConfidence() {
    var transcript = BilingualTranscript(
      primary: Locale(identifier: "tr-TR"), secondary: Locale(identifier: "en-US")
    )
    transcript.add(piece(0, 4, "Please Open the Carling Woven Fix'te", 0.08),
                   isFinal: true, finalizedThrough: 4, to: .secondary)
    transcript.add(piece(0, 4, "Lütfen ayarlar penceresini aç", 0.87),
                   isFinal: true, finalizedThrough: 4.9, to: .primary)

    XCTAssertEqual(transcript.text, "Lütfen ayarlar penceresini aç")
  }
}
