import AppKit
import XCTest
@testable import Boltty

final class AgentPlanTests: XCTestCase {
  private func object(_ json: String) -> JSONObject { JSONObject(line: json)! }

  func testLiveAndRolloutSpellingsReadTheSame() {
    let live = AgentPlan.codexLive(object("""
      {"threadId":"t","turnId":"u","plan":[
        {"step":"Explore project context","status":"inProgress"},
        {"step":"Ask clarifying question","status":"pending"},
        {"step":"Read the brief","status":"completed"}]}
      """))
    let rollout = AgentPlan.codexArguments(
      #"{"plan":[{"step":"Explore project context","status":"in_progress"},{"step":"Ask clarifying question","status":"pending"},{"step":"Read the brief","status":"completed"}]}"#)
    XCTAssertEqual(live, rollout)
    XCTAssertEqual(live.map(\.status), [.inProgress, .pending, .completed])
  }

  func testAPlanRowCountsWhatIsDone() {
    let row = AgentPlan.activity(id: "p", steps: [
      PlanStep(text: "a", status: .completed),
      PlanStep(text: "b", status: .inProgress),
    ])
    XCTAssertEqual(row.headline, "Plan · 1 of 2 done")
    XCTAssertEqual(row.state, .running)
    XCTAssertEqual(
      AgentPlan.activity(id: "p", steps: [PlanStep(text: "a", status: .completed)]).state,
      .completed)
  }

  func testEachTurnKeepsOnePlanWithItsLastVersion() {
    func plan(_ id: String, _ done: Int) -> ConversationPart {
      .activity(AgentPlan.activity(id: id, steps: (0..<3).map {
        PlanStep(text: "s\($0)", status: $0 < done ? .completed : .pending)
      }))
    }
    let text = ConversationPart.text(TextPart(id: "t", kind: .text, text: "hi"))
    let messages = [
      ConversationMessage(id: "u1", role: .user, createdAt: Date()),
      ConversationMessage(id: "a1", role: .agent, createdAt: Date(), parts: [plan("p1", 0), text]),
      ConversationMessage(id: "a2", role: .agent, createdAt: Date(), parts: [plan("p2", 1), plan("p3", 3)]),
      ConversationMessage(id: "u2", role: .user, createdAt: Date()),
      ConversationMessage(id: "a3", role: .agent, createdAt: Date(), parts: [plan("p4", 1)]),
    ]
    let folded = AgentPlan.fold(messages)
    func plans(_ index: Int) -> [AgentActivity] {
      folded[index].parts.compactMap { if case let .activity(a) = $0, a.plan != nil { return a }; return nil }
    }
    XCTAssertEqual(plans(1).map(\.id), ["p1"], "the first stays where it was made")
    XCTAssertEqual(plans(1).first?.state, .completed, "holding the last version")
    XCTAssertTrue(plans(2).isEmpty, "the later versions go")
    XCTAssertEqual(folded[1].parts.count, 2, "the text beside it is untouched")
    XCTAssertEqual(plans(4).first?.headline, "Plan · 1 of 3 done", "a new turn has its own plan")
  }

  func testTheTurnPillSaysWhichStepItIsOn() {
    var reply = ConversationMessage(id: "a", role: .agent, createdAt: Date())
    reply.upsert(.activity(AgentActivity(id: "r", name: "Read", summary: "Read Package.swift", state: .running)))
    reply.upsert(.activity(AgentPlan.activity(id: "p", steps: [
      PlanStep(text: "Explore", status: .completed),
      PlanStep(text: "Write the tests for the plan row and its height", status: .inProgress),
      PlanStep(text: "Ship", status: .pending),
    ])))
    let preview = BolttyAISessionPreview(
      id: UUID(), title: "t", agent: .codex, state: .running, body: "",
      messages: [ConversationMessage(id: "u", role: .user, createdAt: Date()), reply])
    let step = preview.currentStep ?? ""
    XCTAssertTrue(step.hasPrefix("2 of 3 · Write the tests"), step)
    XCTAssertLessThanOrEqual(step.count, BolttyAISessionPreview.stepLabelLimit)
    XCTAssertTrue(step.hasSuffix("…"), "the step gives way at its end, the count stays whole")
  }

  func testTranscriptsWrittenBeforePlansStillDecode() throws {
    let old = try JSONDecoder().decode(
      AgentActivity.self, from: Data(#"{"id":"a","name":"shell","state":"completed","files":[]}"#.utf8))
    XCTAssertNil(old.plan)
  }
}

@MainActor
final class PlanRowTests: XCTestCase {
  private let running = AgentPlan.activity(id: "p", steps: [
    PlanStep(text: "Explore", status: .completed),
    PlanStep(text: "Write", status: .inProgress),
    PlanStep(text: "Ship", status: .pending),
  ])

  func testARunningPlanShowsItsStepsWithoutADisclosure() {
    let row = PaletteActivityRowView(activity: running, isExpanded: false)
    XCTAssertEqual(row.stepTextsForTesting, ["Explore", "Write", "Ship"])
    XCTAssertFalse(row.hasDisclosureForTesting, "the progress is not something to open")
    XCTAssertEqual(
      PaletteActivityRowView.height(for: running, width: 400, isExpanded: false),
      AgentPaletteMetrics.previewActivityRowHeight * 4
        + AgentPaletteMetrics.previewActivityDetailTopMargin * 2)
  }

  func testAFinishedPlanFoldsBehindTheChevron() {
    let done = AgentPlan.activity(id: "p", steps: running.plan!.map {
      PlanStep(text: $0.text, status: .completed)
    })
    let row = PaletteActivityRowView(activity: done, isExpanded: false)
    XCTAssertTrue(row.stepTextsForTesting.isEmpty)
    XCTAssertTrue(row.hasDisclosureForTesting)
    XCTAssertEqual(
      PaletteActivityRowView.height(for: done, width: 400, isExpanded: false),
      AgentPaletteMetrics.previewActivityRowHeight)
    row.apply(done, isExpanded: true)
    XCTAssertEqual(row.stepTextsForTesting.count, 3)
  }
}

@MainActor
final class SteeringTests: XCTestCase {
  private var root: URL!
  private var store: ConversationStore!
  private var client: FakeAgentClient!
  private var engine: ConversationEngine!

  override func setUp() async throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-steer-\(UUID().uuidString)")
    store = ConversationStore(persistence: ConversationPersistence(root: root))
    client = FakeAgentClient()
    client.provider = .codex
    client.capabilities.insert(.steering)
    engine = ConversationEngine(store: store, client: client)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func runningConversation() async throws -> (UUID, String) {
    let id = store.createConversation(workingDirectory: "/tmp", providerID: "codex").id
    _ = await engine.send(text: "count to thirty", in: id)
    let remote = try XCTUnwrap(store.conversation(id: id)?.remoteSessionID)
    store.setExecutionState(.working, for: id)
    return (id, remote)
  }

  func testCommandReturnAddsToTheRunningTurn() async throws {
    let (id, remote) = try await runningConversation()
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    XCTAssertTrue(coordinator.canSteer(id))
    XCTAssertEqual(coordinator.preview(for: id)?.canSteer, true)
    XCTAssertEqual(coordinator.steerFollowUp("and add banana", to: id), .steered)
    for _ in 0..<50 where client.steered.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(client.steered.map(\.text), ["and add banana"])
    XCTAssertEqual(client.steered.first?.sessionID, remote)
    XCTAssertEqual(store.transcripts[id]?.messages.last?.plainText, "and add banana",
                   "on screen as what the person sent")
    XCTAssertNil(coordinator.preview(for: id)?.queuedPrompt, "nothing waits")
  }

  func testARefusedSteerWaitsInTheQueueInstead() async throws {
    let (id, _) = try await runningConversation()
    client.steerError = .transport("turn is not steerable")
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let before = store.transcripts[id]?.messages.count
    _ = coordinator.steerFollowUp("and add banana", to: id)
    for _ in 0..<50 where coordinator.preview(for: id)?.queuedPrompt == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(coordinator.preview(for: id)?.queuedPrompt, "and add banana")
    XCTAssertEqual(store.transcripts[id]?.messages.count, before, "the bubble was taken back")
  }

  func testCommandReturnQueuesWhereTheAgentCannotSteer() async throws {
    client.capabilities.remove(.steering)
    engine = ConversationEngine(store: store, client: client)
    let (id, _) = try await runningConversation()
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    XCTAssertFalse(coordinator.canSteer(id))
    XCTAssertEqual(coordinator.steerFollowUp("later", to: id), .queued)
    XCTAssertTrue(client.steered.isEmpty)
  }

  func testASteerableAgentStillWaitsForTheNextTurn() async throws {
    let (id, remote) = try await runningConversation()
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let sentBefore = client.sentMessages.count
    XCTAssertEqual(coordinator.queueFollowUp("and add banana", to: id), .queued)
    XCTAssertTrue(client.steered.isEmpty)
    XCTAssertEqual(client.sentMessages.count, sentBefore)
    XCTAssertEqual(coordinator.preview(for: id)?.queuedPrompt, "and add banana")
    store.setExecutionState(.idle, for: id)
    for _ in 0..<100 where client.sentMessages.count == sentBefore {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(client.sentMessages.last?.text, "and add banana")
    XCTAssertEqual(client.sentMessages.last?.sessionID, remote)
    XCTAssertNil(coordinator.preview(for: id)?.queuedPrompt)
    XCTAssertTrue(client.steered.isEmpty)
  }
  func testReplacingTheSingleQueuedMessageAndTakingItBack() async throws {
    let (id, _) = try await runningConversation()
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    XCTAssertEqual(coordinator.queueFollowUp("first", to: id), .queued)
    XCTAssertEqual(coordinator.queueFollowUp("second", to: id), .replaced)
    XCTAssertEqual(coordinator.preview(for: id)?.queuedPrompt, "second")
    XCTAssertEqual(coordinator.cancelQueuedFollowUp(for: id), "second")
    XCTAssertNil(coordinator.preview(for: id)?.queuedPrompt)
    XCTAssertTrue(client.steered.isEmpty)
  }

  func testAnAgentThatCannotSteerQueuesAsBefore() async throws {
    client.capabilities.remove(.steering)
    engine = ConversationEngine(store: store, client: client)
    let (id, _) = try await runningConversation()
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    XCTAssertEqual(coordinator.queueFollowUp("later", to: id), .queued)
    XCTAssertTrue(client.steered.isEmpty)
  }

  func testAFollowUpQueuedAsTheTurnEndsIsSentRatherThanStranded() async throws {
    let (id, remote) = try await runningConversation()
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    XCTAssertEqual(coordinator.queueFollowUp("and add banana", to: id), .queued)
    store.setExecutionState(.idle, for: id)
    for _ in 0..<100 where !client.sentMessages.contains(where: { $0.text == "and add banana" }) {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertTrue(client.steered.isEmpty, "a finished turn cannot be steered")
    XCTAssertEqual(client.sentMessages.last?.text, "and add banana")
    XCTAssertEqual(client.sentMessages.last?.sessionID, remote)
    XCTAssertNil(coordinator.preview(for: id)?.queuedPrompt, "nothing is left waiting")
  }
}
