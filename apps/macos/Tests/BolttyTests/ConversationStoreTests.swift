import XCTest
import SwiftUI
import AppKit
@testable import Boltty

@MainActor
final class ConversationStoreTests: XCTestCase {
  private var root: URL!
  private var trash: URL!
  private var store: ConversationStore!
  private var eventCounter = 0

  override func setUp() async throws {
    try await super.setUp()
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-conversations-\(UUID().uuidString)")
    trash = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-trash-\(UUID().uuidString)")
    store = ConversationStore(persistence: ConversationPersistence(root: root, trash: Self.trash(into: trash)))
    eventCounter = 0
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: trash)
    try await super.tearDown()
  }

  private static func trash(into folder: URL) -> @Sendable (URL) throws -> Void {
    { item in
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
    }
  }

  func testCreatingAnExistingIDPreservesItsTranscriptAndMetadata() {
    let original = store.createConversation(title: "First", workingDirectory: "/tmp")
    store.appendUserMessage(id: "message", text: "Keep this", attachments: [], to: original.id)
    store.setDraft("Keep draft", for: original.id)
    let repeated = store.createConversation(id: original.id, title: "Second", workingDirectory: "/other")
    XCTAssertEqual(store.conversations.count, 1)
    XCTAssertEqual(repeated.title, "First")
    XCTAssertEqual(store.conversation(id: original.id)?.draft, "Keep draft")
    XCTAssertEqual(store.transcript(id: original.id).messages.map(\.plainText), ["Keep this"])
  }

  private func makeConversation(
    directory: String = "/tmp/work",
    remote: String = "ses_1"
  ) -> Conversation {
    let conversation = store.createConversation(
      title: "Task",
      workingDirectory: directory
    )
    store.attachRemoteSession(remote, to: conversation.id, model: nil)
    return store.conversation(id: conversation.id)!
  }

  func testConversationsAreOrderedByNewestActivity() {
    let older = store.createConversation(title: "old", workingDirectory: "/tmp")
    let newer = store.createConversation(title: "new", workingDirectory: "/tmp")

    XCTAssertEqual(store.orderedConversations.map(\.id), [newer.id, older.id])
    store.appendUserMessage(id: "m1", text: "touch", attachments: [], to: older.id)
    XCTAssertEqual(store.orderedConversations.map(\.id), [older.id, newer.id])
  }

  func testChatTrayUsesConversationsAndDoesNotRequireTerminalSessions() {
    let chat = ChatWorkspaceCoordinator(store: store, engine: ConversationEngine(store: store, client: FakeAgentClient()))
    let first = makeConversation(remote: "ses_tray")
    store.apply(envelope(.executionStateChanged(sessionID: "ses_tray", state: .working)))
    XCTAssertEqual(chat.statusSnapshot.agentRows.map(\.id), [first.id])
  }

  func testChatTrayOmitsIdleUnreadConversations() {
    let chat = ChatWorkspaceCoordinator(store: store, engine: ConversationEngine(store: store, client: FakeAgentClient()))
    let selected = makeConversation(remote: "ses_selected")
    store.select(selected.id)
    let unread = store.createConversation(title: "varenyky", workingDirectory: "/tmp")
    store.attachRemoteSession("ses_unread", to: unread.id, model: nil)
    store.apply(envelope(.executionStateChanged(sessionID: "ses_unread", state: .idle)))

    XCTAssertTrue(store.conversation(id: unread.id)?.hasUnread == true)
    XCTAssertEqual(chat.statusSnapshot.latestUnreadSessionID, unread.id)
    XCTAssertTrue(chat.statusSnapshot.agentRows.isEmpty)
    XCTAssertEqual(chat.statusSnapshot.iconState, .attention)

    store.apply(envelope(.executionStateChanged(sessionID: "ses_selected", state: .working)))
    XCTAssertEqual(chat.statusSnapshot.agentRows.map(\.id), [selected.id])
  }

  func testAFinishedTurnNotifiesWithAShortStatusAndNotTheReply() {
    let chat = ChatWorkspaceCoordinator(store: store, engine: ConversationEngine(store: store, client: FakeAgentClient()))
    var delivered: [SystemAttentionNotification] = []
    chat.notificationDelivery = { delivered.append($0) }
    let conversation = makeConversation()

    store.apply(envelope(.executionStateChanged(sessionID: "ses_1", state: .working)))
    store.apply(envelope(.messageUpdated(
      sessionID: "ses_1",
      message: ConversationMessage(
        id: "m1",
        role: .agent,
        createdAt: Date(),
        completedAt: Date(),
        parts: [.text(TextPart(
          id: "t1", kind: .text, text: "Готово — відео стиснуте до 12 МБ."
        ))]
      )
    )))
    store.apply(envelope(.executionStateChanged(sessionID: "ses_1", state: .idle)))

    RunLoop.main.run(until: Date().addingTimeInterval(0.2))

    let finished = delivered.last
    XCTAssertEqual(finished?.sessionID, conversation.id)
    XCTAssertEqual(finished?.title, "Task", "the title names the chat")
    XCTAssertEqual(finished?.body, "Done · OpenCode", "the body is the status and whose it is, not the reply")
    XCTAssertEqual(finished?.kind, .finished, "an answer rings as done, not as a call")
  }

  func testATurnWaitingOnAQuestionNotifiesAsNeedingThePerson() {
    let chat = ChatWorkspaceCoordinator(store: store, engine: ConversationEngine(store: store, client: FakeAgentClient()))
    var delivered: [SystemAttentionNotification] = []
    chat.notificationDelivery = { delivered.append($0) }
    _ = makeConversation()

    store.apply(envelope(.executionStateChanged(sessionID: "ses_1", state: .working)))
    store.apply(envelope(.executionStateChanged(sessionID: "ses_1", state: .waiting)))
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))

    XCTAssertEqual(delivered.last?.body, "Needs your answer · OpenCode")
    XCTAssertEqual(delivered.last?.kind, .needsYou)
  }

  func testABannerIsOneShortLineWhateverTheChatIsCalled() {
    let long = String(repeating: "дуже довга назва розмови ", count: 12)
    let service = SystemAttentionNotificationService.self
    XCTAssertLessThanOrEqual(
      DisplayTextSanitizer.truncate(long, limit: service.titleLimit).count, service.titleLimit + 1)
    XCTAssertLessThanOrEqual(service.bodyLimit, 100, "Claude's own cap, and a status is far under it")
    XCTAssertEqual(SystemAttentionNotification.statusLine("Done", agent: "Claude"), "Done · Claude")
    XCTAssertEqual(SystemAttentionNotification.statusLine("Done", agent: nil), "Done")
    XCTAssertEqual(SystemAttentionNotification.needsWords(for: nil), "Needs your answer")
  }

  func testAReplyTypedIntoTheBannerReachesTheConversation() {
    let chat = ChatWorkspaceCoordinator(store: store, engine: ConversationEngine(store: store, client: FakeAgentClient()))
    let conversation = makeConversation()

    XCTAssertTrue(chat.replyFromNotification("а тепер у 720p", to: conversation.id))
    XCTAssertEqual(
      chat.preview(for: conversation.id)?.messages.last?.plainText,
      "а тепер у 720p"
    )
  }

  func testAReplyIsRefusedWhileAQuestionIsOpen() {
    let chat = ChatWorkspaceCoordinator(store: store, engine: ConversationEngine(store: store, client: FakeAgentClient()))
    let conversation = makeConversation()
    store.apply(envelope(.interactionAsked(question())))
    XCTAssertNotNil(store.transcript(id: conversation.id).openInteraction)

    XCTAssertFalse(chat.replyFromNotification("так", to: conversation.id))
    XCTAssertFalse(
      store.transcript(id: conversation.id).messages.contains { $0.plainText.contains("так") },
      "the words must not be queued behind a turn that cannot end on its own"
    )
  }

  func testClearingHistoryMovesEverythingToTheTrash() throws {
    let kept = makeConversation(remote: "ses_keep")
    let other = makeConversation(remote: "ses_other")
    store.appendUserMessage(id: "m1", text: "щось", attachments: [], to: other.id)
    store.apply(envelope(.partDelta(
      sessionID: "ses_other", messageID: "a1", partID: "a1-text", kind: .text, delta: "так"
    )))

    XCTAssertEqual(store.deleteAllConversations(), 2)
    store.flush()

    XCTAssertTrue(store.conversations.isEmpty)
    XCTAssertTrue(store.transcript(id: other.id).messages.isEmpty)
    XCTAssertNil(store.selectedConversationID)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent(other.id.uuidString).path),
      "the pending save did not put the folder back"
    )

    let items = try FileManager.default.contentsOfDirectory(atPath: trash.path)
    XCTAssertEqual(items.count, 1, "one folder in the Trash, not a column of ids")
    let folder = trash.appendingPathComponent(try XCTUnwrap(items.first))
    XCTAssertTrue(folder.lastPathComponent.hasPrefix("Boltty History "), folder.lastPathComponent)
    let index = try String(contentsOf: folder.appendingPathComponent("index.json"), encoding: .utf8)
    XCTAssertTrue(index.contains(kept.id.uuidString))
    XCTAssertTrue(index.contains(other.id.uuidString))
    let transcript = try String(
      contentsOf: folder.appendingPathComponent(other.id.uuidString)
        .appendingPathComponent("transcript.json"),
      encoding: .utf8
    )
    XCTAssertTrue(transcript.contains("щось"), "the save that was still pending reached the Trash")
  }

  func testDeletingOneChatMovesOnlyItToTheTrash() throws {
    let kept = makeConversation(remote: "ses_keep")
    let gone = makeConversation(remote: "ses_gone")
    store.rename(id: gone.id, to: "Пошта: нові листи")
    store.appendUserMessage(id: "m1", text: "що в пошті", attachments: [], to: gone.id)

    store.trashConversation(id: gone.id)
    store.flush()

    XCTAssertEqual(store.conversations.map(\.id), [kept.id])
    XCTAssertTrue(store.transcript(id: gone.id).messages.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: root.appendingPathComponent(gone.id.uuidString).path))
    let items = try FileManager.default.contentsOfDirectory(atPath: trash.path)
    XCTAssertEqual(items.count, 1)
    let folder = trash.appendingPathComponent(try XCTUnwrap(items.first))
    XCTAssertTrue(
      folder.lastPathComponent.hasPrefix("Boltty Chat – Пошта- нові листи "),
      "named for the chat, with no colon for Finder: \(folder.lastPathComponent)")
    let transcript = try String(
      contentsOf: folder.appendingPathComponent(gone.id.uuidString)
        .appendingPathComponent("transcript.json"),
      encoding: .utf8)
    XCTAssertTrue(transcript.contains("що в пошті"))
  }

  func testAHistoryTheTrashRefusesStaysOnDisk() throws {
    let refusingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-conversations-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: refusingRoot) }
    let refusing = ConversationStore(persistence: ConversationPersistence(
      root: refusingRoot,
      trash: { _ in throw CocoaError(.fileWriteVolumeReadOnly) }
    ))
    let chat = refusing.createConversation(title: "Task", workingDirectory: "/tmp")
    refusing.appendUserMessage(id: "m1", text: "не губи", attachments: [], to: chat.id)

    XCTAssertEqual(refusing.deleteAllConversations(), 1)
    refusing.flush()

    XCTAssertTrue(refusing.conversations.isEmpty)
    let kept = try FileManager.default.contentsOfDirectory(atPath: refusingRoot.path)
      .filter { $0.hasPrefix("Boltty History ") }
    XCTAssertEqual(kept.count, 1)
    let transcript = refusingRoot.appendingPathComponent(try XCTUnwrap(kept.first))
      .appendingPathComponent(chat.id.uuidString)
      .appendingPathComponent("transcript.json")
    XCTAssertTrue(try String(contentsOf: transcript, encoding: .utf8).contains("не губи"))
  }

  func testAnUnknownConversationIsNotAddressed() {
    let chat = ChatWorkspaceCoordinator(store: store, engine: ConversationEngine(store: store, client: FakeAgentClient()))
    let first = makeConversation()
    store.select(first.id)
    XCTAssertFalse(chat.replyFromNotification("привіт", to: UUID()))
    XCTAssertEqual(store.selectedConversationID, first.id)
  }

  func testChatShortcutCatalogDoesNotAdvertiseTerminalCommands() {
    let ids = Set(KeyboardShortcutCatalog.customizableIDs)
    XCTAssertFalse(ids.contains("askBoltty"), "the launch hotkey is the key that opens it")
    XCTAssertTrue(ids.contains("settings"))
    for retired in [
      "splitRight", "splitDown", "clearScreen", "saveScrollback", "previousPrompt",
      "newWindow", "selectTab6", "toggleSidebar"
    ] {
      XCTAssertFalse(ids.contains(retired))
    }
  }

  // MARK: - Messages

  func testOneSendProducesOneMessage() {
    let conversation = makeConversation()
    store.appendUserMessage(id: "msg_1", text: "hello", attachments: [], to: conversation.id)
    store.apply(
      envelope(
        .messageUpdated(
          sessionID: "ses_1",
          message: ConversationMessage(id: "msg_1", role: .user, createdAt: Date())
        )
      )
    )
    let messages = store.transcript(id: conversation.id).messages
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.plainText, "hello")
  }

  func testStreamingDeltasGrowOnePartRatherThanAppendingBubbles() {
    let conversation = makeConversation()
    for chunk in ["Hel", "lo ", "world"] {
      store.apply(
        envelope(
          .partDelta(
            sessionID: "ses_1",
            messageID: "msg_a",
            partID: "prt_1",
            kind: .text,
            delta: chunk
          )
        )
      )
    }
    let messages = store.transcript(id: conversation.id).messages
    XCTAssertEqual(messages.count, 1, "a delta must never create a second message")
    XCTAssertEqual(messages[0].parts.count, 1, "a delta must never create a second part")
    XCTAssertEqual(messages[0].plainText, "Hello world")
  }

  func testRepeatedEventIsIgnored() {
    let conversation = makeConversation()
    let repeated = AgentEventEnvelope(
      id: "evt_same",
      sequence: 1,
      event: .partDelta(
        sessionID: "ses_1",
        messageID: "msg_a",
        partID: "prt_1",
        kind: .text,
        delta: "twice?"
      )
    )
    XCTAssertTrue(store.apply(repeated))
    XCTAssertFalse(store.apply(repeated), "the same event id must not be applied again")
    XCTAssertEqual(store.transcript(id: conversation.id).messages[0].plainText, "twice?")
  }

  func testReplayBelowTheWatermarkIsIgnored() {
    let conversation = makeConversation()
    store.apply(
      AgentEventEnvelope(
        id: "evt_5",
        sequence: 5,
        event: .partDelta(
          sessionID: "ses_1", messageID: "msg_a", partID: "prt_1", kind: .text, delta: "five"
        )
      )
    )
    store.apply(
      AgentEventEnvelope(
        id: "evt_3-again",
        sequence: 3,
        event: .partDelta(
          sessionID: "ses_1", messageID: "msg_a", partID: "prt_1", kind: .text, delta: "three"
        )
      )
    )
    XCTAssertEqual(store.transcript(id: conversation.id).messages[0].plainText, "five")
  }

  func testPartUpdateRewritesInPlace() {
    let conversation = makeConversation()
    store.apply(
      envelope(
        .partUpdated(
          sessionID: "ses_1",
          messageID: "msg_a",
          part: .text(TextPart(id: "prt_1", kind: .text, text: "draft"))
        )
      )
    )
    store.apply(
      envelope(
        .partUpdated(
          sessionID: "ses_1",
          messageID: "msg_a",
          part: .text(TextPart(id: "prt_1", kind: .text, text: "final"))
        )
      )
    )
    let message = store.transcript(id: conversation.id).messages[0]
    XCTAssertEqual(message.parts.count, 1)
    XCTAssertEqual(message.plainText, "final")
  }

  func testEventForAnotherSessionIsIgnored() {
    let conversation = makeConversation()
    XCTAssertFalse(
      store.apply(
        envelope(
          .partDelta(
            sessionID: "ses_somebody_else",
            messageID: "msg_x",
            partID: "prt_1",
            kind: .text,
            delta: "not ours"
          )
        )
      )
    )
    XCTAssertTrue(store.transcript(id: conversation.id).messages.isEmpty)
  }

  func testParallelConversationsInDifferentFoldersStayApart() {
    let first = makeConversation(directory: "/tmp/one", remote: "ses_1")
    let second = store.createConversation(title: "Other", workingDirectory: "/tmp/two")
    store.attachRemoteSession("ses_2", to: second.id, model: nil)

    store.apply(
      envelope(
        .partDelta(
          sessionID: "ses_1", messageID: "m1", partID: "p1", kind: .text, delta: "first"
        )
      )
    )
    store.apply(
      envelope(
        .partDelta(
          sessionID: "ses_2", messageID: "m2", partID: "p2", kind: .text, delta: "second"
        )
      )
    )
    XCTAssertEqual(store.transcript(id: first.id).messages.map(\.plainText), ["first"])
    XCTAssertEqual(store.transcript(id: second.id).messages.map(\.plainText), ["second"])
    XCTAssertEqual(store.conversation(id: first.id)?.workingDirectory, "/tmp/one")
    XCTAssertEqual(store.conversation(id: second.id)?.workingDirectory, "/tmp/two")
  }

  // MARK: - Reconnect

  func testReconnectSnapshotDoesNotDuplicateOrLoseMessages() {
    let conversation = makeConversation()
    store.appendUserMessage(id: "msg_1", text: "do it", attachments: [], to: conversation.id)
    store.apply(
      envelope(
        .partDelta(
          sessionID: "ses_1", messageID: "msg_2", partID: "prt_1", kind: .text, delta: "partial"
        )
      )
    )

    let snapshot = [
      ConversationMessage(
        id: "msg_1",
        role: .user,
        createdAt: Date(timeIntervalSince1970: 1),
        completedAt: Date(timeIntervalSince1970: 1),
        parts: [.text(TextPart(id: "t1", kind: .text, text: "do it"))]
      ),
      ConversationMessage(
        id: "msg_2",
        role: .agent,
        createdAt: Date(timeIntervalSince1970: 2),
        completedAt: Date(timeIntervalSince1970: 3),
        parts: [.text(TextPart(id: "prt_1", kind: .text, text: "partial and then the rest"))]
      )
    ]
    store.replaceMessages(snapshot, in: conversation.id, openInteractions: [])

    let messages = store.transcript(id: conversation.id).messages
    XCTAssertEqual(messages.count, 2, "reconciliation is by id, so nothing is duplicated")
    XCTAssertEqual(messages[1].plainText, "partial and then the rest")
  }

  func testSnapshotKeepsAMessageStillStreamingLocally() {
    let conversation = makeConversation()
    store.apply(
      envelope(
        .partDelta(
          sessionID: "ses_1", messageID: "msg_new", partID: "p", kind: .text, delta: "just started"
        )
      )
    )
    store.replaceMessages([], in: conversation.id, openInteractions: [])
    XCTAssertEqual(
      store.transcript(id: conversation.id).messages.map(\.id),
      ["msg_new"],
      "an in-flight message must survive a snapshot that predates it"
    )
  }

  func testDroppedConnectionDoesNotEndTheTask() {
    let conversation = makeConversation()
    store.apply(envelope(.executionStateChanged(sessionID: "ses_1", state: .working)))
    store.apply(envelope(.connection(.reconnecting)))
    XCTAssertEqual(
      store.conversation(id: conversation.id)?.lastKnownState,
      .working,
      "losing the stream is a connection fact, not an execution fact"
    )
    XCTAssertEqual(store.connectionState(forProviderID: ""), .reconnecting)
  }

  func testOneAgentsConnectionDoesNotSpeakForAnother() {
    store.apply(
      envelope(.connection(.connected)).stamped(with: AgentId.claude.rawValue)
    )
    store.apply(
      envelope(.connection(.reconnecting)).stamped(with: AgentId.opencode.rawValue)
    )

    XCTAssertEqual(
      store.connectionState(forProviderID: AgentId.claude.rawValue),
      .connected,
      "an agent that is not installed must not report on the one being used"
    )
    XCTAssertEqual(
      store.connectionState(forProviderID: AgentId.opencode.rawValue),
      .reconnecting
    )
    XCTAssertEqual(
      store.connectionState(forProviderID: AgentId.codex.rawValue),
      .offline,
      "an agent nobody has spoken to is offline, not whatever another reported"
    )
  }

  // MARK: - Stop

  func testStopThenLateEventsSettleOnIdle() {
    let conversation = makeConversation()
    store.apply(envelope(.executionStateChanged(sessionID: "ses_1", state: .working)))
    store.apply(
      envelope(
        .sessionFailed(
          sessionID: "ses_1",
          failure: MessageFailure(name: "MessageAbortedError", message: "aborted")
        )
      )
    )
    XCTAssertEqual(store.conversation(id: conversation.id)?.lastKnownState, .idle)
    store.apply(
      envelope(
        .partDelta(
          sessionID: "ses_1", messageID: "msg_a", partID: "p", kind: .text, delta: "tail"
        )
      )
    )
    XCTAssertEqual(
      store.conversation(id: conversation.id)?.lastKnownState,
      .idle,
      "a late delta must not put the conversation back to working"
    )
  }

  func testProviderErrorIsShownAsFailedNotIdle() {
    let conversation = makeConversation()
    store.apply(
      envelope(
        .sessionFailed(
          sessionID: "ses_1",
          failure: MessageFailure(name: "ProviderAuthError", message: "no credentials")
        )
      )
    )
    XCTAssertEqual(store.conversation(id: conversation.id)?.lastKnownState, .failed)
  }

  // MARK: - Questions and permissions

  private func question(id: String = "que_1") -> PendingInteraction {
    PendingInteraction(
      id: id,
      conversationID: store.conversations[0].id,
      remoteSessionID: "ses_1",
      kind: .question(
        QuestionPrompt(
          items: [
            QuestionItem(
              header: "Framework",
              question: "Which one?",
              choices: [
                AgentChoice(value: "SwiftUI", label: "SwiftUI"),
                AgentChoice(value: "AppKit", label: "AppKit")
              ],
              allowsMultiple: false,
              allowsCustom: false
            )
          ],
          toolCallID: "call_1"
        )
      )
    )
  }

  func testQuestionMakesTheConversationWaitAndKeepsProviderOptionValues() {
    let conversation = makeConversation()
    store.apply(envelope(.interactionAsked(question())))
    XCTAssertEqual(store.conversation(id: conversation.id)?.lastKnownState, .waiting)
    guard case let .question(prompt)? = store.transcript(id: conversation.id)
      .openInteraction?.kind
    else { return XCTFail("expected an open question") }
    XCTAssertEqual(
      prompt.items[0].choices.map(\.value),
      ["SwiftUI", "AppKit"],
      "option values come from the payload, never from what a button draws"
    )
  }

  func testAnsweringTwiceSendsOneReply() {
    let conversation = makeConversation()
    store.apply(envelope(.interactionAsked(question())))
    XCTAssertTrue(store.beginSubmitting(interactionID: "que_1", in: conversation.id))
    XCTAssertFalse(
      store.beginSubmitting(interactionID: "que_1", in: conversation.id),
      "a card already sending must refuse a second press"
    )
    store.resolveInteraction(
      id: "que_1",
      in: conversation.id,
      with: .answered([["SwiftUI"]])
    )
    XCTAssertFalse(
      store.beginSubmitting(interactionID: "que_1", in: conversation.id),
      "an answered card must refuse a second press"
    )
  }

  func testAnswerFromAnotherClientClosesTheCard() {
    let conversation = makeConversation()
    store.apply(envelope(.interactionAsked(question())))
    store.apply(
      envelope(
        .interactionResolved(
          sessionID: "ses_1",
          requestID: "que_1",
          resolution: .resolvedElsewhere
        )
      )
    )
    XCTAssertNil(store.transcript(id: conversation.id).openInteraction)
    XCTAssertEqual(
      store.transcript(id: conversation.id).interactions[0].resolution,
      .resolvedElsewhere
    )
  }

  func testLocalAnswerIsNotOverwrittenByTheProviderEcho() {
    let conversation = makeConversation()
    store.apply(envelope(.interactionAsked(question())))
    store.resolveInteraction(id: "que_1", in: conversation.id, with: .answered([["AppKit"]]))
    store.apply(
      envelope(
        .interactionResolved(
          sessionID: "ses_1", requestID: "que_1", resolution: .resolvedElsewhere
        )
      )
    )
    XCTAssertEqual(
      store.transcript(id: conversation.id).interactions[0].resolution,
      .answered([["AppKit"]]),
      "the first resolution wins, so our own reply is not relabelled"
    )
  }

  func testRepeatedAskDoesNotReopenAnAnsweredCard() {
    let conversation = makeConversation()
    store.apply(envelope(.interactionAsked(question())))
    store.resolveInteraction(id: "que_1", in: conversation.id, with: .answered([["SwiftUI"]]))
    store.apply(envelope(.interactionAsked(question()), id: "evt_repeat_ask"))
    XCTAssertNil(store.transcript(id: conversation.id).openInteraction)
  }

  func testRejectionIsRecordedAsRejectionNotConsent() {
    let conversation = makeConversation()
    store.apply(envelope(.interactionAsked(question())))
    store.resolveInteraction(id: "que_1", in: conversation.id, with: .rejected)
    XCTAssertEqual(store.transcript(id: conversation.id).interactions[0].resolution, .rejected)
  }

  func testDeletedProviderSessionExpiresOpenPermissionsWithoutGrantingThem() {
    let conversation = makeConversation()
    let permission = PendingInteraction(
      id: "per_1",
      conversationID: conversation.id,
      remoteSessionID: "ses_1",
      kind: .permission(
        PermissionPrompt(
          action: "bash",
          resources: ["rm -rf /tmp/x"],
          savePatterns: [],
          toolCallID: nil
        )
      )
    )
    store.apply(envelope(.interactionAsked(permission)))
    store.apply(envelope(.sessionDeleted(sessionID: "ses_1")))

    let resolved = store.transcript(id: conversation.id).interactions[0]
    XCTAssertEqual(resolved.resolution, .expired)
    XCTAssertNotEqual(resolved.resolution, .permission(.once))
    XCTAssertNotEqual(resolved.resolution, .permission(.always))
    XCTAssertNil(
      store.conversation(id: conversation.id)?.remoteSessionID,
      "a session the provider forgot must not still be addressed"
    )
  }

  // MARK: - Working directory

  func testWorkingDirectoryFreezesOnceTheProviderHasASession() {
    let conversation = store.createConversation(title: "T", workingDirectory: "/tmp/a")
    store.setWorkingDirectory("/tmp/b", for: conversation.id)
    XCTAssertEqual(store.conversation(id: conversation.id)?.workingDirectory, "/tmp/b")

    store.attachRemoteSession("ses_9", to: conversation.id, model: nil)
    store.setWorkingDirectory("/tmp/c", for: conversation.id)
    XCTAssertEqual(
      store.conversation(id: conversation.id)?.workingDirectory,
      "/tmp/b",
      "the folder is fixed once work has started"
    )
  }

  func testANewConversationStartsInHomeWhateverChatWasOpened() {
    let first = store.createConversation(title: "First", workingDirectory: "/tmp/repo")
    store.select(first.id)
    XCTAssertEqual(store.defaultWorkingDirectory(), WorkingDirectoryResolver.homeDirectoryPath)
  }

  // MARK: - Unread and selection

  func testACompletedReplyElsewhereMarksUnreadWithoutChangingSelection() {
    let first = makeConversation(remote: "ses_1")
    let second = store.createConversation(title: "Other", workingDirectory: "/tmp")
    store.attachRemoteSession("ses_2", to: second.id, model: nil)
    store.select(first.id)

    store.apply(envelope(.executionStateChanged(sessionID: "ses_2", state: .idle)))
    XCTAssertEqual(store.selectedConversationID, first.id)
    XCTAssertTrue(store.conversation(id: second.id)?.hasUnread == true)
    XCTAssertFalse(store.conversation(id: first.id)?.hasUnread == true)
  }

  // MARK: - Drafts and staged files

  func testStagedFilesFollowTheirConversation() {
    let first = makeConversation(remote: "ses_1")
    let second = store.createConversation(title: "Other", workingDirectory: "/tmp")
    store.addDraftAttachment(attachment("notes.txt"), to: first.id)

    XCTAssertEqual(store.conversation(id: first.id)?.draftAttachments.map(\.displayName), ["notes.txt"])
    XCTAssertEqual(store.conversation(id: second.id)?.draftAttachments, [])
  }

  func testSendingClearsOnlyTheFilesThatWentWithIt() {
    let conversation = makeConversation()
    let sent = attachment("sent.txt")
    store.addDraftAttachment(sent, to: conversation.id)
    store.setDraft("look at this", for: conversation.id)
    let staged = attachment("later.txt")
    store.addDraftAttachment(staged, to: conversation.id)

    store.appendUserMessage(id: "m1", text: "look at this", attachments: [sent], to: conversation.id)

    XCTAssertEqual(store.conversation(id: conversation.id)?.draft, "")
    XCTAssertEqual(
      store.conversation(id: conversation.id)?.draftAttachments.map(\.id),
      [staged.id],
      "a file attached mid-send is still waiting to be sent"
    )
  }

  func testAMessageThatNeverLandedComesBackAsADraft() {
    let conversation = makeConversation()
    let file = attachment("plan.md")
    store.appendUserMessage(id: "m1", text: "do the thing", attachments: [file], to: conversation.id)

    store.revertUserMessage(
      id: "m1",
      restoringDraft: "do the thing",
      attachments: [file],
      in: conversation.id
    )

    XCTAssertTrue(store.transcript(id: conversation.id).messages.isEmpty)
    XCTAssertEqual(store.conversation(id: conversation.id)?.draft, "do the thing")
    XCTAssertEqual(store.conversation(id: conversation.id)?.draftAttachments.map(\.id), [file.id])
  }

  func testTextTypedWhileASendWasInFlightIsNotOverwrittenByTheOneComingBack() {
    let conversation = makeConversation()
    store.appendUserMessage(id: "m1", text: "first", attachments: [], to: conversation.id)
    store.setDraft("second", for: conversation.id)

    store.revertUserMessage(id: "m1", restoringDraft: "first", attachments: [], in: conversation.id)

    XCTAssertEqual(
      store.conversation(id: conversation.id)?.draft,
      "first\nsecond",
      "neither of the two things typed is dropped to keep the field tidy"
    )
  }

  func testTheNameAFileWasAttachedUnderIsReadBackOffBolttysCopy() throws {
    let conversation = store.createConversation(title: "Files", workingDirectory: "/tmp")
    let source = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: source) }
    let original = source.appendingPathComponent("report.pdf")
    try Data("pdf".utf8).write(to: original)
    var draft = PromptDraft("see ")
    draft.append(PromptAttachment.file(original, label: "file 1"))

    store.setPanelDraft(draft, for: conversation.id)

    let saved = try XCTUnwrap(store.conversation(id: conversation.id)?.panelDraft?.attachments.first)
    guard case let .file(copy) = saved.payload else { return XCTFail("not a file chip") }
    XCTAssertNotEqual(copy.lastPathComponent, "report.pdf", "precondition: the draft holds a copy")
    XCTAssertEqual(ConversationStore.attachedName(of: copy, in: conversation.id), "report.pdf")
    XCTAssertEqual(ConversationStore.attachedName(of: original, in: conversation.id), "report.pdf")
    XCTAssertEqual(
      ConversationStore.attachedName(of: copy, in: UUID()), copy.lastPathComponent,
      "another chat's copy is not this one's")
    let lookalike = source.appendingPathComponent("3F2A1B2C-notes.txt")
    XCTAssertEqual(
      ConversationStore.attachedName(of: lookalike, in: conversation.id), "3F2A1B2C-notes.txt",
      "a name that only looks like a copy's is the person's own")
  }

  func testAnIndexWithoutStagedFilesStillLoads() throws {
    let older = """
    {"version":1,"conversations":[{"id":"\(UUID().uuidString)","providerID":"opencode",\
    "title":"Old","workingDirectory":"/tmp","createdAt":"2026-01-01T00:00:00Z",\
    "updatedAt":"2026-01-01T00:00:00Z","draft":"kept","hasUnread":false,\
    "lastKnownState":"idle"}]}
    """
    store.close()
    try Data(older.utf8).write(to: root.appendingPathComponent("index.json"))

    let reopened = ConversationStore(persistence: ConversationPersistence(root: root))
    XCTAssertEqual(reopened.conversations.map(\.title), ["Old"])
    XCTAssertEqual(reopened.conversations.first?.draft, "kept")
    XCTAssertEqual(reopened.conversations.first?.draftAttachments, [])
  }

  private func attachment(_ name: String) -> ConversationAttachment {
    ConversationAttachment(id: UUID().uuidString, displayName: name)
  }

  // MARK: - Search

  func testSearchMatchesTitleAndLastMessage() {
    let a = store.createConversation(title: "Rename the files", workingDirectory: "/tmp")
    let b = store.createConversation(title: "Something else", workingDirectory: "/tmp")
    store.appendUserMessage(id: "m", text: "about invoices", attachments: [], to: b.id)

    XCTAssertEqual(store.conversations(matching: "rename").map(\.id), [a.id])
    XCTAssertEqual(store.conversations(matching: "invoice").map(\.id), [b.id])
    XCTAssertEqual(store.conversations(matching: "").count, 2)
  }

  func testSearchMatchesAnyMessageInTheTranscript() {
    let conversation = makeConversation()
    store.appendUserMessage(id: "m1", text: "about invoices", attachments: [], to: conversation.id)
    store.appendUserMessage(id: "m2", text: "never mind", attachments: [], to: conversation.id)
    _ = store.createConversation(title: "Unrelated", workingDirectory: "/tmp")

    XCTAssertEqual(store.conversations(matching: "invoices").map(\.id), [conversation.id])
  }

  func testSearchFindsTextTheRowIsShowingWhenTheLastMessageIsToolOnly() {
    let conversation = makeConversation(remote: "ses_tools")
    store.appendUserMessage(id: "m1", text: "about invoices", attachments: [], to: conversation.id)
    store.apply(envelope(.messageUpdated(
      sessionID: "ses_tools",
      message: ConversationMessage(
        id: "m2",
        role: .agent,
        createdAt: Date(),
        parts: [.activity(AgentActivity(id: "act_1", name: "bash", state: .completed))]
      )
    )))

    XCTAssertEqual(store.subtitle(for: conversation.id), "about invoices")
    XCTAssertEqual(store.conversations(matching: "about invoices").map(\.id), [conversation.id])
  }

  func testSearchIgnoresCase() {
    let conversation = makeConversation()
    store.appendUserMessage(id: "m1", text: "Про Рахунки", attachments: [], to: conversation.id)

    XCTAssertEqual(store.conversations(matching: "рахунки").map(\.id), [conversation.id])
    XCTAssertEqual(store.conversations(matching: "  РАХУНКИ  ").map(\.id), [conversation.id])
  }

  private func envelope(_ event: AgentEvent, id: String? = nil) -> AgentEventEnvelope {
    eventCounter += 1
    return AgentEventEnvelope(
      id: id ?? "evt_\(eventCounter)",
      sequence: eventCounter,
      event: event
    )
  }
}
