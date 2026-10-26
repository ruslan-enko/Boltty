import Foundation
import NaturalLanguage

/// Two recognizers hear the same audio, one per language, and this decides
/// whose words each stretch of it gets (Settings › Voice › Second language).
///
/// Apple's speech API takes one locale per recognizer and has no language
/// detection (read off the macOS 27 SDK's `Speech.swiftinterface`;
/// `selectedLocales` is plural and nothing can set two). So a second language
/// is a second recognizer. What the two do on the same audio was measured
/// with `say`'s English, Ukrainian and Turkish voices:
///
/// - **A recognizer in the wrong language says nothing, or something
///   confidently small.** English speech through Ukrainian gave nothing or one
///   word; Ukrainian speech through English gave "With Alaska, with cravic, no,
///   no" at 0.14 confidence, against 0.95–0.98 for English in English.
/// - **Confidence arrives on final results only.** Every volatile result,
///   whichever model, carries none, so while a phrase is being said there is
///   nothing to choose by.
/// - **Not every model reports it at all.** The new `SpeechTranscriber` does
///   (English); the older `DictationTranscriber` does for Turkish and not for
///   Ukrainian.
/// - **A finished phrase is a segment with a time range**, on one clock for
///   both recognizers because both are fed the same buffers. The ranges do
///   not agree: Ukrainian's ran 1.8 s past the speech, English's stopped
///   with it. `resultsFinalizationTime` is the end of the last final and does
///   not grow with silence, so "the recognizer has caught up to here" cannot
///   be waited for — a phrase would stay open to the end of the take.
///
/// So the choice is made **per finished phrase**, never per word, as soon as
/// there is something to choose between. What cannot wait for the other
/// recognizer is shown; what could still lose to it is held back
/// (`provisional`). While a phrase is still being said, the words are the
/// leading recognizer's: the primary language's, unless the secondary has
/// written clearly more (`switchMargin`) — what a wrong language lacks is the
/// only thing that tells it apart before the confidence exists.
struct BilingualTranscript {
  enum Side: Sendable {
    case primary
    case secondary

    var other: Side { self == .primary ? .secondary : .primary }
  }

