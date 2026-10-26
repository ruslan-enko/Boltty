import CoreGraphics
import Foundation

/// One thing an answer draws: on the screen, in the picture's 0–1000 across
/// and down (0 0 its top left) — the scale `<point>` already uses — or on a
/// board beside the face, in 0–1000 across a square.
struct AskBolttyShape: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    /// Round something: a centre and a radius in the across scale.
    case circle(center: CGPoint, radius: CGFloat)
    case box(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    case line(from: CGPoint, to: CGPoint)
    /// A free outline: a polygon, a figure, a curve.
    case path([Segment])
    /// Words alone, at a place.
    case label(at: CGPoint)
  }

  /// A step of a `path`, absolute, in 0–1000.
  enum Segment: Equatable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(CGPoint, control: CGPoint)
    case curve(CGPoint, control1: CGPoint, control2: CGPoint)
    case close
  }

  var kind: Kind
  var label: String?

  static let names = ["circle", "box", "arrow", "line", "path", "label"]

  /// One self-closing tag, or `nil` when it does not say where.
  static func parse(_ tag: String) -> AskBolttyShape? {
    guard let name = tagName(tag), names.contains(name) else { return nil }
    let label = attribute("label", in: tag) ?? attribute("text", in: tag)
    func number(_ key: String) -> CGFloat? {
      attribute(key, in: tag).flatMap(Double.init).flatMap { $0.isFinite ? CGFloat($0) : nil }
    }
    func point(_ x: String, _ y: String) -> CGPoint? {
      guard let x = number(x), let y = number(y) else { return nil }
      return clamped(CGPoint(x: x, y: y))
    }
    let kind: Kind
    switch name {
    case "circle":
      guard let center = point("x", "y"), let radius = number("r") ?? number("rx"), radius > 0
      else { return nil }
      kind = .circle(center: center, radius: min(radius, 1000))
    case "box":
      if let a = point("x1", "y1"), let b = point("x2", "y2") {
        kind = .box(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(b.x - a.x), height: abs(b.y - a.y)))
      } else if let origin = point("x", "y"), let w = number("w") ?? number("width"),
                let h = number("h") ?? number("height") {
        kind = .box(CGRect(origin: origin, size: CGSize(width: abs(w), height: abs(h))))
      } else {
        return nil
      }
    case "arrow", "line":
      guard let from = point("x1", "y1"), let to = point("x2", "y2"), from != to else { return nil }
      kind = name == "arrow" ? .arrow(from: from, to: to) : .line(from: from, to: to)
    case "path":
      guard let d = attribute("d", in: tag) ?? attribute("points", in: tag) else { return nil }
      let segments = attribute("d", in: tag) != nil ? pathSegments(d) : polygon(d)
      guard segments.count >= 2 else { return nil }
      kind = .path(segments)
    default:
      guard let at = point("x", "y"), label?.isEmpty == false else { return nil }
      kind = .label(at: at)
    }
    let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    return AskBolttyShape(kind: kind, label: trimmed?.isEmpty == false ? trimmed : nil)
  }

  // MARK: - Reading a tag

  static func tagName(_ tag: String) -> String? {
    guard let range = tag.range(of: #"^<\s*([a-zA-Z]+)"#, options: .regularExpression) else { return nil }
    return tag[range].dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
  }

  static func attribute(_ name: String, in tag: String) -> String? {
    let pattern = #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s/>]+))"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
    else { return nil }
    for group in 1...3 {
      if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
    }
    return nil
  }

  private static func clamped(_ point: CGPoint) -> CGPoint {
    CGPoint(x: min(max(point.x, 0), 1000), y: min(max(point.y, 0), 1000))
  }

  /// SVG's path data, the commands an outline needs: M L H V Q C Z, absolute
  /// and relative, with a repeated pair after M read as L.
  static func pathSegments(_ data: String) -> [Segment] {
    let tokens = data.replacingOccurrences(
      of: #"([MmLlHhVvQqCcZz])"#, with: " $1 ", options: .regularExpression)
      .replacingOccurrences(of: ",", with: " ")
      .replacingOccurrences(of: #"(\d)-"#, with: "$1 -", options: .regularExpression)
      .split(whereSeparator: \.isWhitespace).map(String.init)
    var segments: [Segment] = []
    var index = 0
    var command: Character = "M"
    var current = CGPoint.zero
    var start = CGPoint.zero
    func next() -> CGFloat? {
      guard index < tokens.count, let value = Double(tokens[index]), value.isFinite else { return nil }
      index += 1
      return CGFloat(value)
    }
    func pair(_ relative: Bool) -> CGPoint? {
      guard let x = next(), let y = next() else { return nil }
      return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
    }
    while index < tokens.count, segments.count < 400 {
      if let letter = tokens[index].first, tokens[index].count == 1, letter.isLetter {
        command = letter
        index += 1
        if command == "Z" || command == "z" {
          segments.append(.close)
          current = start
          continue
        }
      }
      let relative = command.isLowercase
      switch command.uppercased() {
      case "M":
        guard let p = pair(relative) else { return segments }
        segments.append(.move(clamped(p)))
        current = p
        start = p
        command = relative ? "l" : "L"
      case "L":
        guard let p = pair(relative) else { return segments }
        segments.append(.line(clamped(p)))
        current = p
      case "H":
        guard let x = next() else { return segments }
        current = CGPoint(x: relative ? current.x + x : x, y: current.y)
        segments.append(.line(clamped(current)))
      case "V":
        guard let y = next() else { return segments }
        current = CGPoint(x: current.x, y: relative ? current.y + y : y)
        segments.append(.line(clamped(current)))
      case "Q":
        guard let c = pair(relative), let p = pair(relative) else { return segments }
        segments.append(.quad(clamped(p), control: clamped(c)))
        current = p
      case "C":
        guard let c1 = pair(relative), let c2 = pair(relative), let p = pair(relative)
        else { return segments }
        segments.append(.curve(clamped(p), control1: clamped(c1), control2: clamped(c2)))
        current = p
      default:
        index += 1
      }
    }
    if case .move = segments.first {} else if !segments.isEmpty { return [] }
    return segments
  }

  /// SVG's polygon `points`: pairs, closed.
  private static func polygon(_ data: String) -> [Segment] {
    let values = data.replacingOccurrences(of: ",", with: " ")
      .split(whereSeparator: \.isWhitespace).compactMap { Double($0) }.map { CGFloat($0) }
    var segments: [Segment] = []
    var i = 0
    while i + 1 < values.count, segments.count < 400 {
      let p = clamped(CGPoint(x: values[i], y: values[i + 1]))
      segments.append(segments.isEmpty ? .move(p) : .line(p))
      i += 2
    }
    if segments.count >= 3 { segments.append(.close) }
    return segments
  }
}

/// What an answer marks, in the order it wrote them: a place the face flies
/// to, a shape on the screen, or a board of shapes beside the face.
enum AskBolttyMark: Equatable, Sendable {
  case point(AskBolttyPoint)
  case shape(AskBolttyShape)
  case board([AskBolttyShape])

  /// A board as a whole, or one self-closing tag of a kind Ask Boltty draws.
  static let pattern =
    #"(?s)<board\b[^>]*>.*?</board\s*>|<(?:point|circle|box|arrow|line|path|label)\b[^>]*>"#

  /// The most an answer draws: a model that loops does not paint the screen.
  static let limit = 40

  static func parse(_ tag: String) -> AskBolttyMark? {
    if tag.lowercased().hasPrefix("<board") {
      guard let open = tag.firstIndex(of: ">"),
            let close = tag.range(of: "</board", options: [.caseInsensitive, .backwards])
      else { return nil }
      let inside = String(tag[tag.index(after: open)..<close.lowerBound])
      let shapes = shapeTags(in: inside).compactMap(AskBolttyShape.parse)
      return shapes.isEmpty ? nil : .board(Array(shapes.prefix(limit)))
    }
    if AskBolttyShape.tagName(tag) == "point" { return AskBolttyPoint.parse(tag).map(Self.point) }
    return AskBolttyShape.parse(tag).map(Self.shape)
  }

  /// Every complete mark in `text`, in order. One that does not parse is
  /// skipped, so the n-th of these is the n-th marker the voice carries.
  static func all(in text: String) -> [AskBolttyMark] {
    guard text.contains("<") else { return [] }
    var marks: [AskBolttyMark] = []
    var from = text.startIndex
    while let range = text.range(of: pattern, options: .regularExpression, range: from..<text.endIndex),
          marks.count < limit {
      if let mark = parse(String(text[range])) { marks.append(mark) }
      from = range.upperBound
    }
    return marks
  }

  /// The text with every mark gone, for anything that shows an answer.
  static func stripped(_ text: String) -> String {
    guard text.contains("<") else { return text }
    let tag = #"[ \t]*(?:"# + pattern + #")[ \t]*"#
    var out = text.replacingOccurrences(of: #"(?m)^"# + tag + #"\n?"#, with: "", options: .regularExpression)
    out = out.replacingOccurrences(of: #"(?m)"# + tag + "$", with: "", options: .regularExpression)
    return out.replacingOccurrences(of: tag, with: " ", options: .regularExpression)
  }

  /// A mark still arriving — `<circ`, `<arrow x1="4`, a board not yet closed
  /// — is not text yet: everything from where it opens is held back.
  static func withoutUnfinished(_ text: String) -> String {
    var text = text
    if let open = text.range(of: "<board", options: [.caseInsensitive, .backwards]),
       text.range(of: #"</board\s*>"#, options: [.regularExpression, .caseInsensitive],
                  range: open.upperBound..<text.endIndex) == nil {
      text = String(text[..<open.lowerBound])
    }
    guard let open = text.lastIndex(of: "<"), !text[open...].contains(">") else { return text }
    let rest = text[text.index(after: open)...].lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let started = rest.isEmpty || (["point", "board"] + AskBolttyShape.names).contains { name in
      rest.hasPrefix(name) || name.hasPrefix(rest)
    }
    return started ? String(text[..<open]) : text
  }

  private static func shapeTags(in text: String) -> [String] {
    let pattern = #"<(?:circle|box|arrow|line|path|label)\b[^>]*>"#
    var tags: [String] = []
    var from = text.startIndex
    while let range = text.range(of: pattern, options: .regularExpression, range: from..<text.endIndex) {
      tags.append(String(text[range]))
      from = range.upperBound
    }
    return tags
  }
}

/// A shape put up by an answer, and where its 0–1000 is measured: across the
/// screen's picture (`frame`, AppKit's global coordinates), or on the board.
struct AskBolttyStroke: Equatable {
  var shape: AskBolttyShape
  /// `nil`: on the board.
  var frame: CGRect?
}
