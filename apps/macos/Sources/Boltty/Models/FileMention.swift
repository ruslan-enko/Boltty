import Foundation

/// `@` in the composer, followed by what is typed after it: a file to bring
/// with the words, chosen from a list and then made a card.
enum FileMention {
  struct Token: Equatable {
    /// The `@` and the query after it, in the field's UTF-16 units.
    let range: NSRange
    let query: String
  }

  struct Candidate: Equatable, Sendable {
    let url: URL
    let isDirectory: Bool
    /// The path under the searched folder, or the whole path when it is not under it.
    let relativePath: String
    let modified: Date?
  }

  static let queryLimit = 80

  /// The `@` word the caret stands in. An `@` inside a word (`me@site.com`)
  /// starts nothing.
  static func token(in text: String, caret: Int) -> Token? {
    let string = text as NSString
    guard caret >= 1, caret <= string.length else { return nil }
    var index = caret - 1
    while index >= 0 {
      let unit = string.character(at: index)
      if unit == 0x40 {
        if index > 0, let before = UnicodeScalar(string.character(at: index - 1)),
           !CharacterSet.whitespacesAndNewlines.contains(before) {
          return nil
        }
        let range = NSRange(location: index, length: caret - index)
        let query = string.substring(with: NSRange(location: index + 1, length: caret - index - 1))
        guard query.count <= queryLimit else { return nil }
        return Token(range: range, query: query)
      }
      if let scalar = UnicodeScalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) {
        return nil
      }
      index -= 1
    }
    return nil
  }

  /// Best first: the name starting with the query, then holding it, then the
  /// path holding it, then its letters in order. Shallow and recent break ties.
  static func rank(_ candidates: [Candidate], query: String, limit: Int) -> [Candidate] {
    let needle = query.lowercased()
    guard !needle.isEmpty else {
      return Array(
        candidates
          .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
          .prefix(limit))
    }
    var scored: [(Candidate, Double)] = []
    scored.reserveCapacity(64)
    for candidate in candidates {
      guard let score = score(candidate, needle: needle) else { continue }
      scored.append((candidate, score))
    }
    scored.sort { lhs, rhs in
      if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
      return (lhs.0.modified ?? .distantPast) > (rhs.0.modified ?? .distantPast)
    }
    return scored.prefix(limit).map(\.0)
  }

  static func score(_ candidate: Candidate, needle: String) -> Double? {
    let name = candidate.url.lastPathComponent.lowercased()
    let path = candidate.relativePath.lowercased()
    let base: Double
    if name == needle {
      base = 1200
    } else if name.hasPrefix(needle) {
      base = 1000
    } else if name.contains(needle) {
      base = 700
    } else if path.contains(needle) {
      base = 400
    } else if isSubsequence(needle, of: name) {
      base = 200
    } else if isSubsequence(needle, of: path) {
      base = 60
    } else {
      return nil
    }
    let depth = Double(path.reduce(0) { $1 == "/" ? $0 + 1 : $0 })
    return base - depth * 8 - Double(path.count) * 0.2
  }

  static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
    var rest = needle.makeIterator()
    guard var wanted = rest.next() else { return true }
    for character in haystack where character == wanted {
      guard let next = rest.next() else { return true }
      wanted = next
    }
    return false
  }
}
