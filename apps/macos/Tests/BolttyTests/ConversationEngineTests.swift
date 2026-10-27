import XCTest
@testable import Boltty

@MainActor
final class ConversationEngineTests: XCTestCase {
  private var root: URL!
  private var store: ConversationStore!
  private var client: FakeAgentClient!
  private var engine: ConversationEngine!

  override func setUp() async throws {
    try await super.setUp()
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-engine-\(UUID().uuidString)")
    store = ConversationStore(persistence: ConversationPersistence(
      root: root, trash: { try FileManager.default.removeItem(at: $0) }))
    client = FakeAgentClient()
    engine = ConversationEngine(store: store, client: client)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
    try await super.tearDown()
  }

  private func newConversation() -> UUID {
    store.createConversation(title: "New conversation", workingDirectory: "/tmp/work").id
  }

  func testPanelShowsThinkingDuringCreationAndRestoresAnUnsentPromptOnFailure() async throws {
    client.createSessionError = .transport("offline")
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let conversation = coordinator.startConversationInBackground(prompt: "Keep this prompt")
    let panel: any BolttyAIConversations = coordinator
    XCTAssertTrue(try XCTUnwrap(panel.preview(for: conversation.id)).isBusy)
    XCTAssertFalse(coordinator.sendFollowUp("duplicate", to: conversation.id))
    for _ in 0..<100 where coordinator.pendingPanelPrompts[conversation.id] != nil { await Task.yield() }
    let preview = try XCTUnwrap(panel.preview(for: conversation.id))
    XCTAssertFalse(preview.isBusy)
    XCTAssertEqual(preview.retryPrompt, "Keep this prompt")
    XCTAssertEqual(store.conversation(id: conversation.id)?.draft, "Keep this prompt")
    XCTAssertTrue(client.sentMessages.isEmpty)
  }

  func testAStuckSendIsEscapableAndHandsThePromptBack() async throws {
    client.sendHangs = true
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let conversation = coordinator.startConversationInBackground(prompt: "Check my SSD")
    let panel: any BolttyAIConversations = coordinator
    for _ in 0..<200 where store.transcript(id: conversation.id).messages.isEmpty {
      await Task.yield()
    }

    let stuck = try XCTUnwrap(panel.preview(for: conversation.id))
    XCTAssertTrue(stuck.isBusy)
    XCTAssertTrue(stuck.canStop, "a wait of ours is ours to abandon, whatever the provider offers")
    XCTAssertFalse(coordinator.sendFollowUp("anything", to: conversation.id))

    await panel.stopConversation(id: conversation.id)
    for _ in 0..<200 where coordinator.pendingPanelPrompts[conversation.id] != nil {
      await Task.yield()
    }

    let freed = try XCTUnwrap(panel.preview(for: conversation.id))
    XCTAssertFalse(freed.isBusy, "a stopped send must not leave the chat busy forever")
    XCTAssertEqual(freed.retryPrompt, "Check my SSD", "the text is handed back, not lost")
    XCTAssertTrue(
      coordinator.sendFollowUp("now it goes", to: conversation.id),
      "the next prompt has to get through, which is the point of stopping"
    )
  }

  func testPanelWalksEveryQuestionAndSendsOneCompleteAnswer() async throws {
    let id = newConversation()
    await engine.send(text: "Plan it", in: id)
    let remote = try XCTUnwrap(store.conversation(id: id)?.remoteSessionID)
    let questions = ["Language?", "Framework?"].map {
      QuestionItem(header: "Choice", question: $0, choices: [AgentChoice(value: "one"), AgentChoice(value: "two")], allowsMultiple: false, allowsCustom: true)
    }
    store.apply(AgentEventEnvelope(id: "ask", sequence: 1, event: .interactionAsked(PendingInteraction(id: "multi", conversationID: id, remoteSessionID: remote, kind: .question(QuestionPrompt(items: questions, toolCallID: nil))))))
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let panel: any BolttyAIConversations = coordinator
    let first = try XCTUnwrap(panel.preview(for: id)?.question)
    XCTAssertEqual(first.prompt, "Language?")
    try await panel.answer(first, with: ["one"])
    XCTAssertTrue(client.questionReplies.isEmpty)
    let second = try XCTUnwrap(panel.preview(for: id)?.question)
    XCTAssertEqual(second.prompt, "Framework?")
    try await panel.answer(second, with: ["two"])
    XCTAssertEqual(client.questionReplies.count, 1)
    XCTAssertEqual(client.questionReplies.first?.answers, [["one"], ["two"]])
    XCTAssertNil(panel.preview(for: id)?.question)
  }

  func testOpenCodeQuestionsResolveTheirConversationOffMainActor() async throws {
    let openCode = OpenCodeClient()
    let routingEngine = ConversationEngine(store: store, client: openCode)
    defer { withExtendedLifetime(routingEngine) {} }
    let conversation = store.createConversation(
      title: "Background question", workingDirectory: "/tmp/work", providerID: "opencode"
    )
    store.attachRemoteSession("ses_background", to: conversation.id, model: nil)
    let events = try await Task.detached {
      let frame = try JSONDecoder().decode(OpenCodeDTO.EventFrame.self, from: Data(
        #"{"type":"question.v2.asked","data":{"id":"que_background","sessionID":"ses_background","questions":[{"question":"Choose","header":"Choice","options":[{"label":"A","description":"First"}]}]}}"#.utf8
      ))
      return OpenCodeClient.domainEvents(from: frame, resolver: openCode.conversationResolver)
    }.value
    guard case let .interactionAsked(interaction) = events.first else {
      return XCTFail("the background question must become an interaction")
    }
    XCTAssertEqual(interaction.conversationID, conversation.id)
    XCTAssertEqual(interaction.remoteSessionID, "ses_background")
  }

