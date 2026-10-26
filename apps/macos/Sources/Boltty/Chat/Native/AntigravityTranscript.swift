import Foundation
import SQLite3

/// Reads an Antigravity conversation off `agy`'s own record:
/// `~/.gemini/antigravity-cli/conversations/<id>.db`, a SQLite file whose
/// `steps` rows hold protobuf with no published schema.
///
/// The fields below were measured on agy 1.3.4 against
/// conversations whose text was known, and each one is read defensively: a
/// field that moves costs that piece of the transcript, never the read.
///
/// - `steps.step_type` 14 is the person's input: its text at 19.2.
/// - 15 is the agent's reply: its text at 20.1, its tool calls at 20.7
///   (1 id, 2 name, 3 arguments as JSON). 20.3 is thinking, never shown.
/// - 17 is an error: the provider's words at 24.3.1, else 24.3.2.
/// - Every step's own call, when it is one, is at 5.4.1; `steps.status` 7 is
///   a step that failed (a refused tool), 3 one that finished.
/// - 5.1 is when the step was made (seconds, nanos).
enum AntigravityTranscript {
  enum StepType {
    static let userInput = 14
    static let reply = 15
    static let error = 17
  }

  static let failedStatus = 7

  static var defaultRoot: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".gemini/antigravity-cli/conversations")
  }

  static func url(sessionID: String, in root: URL = defaultRoot) -> URL {
    root.appendingPathComponent("\(sessionID).db")
  }

  /// `nil` when the conversation has no file; throws when it has one that
  /// cannot be read.
  static func transcript(sessionID: String, in root: URL = defaultRoot) throws -> DiskTranscript? {
    let file = url(sessionID: sessionID, in: root)
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    return DiskTranscript(messages: try read(at: file), directory: nil, title: nil)
  }

  struct Step {
    var index: Int
    var type: Int
    var status: Int
    var payload: Data
  }

  /// The files are WAL databases. While `agy` has one open its steps are in
  /// the `-wal`, which only a `mode=ro` connection reads; once it exits it
  /// leaves no `-wal` or `-shm`, and `mode=ro` cannot open the file at all
  /// (it may not create the `-shm`), so then it is opened immutable — nothing
  /// is writing it. A read that loses that race is retried once.
  static func read(at file: URL) throws -> [ConversationMessage] {
    do {
      return messages(from: try steps(at: file))
    } catch {
      return messages(from: try steps(at: file))
    }
  }

  static func steps(at file: URL) throws -> [Step] {
    try rows(at: file, "SELECT idx, step_type, status, step_payload FROM steps ORDER BY idx") {
      Step(
        index: Int(sqlite3_column_int64($0, 0)),
        type: Int(sqlite3_column_int64($0, 1)),
        status: Int(sqlite3_column_int64($0, 2)),
        payload: blob($0, 3)
      )
    }
  }

  /// The model each number names, off `gen_metadata` — one row per model
  /// call, the number at 1.3 and its name at 1.19 (agy 1.3.4: every number
  /// on this Mac's 433 replies had one). A reply step carries only the number.
  static func modelNames(at file: URL) throws -> [UInt64: String] {
    var names: [UInt64: String] = [:]
    let calls = try rows(at: file, "SELECT data FROM gen_metadata") { ProtoFields(blob($0, 0)) }
    for call in calls {
      guard let generation = call.message(1),
            let number = generation.varint(3),
            let name = generation.string(19), !name.isEmpty
      else { continue }
      names[number] = name
    }
    return names
  }

  /// The files are WAL databases; see `read(at:)` for why the mode depends
  /// on whether a `-wal` stands beside them.
  private static func rows<Row>(
    at file: URL, _ sql: String, _ make: (OpaquePointer) -> Row
  ) throws -> [Row] {
    var handle: OpaquePointer?
    let live = FileManager.default.fileExists(atPath: file.path + "-wal")
    let uri = "file:\(file.path)?" + (live ? "mode=ro" : "immutable=1")
    guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
          let handle
    else {
      let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
      sqlite3_close(handle)
      throw NativeSessionStoreError.unreadable(path: file.path, reason: reason)
    }
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw NativeSessionStoreError.unreadable(
        path: file.path, reason: String(cString: sqlite3_errmsg(handle))
      )
    }
    defer { sqlite3_finalize(statement) }

    var rows: [Row] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        throw NativeSessionStoreError.unreadable(
          path: file.path, reason: String(cString: sqlite3_errmsg(handle))
        )
      }
      rows.append(make(statement))
    }
    return rows
  }

  private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
    let length = Int(sqlite3_column_bytes(statement, column))
    return sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: length) } ?? Data()
  }

  // MARK: - Usage

  /// What one step counts toward Usage: the person's input is a message; a
  /// reply step is a model call, its tokens at 5.9 — 2 input, 3 output
  /// (thinking included), 5 cached input, counted apart from 2 as Claude
  /// Code's cache reads are. Measured against the `usage` `agy` printed for
  /// the same turns: input and output matched to the token; the cache field
  /// was not seen beside a nonzero `cache_read_tokens`, and is read as one
  /// because it exceeds the input on 264 of the 265 replies that carry it.
  struct Use: Equatable {
    var date: Date
    var model: String
    var tokens: Int
    var messages: Int
  }

  static func usage(of steps: [Step], models: [UInt64: String]) -> [Use] {
    steps.compactMap { step in
      let fields = ProtoFields(step.payload)
      let meta = fields.message(5)
      let date = meta?.message(1).flatMap(date(from:)) ?? Date(timeIntervalSince1970: 0)
      switch step.type {
      case StepType.userInput:
        guard let text = fields.message(19)?.string(2), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return Use(date: date, model: "", tokens: 0, messages: 1)
      case StepType.reply:
        guard let use = meta?.message(9) else { return nil }
        let tokens = [2, 3, 5].reduce(0) { $0 + Int(use.varint($1) ?? 0) }
        let model = use.varint(1).flatMap { models[$0] } ?? ""
        return Use(date: date, model: model, tokens: tokens, messages: 1)
      default:
        return nil
      }
    }
  }

  static func messages(from steps: [Step]) -> [ConversationMessage] {
    var failedCalls: Set<String> = []
    for step in steps where step.status == failedStatus {
      let fields = ProtoFields(step.payload)
      if let call = fields.message(5)?.message(4)?.string(1) { failedCalls.insert(call) }
    }

    var messages: [ConversationMessage] = []
    for step in steps {
      let fields = ProtoFields(step.payload)
      let created = fields.message(5)?.message(1).flatMap(date(from:)) ?? Date(timeIntervalSince1970: 0)
      let id = "agy-\(step.index)"
      switch step.type {
      case StepType.userInput:
        guard let text = fields.message(19)?.string(2)?
          .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { continue }
        messages.append(ConversationMessage(
          id: id, role: .user, createdAt: created, completedAt: created,
          parts: [.text(TextPart(id: "\(id)-text", kind: .text, text: text))]
        ))

      case StepType.reply:
        guard let reply = fields.message(20) else { continue }
        var parts: [ConversationPart] = []
        if let text = reply.string(1)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
          parts.append(.text(TextPart(id: "\(id)-text", kind: .text, text: text)))
        }
        for (offset, call) in reply.messages(7).enumerated() {
          guard let name = call.string(2) else { continue }
          let callID = call.string(1) ?? "\(id)-call-\(offset)"
          parts.append(.activity(AgentActivity(
            id: callID,
            name: name,
            summary: call.string(3).flatMap(summary(ofArguments:)),
            state: failedCalls.contains(callID) ? .failed : .completed
          )))
        }
        guard !parts.isEmpty else { continue }
        messages.append(ConversationMessage(
          id: id, role: .agent, createdAt: created, completedAt: created, parts: parts
        ))

      case StepType.error:
        let detail = fields.message(24)?.message(3)
        guard let words = detail?.string(1) ?? detail?.string(2) else { continue }
        messages.append(ConversationMessage(
          id: id, role: .agent, createdAt: created, completedAt: created,
          failure: MessageFailure(name: "AntigravityError", message: words)
        ))

      default:
        continue
      }
    }
    return messages
  }

  /// `agy` describes each call in its own words (`toolAction`), which reads
  /// better than the arguments.
  private static func summary(ofArguments json: String) -> String? {
    guard let object = JSONObject(line: json) else { return nil }
    return object.string("toolAction") ?? object.string("toolSummary")
  }

  private static func date(from timestamp: ProtoFields) -> Date? {
    guard let seconds = timestamp.varint(1) else { return nil }
    let nanos = timestamp.varint(2) ?? 0
    return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1e9)
  }
}

