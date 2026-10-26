import XCTest
@testable import Boltty

/// The rule this pins: nothing a CLI wrote is the first thing a person reads,
/// and nothing a CLI wrote is thrown away either.
final class AgentFailureReportTests: XCTestCase {
  private func preview(
    state: AgentReportedState?,
    notice: String? = nil,
    messages: [ConversationMessage] = [],
    question: AgentQuestion? = nil,
    retryPrompt: String? = nil
  ) -> BolttyAISessionPreview {
    BolttyAISessionPreview(
      id: UUID(),
      title: "A chat",
      agent: .opencode,
      state: state,
      body: "",
      question: question,
      messages: messages,
      notice: notice,
      retryPrompt: retryPrompt
    )
  }

  private func failed(
    name: String,
    message: String,
    id: String = "m1"
  ) -> ConversationMessage {
    ConversationMessage(
      id: id,
      role: .agent,
      createdAt: Date(timeIntervalSince1970: 0),
      parts: [],
      failure: MessageFailure(name: name, message: message)
    )
  }

  private func agent(id: String) -> ConversationMessage {
    ConversationMessage(
      id: id,
      role: .agent,
      createdAt: Date(timeIntervalSince1970: 1),
      parts: []
    )
  }

  private func user(id: String) -> ConversationMessage {
    ConversationMessage(
      id: id,
      role: .user,
      createdAt: Date(timeIntervalSince1970: 1),
      parts: []
    )
  }

  func testAFinishedTurnWithNothingWrongHasNoCard() {
    XCTAssertNil(AgentFailureReport.make(from: preview(state: .finished)))
  }

  func testARunningTurnNeverDrawsTheCard() {
    XCTAssertNil(
      AgentFailureReport.make(
        from: preview(state: .running, notice: "Something did not take.")
      ),
      "a notice mid-turn belongs in the transient error line, not in a card saying the turn is over"
    )
  }

  func testAnOpenQuestionIsNotAFailure() {
    let question = AgentQuestion(
      kind: .question,
      requestID: "q1",
      header: "Pick",
      prompt: "Which?",
      options: [AgentQuestion.Option(label: "A", detail: nil, value: "A")],
      allowsMultiple: false,
      allowsCustom: false
    )
    XCTAssertNil(
      AgentFailureReport.make(from: preview(state: .blocked, question: question))
    )
  }

  func testTheSentenceIsBolttysAndTheCLIsWordsAreInTheDetails() throws {
    let report = try XCTUnwrap(
      AgentFailureReport.make(
        from: preview(
          state: .failed,
          notice: "Grok: unknown flag: --output-format"
        )
      )
    )
    XCTAssertEqual(report.sentence, AgentFailureReport.universalSentence)
    XCTAssertFalse(
      report.sentence.contains("--output-format"),
      "the CLI's own line must never be the sentence"
    )
    XCTAssertEqual(report.details, "Grok: unknown flag: --output-format")
  }

  func testAFailedMessageIsEvidenceEvenWithoutANotice() throws {
    let report = try XCTUnwrap(
      AgentFailureReport.make(
        from: preview(state: .finished, messages: [failed(name: "ProviderError", message: "429")])
      )
    )
    XCTAssertEqual(report.details, "ProviderError: 429")
  }

  /// The user pressed Stop. That is an outcome, not a fault.
  func testAnInterruptIsNotAFailure() {
    XCTAssertNil(
      AgentFailureReport.make(
        from: preview(
          state: .finished,
          messages: [failed(name: "MessageAbortedError", message: "aborted")]
        )
      )
    )
  }

  /// OpenCode 2.0 names an interrupted turn `aborted` — read off its own
  /// database on 2.0.24. Read as a failure, it draws the card with
  /// "aborted: Step interrupted" in Details.
  func testAnInterruptedOpenCode2TurnIsNotAFailure() {
    XCTAssertNil(
      AgentFailureReport.make(
        from: preview(
          state: .finished,
          messages: [failed(name: "aborted", message: "Step interrupted")]
        )
      )
    )
  }

