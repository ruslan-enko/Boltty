import Foundation

enum SupertonicText {
  static let languages: Set<String> = [
    "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi",
    "fr", "hi", "hr", "hu", "id", "it", "lt", "lv", "nl", "pl", "pt", "ro",
    "ru", "sk", "sl", "sv", "tr", "uk", "vi",
  ]

  static let window = 128

  /// Characters per pass. The window would hold ~110, but quality falls off
  /// toward its end (FluidAudio measured 17.6 % WER at 105 characters, 0 % at
  /// 71), so passes stay in the clean range. Korean and Japanese decompose to
  /// more scalars per character.
  static func passLength(for language: String) -> Int {
    language == "ko" || language == "ja" ? 57 : 70
  }

  static let cyrillic: Set<String> = ["uk", "ru", "bg"]

  struct Run: Equatable {
    var text: String
    var language: String
  }

  static func runs(_ text: String, language: String) -> [Run] {
    guard cyrillic.contains(language) else { return [Run(text: text, language: language)] }
    var runs: [Run] = []
    var current = ""
    var currentLanguage = language
    for character in text {
      let script: String? = if character.isLetter {
        isLatin(character) ? "en" : language
      } else {
        nil
      }
      if let script, script != currentLanguage, !current.isEmpty {
        runs.append(Run(text: current, language: currentLanguage))
        current = ""
      }
      if let script { currentLanguage = script }
      current.append(character)
    }
    if !current.isEmpty { runs.append(Run(text: current, language: currentLanguage)) }
    return merged(runs, into: language)
  }

  static func tagged(_ text: String, language: String, last: Bool) -> String {
    var body = clean(text)
    guard !body.isEmpty else { return "" }
    if last {
      body = terminated(body)
    } else if terminated(body) != body {
      body += ","
    }
    return "<\(language)>\(body)</\(language)>"
  }

  static func encode(_ tagged: String, indexer: [Int32]) -> (ids: [Int32], mask: [Float]) {
    var ids = [Int32](repeating: 0, count: window)
    var mask = [Float](repeating: 0, count: window)
    for (index, scalar) in tagged.unicodeScalars.prefix(window).enumerated() {
      let value = Int(scalar.value)
      ids[index] = value < indexer.count ? indexer[value] : -1
      mask[index] = 1
    }
    return (ids, mask)
  }

  // MARK: - Cleaning (from the reference)

