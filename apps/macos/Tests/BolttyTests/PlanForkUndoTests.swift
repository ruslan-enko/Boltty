import XCTest
@testable import Boltty

final class PlanModeTests: XCTestCase {
  func testClaudeCodePlansInPlanModeAndOtherwiseInTheChatsOwn() {
    XCTAssertEqual(ClaudeCodeClient.permissionMode(for: AgentSessionOptions(directory: "/", planMode: true)), "plan")
    XCTAssertEqual(ClaudeCodeClient.permissionMode(for: AgentSessionOptions(directory: "/", permissionMode: "acceptEdits")), "acceptEdits")
    XCTAssertEqual(ClaudeCodeClient.permissionMode(for: AgentSessionOptions(directory: "/")), "default")
  }

  func testAPlanStoredBeforeEndedTurnStillReads() throws {
    let plan = try JSONDecoder().decode(PlanPrompt.self, from: Data(##"{"markdown": "# Plan"}"##.utf8))
    XCTAssertFalse(plan.isAnsweredByMessage)
  }

  func testAChatStoredBeforePlanModeAndForksStillReads() throws {
    let json = #"""
      {"id": "8E7B4B8E-0C4B-4C9A-9C6B-2F3E4B5A6C7D", "title": "t", "workingDirectory": "/",
       "createdAt": 0, "updatedAt": 0}
      """#
    let conversation = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
    XCTAssertFalse(conversation.planMode)
    XCTAssertNil(conversation.forkedFrom)
  }

  func testAntigravityPlanIsMarkdownInItsBrain() {
    let brain = AntigravityClient.brain
    XCTAssertTrue(AntigravityClient.isPlanFile(brain + "/c1/implementation_plan.md"))
    XCTAssertTrue(AntigravityClient.isPlanFile(brain + "/c1/plan.md"))
    XCTAssertFalse(AntigravityClient.isPlanFile(brain + "/c1/notes.txt"))
    XCTAssertFalse(AntigravityClient.isPlanFile("/tmp/plan.md"))
  }

  func testAntigravityRunsTheChatsModeAndPlansInPlan() {
    let agent = ACPAgent.antigravity(transcriptRoot: URL(fileURLWithPath: "/tmp"), skipsPermissions: false)
    XCTAssertEqual(agent.modeID(AgentSessionOptions(directory: "/", permissionMode: "accept-edits")), "accept-edits")
    XCTAssertEqual(agent.modeID(AgentSessionOptions(directory: "/", permissionMode: "skip")), "default")
    XCTAssertEqual(agent.modeID(AgentSessionOptions(directory: "/", permissionMode: "auto", planMode: true)), "plan")
    XCTAssertEqual(agent.modeID(AgentSessionOptions(directory: "/", permissionMode: "auto", readOnly: true)), "default")
  }

  func testPlanStandsInEachLadderWhereItsCLIPutsIt() {
    func ids(_ agent: AgentId) -> [String] { PermissionMode.walk(for: agent, plans: true).map(\.id) }
    XCTAssertEqual(ids(.claude), ["default", "acceptEdits", "plan", "auto", "bypassPermissions"])
    XCTAssertEqual(ids(.antigravity), ["default", "accept-edits", "auto", "plan", "skip"])
    XCTAssertEqual(ids(.codex), ["ask", "approveForMe", "fullAccess", "plan"])
    XCTAssertEqual(ids(.opencode), ["build", "plan"])
    XCTAssertFalse(PermissionMode.ladder(for: .claude).contains { $0.id == PermissionMode.planID },
                   "Settings chooses no plan")
  }

  func testEachCLIAnswersAPlanInItsOwnWords() {
    XCTAssertEqual(ClaudeCodeClient.planAnswers(launchedWith: AgentSessionOptions(directory: "/")),
                   [.useAuto, .approveEdits, .keepPlanning])
    XCTAssertEqual(
      ClaudeCodeClient.planAnswers(launchedWith: AgentSessionOptions(directory: "/", permissionMode: "bypassPermissions")),
      [.bypass, .approveEdits, .keepPlanning])
    XCTAssertEqual(PlanAnswer.implement.message, "Implement the plan.")
    XCTAssertEqual(PlanAnswer.quit.decision, .abandoned)
    XCTAssertEqual(PlanAnswer.useAuto.mode, "auto")
  }
}

@MainActor
final class ForkTests: XCTestCase {
  private func message(_ id: String, _ role: ConversationMessage.Role) -> ConversationMessage {
    ConversationMessage(id: id, role: role, createdAt: Date())
  }

  func testAForkKeepsTheTurnThroughItsLastAnswer() {
    let messages = [
      message("q1", .user), message("a1", .agent), message("a1b", .agent),
      message("q2", .user), message("a2", .agent),
    ]
    XCTAssertEqual(ConversationEngine.messages(messages, throughTurnOf: "a1").map(\.id), ["q1", "a1", "a1b"])
    XCTAssertEqual(ConversationEngine.messages(messages, throughTurnOf: "a2").map(\.id), messages.map(\.id))
    XCTAssertEqual(ConversationEngine.messages(messages, throughTurnOf: nil).count, 5)
  }

  func testClaudeCodeForksFromTheSourceIntoTheNewID() {
    let launched = ["--print", "--session-id", "new", "--model", "haiku"]
    XCTAssertEqual(
      ClaudeCodeClient.forkArguments(launched, id: "new", from: "old", at: "rec"),
      ["--print", "--model", "haiku", "--resume", "old", "--resume-session-at", "rec", "--fork-session",
       "--session-id", "new"])
    XCTAssertFalse(ClaudeCodeClient.forkArguments(launched, id: "new", from: "old", at: nil)
      .contains("--resume-session-at"))
  }

  func testACodexForkReadsItsSourceFirst() throws {
    let sessions = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let day = sessions.appendingPathComponent("2026/11/18")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sessions) }
    let source = [
      #"{"type":"session_meta","payload":{"id":"src"}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"user","id":"u1","content":[{"type":"input_text","text":"first"}]}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"assistant","id":"a1","content":[{"type":"output_text","text":"one"}]}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"user","id":"u2","content":[{"type":"input_text","text":"left out"}]}}"#,
    ]
    let fork = [
      #"{"type":"session_meta","payload":{"id":"fork","forked_from_id":"src","forked_from_ordinal_exclusive":3}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"user","id":"u3","content":[{"type":"input_text","text":"after"}]}}"#,
    ]
    try source.joined(separator: "\n").write(to: day.appendingPathComponent("rollout-1-src.jsonl"), atomically: true, encoding: .utf8)
    let forkURL = day.appendingPathComponent("rollout-2-fork.jsonl")
    try fork.joined(separator: "\n").write(to: forkURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(CodexRolloutTranscript.read(at: forkURL).map(\.plainText), ["first", "one", "after"])
  }
}

@MainActor
final class FileUndoTests: XCTestCase {
  func testTheAlertNamesFilesInTheFolderByTheirPlaceInIt() {
    let text = AgentPaletteController.undoDescription(
      FileUndo(files: ["/work/a.txt", "/elsewhere/b.txt"]), agent: "Claude Code", folder: "/work")
    XCTAssertTrue(text.hasPrefix("a.txt\n/elsewhere/b.txt"))
    XCTAssertTrue(text.hasSuffix("the chat stays as it is."))
  }

  func testAnUndoThatCutsTheChatSaysSo() {
    let text = AgentPaletteController.undoDescription(FileUndo(cutsHistory: true), agent: "OpenCode", folder: "/w")
    XCTAssertEqual(text, "OpenCode puts its changes to files back as they were, and this request and all after it leave the chat.")
  }
}
