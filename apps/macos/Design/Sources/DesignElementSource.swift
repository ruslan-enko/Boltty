import Foundation

final class DesignElementSource: @unchecked Sendable {
  struct Place: Equatable {
    let file: URL
    let line: Int
  }

  private struct Body {
    let place: Place
    var lines: [String]
  }

  private var classes: [String: Body] = [:]
  private var blocks: [String: (file: String, text: String)] = [:]
  private var resolved: [String: Set<String>] = [:]
  private var used: [String: Set<String>] = [:]

  init(root: URL = DesignSources.root) {
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" && !$0.path.contains("/UI/Design/") } ?? []
    for file in files {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      read(text, file: file)
    }
  }

  private func read(_ text: String, file: URL) {
    let lines = text.components(separatedBy: "\n")
    var index = 0
    while index < lines.count {
      guard let first = lines[index].utf8.first, first != UInt8(ascii: " "), lines[index].hasSuffix("{"),
            let match = lines[index].firstMatch(of: /^(?:[a-z@A-Z]+ )*(enum|struct|class|extension) (\w+)/)
      else {
        index += 1
        continue
      }
      let name = String(match.2)
      let start = index
      index += 1
      while index < lines.count, lines[index] != "}" { index += 1 }
      let body = Array(lines[start..<min(index, lines.count)])
      if match.1 == "class" || match.1 == "enum" {
        let others = classes[name]?.lines ?? []
        classes[name] = Body(place: Place(file: file, line: start + 1), lines: body + others)
      } else if match.1 == "extension" {
        if classes[name] != nil { classes[name]?.lines += body } else {
          classes[name] = Body(place: Place(file: file, line: start + 1), lines: body)
        }
      }
      readStatics(body, owner: name, file: file)
    }
  }

  private func readStatics(_ body: [String], owner: String, file: URL) {
    var index = 1
    while index < body.count {
      guard body[index].hasPrefix("  "), body[index].contains("static "),
            let match = body[index].firstMatch(of: /^\s\s(?:[a-z@A-Z]+ )*static (?:let|var|func) (\w+)/)
      else {
        index += 1
        continue
      }
      let start = index
      index += 1
      while index < body.count, body[index].hasPrefix("    ") || body[index].hasPrefix("  }") || body[index].hasPrefix("  )") {
        index += 1
      }
      let text = body[start..<index].joined(separator: "\n")
      blocks["\(owner).\(match.1)", default: (file.lastPathComponent, "")].text += "\n" + text
    }
  }

  func place(of type: String) -> Place? { classes[type]?.place }

  func place(of type: String, property: String?) -> Place? {
    guard let body = classes[type], let property,
          let lines = try? String(contentsOf: body.place.file, encoding: .utf8).components(separatedBy: "\n"),
          let line = lines.indices.first(where: {
            $0 >= body.place.line - 1 && (lines[$0].contains("let \(property)") || lines[$0].contains("var \(property)"))
          })
    else { return classes[type]?.place }
    return Place(file: body.place.file, line: line + 1)
  }

  func values(of type: String, property: String? = nil) -> Set<String> {
    let cache = "\(type).\(property ?? "")"
    if let known = used[cache] { return known }
    guard let body = classes[type] else { return [] }
    var found: Set<String> = []
    if let property {
      for index in body.lines.indices where Self.mentions(body.lines[index], property) {
        let end = min(body.lines.count, index + (body.lines[index].hasSuffix("(") || body.lines[index].hasSuffix("=") ? 4 : 1))
        found.formUnion(keys(in: body.lines[index..<end].joined(separator: "\n"), owner: type))
      }
    } else {
      found = keys(in: body.lines.joined(separator: "\n"), owner: type)
    }
    used[cache] = found
    return found
  }

  static func mentions(_ line: String, _ word: String) -> Bool {
    var range = line.startIndex..<line.endIndex
    while let hit = line.range(of: word, range: range) {
      let before = hit.lowerBound > line.startIndex ? line[line.index(before: hit.lowerBound)] : " "
      let after = hit.upperBound < line.endIndex ? line[hit.upperBound] : " "
      if !isWord(before), !isWord(after) { return true }
      range = hit.upperBound..<line.endIndex
    }
    return false
  }

  private static func isWord(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }

  private func keys(in text: String, owner: String) -> Set<String> {
    var found: Set<String> = []
    for name in Self.names(in: text, owner: owner) { found.formUnion(keys(of: name)) }
    return found
  }

  private func keys(of name: String) -> Set<String> {
    if let known = resolved[name] { return known }
    guard let block = blocks[name] else { return [] }
    resolved[name] = []
    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
    var found: Set<String> = []
    if block.text.contains("live(") { found.insert("\(block.file).\(parts[1])") }
    for other in Self.names(in: block.text, owner: parts[0]) where other != name { found.formUnion(keys(of: other)) }
    resolved[name] = found
    return found
  }

  static func names(in text: String, owner: String) -> Set<String> {
    var found: Set<String> = []
    var word = "", previous = ""
    var dotted = false
    func close() {
      guard !word.isEmpty else { return }
      if dotted {
        found.insert("\(previous == "Self" ? owner : previous).\(word)")
      } else {
        found.insert("\(owner).\(word)")
      }
      previous = word
      word = ""
    }
    for character in text {
      if Self.isWord(character) {
        word.append(character)
      } else {
        close()
        dotted = character == "."
        if character != "." { previous = "" }
      }
    }
    close()
    return found
  }
}
