import XCTest
@testable import Boltty

@MainActor
final class CodexSessionRecoveryTests: XCTestCase {
  private var root: URL!
  private var client: CodexClient!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = root.appendingPathComponent("codex-fixture")
    try Self.fixture.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    client = CodexClient(executable: script.path, codexHome: root.appendingPathComponent("codex-home"))
    let client = client!
    let root = root!
    addTeardownBlock {
      await client.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func requests() throws -> [JSONObject] {
    try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
      .split(separator: "\n").compactMap { JSONObject(line: String($0)) }
  }

  private func send(to id: String = "saved") async throws {
    try await client.send(messageID: "msg_followup", text: "Continue", attachments: [], to: id)
  }

  func testPersistedConversationResumesBeforeSendingAndKeepsItsHistory() async throws {
    let persistenceRoot = root.appendingPathComponent("store")
    let original = ConversationStore(persistence: ConversationPersistence(root: persistenceRoot))
    let conversation = original.createConversation(title: "Saved", workingDirectory: "/tmp", providerID: "codex")
    original.attachRemoteSession("saved", to: conversation.id, model: nil)
    original.appendUserMessage(id: "old", text: "Earlier message", attachments: [], to: conversation.id)
    original.close()

    let store = ConversationStore(persistence: ConversationPersistence(root: persistenceRoot))
    defer { store.close() }
    let engine = ConversationEngine(store: store, client: client)
    let sent = await engine.send(text: "Continue", in: conversation.id)

    XCTAssertTrue(sent)
    XCTAssertEqual(store.conversation(id: conversation.id)?.remoteSessionID, "saved")
    XCTAssertEqual(store.transcript(id: conversation.id).messages.map(\.plainText), ["Earlier message", "Continue"])
    XCTAssertNil(engine.notices[conversation.id])
    let calls = try requests()
    XCTAssertEqual(calls.compactMap { $0.string("method") }, ["initialize", "initialized", "thread/resume", "turn/start"])
    let turn = try XCTUnwrap(calls.last?.object("params"))
    XCTAssertEqual(turn.string("model"), "saved-model")
    XCTAssertEqual(turn.string("effort"), "low")
    XCTAssertEqual(turn.string("approvalPolicy"), "on-request")
  }

  func testExistingThreadIsResumedAgainAfterServerRestart() async throws {
    let info = try await client.createSession(id: "local", options: AgentSessionOptions(
      directory: "/tmp", model: ModelSelection(providerID: "codex", modelID: "chosen-model"),
      effort: "high", autoApprove: true
    ))
    await client.shutdown()
    try await send(to: info.id)
    let calls = try requests()
    XCTAssertEqual(calls.filter { $0.string("method") == "thread/start" }.count, 1)
    XCTAssertEqual(calls.filter { $0.string("method") == "thread/resume" }.count, 1)
    XCTAssertEqual(calls.last?.object("params")?.string("model"), "chosen-model")
    XCTAssertEqual(calls.last?.object("params")?.string("effort"), "high")
    XCTAssertEqual(calls.last?.object("params")?.string("approvalPolicy"), "never")
  }

  func testLoadedThreadDoesNotResumeOnEverySend() async throws {
    try await send()
    try await send()
    let methods = try requests().compactMap { $0.string("method") }
    XCTAssertEqual(methods.filter { $0 == "thread/resume" }.count, 1)
    XCTAssertEqual(methods.filter { $0 == "turn/start" }.count, 2)
  }

  func testAutoApprovalChangeOnSavedThreadIsNotLost() async throws {
    try await client.setAutoApproval(true, sessionID: "saved")
    try await send()
    XCTAssertEqual(try requests().last?.object("params")?.string("approvalPolicy"), "never")
  }

  func testMissingRolloutIsReportedAsSessionNotFound() async throws {
    do {
      try await send(to: "missing")
      XCTFail("A missing rollout must not accept a turn")
    } catch {
      XCTAssertEqual(error as? AgentClientError, .sessionNotFound)
    }
    XCTAssertFalse(try requests().contains { $0.string("method") == "turn/start" })
  }

  private var sessionsDay: URL {
    root.appendingPathComponent("codex-home/sessions/2026/09/22")
  }

  @discardableResult
  private func writeRollout(id: String, lines: [String]) throws -> URL {
    try FileManager.default.createDirectory(at: sessionsDay, withIntermediateDirectories: true)
    let url = sessionsDay.appendingPathComponent("rollout-2026-09-22T10-00-00-\(id).jsonl")
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func testAnUnreadableRolloutDoesNotPretendTheHistoryWasDeleted() async throws {
    let rollout = try writeRollout(id: "unreadable", lines: ["{}"])
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rollout.path)
    addTeardownBlock {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rollout.path)
    }
    do {
      _ = try await client.loadSession(id: "unreadable")
      XCTFail("an unreadable rollout must not come back as a transcript")
    } catch let error as AgentClientError {
      guard case .transport = error else { return XCTFail("expected transport, got \(error)") }
    }
  }

