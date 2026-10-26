import Foundation
import XCTest
@testable import Boltty

@MainActor
final class GrokHistoryTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-grok-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let root = root!
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
  }

  private var sessions: URL { root.appendingPathComponent("sessions") }

  @discardableResult
  private func writeSession(id: String, history: [String]?) throws -> URL {
    let directory = sessions.appendingPathComponent("%2FUsers%2Fme%2Fwork")
      .appendingPathComponent(id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let summary = #"{"info":{"id":"\#(id)","cwd":"/Users/me/work"},"num_messages":2,"session_summary":"Tray","last_active_at":"2026-09-22T10:00:00.000000Z"}"#
    try summary.write(to: directory.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
    if let history {
      try (history.joined(separator: "\n") + "\n").write(
        to: directory.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8
      )
    }
    return directory
  }

  private func client(executable: String = "/nonexistent/grok") -> ACPClient {
    let sessions = sessions
    var agent = ACPAgent.grok
    agent.history = { try GrokChatHistoryTranscript.transcript(sessionID: $0, in: sessions) }
    return ACPClient(agent: agent, executable: executable)
  }

  // MARK: - Reading

  func testGrokAndCodexNowDeclareTheyCanFollowAChat() {
    XCTAssertTrue(ACPAgent.grok.capabilities.contains(.rereadableTranscript))
    XCTAssertTrue(CodexClient().capabilities.contains(.rereadableTranscript))
  }

  func testReadingASessionComesFromItsHistoryAndNeverStartsTheAgent() async throws {
    try writeSession(id: "chat", history: [
      #"{"type":"user","content":[{"type":"text","text":"<user_query>\nwhy is the tray blank\n</user_query>"}]}"#,
      #"{"type":"assistant","content":"Looking now."}"#,
    ])

    let snapshot = try await client().loadSession(id: "chat")

    XCTAssertEqual(snapshot.messages.map(\.plainText), ["why is the tray blank", "Looking now."])
    XCTAssertEqual(snapshot.info.directory, "/Users/me/work")
    XCTAssertEqual(snapshot.info.title, "Tray")
  }

  func testASessionThatHasNotTakenATurnIsEmptyRatherThanMissing() async throws {
    try writeSession(id: "fresh", history: nil)

    let snapshot = try await client().loadSession(id: "fresh")

    XCTAssertEqual(snapshot.messages, [])
  }

  func testASessionWithNoDirectoryAndNothingRunningHereIsNotFound() async throws {
    do {
      _ = try await client().loadSession(id: "nowhere")
      XCTFail("there is nothing to read")
    } catch {
      XCTAssertEqual(error as? AgentClientError, .sessionNotFound)
    }
  }

  func testAnUnreadableHistoryIsATransportFailureNotADeletion() async throws {
    let directory = try writeSession(id: "locked", history: [#"{"type":"assistant","content":"x"}"#])
    let history = directory.appendingPathComponent("chat_history.jsonl")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: history.path)
    addTeardownBlock {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: history.path)
    }

    do {
      _ = try await client().loadSession(id: "locked")
      XCTFail("an unreadable history must not come back as a transcript")
    } catch let error as AgentClientError {
      guard case .transport = error else { return XCTFail("expected transport, got \(error)") }
    }
  }

  // MARK: - Sending into a session this process has not seen

  private func fixtureAgent() throws -> String {
    let script = root.appendingPathComponent("grok-fixture")
    try Self.fixture.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script.path
  }

  private func requests() throws -> [String] {
    try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
      .split(separator: "\n")
      .compactMap { JSONObject(line: String($0))?.string("method") }
  }

  func testSendingIntoASessionFromElsewhereLoadsItAndTheReplayIsNotTheReply() async throws {
    let client = ACPClient(agent: .grok, executable: try fixtureAgent())
    addTeardownBlock { await client.shutdown() }
    let events = client.events()
    let received = Task { () -> [String] in
      var deltas: [String] = []
      for await envelope in events {
        if case let .partDelta(_, _, _, _, delta) = envelope.event { deltas.append(delta) }
        if case .executionStateChanged(_, .idle) = envelope.event { break }
      }
      return deltas
    }

    try await client.send(messageID: "msg_1", text: "ping", attachments: [], to: "elsewhere")
    let deltas = await received.value

    XCTAssertEqual(try requests().filter { $0.hasPrefix("session/") },
                   ["session/load", "session/prompt"])
    XCTAssertEqual(deltas, ["pong"], "the replayed history is not this turn's reply")
  }

  func testASessionTheAgentHasLostIsNotFoundSoTheEngineCanStartAnew() async throws {
    let client = ACPClient(agent: .grok, executable: try fixtureAgent())
    addTeardownBlock { await client.shutdown() }

    do {
      try await client.send(messageID: "msg_1", text: "ping", attachments: [], to: "lost")
      XCTFail("a session the agent cannot load must not accept a turn")
    } catch {
      XCTAssertEqual(error as? AgentClientError, .sessionNotFound)
    }
    XCTAssertFalse(try requests().contains("session/prompt"))
  }

  func testConcurrentFirstCallsStartOneAgent() async throws {
    let client = ACPClient(agent: .grok, executable: try fixtureAgent())
    addTeardownBlock { await client.shutdown() }

    async let first = client.usageLimits()
    async let second = client.usageLimits()
    async let third = try? client.availableModels()
    _ = await (first, second, third)

    XCTAssertEqual(try requests().filter { $0 == "initialize" }.count, 1)
  }

  private static let fixture = #"""
    #!/usr/bin/env python3
    import json, os, sys
    root = os.path.dirname(os.path.abspath(__file__))
    known = set()
    def say(obj):
        print(json.dumps(obj), flush=True)
    def update(sid, text):
        say({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': sid,
             'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': text}}}})
    for line in sys.stdin:
        request = json.loads(line)
        with open(os.path.join(root, 'requests'), 'a') as log:
            log.write(json.dumps(request) + '\n')
        if 'id' not in request:
            continue
        method, params = request['method'], request.get('params', {})
        sid = params.get('sessionId')
        if method == 'session/load':
            if sid == 'lost':
                say({'id': request['id'], 'error': {'code': -32602, 'message': 'session not found'}})
                continue
            # ACP replays the history before it answers.
            update(sid, 'OLD HISTORY')
            known.add(sid)
            say({'id': request['id'], 'result': {}})
        elif method == 'session/prompt':
            if sid not in known:
                say({'id': request['id'], 'error': {'code': -32602, 'message': 'unknown session'}})
                continue
            update(sid, 'pong')
            say({'id': request['id'], 'result': {'stopReason': 'end_turn'}})
        else:
            say({'id': request['id'], 'result': {'protocolVersion': 1,
                 'agentCapabilities': {'loadSession': True}}})
    """#
}

final class ACPPromptBlockTests: XCTestCase {
  func testAPictureGoesAsItsBytesAndAFileAsItsPath() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-acp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let picture = folder.appendingPathComponent("image1.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
    let notes = folder.appendingPathComponent("notes.txt")
    try Data("hi".utf8).write(to: notes)

    let blocks = ACPClient.promptBlocks(text: "What is this?", attachments: [
      OutgoingAttachment(url: picture, displayName: "image1.png", mimeType: "image/png"),
      OutgoingAttachment(url: notes, displayName: "notes.txt", mimeType: nil),
    ])

    XCTAssertEqual(blocks.count, 3)
    XCTAssertEqual(blocks[0]["text"] as? String, "What is this?")
    XCTAssertEqual(blocks[1]["type"] as? String, "image")
    XCTAssertEqual(blocks[1]["mimeType"] as? String, "image/png")
    XCTAssertEqual(blocks[1]["data"] as? String, Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
    XCTAssertEqual(blocks[2]["text"] as? String, "Attached file: \(notes.path)")
  }
}

@MainActor
final class GrokPlanTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-grok-plan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let root = root!
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
  }

  private static let plan = "# Rename the tray\n\n1. Rename it.\n2. Test it."

  private func client(resolving: Bool = true) throws -> ACPClient {
    let script = root.appendingPathComponent("grok-fixture")
    try Self.fixture.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    var agent = ACPAgent.grok
    agent.history = nil
    let client = ACPClient(agent: agent, executable: script.path)
    if resolving {
      let conversation = UUID()
      client.setConversationResolver { _ in conversation }
    }
    addTeardownBlock { await client.shutdown() }
    return client
  }

  private func responses() throws -> [Int: JSONObject] {
    let text = (try? String(contentsOf: root.appendingPathComponent("responses"), encoding: .utf8)) ?? ""
    var byID: [Int: JSONObject] = [:]
    for line in text.split(separator: "\n") {
      guard let frame = JSONObject(line: String(line)), let id = frame.int("id") else { continue }
      byID[id] = frame
    }
    return byID
  }

  private func turn(
    _ client: ACPClient,
    prompt: String = "plan it",
    answer: ((PendingInteraction) async throws -> Void)? = nil
  ) async throws -> [AgentEvent] {
    let events = client.events()
    let received = Task { () -> [AgentEvent] in
      var seen: [AgentEvent] = []
      for await envelope in events {
        seen.append(envelope.event)
        if case let .interactionAsked(interaction) = envelope.event {
          try? await answer?(interaction)
        }
        if case .executionStateChanged(_, .idle) = envelope.event { break }
      }
      return seen
    }
    try await client.send(messageID: "msg_1", text: prompt, attachments: [], to: "ses_plan")
    return await received.value
  }

  func testThePlanIsAskedAndSentBackWithItsWords() async throws {
    let client = try client()
    let events = try await turn(client) { interaction in
      try await client.answerPlan(
        requestID: interaction.id, sessionID: interaction.remoteSessionID,
        decision: .cancelled, feedback: "  smaller steps ")
    }

    let asked = events.compactMap { event -> PendingInteraction? in
      if case let .interactionAsked(interaction) = event { return interaction }
      return nil
    }
    XCTAssertEqual(asked.count, 1)
    XCTAssertEqual(asked.first?.id, "call-1", "the card is addressed by the tool call")
    XCTAssertEqual(asked.first?.kind, .plan(PlanPrompt(markdown: Self.plan, toolCallID: "call-1")))
    XCTAssertTrue(events.contains(.interactionResolved(
      sessionID: "ses_plan", requestID: "call-1", resolution: .plan(.cancelled))))

    let answer = try XCTUnwrap(try responses()[900]?.object("result"))
    XCTAssertEqual(answer.string("outcome"), "cancelled")
    XCTAssertEqual(answer.string("feedback"), "smaller steps")
  }

  func testThePlanIsTheTurnsTextAndNotAToolRow() async throws {
    let client = try client()
    let events = try await turn(client) { interaction in
      try await client.answerPlan(
        requestID: interaction.id, sessionID: interaction.remoteSessionID,
        decision: .approved, feedback: nil)
    }

    let activities = events.compactMap { event -> String? in
      if case let .partUpdated(_, _, .activity(activity)) = event { return activity.name }
      return nil
    }
    XCTAssertFalse(activities.contains("exit_plan_mode"), "the plan is not drawn twice")
    let planParts = events.compactMap { event -> String? in
      if case let .partUpdated(_, _, .text(text)) = event { return text.text }
      return nil
    }
    XCTAssertEqual(planParts, [Self.plan])
    let deltas = events.compactMap { event -> String? in
      if case let .partDelta(_, _, partID, _, delta) = event { return "\(partID): \(delta)" }
      return nil
    }
    XCTAssertEqual(deltas, ["msg_1-reply-text: Planning.", "msg_1-reply-text-1: Done."],
                   "what follows the plan is a part of its own, after it")

    let snapshot = try await client.loadSession(id: "ses_plan")
    let reply = try XCTUnwrap(snapshot.messages.first { $0.id == "msg_1-reply" })
    XCTAssertEqual(reply.parts.map(\.id), [
      "msg_1-reply-text", "msg_1-reply-plan-call-1", "msg_1-reply-text-1",
    ])
    XCTAssertEqual(try responses()[900]?.object("result")?.string("outcome"), "approved")
  }

  func testAnEmptyPlanIsStillAsked() async throws {
    let client = try client()
    let events = try await turn(client, prompt: "empty") { interaction in
      try await client.answerPlan(
        requestID: interaction.id, sessionID: interaction.remoteSessionID,
        decision: .abandoned, feedback: "ignored")
    }

    XCTAssertTrue(events.contains { event in
      if case let .interactionAsked(interaction) = event {
        return interaction.kind == .plan(PlanPrompt(markdown: "", toolCallID: "call-1"))
      }
      return false
    })
    let answer = try XCTUnwrap(try responses()[900]?.object("result"))
    XCTAssertEqual(answer.string("outcome"), "abandoned")
    XCTAssertNil(answer.string("feedback"), "only a plan sent back carries words")
  }

  func testAPlanNoConversationOwnsIsAbandoned() async throws {
    let client = try client(resolving: false)
    let events = try await turn(client)

    XCTAssertFalse(events.contains { if case .interactionAsked = $0 { return true }; return false })
    XCTAssertEqual(try responses()[900]?.object("result")?.string("outcome"), "abandoned")
  }

  func testARequestBolttyDoesNotHaveIsStillMethodNotFound() async throws {
    let client = try client()
    _ = try await turn(client) { interaction in
      try await client.answerPlan(
        requestID: interaction.id, sessionID: interaction.remoteSessionID,
        decision: .approved, feedback: nil)
    }

    XCTAssertEqual(try responses()[901]?.object("error")?.int("code"), -32601)
  }

  func testAPlanAlreadyAnsweredIsGone() async throws {
    let client = try client()
    do {
      try await client.answerPlan(requestID: "call-1", sessionID: "ses_plan", decision: .approved, feedback: nil)
      XCTFail("there is no plan to answer")
    } catch {
      XCTAssertEqual(error as? AgentClientError, .requestGone)
    }
  }

  func testTheThreeAnswersOnTheWire() {
    XCTAssertEqual(ACPClient.planResult(.approved, feedback: "words") as NSDictionary,
                   ["outcome": "approved"])
    XCTAssertEqual(ACPClient.planResult(.cancelled, feedback: " tighter ") as NSDictionary,
                   ["outcome": "cancelled", "feedback": "tighter"])
    XCTAssertEqual(ACPClient.planResult(.cancelled, feedback: "  ") as NSDictionary,
                   ["outcome": "cancelled"])
    XCTAssertEqual(ACPClient.planResult(.abandoned, feedback: nil) as NSDictionary,
                   ["outcome": "abandoned"])
  }

  func testOtherAgentsHaveNoPlanToAnswer() async {
    do {
      try await CodexClient().answerPlan(requestID: "p", sessionID: "s", decision: .approved, feedback: nil)
      XCTFail("Codex never asks for a plan")
    } catch {
      XCTAssertEqual(error as? AgentClientError, .requestGone)
    }
  }

  private static let fixture = #"""
    #!/usr/bin/env python3
    import json, os, sys
    root = os.path.dirname(os.path.abspath(__file__))
    PLAN = '# Rename the tray\n\n1. Rename it.\n2. Test it.'
    def say(obj):
        print(json.dumps(obj), flush=True)
    def log(frame):
        with open(os.path.join(root, 'responses'), 'a') as out:
            out.write(json.dumps(frame) + '\n')
    def update(sid, body):
        say({'jsonrpc': '2.0', 'method': 'session/update',
             'params': {'sessionId': sid, 'update': body}})
    def chunk(sid, text):
        update(sid, {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': text}})
    def wait_for(rid):
        while True:
            line = sys.stdin.readline()
            if not line:
                sys.exit(0)
            frame = json.loads(line)
            if 'method' not in frame:
                log(frame)
                if frame.get('id') == rid:
                    return frame
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        request = json.loads(line)
        if 'method' not in request:
            log(request)
            continue
        if 'id' not in request:
            continue
        method, params = request['method'], request.get('params', {})
        sid = params.get('sessionId')
        if method == 'session/prompt':
            text = params['prompt'][0]['text']
            chunk(sid, 'Planning.')
            update(sid, {'sessionUpdate': 'tool_call', 'toolCallId': 'call-1', 'title': 'exit_plan_mode',
                         'rawInput': {}, '_meta': {'x.ai/tool': {'name': 'exit_plan_mode', 'kind': 'exit_plan'}}})
            say({'jsonrpc': '2.0', 'id': 901, 'method': 'x.ai/not_a_thing', 'params': {'sessionId': sid}})
            wait_for(901)
            ask = {'sessionId': sid, 'toolCallId': 'call-1'}
            if text != 'empty':
                ask['planContent'] = PLAN
            say({'jsonrpc': '2.0', 'id': 900, 'method': 'x.ai/exit_plan_mode', 'params': ask})
            wait_for(900)
            update(sid, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'call-1', 'status': 'completed'})
            chunk(sid, 'Done.')
            say({'jsonrpc': '2.0', 'id': request['id'], 'result': {'stopReason': 'end_turn'}})
        else:
            say({'jsonrpc': '2.0', 'id': request['id'], 'result': {'protocolVersion': 1,
                 'agentCapabilities': {'loadSession': True}}})
    """#
}