  static func clean(_ raw: String) -> String {
    var text = raw.decomposedStringWithCompatibilityMapping
    text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !isEmoji($0.value) }))
    for (old, new) in symbolReplacements { text = text.replacingOccurrences(of: old, with: new) }
    for symbol in decorativeSymbols { text = text.replacingOccurrences(of: symbol, with: "") }
    for (old, new) in expressionReplacements { text = text.replacingOccurrences(of: old, with: new) }
    for old in [" ,", " .", " !", " ?", " ;", " :", " '"] {
      text = text.replacingOccurrences(of: old, with: String(old.dropFirst()))
    }
    for (twice, once) in [("\"\"", "\""), ("''", "'"), ("``", "`")] {
      while text.contains(twice) { text = text.replacingOccurrences(of: twice, with: once) }
    }
    text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The reference ends every utterance on punctuation; without it the last
  /// word trails off.
  static func terminated(_ text: String) -> String {
    guard let last = text.unicodeScalars.last else { return text }
    let closing: Set<Unicode.Scalar> = [
      ".", "!", "?", ";", ":", ",", "'", "\"", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",
      ")", "]", "}", "…", "。", "」", "』", "】", "〉", "》", "›", "»",
    ]
    return closing.contains(last) ? text : text + "."
  }

  // MARK: - Chunking (from the reference)

  static func passes(_ piece: String, limit: Int) -> [String] {
    let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    guard trimmed.count > limit else { return [trimmed] }
    var passes: [String] = []
    var current = ""
    for sentence in sentences(trimmed) {
      if sentence.count > limit {
        flush(&current, into: &passes)
        packCommas(sentence, limit: limit, into: &passes)
        continue
      }
      if !current.isEmpty, current.count + sentence.count + 1 > limit {
        passes.append(current)
        current = ""
      }
      current = current.isEmpty ? sentence : "\(current) \(sentence)"
    }
    flush(&current, into: &passes)
    return passes
  }

  private static func sentences(_ text: String) -> [String] {
    var sentences: [String] = []
    var current = ""
    var characters = Array(text)[...]
    while let character = characters.popFirst() {
      current.append(character)
      if ".!?".contains(character), characters.first?.isWhitespace ?? false {
        let word = current.split(separator: " ").last.map(String.init) ?? ""
        if !abbreviations.contains(word) {
          sentences.append(current.trimmingCharacters(in: .whitespaces))
          current = ""
        }
      }
    }
    let rest = current.trimmingCharacters(in: .whitespaces)
    if !rest.isEmpty { sentences.append(rest) }
    return sentences
  }

  private static func packCommas(_ sentence: String, limit: Int, into passes: inout [String]) {
    var current = ""
    for raw in sentence.components(separatedBy: ",") {
      let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if part.isEmpty { continue }
      if part.count > limit {
        flush(&current, into: &passes)
        packWords(part, limit: limit, into: &passes)
        continue
      }
      if !current.isEmpty, current.count + part.count + 2 > limit {
        passes.append(current + ",")
        current = ""
      }
      current = current.isEmpty ? part : "\(current), \(part)"
    }
    flush(&current, into: &passes)
  }

  private static func packWords(_ phrase: String, limit: Int, into passes: inout [String]) {
    var current = ""
    for word in phrase.split(whereSeparator: \.isWhitespace) {
      if !current.isEmpty, current.count + word.count + 1 > limit {
        passes.append(current)
        current = ""
      }
      current = current.isEmpty ? String(word) : "\(current) \(word)"
    }
    flush(&current, into: &passes)
  }

  private static func flush(_ buffer: inout String, into passes: inout [String]) {
    let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { passes.append(trimmed) }
    buffer = ""
  }

  // MARK: - Scripts

  private static func isLatin(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: true
      default: !scalar.properties.isAlphabetic
      }
    }
  }

  private static func merged(_ runs: [Run], into language: String) -> [Run] {
    var out: [Run] = []
    for run in runs {
      if let last = out.last, last.language == run.language || !run.text.contains(where: \.isLetter) {
        out[out.count - 1].text += run.text
      } else {
        out.append(run)
      }
    }
    return out
  }

  // MARK: - Tables (from the reference)

  private static let abbreviations: Set<String> = [
    "Dr.", "Mr.", "Mrs.", "Ms.", "Prof.", "Sr.", "Jr.", "St.", "Ave.", "Rd.", "Blvd.", "Dept.",
    "Inc.", "Ltd.", "Co.", "Corp.", "etc.", "vs.", "i.e.", "e.g.", "Ph.D.",
  ]

  private static let symbolReplacements: KeyValuePairs<String, String> = [
    "\u{2013}": "-", "\u{2011}": "-", "\u{2014}": "-", "_": " ",
    "\u{201C}": "\"", "\u{201D}": "\"", "\u{2018}": "'", "\u{2019}": "'", "\u{00B4}": "'",
    "`": "'", "[": " ", "]": " ", "|": " ", "/": " ", "#": " ", "\u{2192}": " ", "\u{2190}": " ",
  ]

  private static let decorativeSymbols = ["\u{2665}", "\u{2606}", "\u{2661}", "\u{00A9}", "\\"]

  private static let expressionReplacements: KeyValuePairs<String, String> = [
    "@": " at ", "e.g.,": "for example, ", "i.e.,": "that is, ",
  ]

  private static func isEmoji(_ value: UInt32) -> Bool {
    switch value {
    case 0x1F300...0x1FAFF, 0x2600...0x27BF, 0x1F1E6...0x1F1FF: true
    default: false
    }
  }
}
