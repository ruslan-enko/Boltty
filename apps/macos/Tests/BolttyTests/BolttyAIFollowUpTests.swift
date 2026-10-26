import AppKit
import XCTest
@testable import Boltty

final class BolttyAIFollowUpTests: XCTestCase {
  func testPromptEnterWhileAddressingSendsWhenThereIsText() {
    let conversation = Conversation(title: "ship", workingDirectory: "/tmp")
    XCTAssertEqual(
      BolttyAIFollowUp.confirmPrompt(promptIsEmpty: false, addressedConversation: conversation),
      .send(conversation.id)
    )
  }

  func testPromptEnterWhileAddressingOpensWhenEmpty() {
    let conversation = Conversation(title: "ship", workingDirectory: "/tmp")
    XCTAssertEqual(
      BolttyAIFollowUp.confirmPrompt(promptIsEmpty: true, addressedConversation: conversation),
      .open(conversation.id)
    )
  }

  func testPromptEnterWithNoAddresseeLaunchesANewConversation() {
    XCTAssertEqual(
      BolttyAIFollowUp.confirmPrompt(promptIsEmpty: false, addressedConversation: nil),
      .launchNew
    )
  }

  func testAnEmptyPromptWithNoAddresseeDoesNothing() {
    XCTAssertEqual(
      BolttyAIFollowUp.confirmPrompt(promptIsEmpty: true, addressedConversation: nil),
      .nothing
    )
  }

  func testOnlyARunningAgentIsBusy() {
    XCTAssertTrue(BolttyAIFollowUp.isBusy(reported: .running))
    XCTAssertFalse(BolttyAIFollowUp.isBusy(reported: .blocked))
    XCTAssertFalse(BolttyAIFollowUp.isBusy(reported: .finished))
    XCTAssertFalse(BolttyAIFollowUp.isBusy(reported: .failed))
  }

  func testAnUnreportedAgentIsNotTreatedAsBusy() {
    XCTAssertFalse(BolttyAIFollowUp.isBusy(reported: nil))
  }

  func testPreviewDerivesItsLabelAndGateFromOneState() {
    let working = BolttyAISessionPreview(
      id: UUID(),
      title: "fix login",
      agent: .claude,
      state: .running,
      body: "Editing LoginView.swift"
    )
    XCTAssertEqual(working.statusLabel, "Working")
    XCTAssertTrue(working.isBusy)

    let waiting = BolttyAISessionPreview(
      id: UUID(),
      title: "fix login",
      agent: .claude,
      state: .blocked,
      body: "Found 3 issues"
    )
    XCTAssertEqual(waiting.statusLabel, "Waiting for you")
    XCTAssertFalse(waiting.isBusy)
  }

  func testBusyMessageNamesTheWayThrough() {
    let message = BolttyAIFollowUp.busyMessage(agent: .claude)
    XCTAssertFalse(message.contains(AgentId.claude.shortDisplayName), message)
    XCTAssertTrue(message.contains("above"), message)
    XCTAssertTrue(message.contains("reply to it"), message)
    XCTAssertFalse(message.contains("send anyway"))
  }

  func testStatusLabelUsesTheAgentsOwnReport() {
    XCTAssertEqual(BolttyAIFollowUp.statusLabel(reported: .blocked), "Waiting for you")
    XCTAssertEqual(BolttyAIFollowUp.statusLabel(reported: .running), "Working")
    XCTAssertEqual(BolttyAIFollowUp.statusLabel(reported: .finished), "Finished")
    XCTAssertEqual(BolttyAIFollowUp.statusLabel(reported: .failed), "Failed")
    XCTAssertEqual(BolttyAIFollowUp.statusLabel(reported: nil), "Running")
  }
}

// MARK: - What the permission card says

final class PermissionCardTextTests: XCTestCase {
  private func question(kind: AgentQuestion.Kind, multiple: Bool) -> AgentQuestion {
    AgentQuestion(
      kind: kind,
      requestID: "r1",
      header: "Permission",
      prompt: "Run rm -rf build?",
      options: [AgentQuestion.Option(label: "Allow once", detail: nil, value: "once")],
      allowsMultiple: multiple,
      allowsCustom: false
    )
  }

  func testASingleChoiceFooterNamesConfirmAndNotSpace() {
    let footer = question(kind: .permission, multiple: false).keyboardFooter
    XCTAssertTrue(footer.contains("↵ confirms"), footer)
    XCTAssertTrue(footer.contains("click a row to confirm"), footer)
    XCTAssertFalse(footer.contains("Space"), "Space does nothing here: \(footer)")
  }

  func testAMultipleChoiceFooterNamesSpace() {
    let footer = question(kind: .question, multiple: true).keyboardFooter
    XCTAssertTrue(footer.contains("Space or 1 chooses"), footer)
    XCTAssertTrue(footer.contains("↵ sends"), footer)
    XCTAssertTrue(footer.contains("click a row to choose"), footer)
  }

