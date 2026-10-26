import XCTest
@testable import Boltty

@MainActor
final class AgentRegistryTests: XCTestCase {
  private var root: URL!
  private var store: ConversationStore!
  private var openCode: FakeAgentClient!
  private var claude: FakeAgentClient!
  private var engine: ConversationEngine!

  override func setUp() async throws {
    try await super.setUp()
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-registry-\(UUID().uuidString)")
    store = ConversationStore(persistence: ConversationPersistence(root: root))
    openCode = FakeAgentClient()
    claude = FakeAgentClient()
    claude.provider = .claude
    claude.capabilities = [
      .modelSelection, .permissions, .attachments, .interrupt, .workingDirectory
    ]
    engine = ConversationEngine(
      store: store,
      registry: AgentRegistry(clients: [openCode, claude])
    )
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
    try await super.tearDown()
  }

  private func conversation(on provider: AgentId) -> UUID {
    store.createConversation(
      title: "Task", workingDirectory: "/tmp/work", providerID: provider.rawValue
    ).id
  }

  func testASendGoesToTheConversationsOwnAgent() async {
    let onOpenCode = conversation(on: .opencode)
    let onClaude = conversation(on: .claude)

    await engine.send(text: "first", in: onOpenCode)
    await engine.send(text: "second", in: onClaude)

    XCTAssertEqual(openCode.sentMessages.map(\.text), ["first"])
    XCTAssertEqual(claude.sentMessages.map(\.text), ["second"])
  }

  func testAnAgentThisBuildDoesNotHaveIsAMessageRatherThanACrash() async {
    let orphan = store.createConversation(
      title: "Old", workingDirectory: "/tmp", providerID: "gemini"
    ).id
    store.setDraft("hello", for: orphan)

    let accepted = await engine.send(text: "hello", in: orphan)

    XCTAssertFalse(accepted)
    XCTAssertTrue(store.transcript(id: orphan).messages.isEmpty, "nothing was recorded")
    XCTAssertEqual(store.conversation(id: orphan)?.draft, "hello", "the prompt is kept")
    XCTAssertNotNil(engine.notices[orphan])
    XCTAssertTrue(engine.notices[orphan]!.text.contains("not installed"))
  }

  func testAnEventIsAppliedToItsOwnAgentsConversation() async {
    let onOpenCode = conversation(on: .opencode)
    let onClaude = conversation(on: .claude)
    store.attachRemoteSession("ses_1", to: onOpenCode, model: nil)
    store.attachRemoteSession("ses_1", to: onClaude, model: nil)

    store.apply(AgentEventEnvelope(
      providerID: AgentId.claude.rawValue,
      id: "e1",
      sequence: 1,
      event: .executionStateChanged(sessionID: "ses_1", state: .working)
    ))

    XCTAssertEqual(store.conversation(id: onClaude)?.lastKnownState, .working)
    XCTAssertEqual(
      store.conversation(id: onOpenCode)?.lastKnownState, .idle,
      "the other agent's conversation is untouched"
    )
  }

  func testWatermarksAreCountedPerAgent() async {
    let onOpenCode = conversation(on: .opencode)
    let onClaude = conversation(on: .claude)
    store.attachRemoteSession("ses_1", to: onOpenCode, model: nil)
    store.attachRemoteSession("ses_1", to: onClaude, model: nil)

    store.apply(AgentEventEnvelope(
      providerID: AgentId.opencode.rawValue, id: "a", sequence: 9,
      event: .executionStateChanged(sessionID: "ses_1", state: .working)
    ))
    store.apply(AgentEventEnvelope(
      providerID: AgentId.claude.rawValue, id: "b", sequence: 1,
      event: .executionStateChanged(sessionID: "ses_1", state: .working)
    ))

    XCTAssertEqual(store.conversation(id: onClaude)?.lastKnownState, .working)
  }

  func testCapabilitiesFollowTheConversationsAgent() {
    let onOpenCode = conversation(on: .opencode)
    let onClaude = conversation(on: .claude)

    XCTAssertTrue(engine.capabilities(for: onOpenCode).contains(.questions))
    XCTAssertFalse(
      engine.capabilities(for: onClaude).contains(.questions),
      "a card the CLI can never fill must not be offered"
    )
  }

