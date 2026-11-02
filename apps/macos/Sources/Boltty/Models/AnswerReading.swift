import Foundation

/// When a finished turn is read aloud, and how much of it: the start of its
/// last reply, as the person would hear a colleague say "done, and here is
/// what happened" — not the whole answer, which is on the screen.
enum AnswerReading: String, CaseIterable, Sendable {
  case off = ""
  /// Only turns the person asked for by voice.
  case askedByVoice = "voice"
  case always

  /// At most this many sentences are said.
  static let sentences = 3

  func reads(askedByVoice spoken: Bool) -> Bool {
    switch self {
    case .off: false
    case .askedByVoice: spoken
    case .always: true
    }
  }

  /// The turn's last reply with words of its own: the last agent message
  /// after the person's last message. Tool rows and failures are not words.
  static func reply(in messages: [ConversationMessage]) -> ConversationMessage? {
    let start = (messages.lastIndex { $0.role == .user } ?? -1) + 1
    let turn: ArraySlice<ConversationMessage> = messages[start...]
    return turn.last { $0.role == .agent && !$0.copyableText.isEmpty }
  }

  /// What is said of a reply: its first sentences, as speech (code, tables
  /// and marks left to the screen). `nil` when nothing would be said.
  static func excerpt(of markdown: String) -> String? {
    let text = SpokenText.speakable(markdown)
    var chunker = SentenceChunker()
    let pieces = chunker.append(text + "\n") + chunker.finish()
    let said = pieces.prefix(sentences).joined(separator: " ")
    return said.isEmpty ? nil : said
  }
}