  func testATypedAnswerTakesNoNumbers() {
    let typed = AgentQuestion(
      kind: .question, requestID: "q", header: nil, prompt: "Which?",
      options: [.init(label: "A", detail: nil), .init(label: "B", detail: nil)],
      allowsMultiple: false, allowsCustom: true)
    XCTAssertFalse(typed.answersByNumber)
    XCTAssertFalse(typed.keyboardFooter.contains("1–"), typed.keyboardFooter)
    XCTAssertTrue(typed.keyboardFooter.contains("type your own answer"), typed.keyboardFooter)
    XCTAssertTrue(typed.takesWordsAsAnswer)
    XCTAssertFalse(question(kind: .permission, multiple: false).takesWordsAsAnswer)
  }

  @MainActor
  func testAQuestionIsHeadedByItsOwnHeader() {
    func titled(_ header: String?) -> String {
      BolttyAIPreviewCard.title(of: AgentQuestion(
        kind: .question, requestID: "q", header: header, prompt: "Which?",
        options: [], allowsMultiple: false, allowsCustom: true))
    }
    XCTAssertEqual(titled("1/2 · Зберігання пароля"), "1/2 · Зберігання пароля")
    XCTAssertEqual(titled("  "), "Question")
    XCTAssertEqual(titled(nil), "Question")
    XCTAssertEqual(BolttyAIPreviewCard.title(of: question(kind: .permission, multiple: false)),
                   "Needs your approval")
  }

  func testOnlyAnAnswerThatTookTheWordsEmptiesTheComposer() {
    XCTAssertTrue(AgentQuestion.answer(["в самому застосунку?"], carries: " в самому застосунку? "))
    XCTAssertTrue(AgentQuestion.answer(AgentQuestion.refusal(saying: "use pnpm"), carries: "use pnpm"))
    XCTAssertFalse(AgentQuestion.answer(["Keychain (macOS)"], carries: "в самому застосунку?"))
    XCTAssertFalse(AgentQuestion.answer(["Keychain (macOS)"], carries: ""))
  }

  @MainActor
  func testCodeInAnOptionsSentenceIsSetInMono() {
    let plain: [NSAttributedString.Key: Any] = [.font: roundedAppFont(size: 13)]
    let drawn = BolttyAIOptionRow.codeSpans("Читає через `security` — і все", attributes: plain)
    XCTAssertEqual(drawn.string, "Читає через security — і все")
    let at = (drawn.string as NSString).range(of: "security").location
    let font = drawn.attribute(.font, at: at, effectiveRange: nil) as? NSFont
    XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true, "\(String(describing: font))")
    XCTAssertEqual(BolttyAIOptionRow.codeSpans("a ` b", attributes: plain).string, "a ` b")
    XCTAssertTrue(question(kind: .question, multiple: false).answersByNumber)
    XCTAssertFalse(question(kind: .permission, multiple: false).answersByNumber)
  }

  func testNoSavePatternsMeansTheAnswerDiesWithTheSession() {
    XCTAssertEqual(AgentQuestion.alwaysAllowScope(savePatterns: []), "this session")
    XCTAssertEqual(
      AgentQuestion.alwaysAllowScope(savePatterns: ["  ", ""]),
      "this session",
      "blank patterns are not patterns"
    )
  }

  func testAReportedPatternIsNamed() {
    XCTAssertEqual(
      AgentQuestion.alwaysAllowScope(savePatterns: ["bash:rm *"]),
      "this chat, for bash:rm *"
    )
  }

  func testSeveralPatternsAreCountedRatherThanListed() {
    XCTAssertEqual(
      AgentQuestion.alwaysAllowScope(savePatterns: ["bash:rm *", "edit:src/**"]),
      "this chat, for 2 rules"
    )
  }
}

// MARK: - Enter during a running turn

final class QueuedFollowUpTests: XCTestCase {
  func testTheFirstOneQueuesAndTheNextReplacesIt() {
    XCTAssertEqual(
      BolttyAIFollowUp.queuedMessage(.queued, agent: .opencode),
      "Waiting for this turn to finish — this sends next."
    )
    XCTAssertTrue(
      BolttyAIFollowUp.queuedMessage(.replaced, agent: .opencode).contains("Replaced")
    )
  }

  func testAQueuedPromptOpensTheCardMidTurn() {
    var preview = BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .running, body: "",
      messages: [ConversationMessage(
        id: "a", role: .agent, createdAt: Date(),
        parts: [.text(TextPart(id: "at", kind: .text, text: "half a th"))]
      )]
    )
    XCTAssertTrue(preview.withholdsAnswer, "precondition: the pill would be up")

    preview.queuedPrompt = "And check the tests"
    XCTAssertFalse(preview.withholdsAnswer)
  }
}

// MARK: - Ending a turn

final class TurnTerminationCapabilityTests: XCTestCase {
  func testAnInterruptIsNotAbrupt() {
    let caps: AgentCapabilities = [.interrupt]
    XCTAssertTrue(caps.canEndTurn)
    XCTAssertFalse(caps.endingTurnIsAbrupt)
  }

  func testKillingTheProcessStillCountsAsAWayOut() {
    let caps: AgentCapabilities = [.terminableTurn]
    XCTAssertTrue(caps.canEndTurn)
    XCTAssertTrue(caps.endingTurnIsAbrupt, "the turn is lost, and the button has to say so")
  }

  func testAnAdapterWithNeitherOffersNothing() {
    XCTAssertFalse(AgentCapabilities([.modelSelection]).canEndTurn)
  }
}