/// A protobuf message read without its schema: field number → raw values.
/// Only what the transcript needs — varints and length-delimited fields.
struct ProtoFields {
  private(set) var varints: [Int: [UInt64]] = [:]
  private(set) var bytes: [Int: [Data]] = [:]
  /// False when the bytes are not a well-formed message, which is how a
  /// string is told from a nested message.
  private(set) var isWellFormed = true

  init(_ data: Data) {
    let buffer = [UInt8](data)
    var index = 0
    func varint() -> UInt64? {
      var result: UInt64 = 0
      var shift: UInt64 = 0
      while index < buffer.count, shift < 64 {
        let byte = buffer[index]
        index += 1
        result |= UInt64(byte & 0x7F) << shift
        if byte < 0x80 { return result }
        shift += 7
      }
      return nil
    }
    while index < buffer.count {
      guard let key = varint() else { isWellFormed = false; return }
      let field = Int(key >> 3)
      guard field > 0 else { isWellFormed = false; return }
      switch key & 7 {
      case 0:
        guard let value = varint() else { isWellFormed = false; return }
        varints[field, default: []].append(value)
      case 1:
        index += 8
      case 2:
        guard let length = varint(), length <= UInt64(buffer.count - index) else {
          isWellFormed = false
          return
        }
        bytes[field, default: []].append(Data(buffer[index..<index + Int(length)]))
        index += Int(length)
      case 5:
        index += 4
      default:
        isWellFormed = false
        return
      }
      if index > buffer.count { isWellFormed = false; return }
    }
  }

  func varint(_ field: Int) -> UInt64? { varints[field]?.first }

  func string(_ field: Int) -> String? {
    bytes[field]?.first.flatMap { String(data: $0, encoding: .utf8) }
  }

  func message(_ field: Int) -> ProtoFields? {
    guard let data = bytes[field]?.first else { return nil }
    let fields = ProtoFields(data)
    return fields.isWellFormed ? fields : nil
  }

  func messages(_ field: Int) -> [ProtoFields] {
    (bytes[field] ?? []).map(ProtoFields.init).filter(\.isWellFormed)
  }
}
