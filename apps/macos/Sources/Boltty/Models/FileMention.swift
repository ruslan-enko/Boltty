import Foundation

/// Files for `@` in the composer: a file to bring with the words, chosen from
/// a list and then made a card.
enum FileMention {
  struct Candidate: Equatable, Sendable {
    let url: URL
    let isDirectory: Bool
    /// The path under the searched folder, or the whole path when it is not under it.
    let relativePath: String
    let modified: Date?
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