  func testBackgroundResolverTracksExistingAttachedAndDeletedSessions() async {
    let other = store.createConversation(
      title: "Other provider", workingDirectory: "/tmp/work", providerID: "claude"
    )
    store.attachRemoteSession("same-id", to: other.id, model: nil)
    let existing = store.createConversation(
      title: "Existing", workingDirectory: "/tmp/work", providerID: "opencode"
    )
    store.attachRemoteSession("same-id", to: existing.id, model: nil)
    let openCode = OpenCodeClient()
    let routingEngine = ConversationEngine(store: store, client: openCode)
    defer { withExtendedLifetime(routingEngine) {} }

    let loaded = await Task.detached { openCode.conversationResolver?("same-id") }.value
    XCTAssertEqual(loaded, existing.id, "remote IDs are scoped to their provider")
    store.deleteConversation(id: existing.id)
    let deleted = await Task.detached { openCode.conversationResolver?("same-id") }.value
    XCTAssertNil(deleted, "deletion must remove the routing entry")

    let later = store.createConversation(
      title: "Later", workingDirectory: "/tmp/work", providerID: "opencode"
    )
    store.attachRemoteSession("new-id", to: later.id, model: nil)
    let attached = await Task.detached { openCode.conversationResolver?("new-id") }.value
    XCTAssertEqual(attached, later.id, "new session attachment must update the snapshot")
  }

  func testSendingCreatesTheProviderSessionOnceAndSendsOnce() async {
    let id = newConversation()
    await engine.send(text: "hello", in: id)
    await engine.send(text: "again", in: id)

    XCTAssertEqual(client.createdSessions.count, 1, "the session is created once")
    XCTAssertEqual(client.createdSessions[0].directory, "/tmp/work")
    XCTAssertEqual(client.sentMessages.map(\.text), ["hello"])
    XCTAssertEqual(store.transcript(id: id).messages.count, 1)
  }

  func testTheMessageIdSentIsTheOneDrawn() async {
    let id = newConversation()
    await engine.send(text: "hello", in: id)
    let drawn = store.transcript(id: id).messages.map(\.id)
    XCTAssertEqual(drawn, client.sentMessages.map(\.id))
    XCTAssertTrue(drawn[0].hasPrefix("msg_"), "the provider requires this prefix")
  }

  func testAnIndeterminateSendThatDidLandIsNotResent() async {
    let id = newConversation()
    client.sendError = .indeterminate("timed out")
    client.existingMessagesAnswer = { _ in true }
    await engine.send(text: "risky", in: id)

    XCTAssertTrue(client.sentMessages.isEmpty, "the send threw")
    XCTAssertEqual(
      store.transcript(id: id).messages.count,
      1,
      "the message stays exactly once — it was accepted"
    )
    XCTAssertNil(engine.notices[id], "nothing to warn about: it landed")
  }

  func testAnIndeterminateSendThatDidNotLandTellsTheUserAndDoesNotRetry() async {
    let id = newConversation()
    client.sendError = .indeterminate("timed out")
    client.existingMessagesAnswer = { _ in false }

    await engine.send(text: "risky", in: id)

    XCTAssertTrue(client.sentMessages.isEmpty, "no automatic retry")
    XCTAssertEqual(store.conversation(id: id)?.lastKnownState, .idle)
    XCTAssertNotNil(engine.notices[id])
    XCTAssertTrue(engine.notices[id]!.text.contains("did not reach"))
    XCTAssertTrue(store.transcript(id: id).messages.isEmpty)
    XCTAssertEqual(store.conversation(id: id)?.draft, "risky")
  }

  func testAProviderThatWillNotStartKeepsWhatWasTyped() async {
    let id = newConversation()
    store.setDraft("half a plan", for: id)
    client.createSessionError = .transport("opencode would not start")

    let accepted = await engine.send(text: "half a plan", in: id)

    XCTAssertFalse(accepted)
    XCTAssertEqual(
      store.conversation(id: id)?.draft,
      "half a plan",
      "a provider that never started must not cost a prompt"
    )
    XCTAssertTrue(store.transcript(id: id).messages.isEmpty)
    XCTAssertEqual(engine.notices[id]?.isBlocking, true)
  }

  func testARefusedSendGoesBackToTheComposerInsteadOfLeavingADeadBubble() async {
    let id = newConversation()
    client.sendError = .transport("refused")

    let accepted = await engine.send(text: "hello", in: id)

    XCTAssertFalse(accepted)
    XCTAssertTrue(store.transcript(id: id).messages.isEmpty, "the provider recorded nothing")
    XCTAssertEqual(store.conversation(id: id)?.draft, "hello")
    XCTAssertEqual(store.conversation(id: id)?.lastKnownState, .idle, "and it can be sent again")
  }

  func testAnUnknowableOutcomeKeepsTheMessageRatherThanInvitingADuplicate() async {
    let id = newConversation()
    client.sendError = .indeterminate("timed out")
    client.existingMessagesError = .transport("still unreachable")

    let accepted = await engine.send(text: "risky", in: id)

    XCTAssertTrue(accepted, "it may have landed, so it is not offered back for re-sending")
    XCTAssertEqual(store.transcript(id: id).messages.count, 1)
    XCTAssertEqual(store.conversation(id: id)?.draft, "")
  }

  func testAnUnknowableSendOutcomeIsSurfacedRatherThanGuessed() async {
    let id = newConversation()
    client.sendError = .indeterminate("timed out")
    client.existingMessagesError = .transport("still unreachable")

    await engine.send(text: "risky", in: id)

    XCTAssertTrue(client.sentMessages.isEmpty)
    XCTAssertNotNil(engine.notices[id])
    XCTAssertTrue(
      engine.notices[id]!.text.contains("could not confirm"),
      "the honest answer is that we do not know"
    )
  }

  func testAConversationThatIsWorkingRefusesANewSend() async {
    let id = newConversation()
    await engine.send(text: "first", in: id)
    XCTAssertEqual(store.conversation(id: id)?.lastKnownState, .working)

    await engine.send(text: "second", in: id)
    XCTAssertEqual(client.sentMessages.count, 1)
  }

