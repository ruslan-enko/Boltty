import Foundation

struct ServerSentEventParser {
  struct Event: Equatable {
    var id: String?
    var name: String?
    var data: String
  }

  private var buffer: [UInt8] = []
  private var searchFrom = 0
  private var pendingCarriageReturn = false

  private static let lf = UInt8(ascii: "\n")
  private static let cr = UInt8(ascii: "\r")

  mutating func consume(_ bytes: some Sequence<UInt8>) -> [Event] {
    for byte in bytes {
      if pendingCarriageReturn {
        pendingCarriageReturn = false
        buffer.append(Self.lf)
        if byte == Self.lf { continue }
      }
      if byte == Self.cr {
        pendingCarriageReturn = true
        continue
      }
      buffer.append(byte)
    }
    return drain()
  }

  mutating func consume(_ text: String) -> [Event] {
    consume(Array(text.utf8))
  }

  private mutating func drain() -> [Event] {
    var events: [Event] = []
    var start = 0
    while let index = blankLineIndex(from: max(start, searchFrom)) {
      let frame = String(decoding: buffer[start..<index], as: UTF8.self)
      start = index + 2
      if let event = Self.parse(frame: frame) { events.append(event) }
    }
    if start > 0 { buffer.removeFirst(start) }
    searchFrom = max(0, buffer.count - 1)
    return events
  }

  private func blankLineIndex(from: Int) -> Int? {
    guard buffer.count >= 2, from <= buffer.count - 2 else { return nil }
    for index in from...(buffer.count - 2)
    where buffer[index] == Self.lf && buffer[index + 1] == Self.lf {
      return index
    }
    return nil
  }

  static func parse(frame: String) -> Event? {
    var id: String?
    var name: String?
    var data: [String] = []
    for rawLine in frame.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
      if line.isEmpty || line.hasPrefix(":") { continue }
      guard let colon = line.firstIndex(of: ":") else {
        continue
      }
      let field = String(line[line.startIndex..<colon])
      var value = String(line[line.index(after: colon)...])
      if value.hasPrefix(" ") { value.removeFirst() }
      switch field {
      case "id": id = value
      case "event": name = value
      case "data": data.append(value)
      default: break
      }
    }
    guard !data.isEmpty else { return nil }
    return Event(id: id, name: name, data: data.joined(separator: "\n"))
  }
}
