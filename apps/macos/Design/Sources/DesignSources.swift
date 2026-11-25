import AppKit

struct DesignValue: Sendable {
  let owner: String
  let name: String
  let expression: String
  let file: URL
  let line: Int
  var mentions = 0

  var isWritten: Bool {
    expression.wholeMatch(of: /-?[0-9][0-9_.]*/) != nil
      || expression.hasPrefix("OKLCH(") || expression.hasPrefix("NSColor") || expression.hasPrefix("CGSize(")
  }
}

enum DesignSources {
  static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/Boltty")

  static var areHere: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("UI").path) }

  static func load() -> [DesignValue] {
    var values: [DesignValue] = []
    var words: [Substring: Int] = [:]
    var kept: [String] = []
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    for file in files {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      kept.append(text)
      if file.path.contains("/UI/"), !file.path.contains("/UI/Design/") {
        values += declarations(in: text, file: file)
      }
    }
    let names = Set(values.map(\.name))
    for text in kept {
      for word in text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
      where names.contains(String(word)) {
        words[word, default: 0] += 1
      }
    }
    return values.map { value in
      var value = value
      value.mentions = max(0, (words[Substring(value.name)] ?? 1) - 1)
      return value
    }
  }

  static func declarations(in text: String, file: URL) -> [DesignValue] {
    var owner = ""
    var values: [DesignValue] = []
    for (index, line) in text.components(separatedBy: "\n").enumerated() {
      if let first = line.utf8.first, first != UInt8(ascii: " "), let match = line.firstMatch(of: /^(?:[a-z@]+ )*(?:enum|struct|class|extension) (\w+)/) {
        owner = String(match.1)
      }
      guard line.contains("static "), let match = line.firstMatch(
        of: /^\s+(?:private |fileprivate )?static (?:let|var) (\w+)(?:: ([\w.]+))? (?:= (.+)|\{ (.+) \})$/)
      else { continue }
      var expression = String(match.3 ?? match.4 ?? "").trimmingCharacters(in: .whitespaces)
      if expression.hasPrefix("live("), expression.hasSuffix(")") { expression = String(expression.dropFirst(5).dropLast()) }
      let type = match.2.map(String.init)
      let isDesign = ["CGFloat", "TimeInterval", "CGSize", "Float", "Double", "NSColor"].contains(type)
        || expression.wholeMatch(of: /-?[0-9][0-9_.]*/) != nil
        || ["NSColor", "OKLCH(", "CGSize(", "PaletteInk.", "SpringParameters(", "onPixelGrid(", "fromMock("]
          .contains { expression.hasPrefix($0) }
      guard isDesign else { continue }
      values.append(DesignValue(
        owner: owner, name: String(match.1), expression: expression, file: file, line: index + 1))
    }
    return values
  }
}
