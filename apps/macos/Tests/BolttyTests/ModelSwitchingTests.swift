import XCTest
@testable import Boltty

@MainActor
final class ModelSwitchingTests: XCTestCase {
  private func option(_ provider: String, _ id: String, isDefault: Bool = false, efforts: [String] = []) -> AgentModelOption {
    AgentModelOption(
      selection: ModelSelection(providerID: provider, modelID: id),
      isDefault: isDefault,
      effortOptions: efforts.map { AgentEffortOption(value: $0) })
  }

  private func makeStore() -> ConversationStore {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-models-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return ConversationStore(persistence: ConversationPersistence(root: root))
  }

  private func makeEngine() -> (ConversationStore, ConversationEngine, FakeAgentClient) {
    let client = FakeAgentClient()
    let store = makeStore()
    let engine = ConversationEngine(store: store, client: client)
    return (store, engine, client)
  }

  // MARK: - What Settings stores

  func testAStoredChoiceKnowsItsProviderAndAnOldOneStillReads() {
    let models = [option("zen", "shared"), option("strata", "shared"), option("strata", "other")]
    XCTAssertEqual(models.option(stored: "strata/shared")?.selection.providerID, "strata")
    XCTAssertEqual(models.option(stored: "other")?.selection.providerID, "strata", "stored before it said")
    XCTAssertNil(models.option(stored: "gone"))
    XCTAssertNil(models.option(stored: ""))
    XCTAssertNil(models.option(stored: nil))
  }

  func testAChatsModelIsFoundByProviderFirst() {
    let models = [option("zen", "shared"), option("strata", "shared")]
    let chat = ModelSelection(providerID: "strata", modelID: "shared")
    XCTAssertEqual(models.option(for: chat)?.selection.providerID, "strata")
    let namedByAgent = ModelSelection(providerID: "opencode", modelID: "shared")
    XCTAssertEqual(models.option(for: namedByAgent)?.selection.providerID, "zen")
  }

  func testAChoiceBeforeTheListHasComeKeepsItsProvider() {
    let (store, engine, _) = makeEngine()
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    coordinator.defaultModelID = { _ in "strata/qwen" }
    XCTAssertEqual(
      coordinator.resolvedDefaultModel(for: "opencode"),
      ModelSelection(providerID: "strata", modelID: "qwen"))
  }

  func testOpenCodeWithNoProviderToNameStartsOnItsDefault() {
    let (store, engine, _) = makeEngine()
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    coordinator.defaultModelID = { _ in "qwen" }
    XCTAssertNil(coordinator.resolvedDefaultModel(for: "opencode"), "`opencode/qwen` would not run")
    XCTAssertEqual(coordinator.resolvedDefaultModel(for: "claude")?.modelID, "qwen")
  }

  // MARK: - Applying it

  func testASessionStartedHereIsNotToldAgainUntilTheChatChanges() async throws {
    let (store, engine, client) = makeEngine()
    let chat = store.createConversation(title: "t", workingDirectory: "/tmp", providerID: client.providerID)
    await engine.send(text: "one", in: chat.id)
    XCTAssertTrue(client.preparedSessions.isEmpty, "made with what the chat asks for")

    store.setExecutionState(.idle, for: chat.id)
    await engine.send(text: "two", in: chat.id)
    XCTAssertTrue(client.preparedSessions.isEmpty)

    store.setExecutionState(.idle, for: chat.id)
    engine.chooseModel(option("anthropic", "opus"), for: chat.id)
    XCTAssertTrue(client.preparedSessions.isEmpty, "the choice waits for the next message")
    await engine.send(text: "three", in: chat.id)
    XCTAssertEqual(client.preparedSessions.map(\.options.model?.modelID), ["opus"])
  }

  func testASessionRestoredFromDiskIsToldWhatTheChatRunsOn() async throws {
    let (store, engine, client) = makeEngine()
    let chat = store.createConversation(
      title: "t", workingDirectory: "/tmp", providerID: client.providerID,
      model: ModelSelection(providerID: "anthropic", modelID: "opus"),
      reasoningEffort: "high", autoApprove: true)
    store.attachRemoteSession("saved", to: chat.id, model: nil)

    await engine.send(text: "hello", in: chat.id)

    let prepared = try XCTUnwrap(client.preparedSessions.first)
    XCTAssertEqual(prepared.id, "saved")
    XCTAssertEqual(prepared.options.model?.modelID, "opus")
    XCTAssertEqual(prepared.options.effort, "high")
    XCTAssertTrue(prepared.options.autoApprove)
    XCTAssertEqual(prepared.options.directory, "/tmp")
  }

  func testAModelTheAgentRefusesSendsNothingAndKeepsTheWords() async {
    let (store, engine, client) = makeEngine()
    let chat = store.createConversation(title: "t", workingDirectory: "/tmp", providerID: client.providerID)
    store.attachRemoteSession("saved", to: chat.id, model: nil)
    client.prepareError = .transport("no such model")

    let sent = await engine.send(text: "hello", in: chat.id)

    XCTAssertFalse(sent)
    XCTAssertTrue(store.transcript(id: chat.id).messages.isEmpty)
    XCTAssertEqual(store.conversation(id: chat.id)?.lastKnownState, .idle)
    XCTAssertEqual(engine.notices[chat.id]?.text, "no such model")
  }

