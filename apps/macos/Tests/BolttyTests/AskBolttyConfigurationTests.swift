import XCTest
@testable import Boltty

final class AskBolttyConfigurationTests: XCTestCase {
  private let models: [String: [AgentModelOption]] = [
    "claude": [
      AgentModelOption(selection: ModelSelection(providerID: "claude", modelID: "sonnet", displayName: "Sonnet"), isDefault: true),
      AgentModelOption(selection: ModelSelection(providerID: "claude", modelID: "haiku", displayName: "Haiku"), isDefault: false),
    ],
    "codex": [
      AgentModelOption(
        selection: ModelSelection(providerID: "codex", modelID: "gpt-6-luna"), isDefault: true,
        effortOptions: [AgentEffortOption(value: "low", label: "Low")]),
    ],
  ]

  func testAutomaticIsClaudeInHaikuReadOnly() {
    let target = AskBolttyConfiguration.resolve(
      settings: AppSettings(), candidates: ["codex", "claude"], models: models)
    XCTAssertEqual(target?.providerID, "claude")
    XCTAssertEqual(target?.model?.modelID, "haiku")
    XCTAssertEqual(target?.readOnly, true)
  }

  func testWithoutClaudeTheFirstAgentThatSeesAnswersInItsDefault() {
    let target = AskBolttyConfiguration.resolve(
      settings: AppSettings(), candidates: ["codex"], models: models)
    XCTAssertEqual(target?.providerID, "codex")
    XCTAssertNil(target?.model)
  }

  func testAChosenAgentAndModelAreKeptWhileTheyExist() {
    var settings = AppSettings()
    settings.askBolttyProviderID = "codex"
    settings.askBolttyModelID = "gpt-6-luna"
    settings.askBolttyReadOnly = false
    let target = AskBolttyConfiguration.resolve(settings: settings, candidates: ["claude", "codex"], models: models)
    XCTAssertEqual(target, AskBolttyTarget(
      providerID: "codex", model: ModelSelection(providerID: "codex", modelID: "gpt-6-luna"),
      effort: "low", readOnly: false))
  }

  func testAChosenAgentThatIsNotReadyFallsBackAndForgetsItsModel() {
    var settings = AppSettings()
    settings.askBolttyProviderID = "grok"
    settings.askBolttyModelID = "grok-4.7"
    let target = AskBolttyConfiguration.resolve(settings: settings, candidates: ["claude"], models: models)
    XCTAssertEqual(target?.providerID, "claude")
    XCTAssertEqual(target?.model?.modelID, "haiku")
  }

  func testNoAgentThatSeesIsNoAskBoltty() {
    XCTAssertNil(AskBolttyConfiguration.resolve(settings: AppSettings(), candidates: [], models: models))
  }

  func testOnlyAnAgentThatTakesAPictureCanAskBoltty() {
    XCTAssertTrue(AskBolttyConfiguration.canAnswer([.images]))
    XCTAssertTrue(AskBolttyConfiguration.canAnswer([.attachments]))
    XCTAssertFalse(AskBolttyConfiguration.canAnswer([.modelSelection]))
  }

  func testThePromptSaysWhatIsOnScreenAndHowToAnswer() {
    let region = AskBolttyRegion(
      screenPath: "/tmp/s.png", areaPath: "/tmp/a.png", context: "Preview — “Anatomy.png”",
      recognizedText: "Deltoid", isWholeScreen: false)
    let text = AskBolttyPrompt.text(question: "що це?", region: region, readOnly: true)
    XCTAssertTrue(text.hasSuffix("що це?"))
    XCTAssertTrue(text.contains("in Preview — “Anatomy.png”"))
    XCTAssertTrue(text.contains("red outline"))
    XCTAssertTrue(text.contains("/tmp/s.png"))
    XCTAssertTrue(text.contains("/tmp/a.png"))
    XCTAssertTrue(text.contains("<screen-text>\nDeltoid\n</screen-text>"))
    XCTAssertTrue(text.contains("do not run commands"))
    XCTAssertTrue(text.contains("search the web"))
  }

  /// Ask Boltty was once called Talk, and what was stored under that
  /// name is still read: a chat marked before it, and the Settings page.
  func testWhatWasStoredUnderTalksNameIsStillRead() throws {
    var conversation = Conversation(title: "Test", workingDirectory: "/tmp")
    conversation.isAskBoltty = true
    let json = try JSONEncoder().encode(conversation)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    XCTAssertEqual(object["isTalk"] as? Bool, true, "chats on disk carry the old key")
    XCTAssertTrue(try JSONDecoder().decode(Conversation.self, from: json).isAskBoltty)
    XCTAssertEqual(SettingsPage(rawValue: "talk"), .askBoltty)
  }

  func testAnAnswerThinksAtTheModelsFastest() {
    var settings = AppSettings()
    settings.askBolttyProviderID = "codex"
    settings.askBolttyModelID = "gpt-6-luna"
    let target = AskBolttyConfiguration.resolve(settings: settings, candidates: ["codex"], models: models)
    XCTAssertEqual(target?.effort, "low")
  }

  func testTheFastestEffortPrefersLowOverMinimal() {
    let options = ["high", "minimal", "medium", "low"].map { AgentEffortOption(value: $0) }
    XCTAssertEqual(AskBolttyConfiguration.fastestEffort(options), "low")
    XCTAssertEqual(AskBolttyConfiguration.fastestEffort([AgentEffortOption(value: "high")]), "high")
    XCTAssertNil(AskBolttyConfiguration.fastestEffort([]))
  }
}