  func testReadingAThreadComesFromItsRolloutAndNeverStartsTheServer() async throws {
    try writeRollout(id: "on-disk", lines: [
      #"{"timestamp":"2026-09-22T10:00:01.000Z","type":"response_item","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"input_text","text":"make the button blue"}]}}"#,
      #"{"timestamp":"2026-09-22T10:00:02.000Z","type":"response_item","payload":{"type":"message","id":"m2","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#,
    ])

    let snapshot = try await client.loadSession(id: "on-disk")

    XCTAssertEqual(snapshot.messages.map(\.plainText), ["make the button blue", "Done."])
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("requests").path),
      "the app-server was started to read a file that was already on disk"
    )
  }

  func testAThreadWithNoRolloutAndNothingRunningHereIsNotFound() async throws {
    do {
      _ = try await client.loadSession(id: "nowhere")
      XCTFail("there is nothing to read")
    } catch {
      XCTAssertEqual(error as? AgentClientError, .sessionNotFound)
    }
  }

  func testAThreadRunningHereButNotYetWrittenIsNotReportedGone() async throws {
    let info = try await client.createSession(id: "local", options: AgentSessionOptions(
      directory: "/tmp", model: nil, effort: nil, autoApprove: false
    ))

    let snapshot = try await client.loadSession(id: info.id)

    XCTAssertEqual(snapshot.info.directory, "/tmp")
    XCTAssertEqual(snapshot.messages, [])
  }

  func testUnloadedThreadIsResumedOnceWithoutCreatingANewThread() async throws {
    try await send(to: "unloaded")
    let methods = try requests().compactMap { $0.string("method") }
    XCTAssertEqual(methods.filter { $0 == "thread/resume" }.count, 2)
    XCTAssertEqual(methods.filter { $0 == "turn/start" }.count, 2)
    XCTAssertFalse(methods.contains("thread/start"))
  }

  func testOrdinaryTurnFailureIsNotRetried() async throws {
    do {
      try await send(to: "refused")
      XCTFail("The fixture refuses this turn")
    } catch {
      XCTAssertEqual(error as? AgentClientError, .transport("model unavailable"))
    }
    XCTAssertEqual(try requests().filter { $0.string("method") == "turn/start" }.count, 1)
  }

  func testInitializeRefusesUnreadTrafficAndResumeSkipsTheTurns() async throws {
    try await send()
    let calls = try requests()
    let initialize = try XCTUnwrap(calls.first { $0.string("method") == "initialize" }?.object("params"))
    let refused = initialize.object("capabilities")?.raw["optOutNotificationMethods"] as? [String]
    XCTAssertEqual(refused, CodexClient.unreadNotifications)
    XCTAssertTrue(refused?.contains("turn/diff/updated") == true)
    let resume = try XCTUnwrap(calls.first { $0.string("method") == "thread/resume" }?.object("params"))
    XCTAssertEqual(resume.bool("excludeTurns"), true)
  }

  func testAnIdleThreadIsLetGoAndResumedForTheNextSend() async throws {
    client.idleUnloadDelay = 0.05
    try await send(to: "finishes")
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline, try !requests().contains(where: { $0.string("method") == "thread/unsubscribe" }) {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(try requests().contains { $0.string("method") == "thread/unsubscribe" }, "the idle thread was let go")
    try await Task.sleep(for: .milliseconds(100))
    // The second turn is not let go within the test: at 50 ms its own idle
    // timer fired before the log was read whenever the bundle ran loaded.
    client.idleUnloadDelay = 60
    try await send(to: "finishes")
    let methods = try requests().compactMap { $0.string("method") }.filter { $0 != "initialized" }
    XCTAssertEqual(methods, ["initialize", "thread/resume", "turn/start", "thread/unsubscribe",
                             "thread/resume", "turn/start"])
  }

  private static let fixture = #"""
    #!/usr/bin/env python3
    import json, os, sys
    root = os.path.dirname(os.path.abspath(__file__))
    loaded = set()
    unloaded_once = False
    for line in sys.stdin:
        request = json.loads(line)
        with open(os.path.join(root, 'requests'), 'a') as log:
            log.write(json.dumps(request) + '\n')
        if 'id' not in request:
            continue
        method, params = request['method'], request.get('params', {})
        tid = params.get('threadId')
        result, error = {}, None
        if method == 'thread/start':
            loaded.add('created')
            result = {'thread': {'id': 'created'}, 'cwd': '/tmp'}
        elif method == 'thread/resume':
            if tid == 'missing':
                error = 'no rollout found for thread id ' + tid
            elif tid == 'unreadable':
                error = 'permission denied reading rollout'
            else:
                loaded.add(tid)
                result = {'thread': {'id': tid}, 'cwd': '/tmp', 'model': 'saved-model', 'reasoningEffort': 'low', 'approvalPolicy': 'on-request'}
        elif method == 'turn/start':
            if tid == 'unloaded' and not unloaded_once:
                loaded.discard(tid)
                unloaded_once = True
            if tid not in loaded:
                error = 'thread not found: ' + tid
            elif tid == 'refused':
                error = 'model unavailable'
            else:
                result = {'turn': {'id': 'turn-1'}}
                if tid == 'finishes':
                    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
                    for note in ({'method': 'turn/started', 'params': {'threadId': tid, 'turn': {'id': 'turn-1'}}},
                                 {'method': 'turn/completed', 'params': {'threadId': tid, 'turn': {'id': 'turn-1', 'status': 'completed'}}}):
                        print(json.dumps(note), flush=True)
                    continue
        elif method == 'thread/unsubscribe':
            loaded.discard(tid)
            result = {'status': 'unsubscribed'}
        elif method == 'thread/items/list':
            result = {'data': []}
        response = {'id': request['id']}
        if error:
            response['error'] = {'code': -32600, 'message': error}
        else:
            response['result'] = result
        print(json.dumps(response), flush=True)
    """#
}

final class CodexTurnInputTests: XCTestCase {
  func testAPictureOnDiskIsALocalImage() {
    let picture = URL(fileURLWithPath: "/tmp/boltty/image1.png")
    let notes = URL(fileURLWithPath: "/tmp/boltty/notes.txt")

    let input = CodexClient.turnInput(text: "What is this?", attachments: [
      OutgoingAttachment(url: picture, displayName: "image1.png", mimeType: nil),
      OutgoingAttachment(url: notes, displayName: "notes.txt", mimeType: nil),
    ])

    XCTAssertEqual(input.count, 3)
    XCTAssertEqual(input[1]["type"] as? String, "localImage")
    XCTAssertEqual(input[1]["path"] as? String, "/tmp/boltty/image1.png")
    XCTAssertEqual(input[2]["text"] as? String, "Attached file: /tmp/boltty/notes.txt")
  }
}