  func testTheAgentIsFixedOnceTheConversationHasASession() {
    let id = conversation(on: .opencode)
    store.setProvider(AgentId.claude.rawValue, for: id)
    XCTAssertEqual(store.conversation(id: id)?.providerID, AgentId.claude.rawValue)

    store.attachRemoteSession("ses_9", to: id, model: nil)
    store.setProvider(AgentId.opencode.rawValue, for: id)
    XCTAssertEqual(
      store.conversation(id: id)?.providerID, AgentId.claude.rawValue,
      "the history lives inside that CLI; the row cannot be re-pointed"
    )
  }

  func testChangingAgentDropsAModelTheNewOneHasNeverHeardOf() {
    let id = conversation(on: .opencode)
    store.setModel(
      ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"), for: id
    )

    store.setProvider(AgentId.claude.rawValue, for: id)

    XCTAssertNil(store.conversation(id: id)?.model)
  }

  func testModelListsAreKeptApartByAgent() async {
    openCode.models = [AgentModelOption(
      selection: ModelSelection(providerID: "openai", modelID: "gpt-5"), isDefault: true
    )]
    claude.models = [AgentModelOption(
      selection: ModelSelection(providerID: "claude", modelID: "sonnet"), isDefault: true
    )]
    let onOpenCode = conversation(on: .opencode)
    let onClaude = conversation(on: .claude)

    await engine.refreshAvailability()

    XCTAssertEqual(engine.models(for: onOpenCode).map(\.selection.modelID), ["gpt-5"])
    XCTAssertEqual(engine.models(for: onClaude).map(\.selection.modelID), ["sonnet"])
  }

  // MARK: - The model scan

  func testAnAgentThatNeverListsItsModelsEndsTheScanAtTheDeadline() async {
    engine = ConversationEngine(
      store: store,
      registry: AgentRegistry(clients: [openCode, claude]),
      modelListDeadline: 0.2
    )
    let defaults = isolatedDefaults("boltty.tests.modelScan")
    let settings = BolttyAISettingsModel(
      appModel: AppModel(settings: AppSettings(), defaults: defaults), engine: engine
    )
    let silent: FakeAgentClient = openCode
    silent.modelsHang = true
    addTeardownBlock { silent.releaseModels() }
    claude.models = [AgentModelOption(
      selection: ModelSelection(providerID: "claude", modelID: "sonnet"), isDefault: true
    )]

    let scanned = expectation(description: "the Settings scan finished")
    Task {
      await settings.refreshAgents()
      scanned.fulfill()
    }
    await fulfillment(of: [scanned], timeout: 5)

    XCTAssertFalse(settings.isLoadingModels, "the spinner outlived the scan")
    XCTAssertEqual(
      engine.modelsByProvider[AgentId.opencode.rawValue], [],
      "an agent that ran out of time ends with an empty list, like one that failed"
    )
    XCTAssertEqual(
      engine.modelsByProvider[AgentId.claude.rawValue]?.map(\.selection.modelID), ["sonnet"]
    )
  }

  // MARK: - Reasoning effort

  private func withEffort() async -> UUID {
    claude.capabilities.insert(.reasoningEffort)
    claude.models = [AgentModelOption(
      selection: ModelSelection(providerID: "claude", modelID: "sonnet"),
      isDefault: true,
      effortOptions: [
        AgentEffortOption(value: "low"),
        AgentEffortOption(value: "xhigh", detail: "Slower, thinks longer")
      ]
    )]
    let id = conversation(on: .claude)
    await engine.refreshAvailability()
    return id
  }

  func testEffortLevelsAreTheOnesTheChosenModelReported() async {
    let id = await withEffort()

    XCTAssertEqual(engine.effortOptions(for: id).map(\.value), ["low", "xhigh"])
    XCTAssertEqual(
      engine.effortOptions(for: id).map(\.label), ["Low", "Extra high"],
      "`xhigh` is a name, not something `capitalized` can produce"
    )
  }

