import SQLite3
import XCTest
@testable import Boltty

final class AgentStatisticsTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-statistics-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  private func write(_ lines: [String], to relative: String) throws {
    let url = home.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func date(_ stamp: String) -> Date { ISO8601Stamp.date(from: stamp)! }

  // MARK: Claude Code

  func testAClaudeReplyIsCountedOnceWithItsLastUsage() throws {
    try write([
      #"{"type":"user","message":{"role":"user","content":"fix the tests"},"uuid":"u1","timestamp":"2026-10-13T10:00:00.000Z"}"#,
      #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":100,"cache_creation_input_tokens":0}},"uuid":"a1","timestamp":"2026-10-13T10:00:01.000Z"}"#,
      #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":40,"cache_read_input_tokens":100,"cache_creation_input_tokens":50}},"uuid":"a2","timestamp":"2026-10-13T10:00:02.000Z"}"#,
      #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]},"uuid":"u2","timestamp":"2026-10-13T10:00:03.000Z"}"#,
      #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"uuid":"u3","timestamp":"2026-10-13T10:00:04.000Z"}"#,
      #"{"type":"assistant","message":{"id":"m2","model":"<synthetic>","usage":{}},"uuid":"a3","timestamp":"2026-10-13T10:00:05.000Z"}"#,
    ], to: ".claude/projects/-Users-me-app/s1.jsonl")
    try write([
      #"{"type":"assistant","message":{"id":"m9","model":"claude-haiku-5-5","usage":{"input_tokens":5,"output_tokens":5}},"uuid":"b1","timestamp":"2026-10-13T11:00:00.000Z"}"#,
    ], to: ".claude/projects/-Users-me-app/s1/subagents/agent-x.jsonl")

    let statistics = AgentStatisticsReader(home: home, cacheURL: nil).read()
    XCTAssertEqual(statistics.sessions.count, 1, "a sub-agent's file adds to its parent's session")
    let summary = AgentStatisticsSummary(statistics, range: .all, calendar: utc)
    XCTAssertEqual(summary.messages, 3, "the request, one reply, one sub-agent reply")
    XCTAssertEqual(summary.tokens, 200 + 10)
    XCTAssertEqual(summary.favoriteModel, "Opus 5.5")
    XCTAssertEqual(summary.peakHour, 10)
  }

  // MARK: Codex

  func testCodexTokensAreWhatTheRunningTotalGrewBy() throws {
    let name = "rollout-2026-10-13T10-00-00-01a11508-e860-7262-8977-c90e964ac81f.jsonl"
    try write([
      #"{"timestamp":"2026-10-13T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-6-luna"}}"#,
      #"{"timestamp":"2026-10-13T10:00:00.500Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
      #"{"timestamp":"2026-10-13T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}"#,
      #"{"timestamp":"2026-10-13T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100},"last_token_usage":{"total_tokens":100}}}}"#,
      #"{"timestamp":"2026-10-13T10:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100},"last_token_usage":{"total_tokens":100}}}}"#,
      #"{"timestamp":"2026-10-13T10:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250},"last_token_usage":{"total_tokens":150}}}}"#,
      #"{"timestamp":"2026-10-13T10:00:05.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}}"#,
    ], to: ".codex/sessions/2026/10/13/\(name)")

    let summary = AgentStatisticsSummary(
      AgentStatisticsReader(home: home, cacheURL: nil).read(), range: .all, calendar: utc
    )
    XCTAssertEqual(summary.tokens, 250, "a repeated total adds nothing")
    XCTAssertEqual(summary.messages, 2, "scaffolding filed as the user's is not a message")
    XCTAssertEqual(summary.favoriteModel, "gpt-6-luna")
  }

  // MARK: Grok

