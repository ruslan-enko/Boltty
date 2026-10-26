import XCTest
@testable import Boltty

final class ClaudeCodeWakeTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testATurnTheCLIOpensItselfIsWorkingThenIdle() async throws {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
    let script = root.appendingPathComponent("claude")
    try """
      #!/bin/sh
      BOLTTY_REPLAY_GAP=0.02 BOLTTY_REPLAY='\(fixtures.appendingPathComponent("claude-background-wake.jsonl").path)' \\
        exec /usr/bin/python3 '\(fixtures.appendingPathComponent("replay-cli.py").path)' "$@"
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let client = ClaudeCodeClient(executable: script.path)
    let events = client.events()
    let id = client.makeSessionID()
    _ = try await client.createSession(id: id, options: AgentSessionOptions(directory: root.path))
    try await client.send(messageID: "m1", text: "start it in the background", attachments: [], to: id)

    let collect = Task { () -> [ConversationExecutionState] in
      var states: [ConversationExecutionState] = []
      for await envelope in events {
        if case let .executionStateChanged(sessionID, state) = envelope.event, sessionID == id {
          states.append(state)
          if states.count >= 4 { break }
        }
      }
      return states
    }
    let deadline = Task { try? await Task.sleep(for: .seconds(15)); collect.cancel() }
    let states = await collect.value
    deadline.cancel()
    await client.shutdown()
    XCTAssertEqual(states, [.working, .idle, .working, .idle])
  }
}
