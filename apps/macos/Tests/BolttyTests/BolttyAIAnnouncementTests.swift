import XCTest
@testable import Boltty

@MainActor
final class BolttyAIAnnouncementTests: XCTestCase {
  private let id = UUID()

  private func preview(
    _ state: AgentReportedState?,
    body: String = "",
    question: AgentQuestion? = nil
  ) -> BolttyAISessionPreview {
    BolttyAISessionPreview(
      id: id, title: "Chat", agent: .opencode, state: state, body: body, question: question
    )
  }

  private func question(_ prompt: String) -> AgentQuestion {
    AgentQuestion(
      kind: .permission, requestID: "p1",
      header: "Permission", prompt: prompt,
      options: [.init(label: "Allow once", detail: nil, value: "once")],
      allowsMultiple: false, allowsCustom: false
    )
  }

  private func line(
    _ from: BolttyAISessionPreview?,
    _ to: BolttyAISessionPreview
  ) -> String? {
    BolttyAIAnnouncement.forTransition(from: from, to: to)
  }

  func testTheAnswerArrivingIsSaid() throws {
    let said = try XCTUnwrap(
      line(preview(.running), preview(.finished, body: "Готово. Відео стиснуте до 12 МБ."))
    )
    XCTAssertTrue(said.hasPrefix("Answer ready."), said)
    XCTAssertTrue(said.contains("Готово."), said)
  }

  func testAQuestionIsSaidWithWhatItAsks() throws {
    let said = try XCTUnwrap(
      line(preview(.running), preview(.blocked, question: question("Run a command")))
    )
    XCTAssertTrue(said.contains("Waiting for your answer"), said)
    XCTAssertTrue(said.contains("Run a command"), said)
  }

  func testAFailureIsSaidInBolttysOwnWords() {
    XCTAssertEqual(
      line(preview(.running), preview(.failed)),
      AgentFailureReport.universalSentence
    )
  }

  func testNothingIsSaidWhileATurnIsMerelyRunning() {
    XCTAssertNil(line(preview(.running, body: "Пишу"), preview(.running, body: "Пишу дал")))
    XCTAssertNil(line(preview(.finished, body: "Готово."), preview(.finished, body: "Готово.")))
  }

  func testSwitchingChatsSaysNothing() {
    let other = BolttyAISessionPreview(
      id: UUID(), title: "Other", agent: .opencode, state: .finished, body: "Done."
    )
    XCTAssertNil(line(preview(.running), other))
  }

  func testAVersionNumberIsNotASentenceBoundary() {
    XCTAssertEqual(
      BolttyAIAnnouncement.firstSentence(of: "opencode 1.18.31 is ready. Next line."),
      "opencode 1.18.31 is ready."
    )
  }

  func testALongSentenceIsCutRatherThanRead() {
    let long = String(repeating: "дуже довге речення ", count: 40)
    let cut = BolttyAIAnnouncement.firstSentence(of: long, limit: 60)
    XCTAssertEqual(cut.count, 61)
    XCTAssertTrue(cut.hasSuffix("…"))
  }
}