  func testGrokCountsTurnsFromEventsAndTokensFromUsage() throws {
    let directory = ".grok/sessions/%2FUsers%2Fme/01a099e5"
    try #"{"info":{"id":"g1","cwd":"/Users/me"},"num_messages":5,"current_model_id":"grok-4.7"}"#
      .write(to: home.appendingPathComponent(directory).appendingPathComponentCreating("summary.json"), atomically: true, encoding: .utf8)
    try write([
      #"{"ts":"2026-10-13T08:35:09.682Z","type":"turn_started","model_id":"grok-4.6"}"#,
      #"{"ts":"2026-10-13T08:35:12.162Z","type":"first_token"}"#,
      #"{"ts":"2026-10-13T08:36:12.162Z","type":"first_token"}"#,
    ], to: "\(directory)/events.jsonl")
    try #"{"turns":[{"endedAt":"2026-10-13T08:47:28.397440+00:00","modelUsage":{"grok-4.6":{"totalTokens":1000}}}]}"#
      .write(to: home.appendingPathComponent("\(directory)/usage.json"), atomically: true, encoding: .utf8)
    try #"{"info":{"id":"g2","cwd":"/"},"num_messages":1}"#
      .write(to: home.appendingPathComponent(".grok/sessions/%2F/shell").appendingPathComponentCreating("summary.json"), atomically: true, encoding: .utf8)

    let statistics = AgentStatisticsReader(home: home, cacheURL: nil).read()
    XCTAssertEqual(statistics.sessions.map(\.id), ["g1"])
    let summary = AgentStatisticsSummary(statistics, range: .all, calendar: utc)
    XCTAssertEqual(summary.messages, 3)
    XCTAssertEqual(summary.tokens, 1000)
    XCTAssertEqual(summary.models.first?.id, "grok-4.6")
  }

  // MARK: OpenCode

  func testOpenCodeReadsBothGenerationsAndFoldsSubSessions() throws {
    let url = home.appendingPathComponent(".local/share/opencode/opencode.db")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
    let sql = """
      CREATE TABLE session_v2 (id TEXT PRIMARY KEY, parent_id TEXT);
      CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, time_created INTEGER, data TEXT);
      CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT);
      CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
      CREATE TABLE credential (value TEXT);
      INSERT INTO session_v2 VALUES ('ses_a', NULL), ('ses_child', 'ses_a');
      INSERT INTO session_message VALUES
        ('1', 'ses_a', 'user', 1791841786957, '{}'),
        ('2', 'ses_a', 'assistant', 1791841790959, '{"model":{"id":"big-pickle"},"tokens":{"input":10,"output":5,"reasoning":1,"cache":{"read":100,"write":0}}}'),
        ('3', 'ses_child', 'assistant', 1791841790959, '{"model":{"id":"big-pickle"},"tokens":{"input":4}}'),
        ('4', 'ses_a', 'idle', 1791841790959, '{}');
      INSERT INTO session VALUES ('ses_old', NULL), ('ses_a', NULL);
      INSERT INTO message VALUES
        ('5', 'ses_old', 1790021755604, '{"role":"assistant","modelID":"nemotron","tokens":{"input":20,"output":2,"cache":{"read":0,"write":0}}}'),
        ('6', 'ses_a', 1790021755604, '{"role":"assistant","modelID":"copied","tokens":{"input":999}}');
      """
    XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    sqlite3_close(handle)

    let statistics = AgentStatisticsReader(home: home, cacheURL: nil).read()
    XCTAssertEqual(Set(statistics.sessions.map(\.id)), ["ses_a", "ses_old"])
    let summary = AgentStatisticsSummary(statistics, range: .all, calendar: utc)
    XCTAssertEqual(summary.tokens, 116 + 4 + 22, "1.18's copy of a 2.0 session is not counted twice")
    XCTAssertEqual(summary.messages, 4)
    XCTAssertEqual(summary.sessions, 2)
  }

  // MARK: Cache

