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

  func testUntilChosenThePreferredAgentAnswersInItsDefaultReadOnly() {
    var settings = AppSettings()
    settings.agentPreset = .codex
    let target = AskBolttyConfiguration.resolve(settings: settings, candidates: ["claude", "codex"], models: models)
    XCTAssertEqual(target?.providerID, "codex")
    XCTAssertNil(target?.model)
    XCTAssertEqual(target?.readOnly, true)
  }

  func testNoModelIsPickedByNameForAnAgentNobodyChose() {
    var settings = AppSettings()
    settings.agentPreset = .claude
    let target = AskBolttyConfiguration.resolve(settings: settings, candidates: ["claude"], models: models)
    XCTAssertEqual(target?.providerID, "claude")
    XCTAssertNil(target?.model, "the list has a Haiku; nobody chose it")
  }

  func testWithThePreferredAgentNotReadyTheFirstThatSeesAnswers() {
    var settings = AppSettings()
    settings.agentPreset = .grok
    let target = AskBolttyConfiguration.resolve(settings: settings, candidates: ["codex", "claude"], models: models)
    XCTAssertEqual(target?.providerID, "codex")
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
    XCTAssertNil(target?.model)
  }

  func testAChosenModelTheAgentNoLongerOffersIsItsDefault() {
    var settings = AppSettings()
    settings.askBolttyProviderID = "claude"
    settings.askBolttyModelID = "retired"
    let target = AskBolttyConfiguration.resolve(settings: settings, candidates: ["claude"], models: models)
    XCTAssertEqual(target?.providerID, "claude")
    XCTAssertNil(target?.model)
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

  private func region(wholeScreen: Bool = false, place: FinderPlace? = nil) -> AskBolttyRegion {
    AskBolttyRegion(
      screenPath: "/s.png", areaPath: "/a.png", context: nil, recognizedText: nil,
      isWholeScreen: wholeScreen, finderPlace: place)
  }

  func testThePromptSaysTheRestOfTheScreenIsHiddenUnlessAllOfItWasAsked() {
    XCTAssertTrue(AskBolttyPrompt.bracket(region: region(), readOnly: true).contains("hidden on purpose"))
    XCTAssertFalse(
      AskBolttyPrompt.bracket(region: region(wholeScreen: true), readOnly: true).contains("hidden on purpose"))
  }

  func testAQuestionOverFinderIsToldWhatHereMeans() {
    let place = FinderPlace(folder: "/Users/me/Downloads/", selected: ["a.pdf", "b.png"])
    let bracket = AskBolttyPrompt.bracket(region: region(place: place), readOnly: false)
    XCTAssertTrue(bracket.contains("/Users/me/Downloads/"))
    XCTAssertTrue(bracket.contains("a.pdf, b.png"))
    XCTAssertFalse(AskBolttyPrompt.bracket(region: region(), readOnly: false).contains("Finder folder"))
  }

  func testOverFinderWithNoFolderItIsToldToAskRatherThanGuess() {
    var unread = region()
    unread.isOverUnreadFinder = true
    XCTAssertTrue(AskBolttyPrompt.bracket(region: unread, readOnly: false).contains("rather than guess"))
    XCTAssertFalse(AskBolttyPrompt.bracket(region: region(), readOnly: false).contains("rather than guess"))
  }

  func testOnlyLookingItSaysWhereTheSwitchIs() {
    XCTAssertTrue(AskBolttyPrompt.bracket(region: region(), readOnly: true).contains("Can make changes"))
    XCTAssertFalse(AskBolttyPrompt.bracket(region: region(), readOnly: false).contains("Can make changes"))
  }

  @MainActor
  func testTheFaceAtRestNamesTheKeyThatGoesOn() {
    XCTAssertEqual(AskBolttyController.restHint(launchKey: "⌥Space"), "⌥Space to ask more · Esc to close")
    XCTAssertEqual(AskBolttyController.restHint(launchKey: nil), "Esc to close")
  }
}