  func testAnAgentWithoutTheCapabilityOffersNoLevels() async {
    openCode.models = [AgentModelOption(
      selection: ModelSelection(providerID: "openai", modelID: "gpt-5"),
      isDefault: true,
      effortOptions: [AgentEffortOption(value: "high")]
    )]
    let id = conversation(on: .opencode)
    await engine.refreshAvailability()

    XCTAssertTrue(
      engine.effortOptions(for: id).isEmpty,
      "OpenCode does not declare .reasoningEffort, so nothing is offered"
    )
  }

  func testTheChosenEffortReachesTheAgentWhenTheSessionIsCreated() async {
    let id = await withEffort()
    store.setReasoningEffort("xhigh", for: id)

    await engine.send(text: "think hard", in: id)

    XCTAssertEqual(claude.createdOptions.map(\.effort), ["xhigh"])
  }

  func testASessionWithNoEffortChosenLetsTheAgentUseItsOwn() async {
    let id = await withEffort()

    await engine.send(text: "go", in: id)

    XCTAssertEqual(
      claude.createdOptions.map(\.effort), [nil], "no level is invented for the CLI"
    )
  }

  func testChangingTheModelDropsTheEffortChosenForTheOldOne() async {
    let id = await withEffort()
    store.setReasoningEffort("xhigh", for: id)

    store.setModel(ModelSelection(providerID: "claude", modelID: "haiku"), for: id)

    XCTAssertNil(store.conversation(id: id)?.reasoningEffort)
  }

  func testAnAgentThatIsNotInstalledIsListedWithTheReasonRatherThanHidden() async {
    claude.availability = .notInstalled
    let registry = AgentRegistry(clients: [openCode, claude])

    await registry.probeAll()

    XCTAssertEqual(registry.installations.count, 2, "a missing agent still has a row")
    XCTAssertEqual(registry.installation(for: .claude)?.statusText, "Not installed")
    XCTAssertEqual(registry.ready.map(\.provider), [.opencode])
    XCTAssertEqual(registry.defaultProvider, .opencode)
  }

  func testSignedOutIsItsOwnStateWithTheCommandThatFixesIt() async {
    openCode.availability = .needsLogin("Signed out — run `opencode auth login`.")
    let registry = AgentRegistry(clients: [openCode])

    await registry.probeAll()

    let installation = registry.installation(for: .opencode)
    XCTAssertEqual(installation?.isReady, false)
    XCTAssertTrue(installation!.availability.isInstalled, "it is there, just signed out")
    XCTAssertTrue(installation!.statusText.contains("auth login"))
  }

  func testAnACPClientTakesEverythingAgentSpecificFromItsDescriptor() {
    let grok = ACPClient(agent: .grok)
    XCTAssertEqual(grok.provider, .grok)
    XCTAssertEqual(grok.capabilities, ACPAgent.grok.capabilities)
    XCTAssertEqual(ACPAgent.grok.provider.program, AgentId.grok.program)

    let other = ACPAgent(
      provider: .custom,
      displayName: "Some ACP agent",
      arguments: ["--acp"],
      capabilities: [.permissions, .interrupt]
    )
    let client = ACPClient(agent: other)
    XCTAssertEqual(client.provider, .custom)
    XCTAssertEqual(client.capabilities, [.permissions, .interrupt])
    XCTAssertNotEqual(client.capabilities, grok.capabilities)
  }
}

final class AgentVersionDisplayTests: XCTestCase {
  func testTheVersionIsTheNumberWhateverTheCLIWroteAroundIt() {
    XCTAssertEqual(AgentInstallation.displayVersion("2.1.286 (Claude Code)"), "2.1.286")
    XCTAssertEqual(AgentInstallation.displayVersion("opencode v2.0.22"), "2.0.22")
    XCTAssertEqual(AgentInstallation.displayVersion("codex-cli 0.155.1"), "0.155.1")
    XCTAssertEqual(AgentInstallation.displayVersion("grok 1.0.46-beta.2"), "1.0.46-beta.2")
    XCTAssertEqual(AgentInstallation.displayVersion(" nightly "), "nightly",
                   "nothing version-shaped: the CLI's own words")
  }
}
