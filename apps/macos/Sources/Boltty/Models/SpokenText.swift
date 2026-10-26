import Foundation

/// An answer as it should be heard: markdown's marks gone, code left to the
/// screen, a link said by its words, a list item or a heading a sentence.
enum SpokenText {
  /// `keepingPoints` leaves a marker (`AskBolttyPoint.marker`) where each
  /// mark stood — a `<point …/>`, a shape, a `<board>` — so a piece of the
  /// answer carries what it shows to the moment it is said; otherwise the
  /// marks are dropped.
  static func speakable(_ markdown: String, keepingPoints: Bool = false) -> String {
    var lines: [String] = []
    var inFence = false
    let source = points(in: AskBolttyMark.withoutUnfinished(markdown), keeping: keepingPoints)
    for raw in source.components(separatedBy: .newlines) {
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        continue
      }
      if inFence { continue }
      if let spoken = line(trimmed) { lines.append(spoken) }
    }

    var out: [String] = []
    for line in lines {
      if line.isEmpty, out.last?.isEmpty ?? true { continue }
      out.append(line)
    }
    while out.last?.isEmpty == true { out.removeLast() }
    return out.joined(separator: "\n")
  }

  private static func points(in text: String, keeping: Bool) -> String {
    guard text.contains("<") else { return text }
    var out = ""
    var cursor = text.startIndex
    var index = 0
    while let range = text.range(
      of: AskBolttyMark.pattern, options: .regularExpression, range: cursor..<text.endIndex) {
      out += text[cursor..<range.lowerBound]
      if index < AskBolttyMark.limit, AskBolttyMark.parse(String(text[range])) != nil {
        if keeping { out += " " + AskBolttyPoint.marker(index) }
        index += 1
      }
      cursor = range.upperBound
    }
    return out + text[cursor...]
  }

  /// `nil` for a line that is only markup, such as a table's rule.
  private static func line(_ text: String) -> String? {
    if text.isEmpty { return "" }
    if text.range(of: #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#, options: .regularExpression) != nil {
      return nil
    }
    if text.hasPrefix("|") {
      let cells = text.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
        .components(separatedBy: "|")
        .map { inline($0.trimmingCharacters(in: .whitespaces)) }
        .filter { !$0.isEmpty }
      return sentence(cells.joined(separator: ", "))
    }
    if let heading = text.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
      return sentence(inline(String(text[heading.upperBound...])))
    }
    if let item = text.range(of: #"^([-*+]|\d{1,3}[.)])\s+"#, options: .regularExpression) {
      return sentence(capitalized(inline(String(text[item.upperBound...]))))
    }
    var body = text
    while body.hasPrefix(">") { body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces) }
    return inline(body)
  }

  private static func inline(_ text: String) -> String {
    var s = text
    s = replace(#"!\[([^\]]*)\]\([^)]*\)"#, in: s, with: "$1")
    s = replace(#"\[([^\]]+)\]\([^)]*\)"#, in: s, with: "$1")
    s = replace(#"<?https?://(?:www\.)?([^/\s>]+)[^\s>]*>?"#, in: s, with: "$1")
    s = replace(#"`([^`]*)`"#, in: s, with: "$1")
    s = replace(#"(\*\*|__)(.+?)\1"#, in: s, with: "$2")
    s = replace(#"~~(.+?)~~"#, in: s, with: "$1")
    s = replace(#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, in: s, with: "$1")
    s = replace(#"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#, in: s, with: "$1")
    s = withoutEmoji(s)
    s = replace(#"[ \t]{2,}"#, in: s, with: " ")
    s = replace(#"\s+([.,!?;:])"#, in: s, with: "$1")
    return s.trimmingCharacters(in: .whitespaces)
  }

  private static func withoutEmoji(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      let p = scalar.properties
      let pictograph = p.isEmojiPresentation || (p.isEmoji && scalar.value >= 0x2190)
      if pictograph || scalar.value == 0xFE0F || scalar.value == 0x200D { continue }
      scalars.append(scalar)
    }
    return String(scalars)
  }

  private static func sentence(_ text: String) -> String {
    guard let last = text.last else { return text }
    return ".!?…:;".contains(last) ? text : text + "."
  }

  private static func capitalized(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
  }

  private static func replace(_ pattern: String, in text: String, with template: String) -> String {
    text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
  }
}

/// Cuts text that is still arriving into pieces worth handing to a voice: a
/// sentence once it has closed, a line once it has ended. What is left open
/// waits for more, or for `finish()`.
struct SentenceChunker {
  /// A run with no stop longer than this is cut at a comma or a space, so a
  /// voice never waits on a paragraph.
  static let longestPiece = 220
  private static let abbreviations: Set<String> = [
    "e.g", "i.e", "vs", "cf", "mr", "mrs", "ms", "dr", "fig", "approx", "no",
    "напр", "див", "т.ч", "ім", "англ", "укр",
  ]
  private static let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]"]

  private var buffer = ""

  mutating func append(_ text: String) -> [String] {
    buffer += text
    var pieces: [String] = []
    var chars = Array(buffer)
    var start = 0
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c == "\n" {
        pieces.append(String(chars[start..<i]))
        start = i + 1
      } else if ".!?…".contains(c) {
        var end = i + 1
        while end < chars.count, Self.closers.contains(chars[end]) || ".!?…".contains(chars[end]) { end += 1 }
        guard end < chars.count else { break }
        if chars[end].isWhitespace, !(c == "." && Self.isAbbreviation(chars, dotAt: i)) {
          pieces.append(String(chars[start..<end]))
          start = end
          i = end
          continue
        }
      }
      i += 1
    }
    chars = Array(chars[start...])
    while chars.count > Self.longestPiece {
      let window = chars[..<Self.longestPiece]
      let cut = window.lastIndex(of: ",").map { $0 + 1 }
        ?? window.lastIndex(of: " ")
        ?? Self.longestPiece
      pieces.append(String(chars[..<cut]))
      chars = Array(chars[cut...])
    }
    buffer = String(chars)
    return pieces.compactMap(Self.clean)
  }

  mutating func finish() -> [String] {
    defer { buffer = "" }
    return Self.clean(buffer).map { [$0] } ?? []
  }

  private static func clean(_ piece: String) -> String? {
    let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func isAbbreviation(_ chars: [Character], dotAt index: Int) -> Bool {
    var start = index
    while start > 0, chars[start - 1].isLetter || chars[start - 1] == "." { start -= 1 }
    let word = String(chars[start..<index]).lowercased()
    return abbreviations.contains(word)
  }
}
