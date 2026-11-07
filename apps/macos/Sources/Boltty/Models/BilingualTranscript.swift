import Foundation
import NaturalLanguage

/// Two recognizers hear the same audio, one per language; this decides whose words
/// each stretch gets. Apple's speech API takes one locale per recognizer and has no
/// language detection.
struct BilingualTranscript {
  enum Side: Sendable {
    case primary
    case secondary

    var other: Side { self == .primary ? .secondary : .primary }
  }

  struct Piece: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var confidence: Double?
  }

  static let unreportedConfidence = 0.6
  static let loneFloor = 0.3
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
  private var decided: [(side: Side, text: String)] = []
  private var decidedThrough = 0.0

  init(primary: Locale, secondary: Locale) {
    self.primary = Stream(language: Self.language(of: primary))
    self.secondary = Stream(language: Self.language(of: secondary))
  }

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

  mutating func end(_ side: Side) {
    update(side) {
      $0.ended = true
      $0.tail = nil
    }
    decide()
    updateLeader()
  }

  var text: String {
    var output = Output()
    for phrase in decided {
      output.append(phrase.text, from: phrase.side)
    }
    if let tail = visibleTail(of: leader) {
      output.append(tail.text, from: leader)
    }
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
      let primaryWins = score(of: ours, side: .primary) >= score(of: theirs, side: .secondary)
      return primaryWins ? (.primary, ours.text) : (.secondary, theirs.text)
    }
  }

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

  private func score(of words: Words, side: Side) -> Double {
    if let confidence = words.confidence { return confidence }
    return Self.unreportedConfidence * fit(words.text, side: side)
  }

  private func fit(_ text: String, side: Side) -> Double {
    let own = stream(side).language
    let other = stream(side.other).language
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = [own, other]
    recognizer.processString(text)
    return recognizer.languageHypotheses(withMaximum: 2)[own] ?? 0
  }

  // MARK: - Words still being said

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

  private static func language(of locale: Locale) -> NLLanguage {
    let language = locale.language
    guard let code = language.languageCode?.identifier else { return .undetermined }
    if code == "zh" {
      return NLLanguage("zh-\(language.script?.identifier ?? "Hans")")
    }
    return NLLanguage(code)
  }
}
