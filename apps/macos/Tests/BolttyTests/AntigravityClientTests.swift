import SQLite3
import XCTest
@testable import Boltty

final class AntigravityClientTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testTheTranscriptIsReadOffTheSteps() throws {
    let call = Proto.bytes(7, Proto.join(
      Proto.string(1, "call_1"),
      Proto.string(2, "write_to_file"),
      Proto.string(3, #"{"TargetFile":"/tmp/a","toolAction":"Creating a"}"#)
    ))
    let steps: [(type: Int, status: Int, payload: Data)] = [
      (14, 3, Proto.join(Proto.bytes(5, Proto.bytes(1, Proto.varint(1, 1_792_100_573))),
                         Proto.bytes(19, Proto.string(2, "Make a file")))),
      (15, 3, Proto.bytes(20, Proto.join(
        Proto.string(1, "Done."), Proto.string(3, "thinking that is never shown"), call
      ))),
      (132, 7, Proto.bytes(5, Proto.bytes(4, Proto.string(1, "call_1")))),
      (17, 3, Proto.bytes(24, Proto.bytes(3, Proto.string(1, "Individual quota reached.")))),
      (101, 3, Proto.bytes(114, Proto.string(1, "[Message] scaffolding"))),
    ]
    let file = try makeConversation(id: "c1", steps: steps)

    let messages = try AntigravityTranscript.read(at: file)
    XCTAssertEqual(messages.map(\.role), [.user, .agent, .agent])
    XCTAssertEqual(messages[0].plainText, "Make a file")
    XCTAssertEqual(messages[0].createdAt, Date(timeIntervalSince1970: 1_792_100_573))
    XCTAssertEqual(messages[1].plainText, "Done.")
    XCTAssertFalse(messages[1].containsText("thinking"))
    guard case let .activity(activity) = messages[1].parts.last else {
      return XCTFail("the call is a row")
    }
    XCTAssertEqual(activity.name, "write_to_file")
    XCTAssertEqual(activity.summary, "Creating a")
    XCTAssertEqual(activity.state, .failed, "status 7 on its step is a refusal")
    XCTAssertEqual(messages[2].failure?.message, "Individual quota reached.")
  }

  func testAMissingConversationIsNotFoundAndAnEmptyOneIsEmpty() throws {
    XCTAssertNil(try AntigravityTranscript.transcript(sessionID: "nope", in: root))
    _ = try makeConversation(id: "empty", steps: [])
    XCTAssertEqual(try AntigravityTranscript.transcript(sessionID: "empty", in: root)?.messages, [])
  }

  func testGarbageInAStepCostsThatStepOnly() throws {
    let file = try makeConversation(id: "g", steps: [
      (14, 3, Data([0xFF, 0xFF, 0xFF])),
      (14, 3, Proto.bytes(19, Proto.string(2, "still here"))),
    ])
    XCTAssertEqual(try AntigravityTranscript.read(at: file).map(\.plainText), ["still here"])
  }

  func testEffortSuffixesFoldIntoOneModel() {
    let listing = """
      Fetching available models...
      gemini-3.8-flash-high\tGemini 3.8 Flash (High)
      gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)
      gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
      claude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)
      """
    let models = AntigravityClient.models(fromListing: listing, provider: "agy")
    XCTAssertEqual(models.map(\.selection.modelID), ["gemini-3.8-flash", "claude-opus-4-6-thinking"])
    XCTAssertEqual(models[0].effortOptions.map(\.value), ["high", "medium", "low"])
    XCTAssertTrue(models[0].isDefault)
    XCTAssertTrue(models[1].effortOptions.isEmpty)
  }

  private func makeConversation(
    id: String, steps: [(type: Int, status: Int, payload: Data)], generations: [Data] = []
  ) throws -> URL {
    let file = root.appendingPathComponent("\(id).db")
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
    defer { sqlite3_close(handle) }
    let schema = """
      CREATE TABLE steps (idx integer, step_type integer NOT NULL DEFAULT 0,
        status integer NOT NULL DEFAULT 0, step_payload blob, PRIMARY KEY (idx));
      CREATE TABLE gen_metadata (idx integer, data blob, size integer NOT NULL DEFAULT 0,
        PRIMARY KEY (idx));
      """
    XCTAssertEqual(sqlite3_exec(handle, schema, nil, nil, nil), SQLITE_OK)
    for (index, step) in steps.enumerated() {
      var statement: OpaquePointer?
      sqlite3_prepare_v2(handle, "INSERT INTO steps VALUES (?, ?, ?, ?)", -1, &statement, nil)
      sqlite3_bind_int(statement, 1, Int32(index))
      sqlite3_bind_int(statement, 2, Int32(step.type))
      sqlite3_bind_int(statement, 3, Int32(step.status))
      _ = step.payload.withUnsafeBytes {
        sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(step.payload.count),
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      }
      XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
      sqlite3_finalize(statement)
    }
    for (index, data) in generations.enumerated() {
      var statement: OpaquePointer?
      sqlite3_prepare_v2(handle, "INSERT INTO gen_metadata (idx, data) VALUES (?, ?)", -1, &statement, nil)
      sqlite3_bind_int(statement, 1, Int32(index))
      _ = data.withUnsafeBytes {
        sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count),
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      }
      XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
      sqlite3_finalize(statement)
    }
    return file
  }
}

private enum Proto {
  static func encodeVarint(_ value: UInt64) -> Data {
    var value = value
    var out = Data()
    repeat {
      var byte = UInt8(value & 0x7F)
      value >>= 7
      if value != 0 { byte |= 0x80 }
      out.append(byte)
    } while value != 0
    return out
  }

  static func varint(_ field: Int, _ value: UInt64) -> Data {
    encodeVarint(UInt64(field << 3)) + encodeVarint(value)
  }

  static func bytes(_ field: Int, _ data: Data) -> Data {
    encodeVarint(UInt64(field << 3 | 2)) + encodeVarint(UInt64(data.count)) + data
  }

  static func string(_ field: Int, _ text: String) -> Data { bytes(field, Data(text.utf8)) }

  static func join(_ parts: Data...) -> Data { parts.reduce(Data(), +) }
}