  func testEffortGoesWithTheModelOnlyWhereTheModelHasIt() {
    let (store, engine, client) = makeEngine()
    let chat = store.createConversation(
      title: "t", workingDirectory: "/tmp", providerID: client.providerID, reasoningEffort: "max")
    engine.chooseModel(option("a", "keeps", efforts: ["max", "low"]), for: chat.id)
    XCTAssertEqual(store.conversation(id: chat.id)?.reasoningEffort, "max")
    engine.chooseModel(option("a", "lacks", efforts: ["low"]), for: chat.id)
    XCTAssertNil(store.conversation(id: chat.id)?.reasoningEffort)
  }

  func testAnAgentThatCannotGoBackOffersNoDefaultEffort() {
    let high = AgentEffortOption(value: "high")
    func titles(effort: String?, canReset: Bool) -> [String] {
      ModelMenu.make(
        BolttyAIModelMenu(
          agent: .codex, models: [], current: nil, goneName: nil, efforts: [high],
          effort: effort, canResetEffort: canReset, autoMode: nil),
        chooseModel: { _ in }, chooseEffort: { _ in }, setAutoMode: { _ in }
      ).items.map(\.title)
    }
    XCTAssertFalse(titles(effort: "high", canReset: false).contains("Default"))
    XCTAssertTrue(titles(effort: nil, canReset: false).contains("Default"), "it is where the chat stands")
    XCTAssertTrue(titles(effort: "high", canReset: true).contains("Default"))
  }

  func testAModelChosenWhileTheSessionStartsStands() {
    let store = makeStore()
    let chosen = ModelSelection(providerID: "a", modelID: "chosen")
    let chat = store.createConversation(title: "t", workingDirectory: "/tmp", providerID: "claude", model: chosen)
    store.attachRemoteSession("s", to: chat.id, model: ModelSelection(providerID: "a", modelID: "asked"))
    XCTAssertEqual(store.conversation(id: chat.id)?.model, chosen)
  }

  // MARK: - A model that has gone

  func testATurnThatFailedBeforeAnyReplyKeepsItsWords() {
    let store = makeStore()
    let chat = store.createConversation(title: "t", workingDirectory: "/tmp", providerID: "opencode")
    store.attachRemoteSession("s", to: chat.id, model: nil)
    store.apply(AgentEventEnvelope(providerID: "opencode", event: .sessionFailed(
      sessionID: "s",
      failure: MessageFailure(name: "provider.no-route", message: "Model unavailable: strata/gone"))))

    XCTAssertEqual(store.conversation(id: chat.id)?.lastKnownState, .failed)
    XCTAssertEqual(store.transcript(id: chat.id).messages.last?.failure?.message, "Model unavailable: strata/gone")
  }

  func testTheCardSaysItWasTheModelAndOffersAnother() throws {
    var message = ConversationMessage(id: "m", role: .agent, createdAt: Date(), completedAt: Date())
    message.failure = MessageFailure(name: "provider.no-route", message: "Model unavailable: strata/gone")
    let report = try XCTUnwrap(AgentFailureReport.make(from: BolttyAISessionPreview(
      id: UUID(), title: "t", agent: .opencode, state: .failed, body: "", messages: [message],
      modelChip: BolttyAIModelChip(title: "gone", help: ""))))
    XCTAssertEqual(report.sentence, AgentFailureReport.modelGoneSentence)
    XCTAssertTrue(report.offersModelChoice)
    XCTAssertTrue(report.details.contains("strata/gone"))
  }

  func testOtherFailuresKeepTheOneSentence() throws {
    var message = ConversationMessage(id: "m", role: .agent, createdAt: Date(), completedAt: Date())
    message.failure = MessageFailure(name: "APIError", message: "Overloaded")
    let report = try XCTUnwrap(AgentFailureReport.make(from: BolttyAISessionPreview(
      id: UUID(), title: "t", agent: .claude, state: .failed, body: "", messages: [message],
      modelChip: BolttyAIModelChip(title: "Opus", help: ""))))
    XCTAssertEqual(report.sentence, AgentFailureReport.universalSentence)
    XCTAssertFalse(report.offersModelChoice)
  }

  // MARK: - OpenCode's events

  private func events(_ json: String) throws -> [AgentEvent] {
    let frame = try JSONDecoder().decode(OpenCodeDTO.EventFrame.self, from: Data(json.utf8))
    return OpenCodeClient.domainEvents(from: frame, resolver: nil)
  }

  func testOpenCodeSaysWhenItsCatalogueChanges() throws {
    XCTAssertEqual(try events(#"{"id":"e","type":"model.updated","data":{}}"#), [.modelsChanged])
    XCTAssertEqual(try events(#"{"id":"e","type":"provider.updated","data":{}}"#), [.modelsChanged])
  }

  /// As recorded from 2.2.5 asked to run a model no provider has.
  func testAnExecutionThatFailedIsAFailureAndNotAChatLeftWorking() throws {
    let found = try events(#"""
      {"id":"e","type":"session.execution.failed","data":{"sessionID":"ses_1",\#
      "error":{"type":"provider.no-route","message":"Model unavailable: strata/gone"}}}
      """#)
    guard case let .sessionFailed(sessionID, failure) = found.first else {
      return XCTFail("read as \(found)")
    }
    XCTAssertEqual(sessionID, "ses_1")
    XCTAssertEqual(failure.name, "provider.no-route")
    XCTAssertTrue(AgentFailureReport.saysModelIsGone(failure))
  }
}
