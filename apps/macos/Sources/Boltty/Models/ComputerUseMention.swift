import Foundation

enum ComputerUseMention {
  static let word = "@computer"
  static let keywords = ["computer", "use", "apps", "mac", "screen", "click"]

  static func isAsked(in prompt: String) -> Bool {
    prompt.split(whereSeparator: \.isWhitespace).contains { $0.lowercased() == word }
  }

  static func matches(_ query: String) -> Bool {
    let needle = query.lowercased()
    guard !needle.isEmpty else { return true }
    return keywords.contains { $0.hasPrefix(needle) } || "computer use".hasPrefix(needle)
  }
}