  func testTheCacheReReadsOnlyWhatChanged() throws {
    let cache = home.appendingPathComponent("cache.json")
    let file = ".claude/projects/-p/s.jsonl"
    let reply = { (id: String) in
      #"{"type":"assistant","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":1}},"timestamp":"2026-10-13T10:00:00.000Z"}"#
    }
    try write([reply("a")], to: file)
    let reader = AgentStatisticsReader(home: home, cacheURL: cache)
    XCTAssertEqual(AgentStatisticsSummary(reader.read(), range: .all).messages, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

    try write([reply("a"), reply("b")], to: file)
    XCTAssertEqual(AgentStatisticsSummary(reader.read(), range: .all).messages, 2, "a grown file is read again")

    try FileManager.default.removeItem(at: home.appendingPathComponent(file))
    XCTAssertTrue(reader.read().sessions.isEmpty, "a file gone from disk is gone from the count")
  }

  // MARK: Summary

  func testTheRangeCountsFromMidnightDaysAgo() {
    let now = date("2026-10-13T15:00:00Z")
    let hour = { (stamp: String) in Int(self.date(stamp).timeIntervalSince1970 / 3600) }
    let statistics = AgentStatistics(sessions: [
      .init(agent: "claude", id: "old", samples: [.init(hour: hour("2026-10-06T23:00:00Z"), model: "m", tokens: 5, messages: 1)]),
      .init(agent: "codex", id: "new", samples: [
        .init(hour: hour("2026-10-07T00:00:00Z"), model: "m", tokens: 7, messages: 2),
        .init(hour: hour("2026-10-13T09:00:00Z"), model: "", tokens: 0, messages: 1),
      ]),
    ])
    let week = AgentStatisticsSummary(statistics, range: .week, now: now, calendar: utc)
    XCTAssertEqual(week.sessions, 1)
    XCTAssertEqual(week.messages, 3)
    XCTAssertEqual(week.activeDays, 2)
    let codexOnly = AgentStatisticsSummary(statistics, range: .all, agent: .claude, now: now, calendar: utc)
    XCTAssertEqual(codexOnly.tokens, 5)
  }

  func testModelNamesReadAsPeopleSayThem() {
    XCTAssertEqual(AgentStatisticsSummary.displayName(ofModel: "claude-opus-5-5"), "Opus 5.5")
    XCTAssertEqual(AgentStatisticsSummary.displayName(ofModel: "claude-sonnet-4-5-20250929"), "Sonnet 4.5")
    XCTAssertEqual(AgentStatisticsSummary.displayName(ofModel: "claude-opus-5-5[1m]"), "Opus 5.5")
    XCTAssertEqual(AgentStatisticsSummary.displayName(ofModel: "gpt-6-luna"), "gpt-6-luna")
    XCTAssertEqual(AgentStatisticsSummary.displayName(ofModel: "<synthetic>"), "")
  }

  func testTheBookLineKeepsItsMultipleAPersonCanHold() {
    XCTAssertEqual(AgentStatisticsSummary.bookComparison(tokens: 0), nil)
    XCTAssertEqual(AgentStatisticsSummary.bookComparison(tokens: 19_500), "You’ve used ~50% of the tokens in Animal Farm.")
    XCTAssertTrue(AgentStatisticsSummary.bookComparison(tokens: 16_400_000_000)!.hasSuffix("than every Harry Potter book."))
  }
}

final class AgentStatisticsLiveMeasurement: XCTestCase {
  func testReadThisMachine() throws {
    guard ProcessInfo.processInfo.environment["BOLTTY_STATISTICS"] != nil else {
      throw XCTSkip("set TEST_RUNNER_BOLTTY_STATISTICS=1 to measure")
    }
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("boltty-statistics-live.json")
    try? FileManager.default.removeItem(at: cache)
    var report = ""
    func print(_ line: String) { report += line + "\n" }
    defer {
      try? report.write(
        to: FileManager.default.temporaryDirectory.appendingPathComponent("boltty-statistics-live.txt"),
        atomically: true, encoding: .utf8)
    }
    let reader = AgentStatisticsReader(cacheURL: cache)
    var started = Date()
    let statistics = reader.read()
    let cold = Date().timeIntervalSince(started)
    started = Date()
    _ = reader.read()
    let warm = Date().timeIntervalSince(started)
    for agent in AgentHistory.tabOrder {
      let s = AgentStatisticsSummary(statistics, range: .all, agent: agent)
      print("STATS \(agent.rawValue): sessions \(s.sessions) messages \(s.messages) tokens \(s.tokens) days \(s.activeDays) model \(s.favoriteModel ?? "-")")
    }
    let all = AgentStatisticsSummary(statistics, range: .all)
    print("STATS all: sessions \(all.sessions) messages \(all.messages) tokens \(all.tokens) days \(all.activeDays) peak \(all.peakHour ?? -1) model \(all.favoriteModel ?? "-")")
    print("STATS cold \(cold)s warm \(warm)s cache \((try? Data(contentsOf: cache).count) ?? 0) bytes")
  }
}

@MainActor
final class UsageOverviewOnScreen: XCTestCase {
  func testPhotographTheUsagePage() async throws {
    guard let path = ProcessInfo.processInfo.environment["BOLTTY_USAGE_SHOT"] else {
      throw XCTSkip("set TEST_RUNNER_BOLTTY_USAGE_SHOT=<png> to photograph it")
    }
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("boltty-usage-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    let engine = ConversationEngine(store: store, registry: AgentRegistry(clients: []))
    let appModel = AppModel(settings: AppSettings(), defaults: isolatedDefaults("boltty.tests.usageShot"))
    let controller = SettingsWindowController(model: appModel, engine: engine, frameAutosaveName: "")
    controller.show(page: .usage)
    let window = try XCTUnwrap(controller.window)
    window.orderFrontRegardless()
    try await Task.sleep(for: .seconds(6))
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
    try shot.run()
    shot.waitUntilExit()
    window.orderOut(nil)
  }
}

private extension URL {
  func appendingPathComponentCreating(_ name: String) -> URL {
    try? FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    return appendingPathComponent(name)
  }
}