  func testAWaitingConversationAlsoRefusesANewSend() async {
    let id = newConversation()
    await engine.send(text: "first", in: id)
    let remote = store.conversation(id: id)!.remoteSessionID!
    store.apply(
      AgentEventEnvelope(
        id: "e1",
        sequence: 1,
        event: .interactionAsked(
          PendingInteraction(
            id: "que_1",
            conversationID: id,
            remoteSessionID: remote,
            kind: .question(
              QuestionPrompt(
                items: [
                  QuestionItem(
                    header: "H",
                    question: "Q",
                    choices: [AgentChoice(value: "a")],
                    allowsMultiple: false,
                    allowsCustom: false
                  )
                ],
                toolCallID: nil
              )
            )
          )
        )
      )
    )
    XCTAssertEqual(store.conversation(id: id)?.lastKnownState, .waiting)
    await engine.send(text: "second", in: id)
    XCTAssertEqual(client.sentMessages.count, 1, "the turn is not over while a card is open")
  }

  func testTheTitleIsTakenFromTheFirstPrompt() async {
    let id = newConversation()
    await engine.send(text: "Rename every invoice in the folder", in: id)
    XCTAssertEqual(store.conversation(id: id)?.title, "Rename every invoice in the folder")
  }

  func testALongPromptIsTruncatedIntoATitle() {
    let title = ConversationEngine.title(
      from: "Please go through the whole archive and produce a summary of everything in it"
    )
    XCTAssertLessThanOrEqual(title.count, 41)
    XCTAssertTrue(title.hasSuffix("…"))
  }

  func testATitleNamesNeitherAScreenRegionNorBolttysCopyOfAPicture() {
    let copy = "/Users/me/Library/Application Support/Boltty/Pasteboard/image1-82226C17.png"
    XCTAssertEqual(
      ConversationEngine.title(from: "what is this [Selected on screen in Figma: \"\(copy)\"]"),
      "what is this")
    XCTAssertEqual(ConversationEngine.title(from: "\"\(copy)\""), ConversationEngine.untitled)
  }

  func testAnsweringAQuestionSendsTheProvidersOwnValues() async {
    let id = newConversation()
    await engine.send(text: "go", in: id)
    let remote = store.conversation(id: id)!.remoteSessionID!
    store.apply(
      AgentEventEnvelope(
        id: "e1",
        sequence: 1,
        event: .interactionAsked(
          PendingInteraction(
            id: "que_1",
            conversationID: id,
            remoteSessionID: remote,
            kind: .question(
              QuestionPrompt(
                items: [
                  QuestionItem(
                    header: "Framework",
                    question: "Which?",
                    choices: [
                      AgentChoice(value: "SwiftUI", label: "SwiftUI"),
                      AgentChoice(value: "AppKit", label: "AppKit")
                    ],
                    allowsMultiple: false,
                    allowsCustom: false
                  )
                ],
                toolCallID: nil
              )
            )
          )
        )
      )
    )

    await engine.answer(interactionID: "que_1", in: id, answers: [["AppKit"]])
    XCTAssertEqual(client.questionReplies.count, 1)
    XCTAssertEqual(client.questionReplies[0].answers, [["AppKit"]])

    await engine.answer(interactionID: "que_1", in: id, answers: [["SwiftUI"]])
    XCTAssertEqual(client.questionReplies.count, 1)
  }

  func testAFailedReplyLeavesTheCardLiveSoItCanBeRetried() async {
    let id = newConversation()
    await engine.send(text: "go", in: id)
    let remote = store.conversation(id: id)!.remoteSessionID!
    store.apply(
      AgentEventEnvelope(
        id: "e1",
        sequence: 1,
        event: .interactionAsked(
          PendingInteraction(
            id: "per_1",
            conversationID: id,
            remoteSessionID: remote,
            kind: .permission(
              PermissionPrompt(
                action: "bash",
                resources: ["ls"],
                savePatterns: [],
                toolCallID: nil
              )
            )
          )
        )
      )
    )
    client.permissionError = .transport("offline")
    let failed = await engine.reply(permissionID: "per_1", in: id, decision: .once)

    XCTAssertFalse(failed, "a reply that did not send says so")
    let interaction = store.transcript(id: id).interactions[0]
    XCTAssertTrue(interaction.isOpen, "a reply that did not send must not close the card")
    XCTAssertTrue(interaction.acceptsInput, "and it has to be pressable again")
    XCTAssertNotNil(engine.notices[id])
    client.permissionError = nil
    let retried = await engine.reply(permissionID: "per_1", in: id, decision: .once)
    XCTAssertTrue(retried)
    XCTAssertNil(engine.notices[id], "a successful retry clears the delivery error")
  }

  // MARK: - An ask that is already gone

