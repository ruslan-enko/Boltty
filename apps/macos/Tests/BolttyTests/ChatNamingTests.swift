import XCTest
@testable import Boltty

final class ChatNamingTests: XCTestCase {
  func testANameIsOneLineWithoutMarksOrAFullStop() {
    XCTAssertEqual(ChatNaming.name(from: "«Звуки на сайті enko.work».\n"), "Звуки на сайті enko.work")
    XCTAssertEqual(ChatNaming.name(from: "\n**Sharkord on Zima**\nExtra line"), "Sharkord on Zima")
  }

  func testAPlaceholderOrAnAnswerIsNoName() {
    XCTAssertNil(ChatNaming.name(from: "New session - 2026-09-20T11:14:43.031Z"))
    XCTAssertNil(ChatNaming.name(from: "Untitled"))
    XCTAssertNil(ChatNaming.name(from: "  \n "))
    XCTAssertNil(ChatNaming.name(from: nil))
    XCTAssertNil(ChatNaming.name(from: String(repeating: "word ", count: 30)))
  }

  func testTheWordsGoToTheModelAsDataAndCut() {
    let long = String(repeating: "x", count: ChatNaming.materialLimit + 50)
    let text = ChatNaming.conversation(.init(request: long, reply: "done"))
    XCTAssertTrue(text.hasPrefix("<request>"))
    XCTAssertTrue(text.hasSuffix("<reply>done</reply>"))
    XCTAssertFalse(text.contains(long))
  }

  func testAntigravitysNameIsTheResultFrame() {
    let stream = """
      {"event":"init","conversation_id":"a"}
      {"event":"step_update","text_delta":"Запуск"}
      {"event":"result","result":{"status":"SUCCESS","response":"Запуск Sharkord\\n"}}
      """
    XCTAssertEqual(AntigravityClient.response(inStream: stream), "Запуск Sharkord\n")
    XCTAssertNil(AntigravityClient.response(inStream: "not json"))
  }

  func testAGivenNameStandsOnTheRowWhateverItsWords() {
    var chat = Conversation(title: "Fix the", workingDirectory: "/tmp")
    let request = ConversationMessage(
      id: "m", role: .user, createdAt: Date(),
      parts: [.text(TextPart(id: "p", kind: .text, text: "Fix the tray icon"))]
    )
    let transcript = ConversationTranscript(messages: [request], interactions: [])
    XCTAssertEqual(ChatTitle.forRow(chat, transcript: transcript), "Fix the tray icon")
    chat.hasOwnName = true
    XCTAssertEqual(ChatTitle.forRow(chat, transcript: transcript), "Fix the")
  }
}
