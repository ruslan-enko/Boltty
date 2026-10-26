import XCTest
@testable import Boltty

final class AgentUsageTests: XCTestCase {

  /// The shape `agy -p=/usage --output-format json` printed on agy 1.3.4.
  func testAntigravityHasAWeeklyLimitPerGroupOfModels() throws {
    let line = #"{"conversation_id":"","status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.5217975974082947,"reset_time":"2026-10-22T21:42:35Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-23T11:55:52Z"}]}]}}}"#
    let usage = try XCTUnwrap(AgentUsage.antigravity(XCTUnwrap(JSONObject(line: line))))
    XCTAssertEqual(usage.windows.map(\.title), ["Gemini · Weekly", "Claude and GPT · Weekly"])
    XCTAssertEqual(usage.windows.map(\.usedPercent), [48, 0], "remaining is turned into used")
    XCTAssertEqual(usage.windows.first?.resetsAt, ISO8601Stamp.date(from: "2026-10-22T21:42:35Z"))
    XCTAssertEqual(usage.pressing?.label, "Gemini")
  }

  func testAntigravityWithNoGroupsHasNoLimits() throws {
    XCTAssertNil(AgentUsage.antigravity(try XCTUnwrap(JSONObject(line: #"{"status":"SUCCESS","response":""}"#))))
  }

  private func object(_ json: String) -> JSONObject {
    JSONObject(line: json)!
  }

  // MARK: - Limits

  func testClaudeCodeReportsItsFiveHourAndWeeklyWindows() throws {
    let usage = try XCTUnwrap(AgentUsage.claudeCode(object("""
      {"subscription_type":"pro","rate_limits_available":true,"rate_limits":{
        "five_hour":{"utilization":4,"resets_at":"2026-09-26T21:30:00.278159+00:00"},
        "seven_day":{"utilization":18,"resets_at":"2026-10-01T07:00:00.278176+00:00"},
        "seven_day_opus":null,"nimbus_quill":{"utilization":0,"resets_at":null}}}
      """)))
    XCTAssertEqual(usage.windows.map(\.kind), [.session, .weekly])
    XCTAssertEqual(usage.windows.map(\.usedPercent), [4, 18])
    XCTAssertEqual(
      usage.windows[0].resetsAt?.timeIntervalSince1970 ?? 0, 1_790_458_200, accuracy: 1)
    XCTAssertEqual(usage.pressing?.kind, .weekly, "code-named windows are not guessed at")
  }

  func testClaudeCodeWithoutLimitsSaysNothing() {
    XCTAssertNil(AgentUsage.claudeCode(object(#"{"rate_limits_available":false,"rate_limits":{}}"#)))
  }

  func testCodexNamesItsWindowsByLength() throws {
    let usage = try XCTUnwrap(AgentUsage.codex(object("""
      {"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex",
        "primary":{"usedPercent":8,"windowDurationMins":300,"resetsAt":1790458344},
        "secondary":{"usedPercent":45,"windowDurationMins":10080,"resetsAt":1790501367},
        "planType":"plus"}}
      """)))
    XCTAssertEqual(usage.windows.map(\.kind), [.session, .weekly])
    XCTAssertEqual(usage.pressing?.usedPercent, 45)
    XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_790_501_367))
  }

  func testGrokReportsItsCreditPeriodAsOneWindow() throws {
    let usage = try XCTUnwrap(AgentUsage.grok(object("""
      {"config":{"creditUsagePercent":13.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
        "start":"2026-09-24T15:27:03.926825+00:00","end":"2026-10-01T15:27:03.926825+00:00"},
        "onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0},
        "isUnifiedBillingUser":true},"subscription_tier":"X Premium"}
      """)))
    XCTAssertEqual(usage.windows.map(\.kind), [.weekly], "named by the period's length")
    XCTAssertEqual(usage.pressing?.usedPercent, 13)
    XCTAssertEqual(
      usage.windows[0].resetsAt?.timeIntervalSince1970 ?? 0, 1_790_868_424, accuracy: 1)
  }

  func testGrokOmitsAZeroPercentAndThatReadsAsNothingSpent() throws {
    let usage = try XCTUnwrap(AgentUsage.grok(object("""
      {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
        "start":"2026-10-01T15:27:03.926825+00:00","end":"2026-10-08T15:27:03.926825+00:00"},
        "onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0},
        "isUnifiedBillingUser":true},"subscription_tier":"X Premium"}
      """)))
    XCTAssertEqual(usage.windows.map(\.kind), [.weekly])
    XCTAssertEqual(usage.pressing?.usedPercent, 0)
  }

  func testGrokWithoutACreditPercentSaysNothing() {
    XCTAssertNil(AgentUsage.grok(object(#"{"config":{"prepaidBalance":{"val":0}}}"#)))
    XCTAssertNil(
      AgentUsage.grok(object(#"{"config":{"creditUsagePercent":5}}"#)),
      "a percentage of no stated period is not a window")
  }

  func testAFullWindowOutranksAFullerLookingOne() {
    let usage = AgentUsage(windows: [
      AgentUsageWindow(kind: .session, usedPercent: 100, resetsAt: nil),
      AgentUsageWindow(kind: .weekly, usedPercent: 60, resetsAt: nil),
    ])
    XCTAssertEqual(usage.pressing?.severity, .exhausted)
    let tie = AgentUsage(windows: [
      AgentUsageWindow(kind: .session, usedPercent: 50, resetsAt: nil),
      AgentUsageWindow(kind: .weekly, usedPercent: 50, resetsAt: nil),
    ])
    XCTAssertEqual(tie.pressing?.kind, .weekly, "on a tie the week lasts longer")
  }

  func testSeverityThresholds() {
    func severity(_ percent: Int) -> AgentUsageWindow.Severity {
      AgentUsageWindow(kind: .weekly, usedPercent: percent, resetsAt: nil).severity
    }
    XCTAssertEqual(severity(79), .normal)
    XCTAssertEqual(severity(80), .high)
    XCTAssertEqual(severity(100), .exhausted)
  }

  // MARK: - The pill's words

  func testThePillNamesTheFullestWindow() {
    let usage = AgentUsage(windows: [
      AgentUsageWindow(kind: .session, usedPercent: 8, resetsAt: nil),
      AgentUsageWindow(kind: .weekly, usedPercent: 45, resetsAt: nil),
    ])
    XCTAssertEqual(UsagePillText.title(for: usage), "Weekly 45%")
  }

  func testASpentWindowSaysWhenItComesBack() throws {
    let now = Date(timeIntervalSince1970: 1_790_440_000)
    let reset = now.addingTimeInterval(3_600)
    let usage = AgentUsage(windows: [
      AgentUsageWindow(kind: .session, usedPercent: 100, resetsAt: reset),
    ])
    let title = try XCTUnwrap(UsagePillText.title(for: usage, now: now))
    XCTAssertTrue(title.hasPrefix("Limit reached · back "), title)
    XCTAssertFalse(title.hasSuffix("back "), "the time is not blank: \(title)")
  }

  func testTheTooltipListsEveryWindow() {
    let usage = AgentUsage(windows: [
      AgentUsageWindow(kind: .session, usedPercent: 8, resetsAt: nil),
      AgentUsageWindow(kind: .weekly, usedPercent: 45, resetsAt: nil),
    ])
    XCTAssertEqual(
      UsagePillText.detail(for: usage, agent: .codex),
      "Codex CLI plan\n5-hour: 8% used\nWeekly: 45% used")
  }

  func testTheGaugeNeedleFollowsTheNumber() {
    XCTAssertEqual(UsagePillText.symbolName(for: 4), "gauge.with.dots.needle.0percent")
    XCTAssertEqual(UsagePillText.symbolName(for: 45), "gauge.with.dots.needle.50percent")
    XCTAssertEqual(UsagePillText.symbolName(for: 95), "gauge.with.dots.needle.100percent")
    for percent in [0, 33, 50, 67, 100] {
      XCTAssertNotNil(
        NSImage(systemSymbolName: UsagePillText.symbolName(for: percent), accessibilityDescription: nil))
    }
  }
}

final class AgentContextTests: XCTestCase {
  private func object(_ json: String) -> JSONObject { JSONObject(line: json)! }

  func testClaudeCodeCountsTheWholeWindow() throws {
    let usage = try XCTUnwrap(AgentContextUsage.claudeCode(object(
      #"{"totalTokens":21517,"maxTokens":200000,"rawMaxTokens":200000,"percentage":11}"#)))
    XCTAssertEqual(usage.percent, 11)
  }

  func testCodexLiveAndOnDiskAgree() throws {
    let live = try XCTUnwrap(AgentContextUsage.codex(object(
      #"{"total":{"totalTokens":6498905},"last":{"totalTokens":175904},"modelContextWindow":258400}"#)))
    let disk = try XCTUnwrap(AgentContextUsage.codexRollout(object(
      #"{"total_token_usage":{"total_tokens":6498905},"last_token_usage":{"total_tokens":175904},"model_context_window":258400}"#)))
    XCTAssertEqual(live, disk)
    XCTAssertEqual(live.percent, 68, "the last request, not the thread's lifetime total")
  }

  func testTheRolloutsLastCountWins() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-rollout-\(UUID().uuidString)")
    let day = dir.appendingPathComponent("sessions/2026/09/26")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = "01a0ded2-a2cd-7792-a671-0a4edaa20b84"
    func count(_ used: Int) -> String {
      #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":"# + "\(used)" + #"},"model_context_window":1000}}}"#
    }
    try [count(100), #"{"type":"response_item","payload":{}}"#, count(400)]
      .joined(separator: "\n")
      .write(to: day.appendingPathComponent("rollout-2026-09-26T10-00-00-\(id).jsonl"), atomically: true, encoding: .utf8)
    XCTAssertEqual(CodexRolloutTranscript.contextUsage(threadID: id, codexHome: dir)?.percent, 40)
    XCTAssertNil(CodexRolloutTranscript.contextUsage(threadID: "missing", codexHome: dir))
  }

  func testOnlyARejectedEventIsARefusal() {
    XCTAssertNil(RateLimitHit.claudeCode(object(
      #"{"status":"allowed","resetsAt":1790458200,"rateLimitType":"five_hour"}"#)))
    XCTAssertEqual(
      RateLimitHit.claudeCode(object(#"{"status":"rejected","resetsAt":1790458200}"#))?.resetsAt,
      Date(timeIntervalSince1970: 1_790_458_200))
    XCTAssertTrue(RateLimitHit.isCodexLimit("usageLimitExceeded"))
    XCTAssertTrue(RateLimitHit.isCodexLimit("rateLimitExceeded"))
    XCTAssertFalse(RateLimitHit.isCodexLimit("contextWindowExceeded"))
    XCTAssertFalse(RateLimitHit.isCodexLimit(["httpConnectionFailed": [:]]))
  }

  func testACodexCompactionIsARowInTheTranscript() {
    guard case let .activity(row)? = CodexMapper.part(
      from: object(#"{"type":"contextCompaction","id":"c1"}"#), completed: true)
    else { return XCTFail("a compaction item should map to a row") }
    XCTAssertEqual(row.headline, "Compacted the conversation")
    XCTAssertEqual(
      AgentCompaction.activity(id: "x", before: 21_568, after: 2_974).headline,
      "Compacted the conversation · 21.6k → 3.0k tokens")
  }

  func testARefusedTurnSaysWhenItCanRunAgain() throws {
    let now = Date(timeIntervalSince1970: 1_790_440_000)
    XCTAssertTrue(AgentFailureReport.rateLimitSentence(
      RateLimitHit(resetsAt: now.addingTimeInterval(3_600)), now: now)
      .hasPrefix("Your plan's limit is used up — it comes back "))
    XCTAssertEqual(
      AgentFailureReport.rateLimitSentence(RateLimitHit(resetsAt: nil), now: now),
      "Your plan's limit is used up — try again once it resets.")

    var refused = ConversationMessage(id: "r", role: .agent, createdAt: now)
    refused.failure = MessageFailure(name: "rate_limit_event", message: "limit", rateLimit: RateLimitHit())
    let preview = BolttyAISessionPreview(
      id: UUID(), title: "t", agent: .claude, state: .failed, body: "", messages: [refused])
    let report = try XCTUnwrap(AgentFailureReport.make(from: preview))
    XCTAssertEqual(report.sentence, "Your plan's limit is used up — try again once it resets.")
    XCTAssertTrue(report.details.contains("limit"), "the CLI's own words stay in the drawer")
  }

  func testATranscriptWrittenBeforeRefusalsExistedStillDecodes() throws {
    let old = try JSONDecoder().decode(
      MessageFailure.self, from: Data(#"{"name":"x","message":"y"}"#.utf8))
    XCTAssertNil(old.rateLimit)
  }
}

@MainActor
final class AgentUsageEngineTests: XCTestCase {
  func testTheEngineAsksOnlyAgentsThatDeclareIt() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-usage-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    let limited = FakeAgentClient()
    limited.provider = .codex
    limited.capabilities.insert(.usageLimits)
    limited.usage = AgentUsage(windows: [AgentUsageWindow(kind: .weekly, usedPercent: 45, resetsAt: nil)])
    let silent = FakeAgentClient()
    silent.provider = .claude
    silent.usage = AgentUsage(windows: [AgentUsageWindow(kind: .weekly, usedPercent: 99, resetsAt: nil)])
    let engine = ConversationEngine(store: store, registry: AgentRegistry(clients: [limited, silent]))
    await engine.refreshAvailability()

    await engine.refreshUsage(force: true)
    XCTAssertEqual(engine.usageByProvider["codex"]?.pressing?.usedPercent, 45)
    XCTAssertNil(engine.usageByProvider["claude"])
  }

  func testARefusalEndsRateLimitedWithTheResetThePlanKnows() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-usage-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    let client = FakeAgentClient()
    client.provider = .codex
    client.capabilities.formUnion([.usageLimits, .contextUsage, .compaction])
    let reset = Date(timeIntervalSince1970: 1_790_501_367)
    client.usage = AgentUsage(windows: [AgentUsageWindow(kind: .weekly, usedPercent: 100, resetsAt: reset)])
    client.context = AgentContextUsage(usedTokens: 180_000, limitTokens: 200_000)
    let engine = ConversationEngine(store: store, client: client)
    await engine.refreshAvailability()
    await engine.refreshUsage(force: true)

    let conversation = store.createConversation(workingDirectory: NSHomeDirectory(), providerID: "codex").id
    await engine.send(text: "hi", in: conversation)
    let remote = try XCTUnwrap(store.conversation(id: conversation)?.remoteSessionID)
    client.emit(.messageUpdated(sessionID: remote, message: ConversationMessage(id: "turn", role: .agent, createdAt: Date())))
    client.emit(.sessionFailed(sessionID: remote, failure: MessageFailure(
      name: "usageLimitExceeded", message: "limit", rateLimit: RateLimitHit())))
    client.emit(.executionStateChanged(sessionID: remote, state: .rateLimited))
    for _ in 0..<50 where engine.contextByConversation[conversation] == nil {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertEqual(store.conversation(id: conversation)?.lastKnownState, .rateLimited)
    let failure = store.transcripts[conversation]?.messages.last?.failure
    XCTAssertEqual(failure?.rateLimit?.resetsAt, reset, "filled from the plan reading")
    XCTAssertEqual(engine.contextByConversation[conversation]?.percent, 90, "re-read when the turn ended")

    await engine.compact(conversationID: conversation)
    XCTAssertEqual(client.compacted, [remote])
  }
}

final class AgentActivityHistoryTests: XCTestCase {
  private func object(_ json: String) -> JSONObject { JSONObject(line: json)! }
  private let today: Date = {
    var parts = DateComponents()
    parts.year = 2026; parts.month = 9; parts.day = 26; parts.hour = 20
    return Calendar.current.date(from: parts)!
  }()

  func testCodexCountsTokensAndFillsTheQuietDays() throws {
    let history = try XCTUnwrap(AgentActivityHistory.codex(object("""
      {"summary":{"lifetimeTokens":1473756564,"peakDailyTokens":140487323,"currentStreakDays":1,"longestStreakDays":17},
       "dailyUsageBuckets":[{"startDate":"2026-04-26","tokens":2451831},
         {"startDate":"2026-09-24","tokens":5000},{"startDate":"2026-09-26","tokens":1200}]}
      """), today: today))
    XCTAssertEqual(history.unit, .tokens)
    XCTAssertEqual(history.days.count, AgentActivityHistory.window)
    XCTAssertEqual(history.days.last?.value, 1200, "today is the last bar")
    XCTAssertEqual(history.days[history.days.count - 2].value, 0, "a quiet day is a zero, not a gap")
    XCTAssertEqual(history.days[history.days.count - 3].value, 5000)
    XCTAssertEqual(history.days.map(\.value).reduce(0, +), 6200, "April is outside the window")
    XCTAssertEqual(history.streakDays, 1)
    XCTAssertEqual(history.summary, "1.5B tokens all time")
  }

  func testOpenCodeCountsSteps() throws {
    let history = try XCTUnwrap(AgentActivityHistory.openCode(object("""
      {"sessions":81,"prompts":205,"streak":6,"activeDays":6,
       "activity":[{"date":"2026-09-20","steps":128},{"date":"2026-09-25","steps":93}]}
      """), today: today))
    XCTAssertEqual(history.unit, .steps)
    XCTAssertEqual(history.days.map(\.value).reduce(0, +), 221)
    XCTAssertEqual(history.streakDays, 6)
    XCTAssertEqual(history.summary, "81 sessions, 205 prompts")
  }

  func testNothingToSayIsNoHistory() {
    XCTAssertNil(AgentActivityHistory.codex(object(#"{"dailyUsageBuckets":[]}"#)))
    XCTAssertNil(AgentActivityHistory.openCode(object(#"{"activity":[]}"#)))
  }

  func testCompactNumbers() {
    XCTAssertEqual(AgentActivityHistory.compact(950), "950")
    XCTAssertEqual(AgentActivityHistory.compact(21_568), "21.6k")
    XCTAssertEqual(AgentActivityHistory.compact(6_498_905), "6.5M")
  }
}

@MainActor
final class PlanUsageRingTests: XCTestCase {
  func testQuarterBoundariesAndUnavailableReading() {
    let expected = [(0, 0), (24, 0), (25, 1), (49, 1), (50, 2), (74, 2), (75, 3), (100, 3)]
    for (percent, index) in expected {
      XCTAssertEqual(PlanUsageRingReading.colorIndex(for: percent), index)
    }
    XCTAssertEqual(PlanUsageRingReading.percent(nil), 0)
    XCTAssertEqual(PlanUsageRingReading.percent(AgentUsage(windows: [])), 0)
    XCTAssertEqual(PlanUsageRingReading.percent(AgentUsage(windows: [
      .init(kind: .weekly, usedPercent: 150, resetsAt: nil)])), 100)
  }
  func testFullestPlanDrivesArcAndContextRemainsSeparate() {
    let ring = PlanUsageRingView(frame: .zero)
    ring.chatIsOpen = true
    ring.apply(AgentUsage(windows: [
      .init(kind: .session, usedPercent: 10, resetsAt: Date().addingTimeInterval(3600)),
      .init(kind: .weekly, usedPercent: 26, resetsAt: nil)]), agent: .codex)
    ring.apply(context: .init(usedTokens: 180_000, limitTokens: 200_000), canCompact: false)
    XCTAssertEqual(ring.percentForTesting, 26)
    XCTAssertTrue(ring.detailForTesting.contains("5-hour: 10% used, resets"))
    XCTAssertTrue(ring.detailForTesting.contains("Weekly: 26% used"))
    XCTAssertTrue(ring.detailForTesting.contains("Chat context: 90% used"))
    XCTAssertFalse(ring.offersCompactForTesting)
  }
  func testServiceCardsKeepTheirContentAndCanBeMeasuredBeforeDrawing() throws {
    let question = AgentQuestion(kind: .permission, requestID: "p", header: nil,
      prompt: "May I update the files in this project?", detail: "swift build --configuration debug",
      options: [.init(label: "Allow once", detail: nil, value: "once"),
                .init(label: "Always allow", detail: "For this conversation.", value: "always"),
                .init(label: "Reject", detail: nil, value: "reject")],
      allowsMultiple: false, allowsCustom: false)
    var queued = BolttyAISessionPreview(id: UUID(), title: "Chat", agent: .codex,
      state: .running, body: "")
    queued.queuedPrompt = String(repeating: "Then review the changes and verify the interface. ", count: 4)
    var failed = BolttyAISessionPreview(id: UUID(), title: "Chat", agent: .codex,
      state: .failed, body: "", notice: "Connection refused", retryPrompt: "Try again")
    failed.canStop = false
    let previews = [
      ("permission", BolttyAISessionPreview(id: UUID(), title: "Chat", agent: .codex,
        state: .blocked, body: question.prompt, question: question)),
      ("queue", queued), ("error", failed)]
    for (name, preview) in previews {
      let card = BolttyAIPreviewCard()
      card.appearance = NSAppearance(named: .darkAqua)
      card.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
      card.apply(preview)
      let measured = card.measuredHeight()
      XCTAssertGreaterThan(measured, AgentPaletteMetrics.previewMinHeight)
      XCTAssertLessThan(measured, 600)
      card.layoutSubtreeIfNeeded()
      if name == "permission" {
        XCTAssertEqual(card.questionTitleForTesting, "Needs your approval")
        XCTAssertEqual(card.permissionWellTextForTesting, question.detail)
      }
      if let directory = ProcessInfo.processInfo.environment["BOLTTY_DESIGN_RENDER_DIR"] {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: ceil(measured)))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = root
        card.frame = root.bounds
        root.addSubview(card)
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        window.close()
      }
    }
  }

  func testPinnedPlanDisclosureSurvivesUnchangedPanelLayouts() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = AgentPaletteView(frame: window.contentView!.bounds)
    view.appearance = NSAppearance(named: .darkAqua)
    window.contentView = view
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .codex, state: .finished, body: "Done"))
    view.cancelAllAnimationsAndSettle()
    view.setUsage(AgentUsage(windows: [.init(kind: .weekly, usedPercent: 52, resetsAt: nil)]), agent: .codex)
    view.setContext(.init(usedTokens: 160_000, limitTokens: 200_000), canCompact: true)
    view.layoutSubtreeIfNeeded()
    window.makeFirstResponder(view.field)
    let first = window.firstResponder
    let ring = view.planRingForTesting
    ring.performClick(nil)
    let bubble = try XCTUnwrap(PaletteHelpPresenter.shared.bubbleForTesting)
    for _ in 0..<3 { view.needsLayout = true; view.layoutSubtreeIfNeeded() }
    XCTAssertTrue(PaletteHelpPresenter.shared.bubbleForTesting === bubble)
    XCTAssertTrue(window.firstResponder === first)
    if let directory = ProcessInfo.processInfo.environment["BOLTTY_DESIGN_RENDER_DIR"] {
      let bitmap = try XCTUnwrap(bubble.bitmapImageRepForCachingDisplay(in: bubble.bounds))
      bubble.cacheDisplay(in: bubble.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("limits-popover.png"))
    }
    PaletteHelpPresenter.shared.dismiss()
    window.close()
  }

  func testPopoverActionKeepsItsTargetThroughThePress() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let ring = PlanUsageRingView(frame: NSRect(x: 200, y: 100, width: 40, height: 40))
    window.contentView?.addSubview(ring)
    ring.chatIsOpen = true
    ring.apply(context: .init(usedTokens: 160_000, limitTokens: 200_000), canCompact: true)
    var compacted = 0
    ring.onCompact = { compacted += 1 }
    ring.performClick(nil)
    func buttons(in view: NSView) -> [PaletteIconButton] {
      (view as? PaletteIconButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
    let bubble = try XCTUnwrap(PaletteHelpPresenter.shared.bubbleForTesting)
    let button = try XCTUnwrap(buttons(in: bubble).first)
    PaletteHelpPresenter.shared.dismissBeforePressing(button)
    XCTAssertTrue(PaletteHelpPresenter.shared.isVisibleForTesting)
    button.performClick(nil)
    XCTAssertEqual(compacted, 1)
    XCTAssertFalse(PaletteHelpPresenter.shared.isVisibleForTesting)
    window.close()
  }

  func testHelpDoesNotMoveEditorFocusAndDismissesCleanly() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    let ring = PlanUsageRingView(frame: NSRect(x: 200, y: 100, width: 44, height: 44))
    window.contentView?.addSubview(editor)
    window.contentView?.addSubview(ring)
    window.makeFirstResponder(editor)
    let first = window.firstResponder
    PaletteHelpPresenter.shared.show(for: ring, text: "Plan limits", pinned: true)
    XCTAssertTrue(PaletteHelpPresenter.shared.isVisibleForTesting)
    XCTAssertTrue(window.firstResponder === first)
    PaletteHelpPresenter.shared.dismiss()
    XCTAssertFalse(PaletteHelpPresenter.shared.isVisibleForTesting)
    window.close()
  }
}

@MainActor
final class PaletteHelpPresenterTests: XCTestCase {
  func testTheNextTagShowsAtOnceWhileOneWasJustUp() async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let folder = NSView(frame: NSRect(x: 20, y: 20, width: 26, height: 26))
    let mic = NSView(frame: NSRect(x: 46, y: 20, width: 26, height: 26))
    window.contentView?.addSubview(folder)
    window.contentView?.addSubview(mic)
    let presenter = PaletteHelpPresenter.shared
    presenter.dismiss()
    defer {
      presenter.dismiss()
      window.close()
    }

    presenter.schedule(for: folder, text: "Folder")
    XCTAssertFalse(presenter.isVisibleForTesting, "the first tag waits for the pointer to rest")
    let deadline = Date().addingTimeInterval(AgentPaletteMetrics.helpTagDelay + 3)
    while !presenter.isVisibleForTesting, Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(presenter.isVisibleForTesting, "precondition: it showed")

    presenter.dismiss(for: folder)
    XCTAssertFalse(presenter.isVisibleForTesting)
    presenter.schedule(for: mic, text: "Dictate")
    XCTAssertTrue(presenter.isVisibleForTesting, "the next one shows at once")

    presenter.dismiss()
    presenter.schedule(for: folder, text: "Folder")
    XCTAssertFalse(presenter.isVisibleForTesting, "after a click the next tag waits again")
    presenter.dismiss(for: folder)
    XCTAssertFalse(presenter.isWarmForTesting, "a tag that never showed warms nothing")
  }

  func testATagWithNoRoomAboveGoesUnderItsControl() {
    let room = NSRect(x: 0, y: 0, width: 1512, height: 945)
    let tag = NSSize(width: 520, height: 72)
    let folder = NSRect(x: 980, y: 945 - 74, width: 26, height: 26)

    let under = PaletteHelpPresenter.frame(of: tag, for: folder, in: room, flipped: false)
    XCTAssertLessThanOrEqual(under.maxY, folder.minY, "under the control")
    XCTAssertLessThanOrEqual(under.maxY, room.maxY, "never over the menu bar")

    let lower = folder.offsetBy(dx: 0, dy: -400)
    let over = PaletteHelpPresenter.frame(of: tag, for: lower, in: room, flipped: false)
    XCTAssertGreaterThanOrEqual(over.minY, lower.maxY, "with room, it stands above")

    let flipped = NSRect(x: 980, y: 48, width: 26, height: 26)
    let flippedUnder = PaletteHelpPresenter.frame(of: tag, for: flipped, in: room, flipped: true)
    XCTAssertGreaterThanOrEqual(flippedUnder.minY, flipped.maxY)

    let corner = NSRect(x: 1500, y: 400, width: 26, height: 26)
    let kept = PaletteHelpPresenter.frame(of: tag, for: corner, in: room, flipped: false)
    XCTAssertLessThanOrEqual(kept.maxX, room.maxX)
  }

  func testAShortcutIsSplitIntoItsKeys() {
    XCTAssertEqual(PaletteHelpPresenter.keys(of: "⌘."), ["⌘", "."])
    XCTAssertEqual(PaletteHelpPresenter.keys(of: "↵"), ["↵"])
    XCTAssertEqual(PaletteHelpPresenter.keys(of: "Esc"), ["Esc"])
    XCTAssertEqual(PaletteHelpPresenter.keys(of: "⇧⌘P"), ["⇧", "⌘", "P"])
  }

  func testRenderTheHelpTags() throws {
    guard let directory = ProcessInfo.processInfo.environment["BOLTTY_DESIGN_RENDER_DIR"] else {
      throw XCTSkip("set BOLTTY_DESIGN_RENDER_DIR to render")
    }
    let tags: [(String, String, String?)] = [
      ("send", "Send message", "↵"),
      ("stop", "Stop", "⌘."),
      ("back", "Back", "Esc"),
      ("folder", "/Users/me\nClick to choose the folder this chat works in.", nil),
      ("attach", "Attach a file", nil),
    ]
    let presenter = PaletteHelpPresenter.shared
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (name, text, shortcut) in tags {
      let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
      root.wantsLayer = true
      root.layer?.backgroundColor = NSColor(white: 0.05, alpha: 1).cgColor
      let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .darkAqua)
      window.contentView = root
      let control = NSView(frame: NSRect(x: 190, y: 20, width: 32, height: 32))
      root.addSubview(control)
      presenter.show(for: control, text: text, shortcut: shortcut)
      let bubble = try XCTUnwrap(presenter.bubbleForTesting)
      root.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      CATransaction.flush()
      let area = bubble.frame.insetBy(dx: -16, dy: -16)
      let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: area))
      root.cacheDisplay(in: area, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("help-\(name).png"))
      presenter.dismiss()
      window.close()
    }
  }
}
