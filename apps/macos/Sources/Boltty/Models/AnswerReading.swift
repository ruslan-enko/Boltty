import Foundation

enum AnswerReading: String, CaseIterable, Sendable {
  case off = ""
  case askedByVoice = "voice"
  case always

  static let sentences = 3

  func reads(askedByVoice spoken: Bool) -> Bool {
    switch self {
    case .off: false
    case .askedByVoice: spoken
    case .always: true
    }
  }

  static func reply(in messages: [ConversationMessage]) -> ConversationMessage? {
    let start = (messages.lastIndex { $0.role == .user } ?? -1) + 1
    let turn: ArraySlice<ConversationMessage> = messages[start...]
    return turn.last { $0.role == .agent && !$0.copyableText.isEmpty }
  }

  static func excerpt(of markdown: String) -> String? {
    let text = SpokenText.speakable(markdown)
    var chunker = SentenceChunker()
    let pieces = chunker.append(text + "\n") + chunker.finish()
    let said = pieces.prefix(sentences).joined(separator: " ")
    return said.isEmpty ? nil : said
  }
}