  /// What a recognizer said about one stretch of audio, in seconds on the
  /// take's clock.
  struct Piece: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    /// `nil` where the model reports none.
    var confidence: Double?
  }

  /// What a model that reports no confidence is taken to have when its words
  /// are in its own language: between what a wrong-language recognizer scored
  /// (0.08–0.52 in the measurement) and a right one (0.80–0.99), so a
  /// recognizer that does report wins over it only by being sure.
  static let unreportedConfidence = 0.6
  /// A phrase only one recognizer wrote is kept above this: below it, it was
  /// noise or the wrong language with nobody to say so.
  static let loneFloor = 0.3
  /// How many more characters the other recognizer must have written to take
  /// the live words from the leader.
  static let switchMargin = 8

  private struct Stream {
    var language: NLLanguage
    var finals: [Piece] = []
    var tail: Piece?
    var finalizedThrough = 0.0
    var ended = false
  }

  private struct Group {
    var members: [(side: Side, piece: Piece)] = []
    var end: Double = 0
  }

  private var primary: Stream
  private var secondary: Stream
  private var leader: Side = .primary
  /// The finished phrases that are written down, in order, and how far into
  /// the audio they reach. Worked out when a final arrives, not on every
  /// volatile result: the words being said do not change them.
  private var decided: [(side: Side, text: String)] = []
  private var decidedThrough = 0.0

  init(primary: Locale, secondary: Locale) {
    self.primary = Stream(language: Self.language(of: primary))
    self.secondary = Stream(language: Self.language(of: secondary))
  }

  /// Both recognizers have said everything they will.
  var isComplete: Bool { primary.ended && secondary.ended }

  mutating func add(
    _ piece: Piece,
    isFinal: Bool,
    finalizedThrough: Double,
    to side: Side
  ) {
    update(side) { stream in
      stream.finalizedThrough = max(stream.finalizedThrough, finalizedThrough)
      if isFinal {
        // The volatile words this covers are in the final now.
        if let tail = stream.tail, tail.start < piece.end - 0.01 { stream.tail = nil }
        if !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          stream.finals.append(piece)
        }
      } else {
        stream.tail = piece.text.isEmpty ? nil : piece
      }
    }
    if isFinal { decide() }
    updateLeader()
  }

  /// A recognizer has finished: nothing more will come from it, so nothing is
  /// held back for it.
  mutating func end(_ side: Side) {
    update(side) {
      $0.ended = true
      $0.tail = nil
    }
    decide()
    updateLeader()
  }

  /// The words to show: every finished phrase in the voice that won it, then
  /// what is still being said in the leader's.
  var text: String {
    var output = Output()
    for phrase in decided {
      output.append(phrase.text, from: phrase.side)
    }
    if let tail = visibleTail(of: leader) {
      output.append(tail.text, from: leader)
    }
    // A later phrase comes with the space that parted it from the one before;
    // when that one was the other voice's and lost, it is a space at the start.
    return String(output.text.drop(while: \.isWhitespace))
  }

  // MARK: - Choosing

  private mutating func decide() {
    decided = []
    decidedThrough = 0
    for group in groups() {
      guard let winner = winner(of: group) else { continue }
      decided.append(winner)
      decidedThrough = max(decidedThrough, group.end)
    }
  }

  /// The finished phrases, those of the two recognizers that overlap in time
  /// being one group: the same audio, heard twice.
  private func groups() -> [Group] {
    let members = (primary.finals.map { (Side.primary, $0) } + secondary.finals.map { (Side.secondary, $0) })
      .sorted { $0.1.start < $1.1.start }

    var groups: [Group] = []
    for (side, piece) in members {
      if var last = groups.last, piece.start < last.end - 0.05 {
        last.members.append((side, piece))
        last.end = max(last.end, piece.end)
        groups[groups.count - 1] = last
      } else {
        groups.append(Group(members: [(side, piece)], end: piece.end))
      }
    }
    return groups
  }

  private func winner(of group: Group) -> (side: Side, text: String)? {
    let ours = Self.words(of: .primary, in: group)
    let theirs = Self.words(of: .secondary, in: group)

    switch (ours.isEmpty, theirs.isEmpty) {
    case (true, true):
      return nil
    case (false, true):
      return keeps(ours, side: .primary, in: group) ? (.primary, ours.text) : nil
    case (true, false):
      return keeps(theirs, side: .secondary, in: group) ? (.secondary, theirs.text) : nil
    case (false, false):
      // A tie is the primary language's: it is the one the person chose first.
      let primaryWins = score(of: ours, side: .primary) >= score(of: theirs, side: .secondary)
      return primaryWins ? (.primary, ours.text) : (.secondary, theirs.text)
    }
  }

  /// Whether words only one recognizer wrote are written down. Noise is not;
  /// and a guess that the other recognizer could still beat is held until it
  /// has caught up to the phrase (or finished), so it is not shown only to be
  /// taken back a second later.
  private func keeps(_ words: Words, side: Side, in group: Group) -> Bool {
    let score = score(of: words, side: side)
    guard score >= Self.loneFloor else { return false }
    let canStillLose = words.confidence != nil && score < Self.unreportedConfidence
    guard canStillLose else { return true }
    let other = stream(side.other)
    return other.ended || other.finalizedThrough >= group.end - 0.001
  }

  private struct Words {
    var text = ""
    /// Mean of the confidences the model reported, by characters; `nil` where
    /// it reported none.
    var confidence: Double?
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  private static func words(of side: Side, in group: Group) -> Words {
    var words = Words()
    var weighted = 0.0
    var weight = 0.0
    for member in group.members where member.side == side {
      words.text += member.piece.text
      if let confidence = member.piece.confidence {
        let count = Double(max(1, member.piece.text.count))
        weighted += confidence * count
        weight += count
      }
    }
    if weight > 0 { words.confidence = weighted / weight }
    return words
  }

  /// A reporting model is as sure as it says. One that reports nothing is as
  /// sure as `unreportedConfidence`, scaled by how much its words read as its
  /// own language — Latin letters out of a Ukrainian model are not Ukrainian.
  private func score(of words: Words, side: Side) -> Double {
    if let confidence = words.confidence { return confidence }
    return Self.unreportedConfidence * fit(words.text, side: side)
  }

  /// How much of the language guess for `text`, held between the two
  /// languages, goes to `side`'s own.
  private func fit(_ text: String, side: Side) -> Double {
    let own = stream(side).language
    let other = stream(side.other).language
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = [own, other]
    recognizer.processString(text)
    return recognizer.languageHypotheses(withMaximum: 2)[own] ?? 0
  }

  // MARK: - Words still being said

  /// What a recognizer is still saying, if it reaches past what is already
  /// written down: the other one's final may have settled this audio while
  /// this one has not caught up, and its words would be said twice.
  private func visibleTail(of side: Side) -> Piece? {
    guard let tail = stream(side).tail, tail.end > decidedThrough + 0.05 else { return nil }
    return tail
  }

  private mutating func updateLeader() {
    let ours = Self.weight(visibleTail(of: .primary)?.text ?? "")
    let theirs = Self.weight(visibleTail(of: .secondary)?.text ?? "")
    switch leader {
    case .primary:
      if theirs >= ours + Self.switchMargin { leader = .secondary }
    case .secondary:
      if ours >= theirs + Self.switchMargin { leader = .primary }
    }
  }

  private static func weight(_ text: String) -> Int {
    text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
  }

  // MARK: - Plumbing

  private func stream(_ side: Side) -> Stream {
    side == .primary ? primary : secondary
  }

  private mutating func update(_ side: Side, _ change: (inout Stream) -> Void) {
    switch side {
    case .primary: change(&primary)
    case .secondary: change(&secondary)
    }
  }

  /// The words of two voices put together: a seam between them gets a space
  /// when neither side brought one.
  private struct Output {
    var text = ""
    private var lastSide: Side?

    mutating func append(_ words: String, from side: Side) {
      guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      var words = words
      if let lastSide, lastSide != side,
         let before = text.last, !before.isWhitespace,
         let after = words.first, !after.isWhitespace {
        words = " " + words
      }
      text += words
      lastSide = side
    }
  }

  /// `NLLanguage` for a locale: the language alone, and Chinese by script.
  private static func language(of locale: Locale) -> NLLanguage {
    let language = locale.language
    guard let code = language.languageCode?.identifier else { return .undetermined }
    if code == "zh" {
      return NLLanguage("zh-\(language.script?.identifier ?? "Hans")")
    }
    return NLLanguage(code)
  }
}
