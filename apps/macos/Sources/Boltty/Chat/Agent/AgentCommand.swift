import Foundation

struct AgentCommand: Sendable, Equatable, Hashable {
  let name: String
  let summary: String
  let argumentHint: String?

  var invocation: String { "/" + name }

  static let plan = AgentCommand(
    name: "plan", summary: String(localized: "Plan first, change nothing until you approve"), argumentHint: nil)
}

extension AgentCommand {
  static func rank(_ commands: [AgentCommand], query: String, limit: Int) -> [AgentCommand] {
    let needle = query.lowercased()
    guard !needle.isEmpty else { return Array(commands.prefix(limit)) }
    var scored: [(offset: Int, command: AgentCommand, score: Int)] = []
    for (offset, command) in commands.enumerated() {
      let name = command.name.lowercased()
      let bare = name.split(separator: ":").last.map(String.init) ?? name
      let score: Int
      if name == needle || bare == needle {
        score = 5
      } else if name.hasPrefix(needle) || bare.hasPrefix(needle) {
        score = 4
      } else if name.contains(needle) {
        score = 3
      } else if FileMention.isSubsequence(needle, of: name) {
        score = 2
      } else if command.summary.lowercased().contains(needle) {
        score = 1
      } else {
        continue
      }
      scored.append((offset, command, score))
    }
    scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
    return scored.prefix(limit).map(\.command)
  }
}

extension AgentCommand {
  static func leading(in text: String) -> (name: String, rest: String)? {
    guard text.hasPrefix("/") else { return nil }
    let body = text.dropFirst()
    let end = body.firstIndex(where: \.isWhitespace) ?? body.endIndex
    let name = String(body[..<end])
    guard !name.isEmpty, !name.contains("/") else { return nil }
    let rest = body[end...].drop { $0 == " " || $0 == "\t" || $0 == "\n" }
    return (name, String(rest))
  }
}
