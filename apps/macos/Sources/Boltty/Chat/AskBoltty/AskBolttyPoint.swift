import CoreGraphics
import Foundation

/// A place on the screen an answer points at: `<point x="…" y="…" label="…"/>`,
/// x and y from 0 to 1000 across the picture Ask Boltty sent (0 0 its top left) —
/// the one scale phase 0 found every agent answers well in.
struct AskBolttyPoint: Equatable, Sendable {
  /// Across the picture, 0…1 from its left.
  var x: CGFloat
  /// Down the picture, 0…1 from its top.
  var y: CGFloat
  var label: String?

  static let pattern = #"<point\b[^>]*>"#

  /// Every complete tag in `text`, in order. A tag that does not say where is
  /// skipped, so the n-th of these is the n-th tag that can be flown to.
  static func all(in text: String) -> [AskBolttyPoint] {
    guard text.contains("<point") else { return [] }
    var points: [AskBolttyPoint] = []
    var from = text.startIndex
    while let range = text.range(of: pattern, options: .regularExpression, range: from..<text.endIndex) {
      if let point = parse(String(text[range])) { points.append(point) }
      from = range.upperBound
    }
    return points
  }

  static func parse(_ tag: String) -> AskBolttyPoint? {
    func value(_ name: String) -> String? {
      let pattern = #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s/>]+))"#
      guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
      else { return nil }
      for group in 1...3 {
        if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
      }
      return nil
    }
    guard let x = value("x").flatMap(Double.init), let y = value("y").flatMap(Double.init),
          x.isFinite, y.isFinite
    else { return nil }
    // Asked for 0–1000; a model that answers in fractions is taken at its word.
    let scale = (x <= 1 && y <= 1) ? 1.0 : 1000.0
    let label = value("label")?.trimmingCharacters(in: .whitespacesAndNewlines)
    return AskBolttyPoint(
      x: CGFloat(min(max(x / scale, 0), 1)), y: CGFloat(min(max(y / scale, 0), 1)),
      label: label?.isEmpty == false ? label : nil)
  }

  /// Where on screen, in AppKit's global coordinates, given where the picture
  /// was taken (`displayFrame`, also AppKit's: its origin at the bottom left).
  func location(in displayFrame: CGRect) -> CGPoint {
    CGPoint(x: displayFrame.minX + x * displayFrame.width,
            y: displayFrame.maxY - y * displayFrame.height)
  }

  /// The text with every tag gone, for anything that shows an answer.
  static func stripped(_ text: String) -> String {
    guard text.contains("<point") else { return text }
    let tag = #"[ \t]*"# + pattern + #"[ \t]*"#
    // At a line's edge a tag goes with its spaces; between words it leaves one.
    var out = text.replacingOccurrences(of: #"(?m)^"# + tag, with: "", options: .regularExpression)
    out = out.replacingOccurrences(of: #"(?m)"# + tag + "$", with: "", options: .regularExpression)
    return out.replacingOccurrences(of: tag, with: " ", options: .regularExpression)
  }

  // MARK: - Through the voice

  /// What stands for the n-th tag in speakable text, so a sentence carries its
  /// point through `SentenceChunker` to the moment it is said. Private-use
  /// characters: never typed, never said, never a sentence's end.
  static let markerOpen: Character = "\u{F8F0}"
  static let markerClose: Character = "\u{F8F1}"

  static func marker(_ index: Int) -> String { "\(markerOpen)\(index)\(markerClose)" }

  /// A piece the chunker handed out: its words, and the tags it carried.
  static func split(_ piece: String) -> (text: String, points: [Int]) {
    guard piece.contains(markerOpen) else { return (piece, []) }
    var text = ""
    var points: [Int] = []
    var number: String?
    for character in piece {
      if character == markerOpen {
        number = ""
      } else if character == markerClose {
        if let index = number.flatMap({ Int($0) }) { points.append(index) }
        number = nil
      } else if number != nil {
        number?.append(character)
      } else {
        text.append(character)
      }
    }
    let words = text
      .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (words, points)
  }
}
