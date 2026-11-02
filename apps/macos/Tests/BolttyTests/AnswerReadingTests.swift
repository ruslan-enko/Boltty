import XCTest
@testable import Boltty

final class AnswerReadingTests: XCTestCase {
  private func message(_ id: String, _ role: ConversationMessage.Role, _ text: String) -> ConversationMessage {
    ConversationMessage(
      id: id, role: role, createdAt: Date(),
      parts: text.isEmpty ? [] : [.text(TextPart(id: "\(id)-text", kind: .text, text: text))])
  }

  func testEachSettingDecidesForSpokenAndTypedTurns() {
    XCTAssertFalse(AnswerReading.off.reads(askedByVoice: true))
    XCTAssertTrue(AnswerReading.askedByVoice.reads(askedByVoice: true))
    XCTAssertFalse(AnswerReading.askedByVoice.reads(askedByVoice: false))
    XCTAssertTrue(AnswerReading.always.reads(askedByVoice: false))
    XCTAssertEqual(AnswerReading(rawValue: ""), .off, "an empty key is never")
  }

  func testTheReplyIsTheTurnsLastAgentMessageWithWords() {
    let messages = [
      message("u1", .user, "First"),
      message("a1", .agent, "Old answer."),
      message("u2", .user, "Second"),
      message("a2", .agent, "Looking."),
      message("a3", .agent, "Done: the tests pass."),
      message("a4", .agent, ""),
    ]
    XCTAssertEqual(AnswerReading.reply(in: messages)?.id, "a3")
  }

  func testATurnWithNoWordsHasNoReply() {
    let messages = [message("a1", .agent, "Old."), message("u", .user, "Go"), message("a2", .agent, "")]
    XCTAssertNil(AnswerReading.reply(in: messages))
  }

  func testTheExcerptIsTheFirstSentencesWithoutCode() {
    let reply = """
    I fixed the crash. The cause was a nil window.

    ```swift
    window!.close()
    ```

    Tests pass now. Nothing else changed.
    """
    XCTAssertEqual(
      AnswerReading.excerpt(of: reply),
      "I fixed the crash. The cause was a nil window. Tests pass now.")
    XCTAssertNil(AnswerReading.excerpt(of: "```\ncode only\n```"))
  }
}
