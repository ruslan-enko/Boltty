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

  // MARK: - The record

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

  // MARK: - Usage

  func testUsageCountsThePersonAndEachModelCallWithItsModelsName() throws {
    let stamp = Proto.bytes(5, Proto.join(
      Proto.bytes(1, Proto.varint(1, 1_792_100_573)),
      Proto.bytes(9, Proto.join(
        Proto.varint(1, 1319), Proto.varint(2, 100), Proto.varint(3, 20), Proto.varint(5, 300),
        Proto.varint(9, 7)
      ))
    ))
    let file = try makeConversation(id: "used", steps: [
      (14, 3, Proto.bytes(19, Proto.string(2, "hello"))),
      (15, 3, Proto.join(stamp, Proto.bytes(20, Proto.string(1, "hi")))),
      (132, 3, Proto.bytes(5, Proto.bytes(4, Proto.string(1, "call")))),
    ], generations: [Proto.bytes(1, Proto.join(
      Proto.varint(3, 1319), Proto.string(19, "gemini-3.8-flash")
    ))])

    let sessions = AgentStatisticsReader.antigravitySessions(at: file)
    XCTAssertEqual(sessions.map(\.agent), ["agy"])
    XCTAssertEqual(sessions.first?.id, "used")
    let samples = sessions.first?.samples ?? []
    XCTAssertEqual(samples.reduce(0) { $0 + $1.messages }, 2, "the person and one reply")
    XCTAssertEqual(samples.reduce(0) { $0 + $1.tokens }, 420, "input, output and cached input")
    XCTAssertTrue(samples.contains { $0.model == "gemini-3.8-flash" && $0.tokens == 420 })
  }

  func testAConversationWithNothingSaidCountsNothing() throws {
    let file = try makeConversation(id: "empty", steps: [], generations: [])
    XCTAssertEqual(AgentStatisticsReader.antigravitySessions(at: file), [])
  }

  // MARK: - Models and endings

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

  func testAnInterruptedTurnIsAStopAndARefusalSaysWhatWasRefused() {
    let stopped = AntigravityClient.failure(
      of: JSONObject(["status": "ERROR", "error": "interrupted"]), stopped: false
    )
    XCTAssertEqual(stopped?.isAbort, true)

    let denied = AntigravityClient.failure(of: JSONObject([
      "status": "SUCCESS",
      "denied_actions": [["action": "command", "display_name": "RunCommand"]],
    ]), stopped: false)
    XCTAssertEqual(denied?.name, AntigravityClient.deniedName)
    XCTAssertTrue(denied?.message.contains("RunCommand") == true)
    XCTAssertFalse(
      denied?.message.contains("Turn on Auto Mode") == true,
      "Auto Mode is accept-edits: it would not let a command through"
    )
    let edit = AntigravityClient.failure(of: JSONObject([
      "status": "SUCCESS",
      "denied_actions": [["action": "write_file", "display_name": "WriteToFile"]],
    ]), stopped: false)
    XCTAssertTrue(edit?.message.contains("Turn on Auto Mode") == true)

    XCTAssertNil(AntigravityClient.failure(of: JSONObject(["status": "SUCCESS"]), stopped: false))
  }

  // MARK: - The process

  /// A stand-in `agy`: says `init` at once, as the real one does, and answers
  /// each stdin line with a reply in its frames.
  func testASessionIsNamedByInitAndATurnStreams() async throws {
    let script = root.appendingPathComponent("agy")
    try """
      #!/usr/bin/python3 -I
      import json, sys
      args = sys.argv[1:]
      cid = args[args.index("--conversation") + 1] if "--conversation" in args else "minted-1"
      def say(o):
          print(json.dumps(o), flush=True)
      say({"event": "init", "conversation_id": cid, "init": {"cwd": "."}})
      for line in sys.stdin:
          text = json.loads(line)["message"]["content"]
          say({"event": "step_update", "step_update": {"conversation_id": cid, "step_index": 0, "state": "DONE", "step_type": "user_input"}})
          say({"event": "step_update", "step_update": {"conversation_id": cid, "step_index": 1, "state": "ACTIVE", "step_type": "agent_response", "text_delta": "echo: "}})
          say({"event": "step_update", "step_update": {"conversation_id": cid, "step_index": 1, "state": "DONE", "step_type": "agent_response", "text_delta": text}})
          say({"event": "result", "result": {"conversation_id": cid, "status": "SUCCESS", "response": "echo: " + text}})
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let client = makeClient(executable: script.path)
    let events = client.events()
    let info = try await client.createSession(
      id: client.makeSessionID(), options: AgentSessionOptions(directory: root.path)
    )
    XCTAssertEqual(info.id, "minted-1", "Antigravity names the conversation")

    try await client.send(messageID: "m1", text: "hi", attachments: [], to: info.id)
    let collect = Task { () -> (String, [ConversationExecutionState]) in
      var text = ""
      var states: [ConversationExecutionState] = []
      for await envelope in events {
        switch envelope.event {
        case let .partDelta(_, messageID, _, _, delta) where messageID == "m1-reply":
          text += delta
        case let .executionStateChanged(_, state):
          states.append(state)
          if state == .idle { return (text, states) }
        default:
          break
        }
      }
      return (text, states)
    }
    let deadline = Task { try? await Task.sleep(for: .seconds(10)); collect.cancel() }
    let (text, states) = await collect.value
    deadline.cancel()
    await client.shutdown()

    XCTAssertEqual(text, "echo: hi", "deltas only, never the repeated response")
    XCTAssertEqual(states, [.working, .idle])
    let sent = try await client.messageExists(id: "m1", in: info.id)
    XCTAssertFalse(sent, "shutdown forgets the session")
  }

  /// A stand-in `agy` that runs the installed hook before a command, as the
  /// real one does, and reports what the hook decided in its reply.
  func testACommandAsksThroughTheGateAndARefusalCarriesTheWords() async throws {
    let hooks = root.appendingPathComponent("config/hooks.json")
    let script = root.appendingPathComponent("agy")
    try """
      #!/usr/bin/python3 -I
      import json, subprocess, sys
      args = sys.argv[1:]
      assert "--dangerously-skip-permissions" in args
      cid = "gated-1"
      def say(o):
          print(json.dumps(o), flush=True)
      say({"event": "init", "conversation_id": cid, "init": {"cwd": "."}})
      for line in sys.stdin:
          hooks = json.load(open("\(hooks.path)"))
          command = hooks["\(AntigravityPermissionGate.hookName)"]["PreToolUse"][0]["hooks"][0]["command"]
          payload = {"conversationId": cid, "workspacePaths": ["\(root.path)"],
                     "toolCall": {"name": "run_command", "args": {"CommandLine": "rm -rf build"}}}
          answer = subprocess.run(command, shell=True, input=json.dumps(payload),
                                  capture_output=True, text=True).stdout
          say({"event": "step_update", "step_update": {"conversation_id": cid, "step_index": 1, "state": "DONE", "step_type": "agent_response", "text_delta": answer.strip()}})
          say({"event": "result", "result": {"conversation_id": cid, "status": "SUCCESS"}})
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let client = makeClient(executable: script.path)
    let conversation = UUID()
    client.setConversationResolver { _ in conversation }
    let events = client.events()
    let info = try await client.createSession(
      id: "x", options: AgentSessionOptions(directory: root.path)
    )
    try await client.send(messageID: "m1", text: "clean up", attachments: [], to: info.id)

    let collect = Task { () -> (PendingInteraction?, String) in
      var asked: PendingInteraction?
      var text = ""
      for await envelope in events {
        switch envelope.event {
        case let .interactionAsked(interaction):
          asked = interaction
          try? await client.answerPermission(
            requestID: interaction.id, sessionID: info.id, decision: .reject, message: "use make clean"
          )
        case let .partDelta(_, _, _, _, delta):
          text += delta
        case let .executionStateChanged(_, state) where state == .idle:
          return (asked, text)
        default:
          break
        }
      }
      return (asked, text)
    }
    let deadline = Task { try? await Task.sleep(for: .seconds(15)); collect.cancel() }
    let (asked, text) = await collect.value
    deadline.cancel()
    await client.shutdown()

    guard case let .permission(prompt) = asked?.kind else { return XCTFail("no card") }
    XCTAssertEqual(asked?.conversationID, conversation)
    XCTAssertEqual(prompt.action, "command")
    XCTAssertEqual(prompt.resources, ["rm -rf build"])
    XCTAssertEqual(
      JSONObject(line: text)?.string("decision"), "deny", text
    )
    XCTAssertEqual(
      JSONObject(line: text)?.string("reason"),
      "The user refused this and said: use make clean"
    )
  }

  // MARK: - Files the person sent

  func testAFileThePersonSentIsReadWithoutACardAndNothingElseOutsideIs() {
    let sent = OutgoingAttachment(
      url: URL(fileURLWithPath: "/Users/x/Library/Application Support/Boltty/a/3f2a1b2c-image1.png"),
      displayName: "image1.png", mimeType: "image/png"
    )
    let granted = AntigravityToolPolicy.readGrants(for: [sent])
    func verdict(_ path: String) -> AntigravityToolPolicy.Verdict {
      AntigravityToolPolicy.verdict(
        tool: "view_file", arguments: JSONObject(["AbsolutePath": path]),
        directory: "/Users/x/project", autoApprove: false, granted: granted
      )
    }
    XCTAssertEqual(verdict(sent.url.path), .allow)
    XCTAssertEqual(
      verdict("/Users/x/Library/Application Support/Boltty/a/../a/3f2a1b2c-image1.png"), .allow,
      "the same file, spelled another way"
    )
    XCTAssertEqual(
      verdict("/Users/x/Library/Application Support/Boltty/a/other.png"),
      .ask(
        action: "read", resources: ["/Users/x/Library/Application Support/Boltty/a/other.png"],
        always: "read:/Users/x/Library/Application Support/Boltty/a/other.png"
      ),
      "only what was sent, not its folder"
    )
  }

  /// A stand-in `agy` that asks the installed hook about a `view_file` on
  /// the file it was sent, as the real one does before opening a picture.
  func testASentPictureIsOpenedWithoutAskingThePerson() async throws {
    let hooks = root.appendingPathComponent("config/hooks.json")
    let picture = root.appendingPathComponent("elsewhere/image1.png")
    let script = root.appendingPathComponent("agy")
    try """
      #!/usr/bin/python3 -I
      import json, subprocess, sys
      cid = "pictured-1"
      def say(o):
          print(json.dumps(o), flush=True)
      say({"event": "init", "conversation_id": cid, "init": {"cwd": "."}})
      for line in sys.stdin:
          hooks = json.load(open("\(hooks.path)"))
          command = hooks["\(AntigravityPermissionGate.hookName)"]["PreToolUse"][0]["hooks"][0]["command"]
          payload = {"conversationId": cid, "workspacePaths": ["\(root.path)/project"],
                     "toolCall": {"name": "view_file", "args": {"AbsolutePath": "\(picture.path)"}}}
          answer = subprocess.run(command, shell=True, input=json.dumps(payload),
                                  capture_output=True, text=True).stdout
          say({"event": "step_update", "step_update": {"conversation_id": cid, "step_index": 1, "state": "DONE", "step_type": "agent_response", "text_delta": answer.strip()}})
          say({"event": "result", "result": {"conversation_id": cid, "status": "SUCCESS"}})
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("project"), withIntermediateDirectories: true
    )
    let client = makeClient(executable: script.path)
    client.setConversationResolver { _ in UUID() }
    let events = client.events()
    let info = try await client.createSession(
      id: "x", options: AgentSessionOptions(directory: root.appendingPathComponent("project").path)
    )
    try await client.send(
      messageID: "m1", text: "what is this? \(picture.path)",
      attachments: [OutgoingAttachment(url: picture, displayName: "image1.png", mimeType: "image/png")],
      to: info.id
    )

    let collect = Task { () -> (Bool, String) in
      var asked = false
      var text = ""
      for await envelope in events {
        switch envelope.event {
        case .interactionAsked:
          asked = true
        case let .partDelta(_, _, _, _, delta):
          text += delta
        case let .executionStateChanged(_, state) where state == .idle:
          return (asked, text)
        default:
          break
        }
      }
      return (asked, text)
    }
    let deadline = Task { try? await Task.sleep(for: .seconds(15)); collect.cancel() }
    let (asked, text) = await collect.value
    deadline.cancel()
    await client.shutdown()

    XCTAssertFalse(asked, "no card for a file the person sent")
    XCTAssertEqual(JSONObject(line: text)?.string("decision"), "allow", text)
  }

  func testACLIThatExitsBeforeInitSaysWhy() async throws {
    let script = root.appendingPathComponent("agy")
    try """
      #!/bin/sh
      echo "Error: unknown flag" >&2
      exit 2
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let client = makeClient(executable: script.path)
    do {
      _ = try await client.createSession(id: "x", options: AgentSessionOptions(directory: root.path))
      XCTFail("a CLI that exits cannot have started a session")
    } catch let error as AgentClientError {
      XCTAssertEqual(error, .serverStartFailed("Error: unknown flag"))
    }
  }

  // MARK: - Helpers

  /// Never the person's `~/.gemini`: the hook and its folder live in `root`.
  private func makeClient(executable: String) -> AntigravityClient {
    AntigravityClient(
      executable: executable,
      transcriptRoot: root,
      hooksFile: root.appendingPathComponent("config/hooks.json"),
      scriptFile: root.appendingPathComponent("gate.sh"),
      gateDirectory: root.appendingPathComponent("gate")
    )
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

/// Writes protobuf the way `agy` stores it, to test the schemaless reader.
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
