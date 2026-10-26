import Foundation

struct NativeSession: Equatable, Identifiable, Sendable {
  let id: String
  let agent: AgentId
  let title: String
  let workingDirectory: String
  let updatedAt: Date
  var sourceURL: URL?
}

enum NativeSessionStoreError: Error, Equatable {
  case unreadable(path: String, reason: String)
}

enum NativeStoreChange: Hashable, Sendable {
  case chat(id: String, at: URL)
}

protocol NativeSessionStore: Sendable {
  var agent: AgentId { get }
  func sessions(limit: Int) throws -> [NativeSession]

  func session(for change: NativeStoreChange) throws -> NativeSession?

  func transcript(for session: NativeSession) throws -> [ConversationMessage]?
}

extension NativeSessionStore {
  func session(for change: NativeStoreChange) throws -> NativeSession? { nil }

  func transcript(for session: NativeSession) throws -> [ConversationMessage]? { nil }
}

// MARK: - Reading the head of a file

enum FileHead {
  static func forEachLine(
    of url: URL,
    maxLines: Int,
    maxBytes: Int = 4 << 20,
    _ body: (Data) throws -> Bool
  ) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try stream(handle, maxLines: maxLines, maxBytes: maxBytes, dropFirstLine: false, body)
  }

  fileprivate static func stream(
    _ handle: FileHandle,
    maxLines: Int,
    maxBytes: Int,
    dropFirstLine: Bool,
    _ body: (Data) throws -> Bool
  ) throws {
    var dropping = dropFirstLine

    // memchr, not firstIndex(of:): the Swift scan was ~400× slower on multi-MB files.
    var buffer: [UInt8] = []
    var start = 0
    var scanned = 0
    var seen = 0
    var read = 0
    let newline = Int32(UInt8(ascii: "\n"))
    let compactionThreshold = 64 << 10

    func newlineIndex(from: Int) -> Int? {
      buffer.withUnsafeBufferPointer { raw -> Int? in
        guard from < raw.count, let base = raw.baseAddress else { return nil }
        guard let hit = memchr(base + from, newline, raw.count - from) else { return nil }
        return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
      }
    }

    func emitLines() throws -> Bool {
      while let index = newlineIndex(from: scanned) {
        let line = Data(buffer[start..<index])
        start = index + 1
        scanned = start
        guard !dropping else {
          dropping = false
          continue
        }
        seen += 1
        if try !body(line) { return false }
        if seen >= maxLines { return false }
      }
      scanned = buffer.count
      if start >= compactionThreshold {
        buffer.removeFirst(start)
        scanned -= start
        start = 0
      }
      return true
    }

    while seen < maxLines, read < maxBytes {
      guard let chunk = try handle.read(upToCount: 64 << 10), !chunk.isEmpty else { break }
      read += chunk.count
      buffer.append(contentsOf: chunk)
      guard try emitLines() else { return }
    }
    if seen < maxLines, start < buffer.count, !dropping {
      _ = try body(Data(buffer[start...]))
    }
  }

  static func lines(of url: URL, maxLines: Int, maxBytes: Int = 4 << 20) throws -> [String] {
    var lines: [String] = []
    try forEachLine(of: url, maxLines: maxLines, maxBytes: maxBytes) { line in
      lines.append(String(decoding: line, as: UTF8.self))
      return true
    }
    return lines
  }
}

enum FileTail {
  @discardableResult
  static func forEachLine(
    of url: URL,
    maxBytes: Int,
    _ body: (Data) throws -> Bool
  ) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    let complete = size <= UInt64(maxBytes)
    try handle.seek(toOffset: complete ? 0 : size - UInt64(maxBytes))
    try FileHead.stream(
      handle, maxLines: .max, maxBytes: maxBytes, dropFirstLine: !complete, body
    )
    return complete
  }
}

// MARK: - Text the CLI wrote and filed as the user's

struct DiskTranscript: Sendable {
  var messages: [ConversationMessage]
  var directory: String?
  var title: String?
}

enum InjectedText {
  static let codexTags = [
    "environment_context", "recommended_plugins",
    "turn_aborted", "system_instruction", "user_instructions",
    "subagent_notification"
  ]

  static let claudeTags = [
    "task-notification", "command-name", "command-message", "command-args",
    "local-command-caveat", "local-command-stdout", "local-command-stderr",
    "system-reminder"
  ]

  static let claudePrefixes = [
    "[Request interrupted by user",
    "Base directory for this skill:"
  ]
  static let grokTags = [
    "system-reminder", "system_reminder", "command-name",
    "user_info", "image_files"
  ]

  static func without(_ text: String, tag: String) -> String {
    var kept = ""
    var rest = Substring(text)
    while let open = rest.range(of: "<\(tag)") {
      let boundary = rest[open.upperBound...].first
      guard boundary == ">" || boundary == " " else {
        kept += rest[..<open.upperBound]
        rest = rest[open.upperBound...]
        continue
      }
      kept += rest[..<open.lowerBound]
      let tail = rest[open.upperBound...]
      if let close = tail.range(of: "</\(tag)>") {
        rest = tail[close.upperBound...]
      } else if let end = tail.firstIndex(of: ">") {
        rest = tail[tail.index(after: end)...]
      } else {
        rest = tail[tail.endIndex...]
      }
    }
    kept += rest
    return kept.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func inside(_ text: String, tag: String) -> String? {
    guard let open = text.range(of: "<\(tag)>") else { return nil }
    let rest = text[open.upperBound...]
    let body = rest.range(of: "</\(tag)>").map { rest[..<$0.lowerBound] } ?? rest
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static let codexPrefixes = [
    "# AGENTS.md instructions",
    "The following is the Codex agent history",
    "## Memory",
    "# Memory"
  ]

  static func isScaffolding(_ text: String, tags: [String], prefixes: [String] = []) -> Bool {
    if prefixes.contains(where: text.hasPrefix) { return true }
    guard text.hasPrefix("<") else { return false }
    return tags.contains { text.hasPrefix("<\($0)>") || text.hasPrefix("<\($0) ") }
  }

  static func title(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let line = trimmed.split(whereSeparator: \.isNewline).first else { return nil }
    let title = String(line).trimmingCharacters(in: .whitespaces)
    return title.isEmpty ? nil : String(title.prefix(120))
  }
}
