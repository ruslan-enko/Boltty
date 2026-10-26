import Foundation

struct SystemAttentionNotification: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case finished
    case needsYou
  }

  let sessionID: UUID
  let title: String
  let body: String
  var kind: Kind = .finished
}

extension SystemAttentionNotification {
  /// What a chat that has stopped needs of the person, in the words the notch uses.
  /// `nil` is a question: also what is said when the ask is not on record yet.
  static func needsWords(for ask: PendingInteraction.Kind?) -> String {
    switch ask {
    case .permission?, .plan?: "Needs your approval"
    case .question?, nil: "Needs your answer"
    }
  }

  /// A banner says a status and whose it is, never the reply: the title already
  /// names the chat, and a banner is read at a glance. Claude's own say "Claude
  /// finished a task" and cut whatever else they carry at 100 characters.
  static func statusLine(_ status: String, agent: String?) -> String {
    guard let agent, !agent.isEmpty else { return status }
    return "\(status) · \(agent)"
  }
}

enum DisplayTextSanitizer {
  static func sanitize(_ value: String) -> String {
    value
      .unicodeScalars
      .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
      .joined()
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
  }

  static func truncate(_ value: String, limit: Int) -> String {
    let clean = sanitize(value)
    guard clean.count > limit else { return clean }
    return String(clean.prefix(limit)) + "…"
  }
}
