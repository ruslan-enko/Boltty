import XCTest
@testable import Boltty

@MainActor
final class AgentAdapterLiveTests: XCTestCase {
  override func setUpWithError() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["BOLTTY_LIVE_AGENTS"] == "1",
      "Set BOLTTY_LIVE_AGENTS=1 to run the adapters against the installed CLIs"
    )
  }

  func testClaudeCodeReportsItselfInstalledAndSignedIn() async throws {
    let client = ClaudeCodeClient()
    let availability = await client.probe()
    switch availability {
    case let .available(version):
      XCTAssertNotNil(version)
    case .notInstalled:
      throw XCTSkip("claude is not on this machine")
    case let .needsLogin(reason), let .unavailable(reason):
      XCTFail("Claude Code is installed but unusable: \(reason)")
    }
  }

  func testClaudeCodeListsItsModels() async throws {
    let client = ClaudeCodeClient()
    guard await client.probe().isAvailable else { throw XCTSkip("claude is not usable here") }

    let models = try await client.availableModels()

    XCTAssertFalse(models.isEmpty, "the handshake carries the model catalog")
    XCTAssertTrue(
      models.contains { $0.selection.modelID == "default" },
      "`default` is the value the CLI takes on --model"
    )
    XCTAssertTrue(models.allSatisfy { !$0.selection.displayName.isEmpty })
  }

  func testClaudeCodeModelsCarryTheirOwnEffortLevels() async throws {
    let client = ClaudeCodeClient()
    guard await client.probe().isAvailable else { throw XCTSkip("claude is not usable here") }

    let models = try await client.availableModels()
    let thinking = models.filter { !$0.effortOptions.isEmpty }

    XCTAssertFalse(thinking.isEmpty, "at least one model thinks in levels")
    for model in thinking {
      XCTAssertTrue(
        model.effortOptions.allSatisfy { !$0.value.isEmpty && !$0.label.isEmpty },
        "\(model.selection.modelID) reported a level with nothing in it"
      )
    }
  }

  func testClaudeCodeOpensASessionOnItsOwnIDAndStreamsATurnBack() async throws {
    let client = ClaudeCodeClient()
    guard await client.probe().isAvailable else { throw XCTSkip("claude is not usable here") }
    defer { Task { await client.shutdown() } }

    let info = try await client.createSession(
      id: client.makeSessionID(),
      options: AgentSessionOptions(directory: NSTemporaryDirectory())
    )

    let answer = Task { () -> String in
      var text = ""
      for await envelope in client.events() {
        switch envelope.event {
        case let .partDelta(_, _, _, kind, delta) where kind == .text:
          text += delta
        case let .executionStateChanged(_, state) where state == .idle:
          return text.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
          continue
        }
      }
      return text
    }

    try await client.send(
      messageID: "msg_live_ping",
      text: "Reply with exactly one word: pong",
      attachments: [],
      to: info.id
    )

    let text = try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask { await answer.value }
      group.addTask {
        try await Task.sleep(nanoseconds: 120_000_000_000)
        return ""
      }
      let first = try await group.next() ?? ""
      group.cancelAll()
      return first
    }

    XCTAssertTrue(
      text.lowercased().contains("pong"),
      "the turn did not stream back as text, got: \(text)"
    )
  }

  func testClaudeCodeRefusesABadSessionIDAtCreationAndSaysWhy() async throws {
    let client = ClaudeCodeClient()
    guard await client.probe().isAvailable else { throw XCTSkip("claude is not usable here") }
    defer { Task { await client.shutdown() } }

    do {
      _ = try await client.createSession(
        id: "ses_thespellingopencodeuses",
        options: AgentSessionOptions(directory: NSTemporaryDirectory())
      )
      XCTFail("a session the CLI refused to open must not come back as a session")
    } catch let AgentClientError.serverStartFailed(detail) {
      XCTAssertTrue(
        detail.lowercased().contains("uuid"),
        "the CLI's own reason has to survive to the user, got: \(detail)"
      )
    }
  }

  func testCodexModelsCarryTheirEffortLevelsAndWhatEachCosts() async throws {
    let client = CodexClient()
    guard await client.probe().isAvailable else { throw XCTSkip("codex is not usable here") }
    defer { Task { await client.shutdown() } }

    let models = try await client.availableModels()
    let thinking = models.filter { !$0.effortOptions.isEmpty }

    XCTAssertFalse(thinking.isEmpty)
    XCTAssertTrue(
      thinking.contains { $0.effortOptions.contains { $0.detail?.isEmpty == false } },
      "Codex describes its levels, and the menu shows what it says"
    )
  }

  // MARK: - Limits (free: no model turn)

  func testClaudeCodeReportsItsPlanLimits() async throws {
    let client = ClaudeCodeClient()
    guard await client.probe().isAvailable else { throw XCTSkip("claude is not usable here") }
    let read = await client.usageLimits()
    let usage = try XCTUnwrap(read, "get_usage answered nothing")
    XCTAssertTrue(usage.windows.contains { $0.kind == .session })
    XCTAssertTrue(usage.windows.contains { $0.kind == .weekly })
    XCTAssertTrue(usage.windows.allSatisfy { (0...100).contains($0.usedPercent) })
  }

  func testGrokReportsItsPlanAllowance() async throws {
    let client = ACPClient(agent: .grok)
    guard await client.probe().isAvailable else { throw XCTSkip("grok is not usable here") }
    defer { Task { await client.shutdown() } }
    let read = await client.usageLimits()
    let usage = try XCTUnwrap(read, "_x.ai/billing answered nothing")
    XCTAssertEqual(usage.windows.count, 1)
    XCTAssertTrue(usage.windows.allSatisfy { (0...100).contains($0.usedPercent) })
  }

  func testCodexReportsItsPlanLimits() async throws {
    let client = CodexClient()
    guard await client.probe().isAvailable else { throw XCTSkip("codex is not usable here") }
    defer { Task { await client.shutdown() } }
    let read = await client.usageLimits()
    let usage = try XCTUnwrap(read, "account/rateLimits/read answered nothing")
    XCTAssertFalse(usage.windows.isEmpty)
  }

  // MARK: - Context and compaction (costs one short turn and one compaction)

  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [AgentEvent] = []
    private var task: Task<Void, Never>?

    init(_ client: AgentClient) {
      task = Task { [weak self] in
        for await envelope in client.events() {
          self?.lock.withLock { self?.seen.append(envelope.event) }
        }
      }
    }

    var events: [AgentEvent] { lock.withLock { seen } }

    func wait(from start: Int = 0, timeout: TimeInterval = 120, for match: @Sendable (AgentEvent) -> Bool) async -> Bool {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        if events.dropFirst(start).contains(where: match) { return true }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return false
    }

    deinit { task?.cancel() }
  }

  private func collect(
    from client: AgentClient, until done: @escaping @Sendable (AgentEvent) -> Bool
  ) -> Task<[AgentEvent], Never> {
    let recorder = Recorder(client)
    return Task {
      _ = await recorder.wait(timeout: 90, for: done)
      return recorder.events
    }
  }

  nonisolated private static func isIdle(_ event: AgentEvent) -> Bool {
    if case .executionStateChanged(_, .idle) = event { return true }
    return false
  }

  private static func compactionRow(in events: [AgentEvent]) -> AgentActivity? {
    for event in events {
      if case let .partUpdated(_, _, .activity(row)) = event, row.name == "compact" { return row }
    }
    return nil
  }

  func testClaudeCodeReadsItsContextAndCompacts() async throws {
    let client = ClaudeCodeClient()
    guard await client.probe().isAvailable else { throw XCTSkip("claude is not usable here") }
    defer { Task { await client.shutdown() } }
    let info = try await client.createSession(
      id: client.makeSessionID(),
      options: AgentSessionOptions(
        directory: NSTemporaryDirectory(),
        model: ModelSelection(providerID: "claude", modelID: "haiku")))

    let turn = collect(from: client, until: Self.isIdle)
    try await client.send(messageID: "msg_ctx", text: "Reply with the single word ok.", attachments: [], to: info.id)
    _ = await turn.value

    let context = await client.contextUsage(sessionID: info.id)
    let before = try XCTUnwrap(context, "get_context_usage answered nothing on a live session")
    XCTAssertGreaterThan(before.usedTokens, 0)
    XCTAssertGreaterThan(before.limitTokens, before.usedTokens)

    let compaction = collect(from: client, until: Self.isIdle)
    try await client.compact(sessionID: info.id)
    let events = await compaction.value
    XCTAssertNotNil(Self.compactionRow(in: events), "compact_boundary became a row")
  }

  func testCodexReadsItsContextAndCompacts() async throws {
    let client = CodexClient()
    guard await client.probe().isAvailable else { throw XCTSkip("codex is not usable here") }
    defer { Task { await client.shutdown() } }
    let info = try await client.createSession(
      id: client.makeSessionID(), options: AgentSessionOptions(directory: NSTemporaryDirectory()))

    let turn = collect(from: client, until: Self.isIdle)
    try await client.send(messageID: "msg_ctx", text: "Reply with the single word ok.", attachments: [], to: info.id)
    _ = await turn.value

    let context = await client.contextUsage(sessionID: info.id)
    let before = try XCTUnwrap(context, "no tokenUsage after a turn")
    XCTAssertGreaterThan(before.limitTokens, before.usedTokens)

    let compaction = collect(from: client, until: Self.isIdle)
    try await client.compact(sessionID: info.id)
    let events = await compaction.value
    XCTAssertNotNil(Self.compactionRow(in: events), "contextCompaction became a row")
  }

  // MARK: - Steering (Codex; costs one short turn)

  func testCodexTakesWordsMidTurnBelowThem() async throws {
    let client = CodexClient()
    guard await client.probe().isAvailable else { throw XCTSkip("codex is not usable here") }
    defer { Task { await client.shutdown() } }
    let info = try await client.createSession(
      id: client.makeSessionID(), options: AgentSessionOptions(directory: NSTemporaryDirectory()))
    let recorder = Recorder(client)
    try await client.send(
      messageID: "msg_count",
      text: "Write the numbers from 1 to 150, each on its own line, and nothing else.",
      attachments: [], to: info.id)
    let writing = await recorder.wait {
      if case .partDelta(_, _, _, .text, _) = $0 { return true }
      return false
    }
    XCTAssertTrue(writing, "the turn never started writing")
    try await client.steer(
      messageID: "msg_steer", text: "When you finish the numbers, write the word banana on its own line.",
      to: info.id)
    let steeredAt = recorder.events.count
    let ended = await recorder.wait(from: steeredAt) { Self.isIdle($0) }
    XCTAssertTrue(ended, "the turn never ended")

    var textAfter = ""
    for event in recorder.events {
      if case let .partDelta(_, messageID, _, .text, delta) = event, messageID.contains("-after-") {
        textAfter += delta
      }
    }
    XCTAssertTrue(textAfter.lowercased().contains("banana"),
                  "the reply after the steer goes below it; got: \(textAfter.suffix(200))")
  }

  func testCodexAndOpenCodeReportTheirDays() async throws {
    let codex = CodexClient()
    if await codex.probe().isAvailable {
      let history = await codex.activityHistory()
      XCTAssertEqual(history?.days.count, AgentActivityHistory.window, "account/usage/read")
      await codex.shutdown()
    }
    let openCode = OpenCodeClient()
    if await openCode.probe().isAvailable {
      let history = await openCode.activityHistory()
      XCTAssertEqual(history?.unit, .steps, "/api/experimental/session/stats")
      await openCode.shutdown()
    }
  }

  func testCodexReportsItselfInstalledAndSignedIn() async throws {
    let client = CodexClient()
    let availability = await client.probe()
    switch availability {
    case .available:
      break
    case .notInstalled:
      throw XCTSkip("codex is not on this machine")
    case let .needsLogin(reason), let .unavailable(reason):
      XCTFail("Codex is installed but unusable: \(reason)")
    }
    await client.shutdown()
  }

  func testCodexAppServerAnswersAfterTheHandshake() async throws {
    let client = CodexClient()
    guard await client.probe().isAvailable else { throw XCTSkip("codex is not usable here") }
    defer { Task { await client.shutdown() } }

    let models = try await client.availableModels()

    XCTAssertFalse(models.isEmpty, "model/list answered")
    XCTAssertTrue(models.allSatisfy { !$0.selection.modelID.isEmpty })
  }

  func testCodexApprovalDecisionsAreTheCLIsOwnValues() {
    XCTAssertEqual(CodexClient.decision(for: .once), "accept")
    XCTAssertEqual(CodexClient.decision(for: .always), "acceptForSession")
    XCTAssertEqual(CodexClient.decision(for: .reject), "decline")
  }

  // MARK: - Grok

  func testGrokReportsItselfInstalled() async throws {
    let client = ACPClient(agent: .grok)
    defer { Task { await client.shutdown() } }
    let availability = await client.probe()
    guard case let .available(version) = availability else {
      return XCTFail("grok did not report itself available: \(availability)")
    }
    XCTAssertFalse(version?.isEmpty ?? true, "grok answered --version with nothing")
  }

  func testGrokModelsCarryTheirOwnEffortLevels() async throws {
    let client = ACPClient(agent: .grok)
    defer { Task { await client.shutdown() } }
    let models = try await client.availableModels()

    XCTAssertFalse(models.isEmpty, "grok listed no models")
    XCTAssertEqual(models.filter(\.isDefault).count, 1, "exactly one model is the default")
    XCTAssertTrue(
      models.allSatisfy { !$0.effortOptions.isEmpty },
      "every Grok model reports reasoning levels"
    )
    for model in models {
      for effort in model.effortOptions {
        XCTAssertEqual(effort.value, effort.value.lowercased())
        XCTAssertFalse(effort.value.contains(" "), "\(effort.value) is not a wire value")
      }
    }
  }

  func testGrokStreamsATurnBackAsText() async throws {
    let client = ACPClient(agent: .grok)
    defer { Task { await client.shutdown() } }
    let models = try await client.availableModels()
    guard let model = models.first else { return XCTFail("no models") }

    let info = try await client.createSession(id: UUID().uuidString, options: AgentSessionOptions(
      directory: NSTemporaryDirectory(),
      model: model.selection,
      effort: model.effortOptions.first(where: { $0.value == "low" })?.value,
      autoApprove: false
    ))

    let answer = Task { () -> String in
      var text = ""
      for await envelope in client.events() {
        switch envelope.event {
        case let .partDelta(_, _, _, kind, delta) where kind == .text:
          text += delta
        case let .executionStateChanged(_, state) where state == .idle:
          return text.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
          continue
        }
      }
      return text
    }

    try await client.send(
      messageID: UUID().uuidString,
      text: "Reply with exactly one word: pong",
      attachments: [],
      to: info.id
    )

    let text = try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask { await answer.value }
      group.addTask {
        try await Task.sleep(nanoseconds: 120_000_000_000)
        return ""
      }
      let first = try await group.next() ?? ""
      group.cancelAll()
      return first
    }

    XCTAssertTrue(
      text.lowercased().contains("pong"),
      "the turn did not stream back as text, got: \(text)"
    )
  }
}

final class ClaudeCodeThrowawayProcessTests: XCTestCase {
  func testAProbeOfACLIThatNeverAnswersEnds() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-silent-claude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("claude")
    try "#!/bin/sh\nexec sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let client = ClaudeCodeClient(executable: script.path, throwawayDeadline: 0.5)
    let started = Date()
    let availability = await client.probe()

    guard case .unavailable = availability else {
      return XCTFail("a CLI that never answers is not available, got \(availability)")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 10, "ended at its deadline, not waited on")
  }
}
