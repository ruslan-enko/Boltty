import Foundation
import XCTest
@testable import Boltty

/// One real turn through the installed `agy`, then the conversation read back
/// off its own `.db` — the protobuf reader against a file `agy` wrote.
final class AntigravityLiveTests: XCTestCase {
  func testATurnIsAnsweredAndReadBackOffTheRecord() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["BOLTTY_LIVE_AGY"] != nil,
      "set BOLTTY_LIVE_AGY to spend one Antigravity turn"
    )
    let client = AntigravityClient()
    addTeardownBlock { await client.shutdown() }
    guard case .available = await client.probe() else { throw XCTSkip("agy is not installed") }
    let models = try await client.availableModels()
    XCTAssertFalse(models.isEmpty)

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let events = client.events()
    let info = try await client.createSession(
      id: client.makeSessionID(), options: AgentSessionOptions(directory: folder.path)
    )
    try await client.send(
      messageID: "m1", text: "Reply with the single word PINEAPPLE.", attachments: [], to: info.id
    )
    let collect = Task { () -> String in
      var text = ""
      for await envelope in events {
        if case let .partDelta(_, _, _, _, delta) = envelope.event { text += delta }
        if case let .executionStateChanged(_, state) = envelope.event, state != .working {
          return text
        }
      }
      return text
    }
    let deadline = Task { try? await Task.sleep(for: .seconds(90)); collect.cancel() }
    let streamed = await collect.value
    deadline.cancel()
    XCTAssertTrue(streamed.contains("PINEAPPLE"), streamed)

    let snapshot = try await client.loadSession(id: info.id)
    XCTAssertEqual(snapshot.messages.first?.plainText, "Reply with the single word PINEAPPLE.")
    XCTAssertTrue(snapshot.messages.last?.plainText.contains("PINEAPPLE") == true)
    XCTAssertEqual(snapshot.messages.map(\.role), [.user, .agent])
  }

  /// The real hook, installed where the product installs it, asked before a
  /// real command: allowed once, the command runs.
  func testACommandAsksAndRunsOnceAllowed() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["BOLTTY_LIVE_AGY"] != nil,
      "set BOLTTY_LIVE_AGY to spend one Antigravity turn"
    )
    let client = AntigravityClient()
    addTeardownBlock { await client.shutdown() }
    guard case .available = await client.probe() else { throw XCTSkip("agy is not installed") }
    client.setConversationResolver { _ in UUID() }

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let events = client.events()
    let info = try await client.createSession(
      id: client.makeSessionID(), options: AgentSessionOptions(directory: folder.path)
    )
    try await client.send(
      messageID: "m1",
      text: "Run exactly this shell command once and nothing else: echo GATED > out.txt",
      attachments: [], to: info.id
    )
    let collect = Task { () -> [String] in
      var asked: [String] = []
      for await envelope in events {
        if case let .interactionAsked(interaction) = envelope.event,
           case let .permission(prompt) = interaction.kind {
          asked.append(prompt.action + ": " + prompt.resources.joined(separator: " "))
          try? await client.answerPermission(
            requestID: interaction.id, sessionID: info.id, decision: .once, message: nil
          )
        }
        if case let .executionStateChanged(_, state) = envelope.event,
           state == .idle || state == .failed {
          return asked
        }
      }
      return asked
    }
    let deadline = Task { try? await Task.sleep(for: .seconds(120)); collect.cancel() }
    let asked = await collect.value
    deadline.cancel()
    XCTAssertEqual(asked.count, 1, "\(asked)")
    XCTAssertTrue(asked.first?.hasPrefix("command: echo GATED") == true, "\(asked)")
    let written = try? String(contentsOf: folder.appendingPathComponent("out.txt"), encoding: .utf8)
    XCTAssertEqual(written?.trimmingCharacters(in: .whitespacesAndNewlines), "GATED")
  }

  /// `/usage` answered by the installed `agy`, with no model call.
  func testThePlanLimitsAreRead() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["BOLTTY_LIVE_AGY"] != nil,
      "set BOLTTY_LIVE_AGY to ask agy for its limits"
    )
    let client = AntigravityClient()
    guard case .available = await client.probe() else { throw XCTSkip("agy is not installed") }
    let read = await client.usageLimits()
    let usage = try XCTUnwrap(read)
    XCTAssertFalse(usage.windows.isEmpty)
    print("AGY USAGE", usage.windows.map { "\($0.title) \($0.usedPercent)% \(String(describing: $0.resetsAt))" })
  }
}
