import XCTest
@testable import Boltty

@MainActor
final class BolttyAILaunchTests: XCTestCase {
  func testEnabledProvidersRoundTripAndMissingKeyMeansAllOn() {
    let defaults = isolatedDefaults("boltty.tests.enabled")

    let settings = AppSettings(enabledProviderIDs: [AgentId.grok.rawValue])
    settings.save(defaults: defaults)
    XCTAssertEqual(AppSettings.load(defaults: defaults).enabledProviderIDs, [AgentId.grok.rawValue])

    let fresh = isolatedDefaults("boltty.tests.enabled.fresh")
    XCTAssertEqual(AppSettings.load(defaults: fresh).enabledProviderIDs, AppSettings.allAdapterProviderIDs)
  }

  func testDefaultModelRoundTrips() {
    let defaults = isolatedDefaults("boltty.tests.models")
    let settings = AppSettings(defaultModelByProvider: ["claude": "opus"])
    settings.save(defaults: defaults)
    XCTAssertEqual(AppSettings.load(defaults: defaults).defaultModelByProvider["claude"], "opus")
  }

  func testDisablingTheDefaultAgentPicksAnother() {
    var settings = AppSettings(
      agentPreset: .claude,
      enabledProviderIDs: [AgentId.claude.rawValue, AgentId.codex.rawValue]
    )
    settings.setProvider(AgentId.claude.rawValue, enabled: false)
    XCTAssertEqual(settings.agentPreset, .codex)
    XCTAssertFalse(settings.isProviderEnabled(AgentId.claude.rawValue))
  }

  func testStartConversationStampsTheDefaultModel() async {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-launch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    let client = FakeAgentClient()
    client.models = [
      AgentModelOption(
        selection: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5", displayName: "Sonnet"),
        isDefault: true
      )
    ]
    let engine = ConversationEngine(store: store, client: client)
    await engine.refreshAvailability()
    let chat = ChatWorkspaceCoordinator(store: store, engine: engine)
    chat.defaultModelID = { _ in "claude-sonnet-5" }

    let conversation = chat.startConversationInBackground(prompt: "hello", providerID: AgentId.opencode.rawValue)
    XCTAssertEqual(conversation.model?.modelID, "claude-sonnet-5")
    XCTAssertEqual(conversation.model?.providerID, "anthropic")
  }

  func testStartConversationStampsTheDefaultEffort() async {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-launch-effort-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    let client = FakeAgentClient()
    client.models = [
      AgentModelOption(
        selection: ModelSelection(providerID: "claude", modelID: "opus", displayName: "Opus"),
        isDefault: true,
        effortOptions: [
          AgentEffortOption(value: "low", label: "Low"),
          AgentEffortOption(value: "high", label: "High")
        ]
      )
    ]
    let engine = ConversationEngine(store: store, client: client)
    await engine.refreshAvailability()
    let chat = ChatWorkspaceCoordinator(store: store, engine: engine)
    chat.defaultModelID = { _ in "opus" }
    chat.defaultEffortID = { _ in "high" }

    let conversation = chat.startConversationInBackground(
      prompt: "hello",
      providerID: AgentId.opencode.rawValue
    )
    XCTAssertEqual(conversation.reasoningEffort, "high")
  }

  func testDefaultEffortIsDroppedWhenTheModelDoesNotOfferIt() async {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-launch-effort-drop-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    let client = FakeAgentClient()
    client.models = [
      AgentModelOption(
        selection: ModelSelection(providerID: "opencode", modelID: "fast"),
        isDefault: true,
        effortOptions: []
      )
    ]
    let engine = ConversationEngine(store: store, client: client)
    await engine.refreshAvailability()
    let chat = ChatWorkspaceCoordinator(store: store, engine: engine)
    chat.defaultEffortID = { _ in "high" }

    let conversation = chat.startConversationInBackground(
      prompt: "hello",
      providerID: AgentId.opencode.rawValue
    )
    XCTAssertNil(conversation.reasoningEffort)
  }

  func testStartConversationRefusesADisabledAgent() async {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-launch-off-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    let client = FakeAgentClient()
    let engine = ConversationEngine(store: store, client: client)
    await engine.refreshAvailability()
    let chat = ChatWorkspaceCoordinator(store: store, engine: engine)
    chat.isProviderEnabled = { _ in false }

    XCTAssertNil(chat.startConversation(prompt: "hello", id: UUID(), workingDirectory: chat.defaultWorkingDirectory()))
  }

  func testAutoRoutingPrefersSettingsAgentAndFallsBackWhenItIsUnavailable() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-launch-auto-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    let claude = FakeAgentClient()
    claude.provider = .claude
    claude.models = [AgentModelOption(
      selection: .init(providerID: "claude", modelID: "sonnet"),
      isDefault: true
    )]
    let codex = FakeAgentClient()
    codex.provider = .codex
    codex.models = [AgentModelOption(
      selection: .init(providerID: "codex", modelID: "gpt-6"),
      isDefault: true
    )]
    let engine = ConversationEngine(store: store, registry: AgentRegistry(clients: [claude, codex]))
    await engine.refreshAvailability()
    let chat = ChatWorkspaceCoordinator(store: store, engine: engine)
    chat.preferredProviderID = { AgentId.codex.rawValue }
    chat.defaultModelID = { $0 == AgentId.codex.rawValue ? "gpt-6" : "sonnet" }

    let preferredID = try XCTUnwrap(chat.startConversation(prompt: "first", id: UUID(), workingDirectory: chat.defaultWorkingDirectory()))
    XCTAssertEqual(store.conversation(id: preferredID)?.providerID, AgentId.codex.rawValue)
    XCTAssertEqual(store.conversation(id: preferredID)?.model?.modelID, "gpt-6")

    codex.availability = .needsLogin("Sign in")
    await engine.refreshAvailability()
    let fallbackID = try XCTUnwrap(chat.startConversation(prompt: "second", id: UUID(), workingDirectory: chat.defaultWorkingDirectory()))
    XCTAssertEqual(store.conversation(id: fallbackID)?.providerID, AgentId.claude.rawValue)
    XCTAssertEqual(store.conversation(id: fallbackID)?.model?.modelID, "sonnet")
  }

  func testAutoRoutingOnlyUsesEnabledReadyAgents() async {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-launch-grok-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    let client = FakeAgentClient()
    client.provider = .grok
    let engine = ConversationEngine(store: store, client: client)
    await engine.refreshAvailability()
    let chat = ChatWorkspaceCoordinator(store: store, engine: engine)

    XCTAssertEqual(chat.automaticProviderID(), AgentId.grok.rawValue)
    chat.isProviderEnabled = { $0 != AgentId.grok.rawValue }
    XCTAssertNil(chat.automaticProviderID())
  }
}
