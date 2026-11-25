import CoreGraphics
import Foundation

struct AskBolttyPoint: Equatable, Sendable {
  var x: CGFloat
  var y: CGFloat
  var label: String?
  var text: String? = nil
  var hasPosition = true

  static let reach: CGFloat = 250

  static let pattern = #"<point\b[^>]*>"#

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
    func words(_ name: String) -> String? {
      let words = value(name)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return words?.isEmpty == false ? words : nil
    }
    let label = words("label")
    let text = words("text")
    guard let x = value("x").flatMap(Double.init), let y = value("y").flatMap(Double.init),
          x.isFinite, y.isFinite
    else {
      guard let text else { return nil }
      return AskBolttyPoint(x: 0.5, y: 0.5, label: label, text: text, hasPosition: false)
    }
    let scale = (x <= 1 && y <= 1) ? 1.0 : 1000.0
    return AskBolttyPoint(
      x: CGFloat(min(max(x / scale, 0), 1)), y: CGFloat(min(max(y / scale, 0), 1)),
      label: label, text: text)
  }

  func placed(among lines: [ScreenText], anywhere: Bool = false) -> AskBolttyPoint? {
    if let text {
      let near = hasPosition ? CGPoint(x: x * 1000, y: y * 1000) : nil
      if let box = ScreenText.find(text, near: near, in: lines, reach: anywhere ? nil : Self.reach) {
        var placed = self
        placed.x = box.midX / 1000
        placed.y = box.midY / 1000
        placed.hasPosition = true
        return placed
      }
    }
    return hasPosition ? self : nil
  }

  func location(in displayFrame: CGRect) -> CGPoint {
    CGPoint(x: displayFrame.minX + x * displayFrame.width,
            y: displayFrame.maxY - y * displayFrame.height)
  }

  static func stripped(_ text: String) -> String {
    guard text.contains("<point") else { return text }
    let tag = #"[ \t]*"# + pattern + #"[ \t]*"#
    var out = text.replacingOccurrences(of: #"(?m)^"# + tag, with: "", options: .regularExpression)
    out = out.replacingOccurrences(of: #"(?m)"# + tag + "$", with: "", options: .regularExpression)
    return out.replacingOccurrences(of: tag, with: " ", options: .regularExpression)
  }

  /// Private-use characters: never typed, never said, never a sentence's end.
  static let markerOpen: Character = "\u{F8F0}"
  static let markerClose: Character = "\u{F8F1}"

  static func marker(_ index: Int) -> String { "\(markerOpen)\(index)\(markerClose)" }

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
