import Foundation
import XCTest
@testable import Boltty

@MainActor
final class OpenCodeFreeModelLiveTests: XCTestCase {
  func testAFreeModelAnswersThroughTheEngineAndThePromptAppearsOnce() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["BOLTTY_LIVE_FREE"] != nil,
      "set BOLTTY_LIVE_FREE to spend one free-model turn"
    )
    let client = OpenCodeClient()
    addTeardownBlock { await client.shutdown() }
    guard case .available = await client.probe() else {
      throw XCTSkip("OpenCode is not installed here")
    }

    var free: ModelSelection?
    let wanted = ProcessInfo.processInfo.environment["BOLTTY_LIVE_FREE_MODEL"]
    for option in try await client.availableModels() where free == nil {
      if let wanted, option.selection.modelID != wanted { continue }
      if await client.isFree(option.selection) { free = option.selection }
    }
    let model = try XCTUnwrap(free, "the catalogue offers no free model")

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-free-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    let engine = ConversationEngine(store: store, registry: AgentRegistry(clients: [client]))
    engine.start()
    addTeardownBlock { await engine.shutdown() }

    let conversation = store.createConversation(
      workingDirectory: NSTemporaryDirectory(),
      providerID: AgentId.opencode.rawValue,
      model: model
    )
    let prompt = "Reply with exactly one word: pong"
    let sent = await engine.send(text: prompt, in: conversation.id)
    XCTAssertTrue(sent, "the engine refused to send")

    let deadline = Date().addingTimeInterval(120)
    var answer: ConversationMessage?
    while Date() < deadline, answer == nil {
      answer = store.transcript(id: conversation.id).messages.last {
        $0.role == .agent && $0.completedAt != nil
          && (!$0.plainText.isEmpty || $0.failure != nil)
      }
      if answer == nil { try await Task.sleep(for: .milliseconds(500)) }
    }
    if answer == nil {
      let seen = store.transcript(id: conversation.id).messages.map { message in
        "\(message.role) done=\(message.completedAt != nil) parts=\(message.parts.count) "
          + "text=\(message.plainText.prefix(40))"
      }
      let state = store.conversation(id: conversation.id)?.lastKnownState
      print("[free model] no answer; state=\(String(describing: state)) transcript=\(seen)")
      await engine.refresh(conversationID: conversation.id)
      let reread = store.transcript(id: conversation.id).messages.map {
        "\($0.role) done=\($0.completedAt != nil) text=\($0.plainText.prefix(40))"
      }
      print("[free model] after refresh: \(reread)")
    }
    let reply = try XCTUnwrap(answer, "\(model.modelID) said nothing within two minutes")
    XCTAssertNil(reply.failure, "refused: \(reply.failure?.message ?? "")")
    XCTAssertTrue(reply.plainText.lowercased().contains("pong"),
                  "\(model.modelID) answered: \(reply.plainText)")

    let typed = store.transcript(id: conversation.id).messages
      .filter { $0.role == .user && $0.plainText == prompt }
    XCTAssertEqual(typed.count, 1, "the prompt should appear once")
    print("[free model] \(model.modelID) answered: \(reply.plainText)")
  }
}