  func testEveryPieceOfEvidenceIsKeptInOrder() throws {
    let report = try XCTUnwrap(
      AgentFailureReport.make(
        from: preview(
          state: .failed,
          notice: "Boltty could not reach OpenCode.",
          messages: [
            failed(name: "First", message: "one", id: "m1"),
            failed(name: "Second", message: "two", id: "m2"),
          ]
        )
      )
    )
    XCTAssertEqual(
      report.details,
      "Boltty could not reach OpenCode.\n\nFirst: one\n\nSecond: two"
    )
  }

  func testARepeatedNameIsNotPrintedTwice() throws {
    let report = try XCTUnwrap(
      AgentFailureReport.make(
        from: preview(state: .failed, messages: [failed(name: "boom", message: "boom")])
      )
    )
    XCTAssertEqual(report.details, "boom")
  }

  func testAFailureWithNothingToShowStillOpensOntoAnExplanation() throws {
    let report = try XCTUnwrap(AgentFailureReport.make(from: preview(state: .failed)))
    XCTAssertFalse(report.details.isEmpty, "a disclosure onto nothing is worse than no disclosure")
  }

  func testRetryIsOfferedOnlyWhenThereIsAPromptToSendAgain() throws {
    let without = try XCTUnwrap(AgentFailureReport.make(from: preview(state: .failed)))
    XCTAssertFalse(without.canRetry)

    let with = try XCTUnwrap(
      AgentFailureReport.make(from: preview(state: .failed, retryPrompt: "Check my SSD"))
    )
    XCTAssertTrue(with.canRetry)
    XCTAssertEqual(with.retryPrompt, "Check my SSD")
  }

  /// A failure belongs to the turn that produced it. Once the agent has
  /// spoken again, the failure is history: drawing it under newer replies
  /// reads as the latest turn failing, while OpenCode's own record shows it
  /// inline, mid-history, with a healthy end.
  func testAFailureFollowedByALaterReplyDrawsNoCard() {
    XCTAssertNil(
      AgentFailureReport.make(
        from: preview(
          state: .finished,
          messages: [
            failed(
              name: "provider.invalid-output",
              message: "The provider response ended unexpectedly.",
              id: "m1"
            ),
            agent(id: "m2"),
          ]
        )
      )
    )
  }

  /// A stop after a failure is moving on too: the old turn's card must not
  /// stand under it either.
  func testAStopAfterAFailureDrawsNoCard() {
    XCTAssertNil(
      AgentFailureReport.make(
        from: preview(
          state: .finished,
          messages: [
            failed(name: "provider.invalid-output", message: "ended", id: "m1"),
            failed(name: "aborted", message: "Step interrupted", id: "m2"),
          ]
        )
      )
    )
  }

  /// A newer user message alone changes nothing: the agent has not spoken
  /// since the failure, so the turn it belongs to is still the latest one
  /// with a reply.
  func testANewerUserMessageAloneKeepsTheCard() throws {
    let report = try XCTUnwrap(
      AgentFailureReport.make(
        from: preview(
          state: .finished,
          messages: [
            failed(name: "provider.invalid-output", message: "ended", id: "m1"),
            user(id: "m2"),
          ]
        )
      )
    )
    XCTAssertEqual(report.details, "provider.invalid-output: ended")
  }

  /// The failure on the latest agent turn still draws, even with older
  /// turns — failed or not — before it.
  func testAFailureOnTheLatestTurnStillDrawsTheCard() throws {
    let report = try XCTUnwrap(
      AgentFailureReport.make(
        from: preview(
          state: .finished,
          messages: [
            agent(id: "m1"),
            failed(name: "boom", message: "bang", id: "m2"),
          ]
        )
      )
    )
    XCTAssertEqual(report.details, "boom: bang")
  }
}
