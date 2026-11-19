import CoreGraphics
import Foundation

enum FinderSpot: Codable, Equatable, Sendable {
  case desktop
  case window(middle: CGPoint, title: String?)
}

struct ScreenSelection: Sendable, Equatable, Codable {
  var region: Data
  var screen: Data
  var frame: CGRect
  var context: String?
  var recognizedText: String?
  var finderSpot: FinderSpot? = nil
  var labels: [ScreenText]? = nil
}

/// A line read off the picture of the screen the agent is sent, its boxes in
/// thousandths of that picture from its top left, as the agent's tags are.
struct ScreenText: Codable, Equatable, Sendable {
  struct Word: Codable, Equatable, Sendable {
    var text: String
    var box: CGRect
  }

  var text: String
  var box: CGRect
  var words: [Word]

  /// The box of `words` as they stand together in one line; of several, the
  /// one nearest `near`, and none farther than `reach` from it.
  static func find(
    _ words: String, near: CGPoint?, in lines: [ScreenText], reach: CGFloat? = nil
  ) -> CGRect? {
    let wanted = keys(words)
    guard !wanted.isEmpty else { return nil }
    var found: [CGRect] = []
    for line in lines {
      let have = line.words.compactMap { word -> (key: String, box: CGRect)? in
        let key = key(word.text)
        return key.isEmpty ? nil : (key, word.box)
      }
      guard have.count >= wanted.count else { continue }
      for start in 0...(have.count - wanted.count)
      where have[start..<(start + wanted.count)].map(\.key) == wanted {
        found.append(have[start..<(start + wanted.count)].map(\.box).reduce(.null) { $0.union($1) })
      }
    }
    if found.isEmpty {
      // Read as one word where Vision split it, or the other way round: the
      // whole line, never a piece of a word ("Save" is not in "Saved").
      let joined = wanted.joined()
      found = lines.filter { keys($0.text).joined() == joined }.map(\.box)
    }
    guard let near else { return found.first }
    func distance(_ box: CGRect) -> CGFloat { hypot(box.midX - near.x, box.midY - near.y) }
    guard let best = found.min(by: { distance($0) < distance($1) }) else { return nil }
    if let reach, distance(best) > reach { return nil }
    return best
  }

  static func key(_ word: String) -> String {
    word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces))
  }

  static func keys(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map { key(String($0)) }.filter { !$0.isEmpty }
  }

  /// The menu bar's band, in thousandths from the top: always listed, since
  /// "where is Export?" is so often answered there.
  static let menuBarDepth: CGFloat = 30

  /// One line a label: `x1 y1 x2 y2 words`, in reading order. Past `byteLimit`
  /// the lines nearest `area` are the ones kept.
  static func listing(_ lines: [ScreenText], byteLimit: Int, near area: CGRect? = nil) -> String? {
    func row(_ line: ScreenText) -> String {
      let words = line.text.count > 80 ? String(line.text.prefix(80)) + "…" : line.text
      return [line.box.minX, line.box.minY, line.box.maxX, line.box.maxY]
        .map { String(Int($0.rounded())) }.joined(separator: " ") + " " + words + "\n"
    }
    func distance(_ line: ScreenText) -> CGFloat {
      guard let area, line.box.minY > menuBarDepth else { return 0 }
      let dx = max(area.minX - line.box.maxX, 0, line.box.minX - area.maxX)
      let dy = max(area.minY - line.box.maxY, 0, line.box.minY - area.maxY)
      return hypot(dx, dy)
    }
    var bytes = 0
    var kept: [ScreenText] = []
    let nearestFirst = lines.enumerated()
      .sorted { (distance($0.element), $0.offset) < (distance($1.element), $1.offset) }
      .map(\.element)
    for line in nearestFirst {
      let size = row(line).utf8.count
      guard bytes + size <= byteLimit else { continue }
      bytes += size
      kept.append(line)
    }
    let out = kept.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }.map(row).joined()
    return out.isEmpty ? nil : out
  }
}