  func testAReplyToAnAskThatIsGonePutsTheCardAwayWithoutANotice() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, remote, _) = try await askedPermission(coordinator)
    client.permissionError = .requestGone
    client.snapshots[remote] = snapshot(remote: remote, state: .interrupted)

    await engine.reply(permissionID: "per_1", in: id, decision: .once)

    let interaction = try XCTUnwrap(store.transcript(id: id).interactions.first)
    XCTAssertEqual(interaction.resolution, .expired)
    XCTAssertFalse(interaction.isSubmitting)
    XCTAssertNil(store.transcript(id: id).openInteraction)
    XCTAssertNil(engine.notices[id], "nothing failed that a retry could fix")
    XCTAssertNil(coordinator.preview(for: id)?.question, "the card is not drawn")
    XCTAssertEqual(store.conversation(id: id)?.lastKnownState, .interrupted,
                   "the provider's state, not 'working' as an answered ask would be")
  }

  private func askedQuestion(
    _ coordinator: ChatWorkspaceCoordinator
  ) async throws -> (id: UUID, remote: String, question: AgentQuestion) {
    let id = newConversation()
    await engine.send(text: "go", in: id)
    let remote = try XCTUnwrap(store.conversation(id: id)?.remoteSessionID)
    store.apply(AgentEventEnvelope(id: "e1", sequence: 1, event: .interactionAsked(
      PendingInteraction(
        id: "que_1", conversationID: id, remoteSessionID: remote,
        kind: .question(QuestionPrompt(items: [
          QuestionItem(
            header: "Framework", question: "Which?",
            choices: [AgentChoice(value: "SwiftUI"), AgentChoice(value: "AppKit")],
            allowsMultiple: false, allowsCustom: true)
        ], toolCallID: nil))
      )
    )))
    let question = try XCTUnwrap(coordinator.preview(for: id)?.question)
    return (id, remote, question)
  }

  func testAnAnswerSaysWhetherItWasDelivered() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, _, question) = try await askedQuestion(coordinator)
    client.questionError = .transport("HTTP 400: Expected string for form field: q0")

    let refused = try await coordinator.answer(question, with: ["AppKit"])

    XCTAssertFalse(refused)
    XCTAssertEqual(coordinator.preview(for: id)?.question, question, "still there to answer")
    XCTAssertNotNil(engine.notices[id])
    client.questionError = nil
    let sent = try await coordinator.answer(question, with: ["AppKit"])
    XCTAssertTrue(sent)
    XCTAssertEqual(client.questionReplies.map { $0.answers }, [[["AppKit"]]])
  }

  func testAnAnswerToAnAskThatIsGoneSaysNothingWent() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, remote, question) = try await askedQuestion(coordinator)
    client.questionError = .requestGone
    client.snapshots[remote] = snapshot(remote: remote, state: .idle)

    let sent = try await coordinator.answer(question, with: ["in the app itself?"])

    XCTAssertFalse(sent)
    XCTAssertNil(coordinator.preview(for: id)?.question, "the card is put away")
  }

  func testAGoneAskDoesNotLeaveTheConversationWaiting() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, _, _) = try await askedPermission(coordinator)
    XCTAssertEqual(store.conversation(id: id)?.lastKnownState, .waiting)
    client.permissionError = .requestGone
    client.loadSessionError = .transport("offline")

    await engine.reply(permissionID: "per_1", in: id, decision: .reject)

    XCTAssertNil(store.transcript(id: id).openInteraction)
    XCTAssertEqual(store.conversation(id: id)?.lastKnownState, .idle)
    XCTAssertNotNil(store.conversation(id: id)?.remoteSessionID, "the session is not forgotten")
  }

  func testAGoneAskLeavesAnAskThatIsStillOpen() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, remote, _) = try await askedPermission(coordinator)
    let stillOpen = PendingInteraction(
      id: "per_2", conversationID: id, remoteSessionID: remote,
      kind: .permission(PermissionPrompt(
        action: "edit", resources: ["App.swift"], savePatterns: [], toolCallID: nil))
    )
    var listed = snapshot(remote: remote, state: .waiting)
    listed.openInteractions = [stillOpen]
    client.snapshots[remote] = listed
    client.permissionError = .requestGone

    await engine.reply(permissionID: "per_1", in: id, decision: .once)

    XCTAssertEqual(store.transcript(id: id).openInteraction?.id, "per_2")
    XCTAssertEqual(store.conversation(id: id)?.lastKnownState, .waiting)
    XCTAssertEqual(coordinator.preview(for: id)?.question?.requestID, "per_2")
  }

  func testOnlyAGoneAskIsPutAway() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, _, _) = try await askedPermission(coordinator)
    client.permissionError = .transport("HTTP 500: boom")

    await engine.reply(permissionID: "per_1", in: id, decision: .once)

    XCTAssertEqual(store.transcript(id: id).openInteraction?.id, "per_1")
    XCTAssertNotNil(engine.notices[id])
  }

  func testAnAnswerToAQuestionThatIsGonePutsItAway() async throws {
    let id = newConversation()
    await engine.send(text: "go", in: id)
    let remote = try XCTUnwrap(store.conversation(id: id)?.remoteSessionID)
    for (n, requestID) in ["que_1", "que_2"].enumerated() {
      store.apply(AgentEventEnvelope(id: "q\(n)", sequence: n + 1, event: .interactionAsked(
        PendingInteraction(
          id: requestID, conversationID: id, remoteSessionID: remote,
          kind: .question(QuestionPrompt(items: [QuestionItem(
            header: "UI", question: "Which?",
            choices: [AgentChoice(value: "AppKit", label: "AppKit")],
            allowsMultiple: false, allowsCustom: false)]))
        )
      )))
    }
    client.questionError = .requestGone
    var stillAsking = snapshot(remote: remote, state: .waiting)
    stillAsking.openInteractions = store.transcript(id: id).interactions.filter { $0.id == "que_2" }
    client.snapshots[remote] = stillAsking

    await engine.answer(interactionID: "que_1", in: id, answers: [["AppKit"]])
    XCTAssertEqual(store.transcript(id: id).openInteraction?.id, "que_2")

    client.snapshots[remote] = snapshot(remote: remote, state: .idle)
    await engine.rejectQuestion(interactionID: "que_2", in: id)

    XCTAssertEqual(store.transcript(id: id).interactions.map(\.resolution), [.expired, .expired])
    XCTAssertNil(engine.notices[id])
    XCTAssertEqual(store.conversation(id: id)?.lastKnownState, .idle)
  }

  func testWordsOnAGoneAskGoAsTheNextMessage() async throws {
    client.capabilities.insert(.permissionMessage)
    engine = ConversationEngine(store: store, client: client)
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, remote, question) = try await askedPermission(coordinator)
    client.permissionError = .requestGone
    client.snapshots[remote] = snapshot(remote: remote, state: .interrupted)

    try await coordinator.answer(question, with: AgentQuestion.refusal(saying: "use pnpm"))

    XCTAssertTrue(client.stopped.isEmpty)
    XCTAssertNil(engine.notices[id])
    for _ in 0..<200 where client.sentMessages.count < 2 { await Task.yield() }
    XCTAssertEqual(client.sentMessages.map(\.text), ["go", "use pnpm"])
    XCTAssertNil(coordinator.queuedPanelPrompts[id])
  }

  func testAReplyToAnAskAlreadyResolvedReportsThatNothingWasSent() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, remote, _) = try await askedPermission(coordinator)
    store.apply(AgentEventEnvelope(id: "e2", sequence: 2, event: .interactionResolved(
      sessionID: remote, requestID: "per_1", resolution: .resolvedElsewhere
    )))

    let sent = await engine.reply(permissionID: "per_1", in: id, decision: .reject)

    XCTAssertFalse(sent)
    XCTAssertTrue(client.permissionReplies.isEmpty)
  }

  // MARK: - Read-only chats

  func testAReadOnlyChatStartsItsSessionReadOnly() async throws {
    let id = store.createConversation(title: "t", workingDirectory: "/tmp", readOnly: true).id
    await engine.send(text: "look", in: id)
    XCTAssertEqual(client.createdOptions.map(\.readOnly), [true])
  }

  func testAReadOnlyChatRefusesEveryPermissionByItself() async throws {
    let (engine, id, remote) = try await attachedConversation(client)
    store.setReadOnly(true, for: id)
    client.emit(.interactionAsked(PendingInteraction(
      id: "per_ro", conversationID: id, remoteSessionID: remote,
      kind: .permission(PermissionPrompt(
        action: "bash", resources: ["rm -rf build"], savePatterns: [], toolCallID: nil))
    )))
    try await waitFor("the refusal") { !self.client.permissionReplies.isEmpty }
    XCTAssertEqual(client.permissionReplies.map(\.decision), [.reject])
    withExtendedLifetime(engine) {}
  }

  func testTwoCallersAskingForOneChatsSessionGetOneSession() async throws {
    let id = newConversation()
    let engine = engine!
    let first = Task { try await engine.ensureRemoteSession(for: id) }
    let second = Task { try await engine.ensureRemoteSession(for: id) }
    let (a, b) = try await (first.value, second.value)
    XCTAssertEqual(a, b)
    XCTAssertEqual(client.createdSessions.count, 1)
  }

  // MARK: - A refusal in words

  private func askedPermission(
    _ coordinator: ChatWorkspaceCoordinator
  ) async throws -> (id: UUID, remote: String, question: AgentQuestion) {
    let id = newConversation()
    await engine.send(text: "go", in: id)
    let remote = try XCTUnwrap(store.conversation(id: id)?.remoteSessionID)
    store.apply(AgentEventEnvelope(id: "e1", sequence: 1, event: .interactionAsked(
      PendingInteraction(
        id: "per_1", conversationID: id, remoteSessionID: remote,
        kind: .permission(PermissionPrompt(
          action: "bash", resources: ["npm install"], savePatterns: [], toolCallID: nil))
      )
    )))
    let question = try XCTUnwrap(coordinator.preview(for: id)?.question)
    return (id, remote, question)
  }

  // MARK: - A plan

  private static let plan = "# Rename the tray\n\n1. Rename it."

  private func askedPlan(
    _ coordinator: ChatWorkspaceCoordinator,
    markdown: String = plan
  ) async throws -> (id: UUID, remote: String, question: AgentQuestion) {
    let id = newConversation()
    await engine.send(text: "plan it", in: id)
    let remote = try XCTUnwrap(store.conversation(id: id)?.remoteSessionID)
    store.apply(AgentEventEnvelope(id: "plan-1", sequence: 1, event: .interactionAsked(
      PendingInteraction(
        id: "call-1", conversationID: id, remoteSessionID: remote,
        kind: .plan(PlanPrompt(markdown: markdown, toolCallID: "call-1"))
      )
    )))
    let question = try XCTUnwrap(coordinator.preview(for: id)?.question)
    return (id, remote, question)
  }

  func testAPlanWaitsOnACardWithItsThreeAnswers() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, _, question) = try await askedPlan(coordinator)

    XCTAssertEqual(store.conversation(id: id)?.lastKnownState, .waiting)
    XCTAssertEqual(question.kind, .plan)
    XCTAssertEqual(question.header, "Rename the tray")
    XCTAssertEqual(question.options.map(\.label), ["Approve", "Request changes", "Quit"])
    XCTAssertEqual(question.options.map(\.value), ["approved", "cancelled", "abandoned"])
    XCTAssertEqual(question.copyText, Self.plan)
    let preview = try XCTUnwrap(coordinator.preview(for: id))
    XCTAssertEqual(preview.messages.filter { $0.plainText == Self.plan }.count, 1,
                   "the plan is in the chat once")
  }

  func testAnEmptyPlanStillTakesTheThreeAnswers() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (_, _, question) = try await askedPlan(coordinator, markdown: "  ")

    XCTAssertEqual(question.prompt, "No plan written yet")
    XCTAssertEqual(question.header, "Plan")
    XCTAssertEqual(question.options.map(\.value), ["approved", "cancelled", "abandoned"])
    XCTAssertNil(question.copyText, "nothing to copy")
  }

  func testApprovingAPlanSendsNoWords() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, _, _) = try await askedPlan(coordinator)

    let sent = await engine.reply(planID: "call-1", in: id, decision: .approved, feedback: "stray")

    XCTAssertTrue(sent)
    XCTAssertEqual(client.planReplies.map(\.decision), [.approved])
    XCTAssertEqual(client.planReplies.map(\.feedback), [nil])
    XCTAssertEqual(store.transcript(id: id).interactions.first?.resolution, .plan(.approved))
  }

  func testRequestingChangesSendsTheWords() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, _, question) = try await askedPlan(coordinator)

    let sent = try await coordinator.answer(question, with: question.refusing(with: "  smaller steps "))

    XCTAssertTrue(sent)
    XCTAssertEqual(client.planReplies.map(\.decision), [.cancelled])
    XCTAssertEqual(client.planReplies.map(\.feedback), ["smaller steps"])
    XCTAssertEqual(store.transcript(id: id).interactions.first?.resolution, .plan(.cancelled))
    XCTAssertTrue(client.sentMessages.allSatisfy { $0.text != "smaller steps" },
                  "the words went with the plan, not as a message after it")
  }

  func testQuittingAPlanSendsNoWords() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (_, _, question) = try await askedPlan(coordinator)

    let sent = try await coordinator.answer(question, with: ["abandoned", "never mind"])

    XCTAssertTrue(sent)
    XCTAssertEqual(client.planReplies.map(\.decision), [.abandoned])
    XCTAssertEqual(client.planReplies.map(\.feedback), [nil])
  }

  func testAPlanAnswerThatDidNotGoLeavesTheCard() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, _, question) = try await askedPlan(coordinator)
    client.planError = .transport("offline")

    let sent = try await coordinator.answer(question, with: question.refusing(with: "smaller steps"))

    XCTAssertFalse(sent, "so the composer keeps the words")
    let interaction = try XCTUnwrap(store.transcript(id: id).interactions.first)
    XCTAssertNil(interaction.resolution)
    XCTAssertTrue(interaction.acceptsInput)
    XCTAssertNotNil(engine.notices[id])
    XCTAssertNotNil(coordinator.preview(for: id)?.question, "the card stays")
  }

  func testAPlanTheAgentNoLongerHasIsPutAway() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, remote, question) = try await askedPlan(coordinator)
    client.planError = .requestGone
    client.snapshots[remote] = snapshot(remote: remote, state: .idle)

    let sent = try await coordinator.answer(question, with: ["approved"])

    XCTAssertFalse(sent)
    XCTAssertEqual(store.transcript(id: id).interactions.first?.resolution, .expired)
    XCTAssertNil(engine.notices[id])
    XCTAssertNil(coordinator.preview(for: id)?.question)
  }

  func testARefusalInWordsTravelsWithTheRefusalWhereTheAgentTakesThem() async throws {
    client.capabilities.insert(.permissionMessage)
    engine = ConversationEngine(store: store, client: client)
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, _, question) = try await askedPermission(coordinator)

    try await coordinator.answer(question, with: AgentQuestion.refusal(saying: "  use pnpm "))

    XCTAssertEqual(client.permissionReplies.map(\.decision), [.reject])
    XCTAssertEqual(client.permissionMessages, ["use pnpm"])
    XCTAssertTrue(client.stopped.isEmpty, "the turn goes on, with the words")
    XCTAssertNil(coordinator.queuedPanelPrompts[id])
    XCTAssertNil(store.transcript(id: id).openInteraction)
  }

  func testARefusalInWordsStopsTheTurnAndSendsThemNextWhereTheAgentCannot() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, remote, question) = try await askedPermission(coordinator)
    coordinator.queuedPanelPrompts[id] = "and run the tests"
    client.snapshots[remote] = snapshot(remote: remote, state: .idle)

    try await coordinator.answer(question, with: AgentQuestion.refusal(saying: "use pnpm"))

    XCTAssertEqual(client.permissionReplies.map(\.decision), [.reject])
    XCTAssertEqual(client.permissionMessages, [nil], "nowhere to put them on this agent")
    XCTAssertEqual(client.stopped, [remote])
    for _ in 0..<200 where client.sentMessages.count < 2 { await Task.yield() }
    XCTAssertEqual(client.sentMessages.map(\.text), ["go", "and run the tests\n\nuse pnpm"])
    XCTAssertNil(coordinator.queuedPanelPrompts[id])
  }

  func testAnUndeliveredRefusalInWordsLeavesEverythingWhereItWas() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, _, question) = try await askedPermission(coordinator)
    client.permissionError = .transport("offline")

    try await coordinator.answer(question, with: AgentQuestion.refusal(saying: "use pnpm"))

    XCTAssertTrue(client.stopped.isEmpty)
    XCTAssertNil(coordinator.queuedPanelPrompts[id])
    XCTAssertNotNil(store.transcript(id: id).openInteraction)
  }

  func testARefusalOfAnAskAlreadyResolvedStopsAndQueuesNothing() async throws {
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, remote, question) = try await askedPermission(coordinator)
    store.apply(AgentEventEnvelope(id: "e2", sequence: 2, event: .interactionResolved(
      sessionID: remote, requestID: "per_1", resolution: .resolvedElsewhere
    )))

    try await coordinator.answer(question, with: AgentQuestion.refusal(saying: "use pnpm"))

    XCTAssertTrue(client.permissionReplies.isEmpty)
    XCTAssertTrue(client.stopped.isEmpty, "the turn goes on")
    XCTAssertNil(coordinator.queuedPanelPrompts[id])
  }

  func testARefusalSaysWhetherItWasDelivered() async throws {
    client.capabilities.insert(.permissionMessage)
    engine = ConversationEngine(store: store, client: client)
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (id, _, _) = try await askedPermission(coordinator)

    client.permissionError = .transport("offline")
    let refusedByTheProvider = await coordinator.refuse(
      permissionID: "per_1", in: id, saying: "use pnpm"
    )
    XCTAssertFalse(refusedByTheProvider)

    client.permissionError = nil
    let delivered = await coordinator.refuse(permissionID: "per_1", in: id, saying: "use pnpm")
    XCTAssertTrue(delivered)

    let again = await coordinator.refuse(permissionID: "per_1", in: id, saying: "use pnpm")
    XCTAssertFalse(again, "an ask already answered takes nothing more")
    XCTAssertEqual(client.permissionReplies.count, 1)
  }

  func testWordsWithAnAllowAreNotSent() async throws {
    client.capabilities.insert(.permissionMessage)
    engine = ConversationEngine(store: store, client: client)
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    let (_, _, question) = try await askedPermission(coordinator)

    try await coordinator.answer(question, with: [PermissionDecision.once.rawValue, "stray"])

    XCTAssertEqual(client.permissionReplies.map(\.decision), [.once])
    XCTAssertEqual(client.permissionMessages, [nil])
  }

  func testStopAsksTheProviderToInterrupt() async {
    let id = newConversation()
    await engine.send(text: "long job", in: id)
    let remote = store.conversation(id: id)!.remoteSessionID!
    client.snapshots[remote] = snapshot(remote: remote, state: .idle)

    await engine.stop(conversationID: id)

    XCTAssertEqual(client.stopped, [remote])
  }

  func testStopWhileWaitingClosesTheCardTheProviderHasDropped() async {
    let id = newConversation()
    await engine.send(text: "long job", in: id)
    let remote = store.conversation(id: id)!.remoteSessionID!
    store.apply(
      AgentEventEnvelope(
        id: "e1",
        sequence: 1,
        event: .interactionAsked(
          PendingInteraction(
            id: "per_1",
            conversationID: id,
            remoteSessionID: remote,
            kind: .permission(
              PermissionPrompt(action: "bash", resources: ["ls"], savePatterns: [], toolCallID: nil)
            )
          )
        )
      )
    )
    XCTAssertEqual(store.conversation(id: id)?.lastKnownState, .waiting)
    client.snapshots[remote] = snapshot(remote: remote, state: .idle)

    await engine.stop(conversationID: id)

    XCTAssertNil(store.transcript(id: id).openInteraction, "no card left with nothing behind it")
    XCTAssertEqual(store.conversation(id: id)?.lastKnownState, .idle)
  }

  func testDeletingAWorkingConversationStopsTheAgentFirst() async {
    let id = newConversation()
    await engine.send(text: "long job", in: id)
    let remote = store.conversation(id: id)!.remoteSessionID!

    await engine.deleteConversation(id: id)

    XCTAssertEqual(client.stopped, [remote], "the row is the only thing that could have stopped it")
    XCTAssertNil(store.conversation(id: id))
  }

  private func snapshot(
    remote: String,
    state: ConversationExecutionState
  ) -> RemoteSessionSnapshot {
    RemoteSessionSnapshot(
      info: RemoteSessionInfo(id: remote, title: "Task", directory: "/tmp/work", model: nil),
      messages: store.transcript(id: store.conversation(remoteSessionID: remote)!.id).messages,
      state: state,
      openInteractions: []
    )
  }
  // MARK: - Listening

  func testAMissingAgentIsNotListenedTo() async throws {
    let missing = FakeAgentClient()
    missing.provider = .opencode
    missing.availability = .notInstalled
    let present = FakeAgentClient()
    present.provider = .claude
    present.availability = .available(version: "test")

    let engine = ConversationEngine(
      store: store, registry: AgentRegistry(clients: [missing, present])
    )
    engine.start()
    try await waitFor("the installed agent to be listened to") { present.isStreaming }

    XCTAssertFalse(
      missing.isStreaming,
      "an agent with no binary must not be listened to at all"
    )

    present.emit(.connection(.connected))
    try await waitFor("the event to arrive") {
      self.store.connectionState(forProviderID: AgentId.claude.rawValue) == .connected
    }
  }

  // MARK: - A turn that ends leaves nothing half-written

  func testAReplyIsFinishedWhenItsTurnEndsEvenIfNobodySaysSo() async throws {
    let (engine, id, remote) = try await attachedConversation(client)
    withExtendedLifetime(engine) {}

    client.streamReply(sessionID: remote, messageID: "msg_reply", chunks: ["po", "ng"])
    try await waitFor("the turn to end") {
      self.store.conversation(id: id)?.lastKnownState == .idle
        && self.store.transcript(id: id).messages.last?.plainText == "pong"
    }

    let reply = try XCTUnwrap(store.transcript(id: id).messages.last)
    XCTAssertEqual(reply.role, .agent)
    XCTAssertNotNil(reply.completedAt, "an idle turn has nothing left to write")
  }

  func testAnIdleTurnThatSaidNothingLeavesTheTranscriptAsItWas() async throws {
    let (engine, id, remote) = try await attachedConversation(client)
    withExtendedLifetime(engine) {}
    store.appendUserMessage(id: "msg_user", text: "hello", attachments: [], to: id)
    let before = store.transcript(id: id).messages

    client.emit(.executionStateChanged(sessionID: remote, state: .idle))
    try await waitFor("the turn to end") {
      self.store.conversation(id: id)?.lastKnownState == .idle
    }

    XCTAssertEqual(store.transcript(id: id).messages, before)
  }

  // MARK: - What a reconnect costs

  private func attachedConversation(
    _ client: FakeAgentClient
  ) async throws -> (engine: ConversationEngine, id: UUID, remote: String) {
    client.provider = .claude
    client.availability = .available(version: "test")
    let engine = ConversationEngine(store: store, registry: AgentRegistry(clients: [client]))
    let id = store.createConversation(
      title: "chat", workingDirectory: "/tmp", providerID: AgentId.claude.rawValue
    ).id
    let remote = "ses_1"
    store.attachRemoteSession(remote, to: id, model: nil)
    client.snapshots[remote] = RemoteSessionSnapshot(
      info: RemoteSessionInfo(id: remote, title: "chat", directory: "/tmp", model: nil),
      messages: [], state: .idle, openInteractions: []
    )
    await engine.refresh(conversationID: id)
    engine.start()
    try await waitFor("the stream") { client.isStreaming }
    client.clearLoadedSessions()
    return (engine, id, remote)
  }

  func testAReconnectSkipsTheReReadWhenTheServerSaysNothingHappened() async throws {
    let client = FakeAgentClient()
    client.missedAnythingAnswer = false
    let attached = try await attachedConversation(client)

    client.emit(.connection(.connected))
    try await waitFor("the reconnect to be handled") {
      self.store.connectionState(forProviderID: AgentId.claude.rawValue) == .connected
    }

    XCTAssertEqual(client.loadedSessions, [], "nothing moved, so nothing needed re-reading")
    XCTAssertEqual(attached.remote, "ses_1")
  }

  func testAReconnectReReadsWhenTheServerSaysSomethingHappened() async throws {
    let client = FakeAgentClient()
    client.missedAnythingAnswer = true
    let attached = try await attachedConversation(client)

    client.emit(.connection(.connected))
    try await waitFor("the re-read") { !client.loadedSessions.isEmpty }

    XCTAssertEqual(client.loadedSessions, ["ses_1"])
    XCTAssertNotNil(attached.engine)
  }

  func testAProviderThatCannotTellIsStillReRead() async throws {
    let client = FakeAgentClient()
    client.missedAnythingAnswer = nil
    let attached = try await attachedConversation(client)

    client.emit(.connection(.connected))
    try await waitFor("the re-read") { !client.loadedSessions.isEmpty }

    XCTAssertEqual(client.loadedSessions, ["ses_1"], "an unknown answer is not a no")
    XCTAssertNotNil(attached.engine)
  }

  func testAnAgentInstalledLaterStartsBeingListenedTo() async throws {
    let late = FakeAgentClient()
    late.provider = .claude
    late.availability = .notInstalled

    let engine = ConversationEngine(store: store, registry: AgentRegistry(clients: [late]))
    engine.start()
    try await waitFor("the first probe") { engine.hasProbed }
    XCTAssertFalse(late.isStreaming)

    late.availability = .available(version: "test")
    await engine.refreshAvailability()

    try await waitFor("the re-probe to open the stream") { late.isStreaming }
  }

  func testASendToAForgottenSessionOpensANewOneAndGoesThrough() async throws {
    let id = newConversation()
    await engine.send(text: "First", in: id)
    store.setExecutionState(.idle, for: id)
    let dead = try XCTUnwrap(store.conversation(id: id)?.remoteSessionID)

    client.sendError = .sessionNotFound
    client.sendErrorCount = 1
    let sent = await engine.send(text: "Second", in: id)

    XCTAssertTrue(sent, "the message has to land, not come back as a sentence")
    let live = try XCTUnwrap(store.conversation(id: id)?.remoteSessionID)
    XCTAssertNotEqual(live, dead, "the dead session id must not survive the retry")
    XCTAssertEqual(client.createdSessions.count, 2)
    XCTAssertEqual(client.sentMessages.last?.text, "Second")
    XCTAssertEqual(client.sentMessages.last?.sessionID, live)
    XCTAssertEqual(
      store.transcript(id: id).messages.filter { $0.role == .user }.map(\.plainText),
      ["First", "Second"],
      "one bubble per prompt: the reverted attempt must not leave a second"
    )
    XCTAssertEqual(store.conversation(id: id)?.draft, "", "the composer is not left holding it")
    XCTAssertEqual(notice(id)?.isBlocking, false)
    XCTAssertTrue(
      try XCTUnwrap(notice(id)?.text).contains("started a new session"),
      "losing the agent's memory of the chat is quiet, but it is not silent"
    )
  }

  func testAProviderThatForgetsEverySessionIsToldOnceAndThenBelieved() async throws {
    let id = newConversation()
    await engine.send(text: "First", in: id)
    store.setExecutionState(.idle, for: id)

    client.sendError = .sessionNotFound
    let sent = await engine.send(text: "Second", in: id)

    XCTAssertFalse(sent)
    XCTAssertEqual(client.createdSessions.count, 2, "exactly one new session, then it stops")
    XCTAssertEqual(store.conversation(id: id)?.draft, "Second", "the prompt comes back intact")
    XCTAssertEqual(
      notice(id)?.text,
      AgentClientError.sessionNotFound.errorDescription,
      "the second refusal is reported as itself"
    )
  }

  func testEachAdapterMintsASessionIDItsCLIWillAccept() {
    XCTAssertNotNil(UUID(uuidString: ClaudeCodeClient().makeSessionID()))
    XCTAssertTrue(FakeAgentClient().makeSessionID().hasPrefix("ses_"))
  }

  private func notice(_ id: UUID) -> EngineNotice? { engine.notices[id] }

  private func waitFor(
    _ what: String,
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  // MARK: - Adopting a CLI's own session

  func testAnAdapterThatCannotReReadASessionDoesNotLoseItsBinding() async throws {
    let conversation = newConversation()
    store.attachRemoteSession("ses_the_cli_owns_this", to: conversation, model: nil)

    await engine.refresh(conversationID: conversation)

    XCTAssertEqual(
      store.conversation(id: conversation)?.remoteSessionID, "ses_the_cli_owns_this",
      "the binding is what makes the next send resume the right session"
    )
    XCTAssertNil(engine.notices[conversation], "nothing was lost, so nothing to announce")
  }

  func testASessionTheProviderForgetsAfterAttachingIsStillADeletion() async throws {
    let conversation = newConversation()
    client.snapshots["ses_live"] = RemoteSessionSnapshot(
      info: RemoteSessionInfo(id: "ses_live", title: "t", directory: "/tmp", model: nil),
      messages: [],
      state: .idle,
      openInteractions: []
    )
    store.attachRemoteSession("ses_live", to: conversation, model: nil)
    await engine.refresh(conversationID: conversation)
    XCTAssertEqual(store.conversation(id: conversation)?.remoteSessionID, "ses_live")

    client.snapshots["ses_live"] = nil
    await engine.refresh(conversationID: conversation)

    XCTAssertNil(store.conversation(id: conversation)?.remoteSessionID)
    XCTAssertNotNil(engine.notices[conversation])
  }

}

final class ClaudeCodeReadOnlyArgumentsTests: XCTestCase {
  func testAReadOnlySessionHasOnlyTheReadingToolsAndAFlagFollowsThem() {
    let arguments = ClaudeCodeClient.sessionArguments(
      id: "11111111-1111-1111-1111-111111111111",
      options: AgentSessionOptions(directory: "/tmp", readOnly: true), resuming: false)
    let tools = try! XCTUnwrap(arguments.firstIndex(of: "--tools"))
    XCTAssertEqual(arguments[tools + 1], "Read,Glob,Grep")
    XCTAssertTrue(arguments[tools + 2].hasPrefix("--"), "--tools is variadic: a flag must end it")
  }

  func testAnOrdinarySessionKeepsEveryTool() {
    let arguments = ClaudeCodeClient.sessionArguments(
      id: "11111111-1111-1111-1111-111111111111",
      options: AgentSessionOptions(directory: "/tmp"), resuming: false)
    XCTAssertFalse(arguments.contains("--tools"))
  }
}
