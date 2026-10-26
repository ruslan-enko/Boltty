import AppKit
import XCTest
@testable import Boltty

@MainActor
final class AgentPaletteViewTests: XCTestCase {
  func testTheMascotKeepsItsDriftWhenTheAgentChanges() {
    let view = makeView(targets: [.opencode])
    view.prepareForPresentation()
    let conversationID = view.pendingConversationID
    XCTAssertEqual(view.mascotIdentityForTesting, conversationID)

    view.render(agent: .codex, animated: false)
    XCTAssertEqual(
      view.mascotIdentityForTesting,
      conversationID,
      "changing the agent must not restart the conversation's drift"
    )
  }

  func testTheMascotWearsTheAddressedAgentsFace() {
    let view = makeView(targets: [.opencode])
    view.prepareForPresentation()
    XCTAssertEqual(view.mascotPaletteIDForTesting, MascotPalette.face(for: .opencode).id)

    view.render(agent: .codex, animated: false)
    XCTAssertEqual(view.mascotPaletteIDForTesting, MascotPalette.face(for: .codex).id)
  }

  func testConversationStateChoosesMascotEmotion() {
    XCTAssertEqual(MascotEmotion(executionState: .idle), .curious)
    XCTAssertEqual(MascotEmotion(executionState: .working), .thinking)
    XCTAssertEqual(MascotEmotion(executionState: .waiting), .concerned)
    XCTAssertEqual(MascotEmotion(executionState: .failed), .sad)
  }

  func testReturningFromANewChatWithoutHidingUsesANewConversationID() {
    let view = makeScreenSizedView()
    let usedID = view.pendingConversationID
    view.enterAddressing(.init(id: usedID, title: "First", agent: .opencode,
      state: .finished, body: "Done"))
    view.leaveAddressing(animated: false)
    XCTAssertNotEqual(view.pendingConversationID, usedID)
    XCTAssertEqual(view.mascotIdentityForTesting, view.pendingConversationID)
  }

  func testBolttyAIMintsANewMascotForEveryPresentation() {
    let view = makeView(targets: [.opencode])
    let first = view.pendingConversationID
    view.prepareForPresentation()

    XCTAssertNotEqual(first, view.pendingConversationID)
    XCTAssertEqual(view.mascotIdentityForTesting, view.pendingConversationID)
    XCTAssertEqual(view.mascotEmotionForTesting, .curious)
  }

  func testListeningAndErrorsChangeTheMascotEmotion() {
    let view = makeView()
    view.setVoiceListening(true)
    XCTAssertEqual(view.mascotEmotionForTesting, .listening)

    view.showError("Microphone unavailable")
    XCTAssertEqual(view.mascotEmotionForTesting, .sad)
  }

  private func makeScreenSizedView(
    targets: [AgentId] = [.opencode]
  ) -> AgentPaletteView {
    let view = makeView(targets: targets)
    view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    view.layoutSubtreeIfNeeded()
    return view
  }

  private func makeView(
    targets: [AgentId] = [.opencode]
  ) -> AgentPaletteView {
    let view = AgentPaletteView()
    view.appearance = NSAppearance(named: .darkAqua)
    view.frame = CGRect(origin: .zero, size: AgentPaletteMetrics.panelSize())
    view.setAgentChoices(targets, planned: targets.first)
    view.prepareForPresentation()
    view.layoutSubtreeIfNeeded()
    return view
  }

  private func reviewQuestion(custom: Bool = false, multiple: Bool = false, count: Int = 3) -> AgentQuestion {
    AgentQuestion(
      kind: .question, requestID: "review",
      header: "Choice", prompt: "Choose an option",
      options: (1...count).map { .init(label: "Option \($0)", detail: nil) },
      allowsMultiple: multiple, allowsCustom: custom
    )
  }

  func testTheFolderDoesNotChangeQuestionCardHeight() {
    func height(withChip: Bool) -> CGFloat {
      let view = makeView()
      view.frame = CGRect(x: 0, y: 0, width: 1440, height: 1600)
      if withChip {
        view.setWorkingDirectory(.forNewPrompt(path: "/Users/someone", honoursWorkingDirectory: true))
      }
      view.enterAddressing(.init(id: UUID(), title: "Agent", agent: .opencode,
                                state: .blocked, body: "Choose", question: reviewQuestion(count: 1)))
      view.layoutSubtreeIfNeeded()
      return view.previewCardHeightForTesting
    }
    XCTAssertEqual(
      height(withChip: true) - height(withChip: false),
      0,
      accuracy: 0.5
    )
  }

  func testTypedAnswerToAClosedChoiceNeverFallsThroughToThePTY() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Agent", agent: .opencode,
                              state: .blocked, body: "Choose", question: reviewQuestion()))
    view.field.setDraft(PromptDraft("some text"))
    var submitted = false
    view.onSubmit = { _ in submitted = true }
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    XCTAssertFalse(submitted)
    XCTAssertNotNil(view.visibleErrorForTesting)
    XCTAssertEqual(view.field.string, "some text")
  }

  func testEmptyMultipleChoiceDoesNotOpenTheSessionOrSubmitAPrompt() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Agent", agent: .opencode,
                              state: .blocked, body: "Choose", question: reviewQuestion(multiple: true)))
    var submitted = false
    view.onSubmit = { _ in submitted = true }
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    XCTAssertFalse(submitted)
    XCTAssertNotNil(view.visibleErrorForTesting)
  }

  func testOptionsCountTowardsTheReplyCardsScreenHeightLimit() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Agent", agent: .opencode,
                              state: .blocked, body: String(repeating: "Long answer. ", count: 300),
                              question: reviewQuestion(count: 12)))
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(view.bounds.contains(view.previewCapsuleFrameForTesting))
  }

  func testAShortReplyCardIsACardAtTheCornerTheReaderSees() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Agent", agent: .opencode,
                              state: .finished, body: "Working…", question: nil))
    view.layoutSubtreeIfNeeded()

    let height = view.previewCardHeightForTesting
    XCTAssertGreaterThan(height, 0, "the card is open")
    XCTAssertEqual(
      view.previewCardCornerRadiusForTesting,
      AgentPaletteMetrics.cardCornerRadius,
      accuracy: 0.01,
      "the mock's corner, whatever the height"
    )
  }

  func testUnifiedShellOwnsAnExplicitShadowOutsideLiveGlass() throws {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Agent", agent: .opencode,
                              state: .finished, body: "A reply"))
    view.layoutSubtreeIfNeeded()
    let layer = try XCTUnwrap(view.unifiedSurfaceLayerForTesting)
    let path = try XCTUnwrap(layer.shadowPath)
    XCTAssertEqual(path.boundingBoxOfPath, layer.bounds)
    XCTAssertFalse(layer.shouldRasterize)
    XCTAssertNil(layer.filters)
    XCTAssertGreaterThan(view.unifiedSurfaceCornerForTesting, 0)
  }

  func testTheCardsTextIsClippedToTheGlassItIsPaintedOn() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Agent", agent: .opencode,
                              state: .finished, body: "Working…", question: nil))
    view.layoutSubtreeIfNeeded()

    let clip = view.previewForegroundClipForTesting
    XCTAssertTrue(clip.clips, "the transcript viewport must clip scrolling text")
    XCTAssertEqual(clip.radius, 0, "only the outer shell rounds the surface")

  }

  func testACornerTakesTheCurveItsWallCanCarry() {
    XCTAssertEqual(
      AgentPaletteMetrics.cornerCurve(radius: 61, shorterSide: 400),
      .continuous
    )
    XCTAssertEqual(
      AgentPaletteMetrics.cornerCurve(radius: 61, shorterSide: 80),
      .circular
    )
    XCTAssertEqual(
      AgentPaletteMetrics.cornerCurve(
        radius: AgentPaletteMetrics.cornerRadius,
        shorterSide: AgentPaletteMetrics.promptSize.height
      ),
      .circular
    )
  }

  func testReplyCardRemeasuresWhenThePanelGetsItsScreenFrame() {
    let view = makeView()
    view.enterAddressing(.init(id: UUID(), title: "Agent", agent: .opencode,
                              state: .blocked, body: String(repeating: "Answer. ", count: 150),
                              question: reviewQuestion()))
    let before = view.previewCardHeightForTesting
    view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(view.previewCardHeightForTesting, before)
  }

  func testEditingTheDictatedDraftKeepsCorrectionsWhenAFinalResultArrives() {
    let view = makeView()
    view.setVoiceListening(true)
    view.applyVoiceTranscript("fix log in")
    view.field.setDraft(PromptDraft("fix login, please"))
    view.applyVoiceTranscript("fix logging")
    XCTAssertEqual(view.field.string, "fix login, please")
    XCTAssertFalse(view.isVoiceListeningForTesting)
  }

  func testSpaceCanChooseSeveralOptionsWithoutTypingIntoThePrompt() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Agent", agent: .opencode,
                              state: .blocked, body: "Choose", question: reviewQuestion(multiple: true)))
    var answers: [String] = []
    view.onAnswerQuestion = { _, _, chosen in answers = chosen }
    XCTAssertFalse(view.textView(view.field, shouldChangeTextIn: .init(location: 0, length: 0),
                                 replacementString: " "))
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    XCTAssertFalse(view.textView(view.field, shouldChangeTextIn: .init(location: 0, length: 0),
                                 replacementString: " "))
    view.confirmCurrentDraft()
    XCTAssertEqual(answers, ["Option 1", "Option 2"])
    XCTAssertTrue(view.field.isEmptyPrompt)
  }

  func testTheMicButtonFrameIsSquareSoItsHoverIsACircle() {
    let mic = makeView().micButtonForTesting
    let side = ComposerControlGroup.target(chat: false)

    XCTAssertEqual(mic.frame.width, side, accuracy: 0.01)
    XCTAssertEqual(mic.frame.height, side, accuracy: 0.01)
    XCTAssertEqual(
      mic.layer?.cornerRadius,
      side / 2,
      "a radius short of half the side rounds the corners instead of filling a circle"
    )
  }

  func testWrappedInitialPromptGrowsTheCapsuleAndThePanelByAsMuch() {
    let view = hostOffscreen(makeView())
    let collapsed = view.fittingSize.height
    XCTAssertEqual(view.promptCapsuleHeightForTesting, AgentPaletteMetrics.promptSize.height, accuracy: 0.5)

    view.field.insertPlainText(
      String(repeating: "dsadasdasdsdfhsbdajhfbhsdjabfhjsab ", count: 4)
    )
    settlePromptLayout(view)
    let grown = view.promptCapsuleHeightForTesting
    XCTAssertGreaterThan(grown, AgentPaletteMetrics.promptSize.height, "the draft wrapped and the capsule grew")
    XCTAssertLessThanOrEqual(grown, AgentPaletteMetrics.promptGrownMaximumHeight + 0.5)
    XCTAssertEqual(
      view.fittingSize.height - collapsed,
      grown - AgentPaletteMetrics.promptSize.height,
      accuracy: 0.5,
      "the panel grows by the capsule's growth and nothing else"
    )
  }

  func testInitialPromptContentNotificationsNeverPublishATallerPanel() {
    let view = hostOffscreen(makeView())
    let collapsed = view.fittingSize.height
    var notifiedHeights: [CGFloat] = []
    view.onContentSizeChange = { [weak view] in
      if let view { notifiedHeights.append(view.fittingSize.height) }
    }

    view.field.insertPlainText(
      String(repeating: "dsadasdasdsdfhsbdajhfbhsdjabfhjsab ", count: 4)
    )

    settlePromptLayout(view)
    let settled = view.fittingSize.height
    XCTAssertGreaterThan(settled, collapsed)
    for height in notifiedHeights {
      XCTAssertLessThanOrEqual(height, settled + 0.5)
      XCTAssertGreaterThanOrEqual(height, collapsed - 0.5)
    }
  }

  func testPromptHasTextField() {
    let view = makeView()
    XCTAssertFalse(view.field.isHidden)
  }

  func testInitDoesNotTrapOnHeightConstraints() {
    let view = AgentPaletteView()
    XCTAssertFalse(view.field.isHidden)
    XCTAssertGreaterThan(view.fittingSize.height, 0)
  }

  func testEnterWithHighlightedSessionSelectsItInsteadOfSubmitting() {
    let view = makeView()
    let agent = BolttyAISessionItem.row("hello", .codex)
    view.setSessions([agent], activeSessionID: agent.id)

    var selected: UUID?
    var submitted: PromptDraft?
    view.onSelectSession = { selected = $0 }
    view.onSubmit = { submitted = $0 }

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertEqual(view.selectedResultIndexForTesting, 0)
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    )

    XCTAssertEqual(selected, agent.id)
    XCTAssertNil(submitted)
  }

  func testConfirmingASwitcherRowGoesThroughOnConfirmSession() {
    let view = makeView()
    let agent = BolttyAISessionItem.row("hello", .claude)
    view.setSessions([agent], activeSessionID: agent.id)

    var confirmed: UUID?
    view.onConfirmSession = { confirmed = $0 }
    view.onSelectSession = { _ in XCTFail("confirm should win over select") }

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    )
    XCTAssertEqual(confirmed, agent.id)
  }

  func testCommandPeriodStopsARunningTurnAndIsOtherwiseEscape() throws {
    let view = makeScreenSizedView()
    var stops = 0
    view.onStop = { stops += 1 }
    let commandPeriod = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: 0, context: nil, characters: ".", charactersIgnoringModifiers: ".",
      isARepeat: false, keyCode: 0x2F  // kVK_ANSI_Period
    ))

    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .codex, state: .finished, body: "done"))
    XCTAssertFalse(view.field.performKeyEquivalent(with: commandPeriod), "nothing running: AppKit's Escape")
    XCTAssertEqual(stops, 0)

    var running = BolttyAISessionPreview(id: UUID(), title: "Chat", agent: .codex, state: .running, body: "")
    running.canStop = true
    view.enterAddressing(running)
    XCTAssertTrue(view.field.performKeyEquivalent(with: commandPeriod))
    XCTAssertEqual(stops, 1)
    XCTAssertEqual(view.stopHelpShortcutForTesting, "⌘.")
  }

  func testStopRequiresBothARunningTurnAndDeclaredSupport() {
    let view = makeView()
    var preview = BolttyAISessionPreview(id: UUID(), title: "Chat", agent: .opencode, state: .running, body: "Working")
    view.enterAddressing(preview)
    XCTAssertFalse(view.sendSlotStopsForTesting)
    preview.canStop = true
    view.updateAddressing(preview)
    XCTAssertTrue(view.sendSlotStopsForTesting, "the Send slot turns into Stop")
    view.leaveAddressing(animated: false)
    XCTAssertFalse(view.sendSlotStopsForTesting)
  }

  func testEnterAddressingShowsThePreviewCardAndHidesTheList() {
    let view = makeView()
    view.setSessions([.row("session")], activeSessionID: nil)
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertTrue(view.isResultsExpandedForTesting)

    let preview = BolttyAISessionPreview(
      id: UUID(),
      title: "fix login",
      agent: .claude,
      state: .blocked,
      body: "Found 3 issues"
    )
    view.enterAddressing(preview)

    XCTAssertTrue(view.isAddressingForTesting)
    XCTAssertEqual(view.addressedSessionIDForTesting, preview.id)
    XCTAssertTrue(view.isPreviewCardVisibleForTesting)
    XCTAssertFalse(view.isResultsExpandedForTesting)
    XCTAssertTrue(view.previewBodyForTesting.contains("Found 3 issues"))
  }

  func testTheReplyCardSitsAboveTheComposer() {
    let view = makeScreenSizedView()
    view.enterAddressing(
      BolttyAISessionPreview(
        id: UUID(),
        title: "fix login",
        agent: .claude,
        state: .blocked,
        body: "Hello! What can I help you with today?"
      )
    )
    view.layoutSubtreeIfNeeded()

    let band = view.previewBandFrameForTesting
    let prompt = view.promptCapsuleFrameForTesting
    let bandIsAbove = view.isFlipped
      ? band.maxY <= prompt.minY
      : band.minY >= prompt.maxY
    XCTAssertTrue(bandIsAbove, "band \(band) should sit above composer \(prompt)")

    let card = view.previewCapsuleFrameForTesting
    let shell = view.unifiedSurfaceFrameForTesting
    XCTAssertEqual(card.minY, shell.minY, accuracy: 0.5,
                   "the transcript runs behind the composer, down to the shell's floor")
    XCTAssertTrue(card.intersects(prompt), "which is what puts the glass over it")
  }

  func testTheTranscriptStartsAtTheShellsTopRim() {
    let view = makeScreenSizedView()
    view.enterAddressing(
      BolttyAISessionPreview(
        id: UUID(), title: "fix login", agent: .claude, state: .finished,
        body: "Hello! What can I help you with today?"
      )
    )
    view.layoutSubtreeIfNeeded()

    let shell = view.unifiedSurfaceFrameForTesting
    let card = view.previewCapsuleFrameForTesting
    let gap = view.isFlipped ? card.minY - shell.minY : shell.maxY - card.maxY
    XCTAssertEqual(
      gap, 0, accuracy: 0.5,
      "shell \(shell) must begin exactly where the transcript does, card \(card)"
    )
  }

  func testFolderAndPlanSitInsideTheComposerWithoutAnExtraTranscriptBand() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .claude,
      state: .finished, body: "Hello! What can I help you with today?"))
    view.setWorkingDirectory(.forNewPrompt(path: "/tmp/repo", honoursWorkingDirectory: true))
    view.layoutSubtreeIfNeeded()
    let composer = view.promptCapsuleFrameForTesting
    let folder = view.convert(view.workingDirectoryChipForTesting.bounds,
      from: view.workingDirectoryChipForTesting)
    let plan = view.convert(view.planRingForTesting.bounds, from: view.planRingForTesting)
    XCTAssertTrue(composer.contains(folder))
    XCTAssertTrue(composer.contains(plan))
    let card = view.previewBandFrameForTesting
    let gap = view.isFlipped ? composer.minY - card.maxY : card.minY - composer.maxY
    XCTAssertEqual(gap, AgentPaletteMetrics.surfaceStackSpacing, accuracy: 0.5)
  }

  func testTheComposerMovesIntoTheChatAndReturnsAfterLeaving() {
    let view = makeScreenSizedView()
    let resting = view.promptTopInsetForTesting

    view.enterAddressing(
      BolttyAISessionPreview(
        id: UUID(),
        title: "fix login",
        agent: .claude,
        state: .blocked,
        body: "Hello! What can I help you with today?"
      )
    )
    XCTAssertGreaterThan(view.promptTopInsetForTesting, resting)

    view.leaveAddressing(animated: false)
    XCTAssertEqual(view.promptTopInsetForTesting, resting, accuracy: 0.5)
  }

  func testTheShellIsLockedUnderTheMenuBarAndCannotBeCarried() {
    let view = makeScreenSizedView()
    view.topReserve = 32
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.promptTopInsetForTesting, 32 + AgentPaletteMetrics.lockedTopGap, accuracy: 0.5)
    XCTAssertEqual(view.promptCenterXOffsetForTesting, 0, accuracy: 0.5)
    XCTAssertTrue(view.gestureRecognizers.compactMap { $0 as? NSPanGestureRecognizer }.isEmpty)

    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .claude, state: .finished, body: "Hello"))
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()
    let shell = view.unifiedSurfaceFrameForTesting
    XCTAssertEqual(view.bounds.maxY - shell.maxY, 32 + AgentPaletteMetrics.lockedTopGap, accuracy: 0.5)
    XCTAssertEqual(shell.midX, view.bounds.midX, accuracy: 0.5)
  }

  func testTheWholeChatFitsInsideTheScreenWithAScrollingTranscript() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Long answer", agent: .claude,
      state: .finished, body: String(repeating: "Long answer line.\n", count: 200)))
    view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(view.previewCardHeightForTesting, 0)
    XCTAssertTrue(view.bounds.contains(view.unifiedSurfaceFrameForTesting))
    XCTAssertTrue(view.unifiedSurfaceFrameForTesting.contains(view.promptCapsuleFrameForTesting))
  }

  func testALongAnswerSizesTheCardForWhatItWraps() {
    let view = makeScreenSizedView()
    let body = String(repeating: "The session token is never refreshed. ", count: 6)
    view.enterAddressing(
      BolttyAISessionPreview(
        id: UUID(),
        title: "fix login",
        agent: .claude,
        state: .blocked,
        body: body
      )
    )

    XCTAssertGreaterThan(
      view.previewCardHeightForTesting,
      AgentPaletteMetrics.previewCardHeight(bodyLineCount: 1)
    )
  }

  func testTheChatShellDoesNotGrowAsTheAnswerArrives() {
    let view = makeScreenSizedView()
    let id = UUID()
    view.enterAddressing(
      BolttyAISessionPreview(
        id: id,
        title: "fix login",
        agent: .claude,
        state: .finished,
        body: "Looking at the login flow."
      )
    )
    view.cancelAllAnimationsAndSettle()
    let first = view.unifiedSurfaceFrameForTesting

    view.updateAddressing(
      BolttyAISessionPreview(
        id: id,
        title: "fix login",
        agent: .claude,
        state: .finished,
        body: String(repeating: "Looking at the login flow. ", count: 8)
      )
    )

    view.cancelAllAnimationsAndSettle()
    XCTAssertEqual(view.unifiedSurfaceFrameForTesting, first)
    XCTAssertTrue(view.previewBodyForTesting.contains("Looking at the login flow."))
  }

  // MARK: - Keys on the reply card

  func testDownArrowDoesNotOpenTheSwitcherUnderTheCard() {
    let view = makeScreenSizedView()
    view.setSessions([.row("claude", .claude)], activeSessionID: nil)
    view.enterAddressing(
      BolttyAISessionPreview(
        id: UUID(),
        title: "fix login",
        agent: .claude,
        state: .blocked,
        body: "Found 3 issues"
      )
    )

    XCTAssertFalse(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertFalse(view.isResultsExpandedForTesting)
    XCTAssertTrue(view.isAddressingForTesting)
  }

  func testUpArrowLeavesTheCardForTheSwitcher() {
    let view = makeScreenSizedView()
    view.setSessions([.row("claude", .claude)], activeSessionID: nil)
    view.enterAddressing(
      BolttyAISessionPreview(
        id: UUID(),
        title: "fix login",
        agent: .claude,
        state: .blocked,
        body: "Found 3 issues"
      )
    )

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveUp(_:)))
    )
    XCTAssertFalse(view.isAddressingForTesting)
    XCTAssertTrue(view.isResultsExpandedForTesting)
  }

  func testASlashInAReplyStaysAReply() {
    let view = makeScreenSizedView()
    let id = UUID()
    view.setSessions([.row("claude", .claude)], activeSessionID: nil)
    view.enterAddressing(
      BolttyAISessionPreview(
        id: id,
        title: "fix login",
        agent: .claude,
        state: .blocked,
        body: "Found 3 issues"
      )
    )

    view.field.setDraft(PromptDraft("/tmp/build.log is the one"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))

    XCTAssertEqual(view.mode, .prompt)
    XCTAssertFalse(view.fieldIsQuery)
    XCTAssertTrue(view.isAddressingForTesting)
    XCTAssertEqual(view.addressedSessionIDForTesting, id)
  }

  func testEnterOnTheCardSubmitsTheReply() {
    let view = makeScreenSizedView()
    var submitted: PromptDraft?
    view.onSubmit = { submitted = $0 }
    view.enterAddressing(
      BolttyAISessionPreview(
        id: UUID(),
        title: "fix login",
        agent: .claude,
        state: .blocked,
        body: "Found 3 issues"
      )
    )

    view.field.setDraft(PromptDraft("Fix only the first issue."))
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    )
    XCTAssertEqual(submitted?.typedText, "Fix only the first issue.")
  }

  func testTabIsInertOnTheCard() {
    let view = makeScreenSizedView(targets: [.claude, .codex])
    view.enterAddressing(
      BolttyAISessionPreview(
        id: UUID(),
        title: "fix login",
        agent: .claude,
        state: .blocked,
        body: "Found 3 issues"
      )
    )

    XCTAssertFalse(view.textView(view.field, doCommandBy: #selector(NSResponder.insertTab(_:))))
    XCTAssertFalse(view.textView(view.field, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
    XCTAssertEqual(view.agentForNewPrompt, .claude, "the agent did not move")
    XCTAssertTrue(view.isAddressingForTesting)
  }

  func testEveryCapsuleInThePaletteDrawsACircularCorner() {
    let button = PaletteIconButton()
    button.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
    button.layoutSubtreeIfNeeded()
    let buttonLayer = button.layer
    XCTAssertEqual(buttonLayer?.cornerRadius, 17, "a round button is radius = side / 2")
    XCTAssertEqual(
      buttonLayer?.cornerCurve, .circular,
      "a squircle at that radius comes to a point instead of closing"
    )

    let pill = VoiceRecordingControls()
    pill.frame = CGRect(x: 0, y: 0, width: 220, height: 40)
    pill.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      pill.layer?.cornerCurve, .circular,
      "short enough that the radius clamps to height / 2 — a capsule"
    )

    XCTAssertEqual(
      AgentPaletteMetrics.cornerCurve(radius: 17, shorterSide: 400),
      .continuous
    )
  }

  func testTheComposersGlyphsStandInsideTheField() {
    let view = makeScreenSizedView()
    view.setAcceptsAttachments(true)
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .opencode,
                               state: .finished, body: "A reply."))
    view.layoutSubtreeIfNeeded()

    XCTAssertTrue(view.isAttachDiscVisibleForTesting, "precondition: the clip is offered")
    let field = view.composerFieldFrameForTesting
    let clip = view.attachDiscFrameForTesting
    let mic = view.voiceControlFrameForTesting
    let box = view.composerForegroundSizeForTesting

    XCTAssertEqual(field.width, box.width, accuracy: 0.6, "the field is the whole row")
    XCTAssertFalse(view.attachRestDiscForTesting.usesSystemGlass, "a glyph, not a disc")
    XCTAssertEqual(clip.width, AgentPaletteMetrics.chatComposerControlDiameter, accuracy: 0.6)
    XCTAssertEqual(mic.width, AgentPaletteMetrics.chatComposerControlDiameter, accuracy: 0.6)
    XCTAssertEqual(
      clip.minX, AgentPaletteMetrics.chatComposerControlsTrailingInset, accuracy: 0.6,
      "the + stands alone at the foot's leading edge, as far in as Return is from the right")
    XCTAssertEqual(
      box.width - mic.maxX, AgentPaletteMetrics.chatComposerControlsTrailingInset
        + AgentPaletteMetrics.chatComposerControlDiameter, accuracy: 0.6)
    XCTAssertEqual(
      mic.midY, AgentPaletteMetrics.chatComposerControlsPadding + ComposerControlGroup.glyph / 2,
      accuracy: 0.6, "along the foot")
    XCTAssertEqual(clip.midY, mic.midY, accuracy: 0.6)
    XCTAssertTrue(view.micButtonForTesting.showsMicrophoneGlyphForTesting,
                  "the chat draws the SF Symbol microphone, not the waveform")
  }

  func testTheChatPlaceholderStandsOnTheLineTheTextWillTake() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .opencode,
                               state: .finished, body: "A reply."))
    view.layoutSubtreeIfNeeded()
    let placeholder = view.placeholderBaselineInWindowForTesting

    view.field.setDraft(PromptDraft("j"))
    view.layoutSubtreeIfNeeded()
    guard let typed = view.typedBaselineInWindowForTesting else { return XCTFail("nothing laid out") }

    XCTAssertEqual(placeholder, typed, accuracy: 0.5)
    XCTAssertEqual(view.composerForegroundSizeForTesting.height,
                   AgentPaletteMetrics.chatComposerBoxHeight, accuracy: 0.5,
                   "one line fits the box without growing it")
  }

  func testAnAgentThatReadsNoFilesMovesNothingOnTheRight() {
    func layout(attachments: Bool) -> (text: CGFloat, folder: CGFloat) {
      let view = makeScreenSizedView()
      view.setWorkingDirectory(.forNewPrompt(path: "/tmp/repo", honoursWorkingDirectory: true))
      view.setAcceptsAttachments(attachments)
      view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .opencode,
                                 state: .finished, body: "A reply."))
      view.layoutSubtreeIfNeeded()
      let folder = view.workingDirectoryChipForTesting
      return (view.promptTextFrameForTesting.width, view.convert(folder.bounds, from: folder).minX)
    }
    let with = layout(attachments: true)
    let without = layout(attachments: false)
    XCTAssertEqual(without.text, with.text, accuracy: 0.6, "the words have the box's width either way")
    XCTAssertEqual(
      without.folder, with.folder, accuracy: 0.6,
      "the + is not in the group on the right, so the group stays put without it"
    )
  }

  func testInitialShellKeepsItsFrameAndPlacementForLongAndClearedDrafts() throws {
    let view = hostOffscreen(makeScreenSizedView())
    settlePromptLayout(view)
    view.cancelAllAnimationsAndSettle()
    let resting = view.unifiedSurfaceFrameForTesting
    XCTAssertEqual(resting.size, AgentPaletteMetrics.promptSize)

    view.field.setDraft(PromptDraft(String(repeating: "a long draft that has to wrap over many lines ", count: 24)))
    settlePromptLayout(view)
    view.cancelAllAnimationsAndSettle()
    let grown = view.unifiedSurfaceFrameForTesting
    XCTAssertEqual(grown.maxY, resting.maxY, accuracy: 0.5, "the top is the anchor")
    XCTAssertEqual(grown.minX, resting.minX, accuracy: 0.5)
    XCTAssertEqual(grown.width, resting.width, accuracy: 0.5)
    XCTAssertEqual(grown.height, AgentPaletteMetrics.promptGrownMaximumHeight, accuracy: 0.5)
    XCTAssertEqual(view.unifiedSurfaceCornerForTesting, resting.height / 2, accuracy: 0.5)

    let scroll = try XCTUnwrap(view.field.enclosingScrollView)
    XCTAssertGreaterThan(view.field.bounds.height, scroll.contentView.bounds.height,
                         "the full draft remains a scrollable document")
    let length = (view.field.string as NSString).length
    XCTAssertEqual(view.field.selectedRange(), NSRange(location: length, length: 0))
    view.field.scrollRangeToVisible(NSRange(location: length - 1, length: 1))
    settlePromptLayout(view)
    XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 0, "the last line can be reached")

    view.field.setDraft(PromptDraft())
    settlePromptLayout(view)
    view.cancelAllAnimationsAndSettle()
    XCTAssertEqual(view.unifiedSurfaceFrameForTesting, resting)
  }

  func testTheComposerKeepsOneCornerHoweverTallItGrows() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .opencode,
                               state: .finished, body: "A reply."))
    view.layoutSubtreeIfNeeded()
    let oneLine = view.composerCornerForTesting
    XCTAssertEqual(
      oneLine.height, AgentPaletteMetrics.chatComposerBoxHeight, accuracy: 0.5,
      "in a chat it is always the box, room for one line (2026-10-06)"
    )
    XCTAssertEqual(
      oneLine.radius, AgentPaletteMetrics.chatComposerRestingCornerRadius, accuracy: 0.5,
      "one line: the corner the box can carry as a squircle, which the shell is concentric with"
    )

    for count in [3, 6, 12] {
      view.field.setDraft(PromptDraft(String(repeating: "wrap this composer onto several lines ", count: count)))
      view.layoutSubtreeIfNeeded()
      let grown = view.composerCornerForTesting
      XCTAssertGreaterThan(grown.height, oneLine.height, "the draft actually wrapped")
      XCTAssertEqual(grown.radius, oneLine.radius, accuracy: 0.01,
                     "\(Int(grown.height)) tall: the same corner, not one that rounds with each line")
      XCTAssertEqual(grown.curve, .continuous, "still a squircle")
    }
  }


  func testTheShellKeepsThePromptCapsuleAndWearsTheMocksCornerForExpandedChat() {
    let view = makeScreenSizedView()
    view.layoutSubtreeIfNeeded()
    let resting = view.unifiedSurfaceFrameForTesting
    XCTAssertEqual(
      view.unifiedSurfaceCornerForTesting,
      resting.height / 2,
      accuracy: 0.5,
      "the resting prompt is a stadium, as it has always been"
    )

    view.enterAddressing(.init(
      id: UUID(), title: "Chat", agent: .opencode, state: .finished,
      body: String(repeating: "A long answer that needs several lines.\n", count: 40)
    ))
    view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(view.unifiedSurfaceFrameForTesting.height, resting.height)
    XCTAssertEqual(
      view.unifiedSurfaceCornerForTesting,
      AgentPaletteMetrics.cardCornerRadius,
      accuracy: 0.5,
      "expanded chat is concentric with its composer (2026-10-07), not the mock's 44"
    )
  }

  func testTheShellNeverCarriesAFilterSoTheGlassStaysLive() {
    let view = makeScreenSizedView()
    view.layoutSubtreeIfNeeded()

    XCTAssertNil(view.unifiedSurfaceLayerForTesting?.filters, "the rim stays sharp")
    XCTAssertFalse(view.unifiedSurfaceLayerForTesting?.shouldRasterize ?? true)
    XCTAssertFalse(view.promptCapsuleRendersOffscreenForTesting)
    XCTAssertFalse(view.resultsCapsuleRendersOffscreenForTesting)
  }

  func testShellSpringCanReverseWithoutJumpingAndSettlesAtTheNewTarget() {
    let view = makeView()
    var frames: [CGRect] = []
    let motion = PaletteSurfaceMotion { frames.append($0) }
    let prompt = CGRect(x: 200, y: 400, width: 520, height: 75)
    let chat = CGRect(x: 200, y: 150, width: 520, height: 325)
    motion.move(to: prompt, in: view, animated: false)
    motion.move(to: chat, in: view, animated: true)
    motion.advance(by: 0.08)
    let midway = frames.last!
    XCTAssertGreaterThan(midway.height, prompt.height)
    XCTAssertLessThan(midway.height, chat.height)
    motion.move(to: prompt, in: view, animated: true)
    XCTAssertEqual(frames.last, midway, "retargeting cannot jump to either endpoint")
    motion.advance(by: 0.001)
    XCTAssertLessThan(abs(frames.last!.height - midway.height), 2)
    for _ in 0..<120 { motion.advance(by: 1.0 / 120) }
    XCTAssertEqual(frames.last!.height, prompt.height, accuracy: 0.1)
    motion.settle()
  }

  func testTheShellMorphLandsWithItsContent() {
    let view = makeView()
    var frames: [CGRect] = []
    let motion = PaletteSurfaceMotion { frames.append($0) }
    let pill = CGRect(x: 200, y: 400, width: 520, height: 75)
    let chat = CGRect(x: 200, y: 150, width: 520, height: 475)
    motion.move(to: pill, in: view, animated: false)
    motion.move(to: chat, in: view, animated: true)
    func travelled() -> CGFloat {
      (frames.last!.height - pill.height) / (chat.height - pill.height)
    }

    for _ in 0..<12 { motion.advance(by: 1.0 / 120) }  // 0.1s
    XCTAssertLessThan(travelled(), 0.9, "a morph this size is followed, not cut to")
    for _ in 0..<18 { motion.advance(by: 1.0 / 120) }  // 0.25s
    XCTAssertGreaterThan(travelled(), 0.95, "the shell has landed by the time its content has")
    motion.settle()
  }

  func testUnifiedChatPlacesComposerBelowHistoryInsideOneSurface() {
    let view = makeView()
    view.frame = CGRect(x: 0, y: 0, width: 1440, height: 1000)
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .opencode,
                              state: .finished, body: "A readable answer."))
    view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThanOrEqual(view.previewBandFrameForTesting.minY, view.promptCapsuleFrameForTesting.maxY - 1)
    XCTAssertTrue(view.unifiedSurfaceFrameForTesting.contains(view.promptCapsuleFrameForTesting))
    XCTAssertTrue(view.isComposerVisibleForTesting)
  }

  func testEscapeReturnsToTheChosenRowThenToPrompt() {
    let view = makeView()
    let rows: [BolttyAISessionItem] = [.row("First"), .row("Second")]
    view.setSessions(rows, activeSessionID: nil)
    view.openSwitcher()
    view.enterAddressing(.init(id: rows[1].id, title: "Second", agent: .opencode,
                              state: .finished, body: "Saved reply"))
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertTrue(view.isResultsExpandedForTesting)
    XCTAssertEqual(view.selectedResultIndexForTesting, 1)
    XCTAssertFalse(view.isAddressingForTesting)
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertFalse(view.isResultsExpandedForTesting)
    XCTAssertEqual(view.mode, .prompt)
  }

  func testEscapeLeavesAddressingAtTheInitialPrompt() {
    let view = makeView()
    view.setSessions([.row("session")], activeSessionID: nil)
    var cancelled = false
    view.onCancel = { cancelled = true }

    view.enterAddressing(
      BolttyAISessionPreview(
        id: UUID(),
        title: "fix login",
        agent: .claude,
        state: .running,
        body: "working"
      )
    )
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    )
    XCTAssertFalse(view.isAddressingForTesting)
    XCTAssertFalse(view.isResultsExpandedForTesting)
    XCTAssertFalse(cancelled)
  }

  func testEscapeCollapsesSessionSwitcherBeforeDismissingPalette() {
    let view = makeView()
    view.setSessions([.row("session")], activeSessionID: nil)
    var cancelled = false
    view.onCancel = { cancelled = true }

    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    XCTAssertTrue(view.isResultsExpandedForTesting)

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    )
    XCTAssertFalse(view.isResultsExpandedForTesting)
    XCTAssertFalse(cancelled)

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    )
    XCTAssertTrue(cancelled)
  }

  func testSessionSwitcherUsesOneShellWithoutScalingItsText() throws {
    let view = makeScreenSizedView()
    view.setSessions([.row("one"), .row("two")], activeSessionID: nil)
    view.openSwitcher()
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(view.unifiedSurfaceFrameForTesting.insetBy(dx: -0.5, dy: -0.5).contains(view.resultsCapsuleFrameForTesting), "shell \(view.unifiedSurfaceFrameForTesting), list \(view.resultsCapsuleFrameForTesting)")
    XCTAssertFalse(view.isComposerVisibleForTesting)
    XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(view.resultsCapsuleLayerForTesting).transform))
    XCTAssertNil(view.resultsForegroundLayerForTesting?.filters)
  }

  func testReturningFromSwitcherRestoresPromptSurfaceGeometry() {
    let view = makeScreenSizedView()
    let initial = view.unifiedSurfaceFrameForTesting
    view.setSessions([.row("one"), .row("two")], activeSessionID: nil)
    view.openSwitcher()
    view.closeSwitcher()
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.unifiedSurfaceFrameForTesting, initial)
    XCTAssertTrue(view.isComposerVisibleForTesting)
  }

  func testPreparingTheShellDoesNotScaleTheLiveEditor() throws {
    let view = makeView()
    view.prepareCapsuleForEntrance()
    let layer = try XCTUnwrap(view.promptCapsuleLayerForTesting)
    XCTAssertTrue(CATransform3DIsIdentity(layer.transform))
    XCTAssertEqual(layer.opacity, 1)
  }

  func testThePanelArrivesWholeWithNothingFadingIn() throws {
    let view = makeView()
    view.prepareCapsuleForEntrance()
    view.layoutForPresentation()

    let capsule = try XCTUnwrap(view.promptCapsuleLayerForTesting)
    XCTAssertTrue(CATransform3DIsIdentity(capsule.transform))
    let content = try XCTUnwrap(view.promptForegroundLayerForTesting)
    XCTAssertNil(content.animation(forKey: "surfaceContent"), "the words are there at once")
    XCTAssertEqual(content.opacity, 1)
  }

  func testShiftTabSwapsTheAgentMarkThroughABlurAndLeavesThePlaceholderStill() throws {
    let view = makeView(targets: [.opencode, .claude])
    view.layoutSubtreeIfNeeded()
    let placeholder = view.promptPlaceholderForTesting

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
    )

    let layer = try XCTUnwrap(view.targetSwapLayerForTesting)
    let crossfade = try XCTUnwrap(layer.animation(forKey: kCATransition) as? CATransition)
    XCTAssertEqual(crossfade.type, .fade)
    XCTAssertEqual(crossfade.duration, AgentPaletteMetrics.targetSwapFadeDuration)

    let resolve = try XCTUnwrap(
      layer.animation(forKey: "targetSwapBlur") as? CABasicAnimation
    )
    XCTAssertEqual(resolve.fromValue as? CGFloat, AgentPaletteMetrics.targetSwapBlurRadius)
    XCTAssertEqual(resolve.toValue as? CGFloat, 0)
    XCTAssertEqual(resolve.duration, AgentPaletteMetrics.targetSwapBlurDuration)
    XCTAssertEqual(resolve.preferredFrameRateRange.preferred, 120)
    XCTAssertEqual(try XCTUnwrap(layer.filters as? [CIFilter]).count, 1)

    XCTAssertEqual(view.promptPlaceholderForTesting, placeholder, "precondition: the words stay")
    let still = try XCTUnwrap(view.placeholderLayerForTesting)
    XCTAssertNil(still.animation(forKey: kCATransition), "unchanged words do not crossfade")
    XCTAssertNil(still.animation(forKey: "targetSwapBlur"), "unchanged words do not blur")
    XCTAssertNil(still.filters)

    XCTAssertNil(view.promptForegroundLayerForTesting?.filters)
    XCTAssertFalse(view.promptCapsuleRendersOffscreenForTesting)
  }

  func testATypedPromptIsFollowedByTheKeysThatActOnIt() {
    let view = makeView(targets: [.opencode, .claude])
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.trailingHintForTesting, [], "an empty field keeps its placeholder")

    view.field.insertPlainText("fix the tests")
    XCTAssertEqual(view.trailingHintForTesting, ["Ask OpenCode ↵", "Claude ⇧⇥"])
    XCTAssertNotNil(view.field.trailingHintFrame, "a short prompt leaves it room")

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
    )
    XCTAssertEqual(view.trailingHintForTesting, ["Ask Claude ↵", "OpenCode ⇧⇥"])

    var leftOut = false
    for _ in 0..<200 where !leftOut {
      view.field.insertPlainText("w")
      leftOut = view.field.trailingHintFrame == nil
    }
    XCTAssertTrue(leftOut, "no room on the line: left out, not wrapped")
  }

  func testTheKeysWaitForTheTypingToRestAndLeaveAtTheNextKeystroke() {
    let view = hostOffscreen(makeScreenSizedView())
    view.setAgentChoices([.claude, .codex], planned: .claude)
    view.field.insertPlainText("fix")
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(view.field.isTrailingHintShown, "not while the sentence is being written")
    XCTAssertTrue(view.field.isTrailingHintPendingForTesting)
    XCTAssertEqual(view.field.trailingHintDelay, 1)

    view.field.restTrailingHintForTesting()
    XCTAssertTrue(view.field.isTrailingHintShown)

    view.field.insertPlainText(" the tests")
    XCTAssertFalse(view.field.isTrailingHintShown, "a keystroke takes them away at once")
    XCTAssertEqual(view.field.trailingHintViewForTesting.alphaValue, 0)
    XCTAssertTrue(view.field.isTrailingHintPendingForTesting, "and the rest starts over")
  }

  func testTheKeysAreCapsulesBesideTheLineTwoPointsUnderTheText() throws {
    let view = hostOffscreen(makeScreenSizedView())
    view.setAgentChoices([.claude, .codex], planned: .claude)
    view.field.insertPlainText("fix")
    view.field.restTrailingHintForTesting()
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()

    let hint = view.field.trailingHintViewForTesting
    XCTAssertEqual(hint.font.pointSize, ((AgentPaletteMetrics.promptFontSize - 2) * 0.8).rounded())
    XCTAssertEqual(hint.capsuleFrames.count, 2)
    for (capsule, keycap) in zip(hint.capsuleFrames, hint.keycapFrames) {
      XCTAssertTrue(capsule.contains(keycap), "the key's keycap stands in its capsule")
      XCTAssertEqual(capsule.maxX - keycap.maxX, keycap.minY - capsule.minY, accuracy: 0.5)
    }
    let scroll = try XCTUnwrap(view.field.enclosingScrollView)
    XCTAssertTrue(hint.superview === scroll.superview, "beside the scroll view, never cut to it")

    let expected = try XCTUnwrap(view.field.trailingHintFrame)
    let placed = view.field.convert(hint.frame, from: hint.superview)
    XCTAssertEqual(placed.minX, expected.minX, accuracy: 0.5)
    XCTAssertEqual(placed.minY, expected.minY, accuracy: 0.5)
  }

  func testWithOneAgentTheHintNamesOnlyReturn() {
    let view = makeView(targets: [.codex])
    view.field.insertPlainText("hi")
    XCTAssertEqual(view.trailingHintForTesting, ["Ask Codex ↵"])
  }

  func testARunningChatSaysReturnQueuesAndCommandPeriodStops() {
    let view = makeView()
    let messages = [
      ConversationMessage(id: "u", role: .user, createdAt: Date(),
                          parts: [.text(TextPart(id: "ut", kind: .text, text: "Rename"))]),
      ConversationMessage(id: "a", role: .agent, createdAt: Date(),
                          parts: [.text(TextPart(id: "at", kind: .text, text: "On it.\n\n"))]),
    ]
    var running = BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .codex, state: .running, body: "", messages: messages)
    running.canStop = true
    view.enterAddressing(running)
    view.field.insertPlainText("and the docs")
    XCTAssertEqual(view.trailingHintForTesting, ["Queue ↵", "Stop ⌘."])

    view.updateAddressing(.init(
      id: running.id, title: "Chat", agent: .codex, state: .finished, body: "Done", messages: messages))
    XCTAssertEqual(view.trailingHintForTesting, [], "an idle chat's Send button says it already")
  }

  func testCommandReturnAddsToTheRunningTurnAndTheHintSaysSo() throws {
    let view = makeView()
    var steered: [String] = []
    view.onSubmitSteering = { steered.append($0.typedText) }
    let commandReturn = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
      isARepeat: false, keyCode: 0x24  // kVK_Return
    ))
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .codex, state: .finished, body: "done"))
    view.field.insertPlainText("and the docs")
    XCTAssertFalse(view.field.performKeyEquivalent(with: commandReturn), "nothing running: declined")

    var running = BolttyAISessionPreview(id: UUID(), title: "Chat", agent: .codex, state: .running, body: "")
    running.canStop = true
    running.canSteer = true
    view.enterAddressing(running)
    if view.field.draft.typedText.isEmpty { view.field.insertPlainText("and the docs") }
    XCTAssertEqual(view.trailingHintForTesting, ["Queue ↵", "Add now ⌘↵", "Stop ⌘."])
    XCTAssertTrue(view.field.performKeyEquivalent(with: commandReturn))
    XCTAssertEqual(steered, ["and the docs"])

    running.canSteer = false
    view.updateAddressing(running)
    XCTAssertEqual(view.trailingHintForTesting, ["Queue ↵", "Stop ⌘."], "Grok: no ⌘↵ to offer")
  }

  func testTheChatsGapsToItsShellAreOneNumber() throws {
    let inset = AgentPaletteMetrics.shellContentInset
    XCTAssertEqual(inset, 12)
    XCTAssertEqual(AgentPaletteMetrics.cardCornerRadius,
                   AgentPaletteMetrics.chatComposerRestingCornerRadius + inset)
    let corner = AgentPaletteMetrics.cardCornerRadius
    let radius = AgentPaletteMetrics.previewCloseDiameter / 2
    let disc = AgentPaletteMetrics.previewCloseInset + radius
    let fromArc = corner - ((corner - disc) * 2.squareRoot() + radius)
    XCTAssertEqual(fromArc, inset, accuracy: 0.5)

    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .codex, state: .finished, body: "done"))
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()
    let shell = view.unifiedSurfaceFrameForTesting
    let composer = view.promptCapsuleFrameForTesting
    XCTAssertEqual(composer.minX - shell.minX, inset, accuracy: 0.5)
    XCTAssertEqual(shell.maxX - composer.maxX, inset, accuracy: 0.5)
    XCTAssertEqual(composer.minY - shell.minY, inset, accuracy: 0.5)
  }

  func testSwitcherKeepsThePromptHorizontalAnchor() {
    let view = makeScreenSizedView()
    let center = view.unifiedSurfaceFrameForTesting.midX
    view.setSessions([.row("one"), .row("two")], activeSessionID: nil)
    view.openSwitcher()
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.unifiedSurfaceFrameForTesting.midX, center, accuracy: 0.5)
  }

  func testSwitcherCardIsNeverRenderedOffscreenBecauseItHostsLiveGlass() {
    let view = makeView()
    view.setSessions([.row("one")], activeSessionID: nil)

    XCTAssertFalse(view.resultsCapsuleRendersOffscreenForTesting)
    view.expandResultsForTesting()
    XCTAssertFalse(
      view.resultsCapsuleRendersOffscreenForTesting,
      "the entrance must not push the card through an offscreen pass"
    )
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(view.resultsCapsuleRendersOffscreenForTesting)
  }

  func testCollapsingTheSwitcherTearsDownTheEntrance() throws {
    let view = makeView()
    view.setSessions([.row("one")], activeSessionID: nil)
    view.expandResultsForTesting()

    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))

    let layer = try XCTUnwrap(view.resultsCapsuleLayerForTesting)
    XCTAssertNil(view.resultsForegroundLayerForTesting?.filters)
    XCTAssertNil(layer.animation(forKey: "resultsAppearScale"))
    XCTAssertTrue(CATransform3DIsIdentity(layer.transform))
    XCTAssertFalse(view.resultsCapsuleRendersOffscreenForTesting)
  }

  func testClosingTheSwitcherNeverResizesThePanelWhileTheCardIsStillVisible() {
    let view = makeView()
    view.setSessions([.row("one")], activeSessionID: nil)
    view.expandResultsForTesting()
    view.layoutSubtreeIfNeeded()
    let expandedHeight = view.fittingSize.height

    var shrankUnderAVisibleCard = false
    view.onContentSizeChange = { [weak view] in
      guard let view, view.isResultsCardVisibleForTesting else { return }
      view.layoutSubtreeIfNeeded()
      if view.fittingSize.height < expandedHeight - 0.5 {
        shrankUnderAVisibleCard = true
      }
    }

    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))

    let settled = expectation(description: "collapse settles")
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Motion.standard + 0.2
    ) {
      settled.fulfill()
    }
    wait(for: [settled], timeout: 2)

    XCTAssertFalse(shrankUnderAVisibleCard)
    XCTAssertFalse(view.isResultsCardVisibleForTesting)
    view.layoutSubtreeIfNeeded()
    XCTAssertLessThan(view.fittingSize.height, expandedHeight)
  }

  func testPreparingForPresentationGivesTheHeightBackImmediately() {
    let view = makeView()
    let collapsedHeight = view.fittingSize.height

    view.setSessions([.row("one")], activeSessionID: nil)
    view.expandResultsForTesting()
    view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(view.fittingSize.height, collapsedHeight)

    view.prepareForPresentation()
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.fittingSize.height, collapsedHeight, accuracy: 0.5)
  }

  func testExpandingPublishesTheTallerFittingSizeBeforeTheCardIsVisible() {
    let view = makeView()
    view.setSessions([.row("me@m1:~")], activeSessionID: nil)
    let collapsed = view.fittingSize.height
    var heightWhenNotified: CGFloat = 0
    var cardVisibleWhenNotified = false
    view.onContentSizeChange = { [weak view] in
      heightWhenNotified = view?.fittingSize.height ?? 0
      cardVisibleWhenNotified = view?.isResultsCardVisibleForTesting ?? false
    }

    view.expandResultsForTesting()

    XCTAssertGreaterThan(heightWhenNotified, collapsed + 40)
    XCTAssertFalse(
      cardVisibleWhenNotified,
      "growing the clip rect must happen before the card can paint into it"
    )
  }

  func testExpandedPanelReservesRoomForTheCardShadowToFallOff() {
    let view = makeScreenSizedView()
    view.topReserve = 24

    view.setSessions([.row("one")], activeSessionID: nil)
    view.expandResultsForTesting()
    view.layoutSubtreeIfNeeded()
    view.cancelAllAnimationsAndSettle()

    let shell = view.unifiedSurfaceFrameForTesting
    XCTAssertEqual(shell.height, AgentPaletteMetrics.historySurfaceHeight,
      accuracy: 0.5, "one row opens the same complete history shell")
    XCTAssertTrue(view.bounds.contains(shell.insetBy(
      dx: -AgentPaletteMetrics.resultsShadowBleed,
      dy: -AgentPaletteMetrics.resultsShadowBleed)),
      "the full history shell leaves room for its shadow inside the screen panel")
    XCTAssertGreaterThanOrEqual(
      AgentPaletteMetrics.resultsShadowBleed,
      PaletteGlassHost.floatingShadowRadius * 2,
      "the shadow reaches roughly its radius in every direction"
    )
  }

  func testTheFirstScreenWearsItsRampOnFirstOpenAndAfterReturningFromChat() {
    let view = makeView()

    XCTAssertTrue(view.surfaceUsesDirectionalGlassOverlayForTesting,
                  "the first screen's shell wears the prompt's ramp")
    XCTAssertFalse(view.usesDirectionalGlassOverlayForTesting,
                   "the composer is the bare glass")

    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .opencode,
      state: .finished, body: "Done."))
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(view.surfaceUsesDirectionalGlassOverlayForTesting,
                   "an open chat's shell is the bare glass")
    XCTAssertFalse(view.usesDirectionalGlassOverlayForTesting,
                   "and so is the chat's composer")

    view.leaveAddressing(animated: false)
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(view.surfaceUsesDirectionalGlassOverlayForTesting,
                  "back on the first screen, the ramp is back on the shell")
    XCTAssertFalse(view.usesDirectionalGlassOverlayForTesting,
                   "and still not on the composer")
  }

  @available(macOS 26.0, *)
  func testTheComposerPutsItsContentInsideTheGlass() {
    let view = makeView()

    XCTAssertTrue(view.composerHostsContentInSystemGlassForTesting)
  }

  @available(macOS 26.0, *)
  func testTheRoundControlsStandOnSystemGlass() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .codex,
                               state: .finished, body: "Answer."))
    view.layoutSubtreeIfNeeded()

    XCTAssertFalse(view.voiceOrbUsesSystemGlassForTesting)
    XCTAssertTrue(view.previewCardForTesting.closeButtonUsesSystemGlassForTesting)
  }

  func testTheCloseControlLeavesTheChat() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .codex,
                               state: .finished, body: "Answer."))
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(view.previewCardForTesting.isCloseVisibleForTesting)

    view.previewCardForTesting.onClose?()

    XCTAssertNil(view.addressedPreviewForTesting)
  }

  func testBolttyAISurfacesShareOneBackground() {
    let view = makeScreenSizedView()
    XCTAssertFalse(view.usesSharedSurfaceStyleForTesting,
                   "the first screen is the one exception")
    XCTAssertTrue(view.surfaceUsesDirectionalGlassOverlayForTesting,
                  "it is the shell that differs: it wears the ramp")
    XCTAssertFalse(view.usesDirectionalGlassOverlayForTesting,
                   "and the composer does not")

    view.setSessions([.row("one")], activeSessionID: nil)
    view.expandResultsForTesting()
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(view.isResultsExpandedForTesting, "precondition: the history is open")
    XCTAssertTrue(view.usesSharedSurfaceStyleForTesting, "the history")

    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .opencode,
                               state: .finished, body: "Done."))
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(view.usesSharedSurfaceStyleForTesting, "an open chat and its composer")

    let listening = hostOffscreen(makeView(targets: [.claude]))
    listening.prepareForPresentation()
    listening.layoutSubtreeIfNeeded()
    listening.setVoiceListening(true)
    listening.layoutSubtreeIfNeeded()
    XCTAssertTrue(listening.isCompactListeningForTesting, "precondition: the listening orb")
    XCTAssertTrue(listening.usesSharedSurfaceStyleForTesting, "the listening orb")
    listening.setVoiceListening(false)
  }

  func testPromptIncludesMicrophoneControl() {
    let view = makeView()

    XCTAssertFalse(view.micButtonForTesting.isHidden)
    XCTAssertEqual(view.micButtonForTesting.accessibilityIdentifier(), "boltty.ask.mic")
  }

  func testVoiceListeningLeavesTheDiscAlone() {
    let view = makeView()
    let orb = view.micButtonForTesting
    view.setVoiceListening(true)

    XCTAssertTrue(view.isVoiceListeningForTesting)
    XCTAssertTrue(orb.isListeningForTesting)
    XCTAssertNotEqual(orb.contentTintColor, NSColor.systemRed)

    view.setVoiceListening(false)
    XCTAssertFalse(orb.isListeningForTesting)
    XCTAssertEqual(orb.contentTintColor, ComposerControlGroup.restingInk,
                   "back in the control group's resting ink")
  }

  func testStoppingDictationKeepsWhatWasAlreadyTyped() {
    let view = makeView()
    view.field.setDraft(PromptDraft("fix the "))

    view.setVoiceListening(true)
    view.applyVoiceTranscript("login bug")
    XCTAssertEqual(view.field.string, "fix the login bug")

    view.setVoiceListening(false)
    XCTAssertEqual(view.field.string, "fix the login bug")

    view.applyVoiceTranscript("login bug in auth")
    XCTAssertEqual(view.field.string, "fix the login bug in auth")
  }

  func testAnEmptyFinalTranscriptDoesNotClearTheTypedPrompt() {
    let view = makeView()
    view.field.setDraft(PromptDraft("ship it"))
    view.setVoiceListening(true)
    view.setVoiceListening(false)

    view.applyVoiceTranscript("")

    XCTAssertEqual(view.field.string, "ship it")
  }

  func testBarsContrastWithWhicheverDiscTheySitOn() {
    let orb = makeView().micButtonForTesting
    orb.appearance = NSAppearance(named: .darkAqua)
    orb.layout()

    func brightnesses() -> [CGFloat] {
      orb.barColorsForTesting.compactMap { color -> CGFloat? in
        NSColor(cgColor: color)?.usingColorSpace(.sRGB)?.brightnessComponent
      }
    }

    let resting = brightnesses()
    XCTAssertEqual(resting.count, AgentPaletteMetrics.voiceOrbBarCount)
    for brightness in resting {
      XCTAssertGreaterThan(brightness, 0.7, "light on a dark disc")
    }

    orb.setListening(true)
    orb.layout()
    for brightness in brightnesses() {
      XCTAssertGreaterThan(brightness, 0.7, "the disc does not change, so neither do the bars")
    }
  }

  func testRecordingKeepsTheDiscUntilHoverRevealsThePill() {
    let view = hostOffscreen(makeView())
    XCTAssertFalse(view.isShowingRecordingControlsForTesting)

    view.setVoiceListening(true)
    XCTAssertFalse(view.isShowingRecordingControlsForTesting)
    XCTAssertFalse(view.micButtonForTesting.isHidden)
    XCTAssertTrue(view.micButtonForTesting.isListeningForTesting)

    view.setRecordingHoverForTesting(true)
    XCTAssertTrue(view.isShowingRecordingControlsForTesting)
    XCTAssertTrue(view.micButtonForTesting.isHidden)

    view.setRecordingHoverForTesting(false)
    XCTAssertFalse(view.isShowingRecordingControlsForTesting)
    XCTAssertFalse(view.micButtonForTesting.isHidden)

    view.setVoiceListening(false)
    XCTAssertFalse(view.isShowingRecordingControlsForTesting)
    XCTAssertFalse(view.micButtonForTesting.isHidden)
  }

  func testCancellingDictationKeepsWhatWasTypedBeforeIt() {
    let view = makeView()
    view.field.setDraft(PromptDraft("fix the "))

    view.setVoiceListening(true)
    view.applyVoiceTranscript("login bug in auth")
    XCTAssertEqual(view.field.string, "fix the login bug in auth")

    view.discardVoiceTranscript()

    XCTAssertEqual(view.field.string, "fix the ")
  }

  func testSilenceDrawsTheRestingWaveformProfile() throws {
    let orb = makeView().micButtonForTesting
    let heights = orb.barHeightsForTesting

    XCTAssertEqual(heights.count, 6)
    XCTAssertEqual(heights.count, AgentPaletteMetrics.voiceOrbBarCount)

    let tallest = try XCTUnwrap(heights.max())
    XCTAssertEqual(heights.firstIndex(of: tallest), 2, "the symbol peaks at bar 3 of 6")
    XCTAssertEqual(tallest, AgentPaletteMetrics.voiceOrbBarHeight, accuracy: 0.01)

    let shortest = try XCTUnwrap(heights.min())
    XCTAssertEqual(heights.firstIndex(of: shortest), 0)
    XCTAssertGreaterThan(heights[4], heights[1])
  }

  func testBarsMoveWithTheVoiceAndNotInUnison() {
    let view = makeView()
    let orb = view.micButtonForTesting
    view.setVoiceListening(true)
    let resting = orb.barHeightsForTesting

    for _ in 0..<20 { view.applyVoiceLevel(1) }
    let speaking = orb.barHeightsForTesting

    XCTAssertNotEqual(resting, speaking, "the bars must respond to level")
    let deltas = zip(resting, speaking).map { $1 - $0 }
    XCTAssertGreaterThan(Set(deltas.map { ($0 * 100).rounded() }).count, 1)
  }

  func testTheVoiceControlRestoresItsInitialAppearanceAfterRecordingAndChat() throws {
    let view = makeView()
    let orb = view.micButtonForTesting
    func assertAtRest(_ moment: String) {
      XCTAssertFalse(orb.usesSystemGlassForTesting, moment)
      XCTAssertTrue(orb.showsMicrophoneGlyphForTesting, moment)
      XCTAssertFalse(orb.drawsBarsForTesting, moment)
      XCTAssertEqual(orb.restingTint, ComposerControlGroup.restingInk, moment)
    }
    assertAtRest("first open")
    XCTAssertEqual(try XCTUnwrap(orb.layer?.backgroundColor).alpha, 0)

    view.setVoiceListening(true)
    XCTAssertTrue(orb.usesSystemGlassForTesting)
    XCTAssertTrue(orb.drawsBarsForTesting, "listening draws the bars on glass")
    view.setVoiceListening(false)
    assertAtRest("after a recording")

    view.enterAddressing(.init(id: UUID(), title: "Agent", agent: .claude, state: nil, body: "done"))
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(orb.usesSystemGlassForTesting)
    view.setVoiceListening(true)
    XCTAssertTrue(orb.usesSystemGlassForTesting)
    view.setVoiceListening(false)
    view.leaveAddressing(animated: false)
    view.layoutSubtreeIfNeeded()
    assertAtRest("after a chat")
  }

  func testTheLevelFallsSlowerThanItRises() {
    let view = makeView()
    let orb = view.micButtonForTesting
    view.setVoiceListening(true)

    view.applyVoiceLevel(1)
    let afterOneLoudReading = orb.smoothedLevelForTesting
    view.applyVoiceLevel(0)
    let afterOneSilentReading = orb.smoothedLevelForTesting

    XCTAssertGreaterThan(afterOneLoudReading, 0.4, "a consonant should light it at once")
    XCTAssertGreaterThan(
      afterOneSilentReading,
      afterOneLoudReading * 0.5,
      "one quiet buffer must not extinguish it"
    )
  }

  func testListeningLightsTheShellRimInTheAgentsColours() {
    let view = hostOffscreen(makeView(targets: [.claude]))
    view.prepareForPresentation()
    view.layoutSubtreeIfNeeded()

    let glow = view.voiceGlowForTesting
    XCTAssertFalse(glow.isListeningForTesting)

    view.setVoiceListening(true)
    view.layoutSubtreeIfNeeded()

    XCTAssertTrue(glow.isListeningForTesting)
    XCTAssertFalse(glow.isHidden)
    XCTAssertEqual(glow.rayColorsForTesting.count, VoiceGlowRenderer.colorCount)
    XCTAssertTrue(view.voiceGlowIsUnderTheGlassForTesting, "the glass bends and frosts it")
    XCTAssertTrue(glow.avoidsOffscreenPassForTesting)
    XCTAssertEqual(glow.paletteIDForTesting, MascotPalette.face(for: .claude).id)
    XCTAssertNil(
      glow.hitTest(NSPoint(x: glow.bounds.midX, y: glow.bounds.minY + 4)),
      "the rim is not a control"
    )

    view.setVoiceListening(false)
    XCTAssertFalse(glow.isListeningForTesting)
  }

  func testTheRimWearsTheSameFaceAsTheMascotWhateverTheAgent() {
    let view = hostOffscreen(makeView(targets: [.opencode, .codex]))
    view.prepareForPresentation()
    view.setVoiceListening(true)

    XCTAssertEqual(
      view.voiceGlowForTesting.paletteIDForTesting,
      view.mascotPaletteIDForTesting
    )
    XCTAssertEqual(view.voiceGlowForTesting.paletteIDForTesting, MascotPalette.face(for: .opencode).id)

    view.render(agent: .codex, animated: false)
    XCTAssertEqual(
      view.voiceGlowForTesting.paletteIDForTesting,
      view.mascotPaletteIDForTesting
    )
    XCTAssertEqual(view.voiceGlowForTesting.paletteIDForTesting, MascotPalette.face(for: .codex).id)
    view.setVoiceListening(false)
  }

  func testTheMicrophoneCollapsesThePromptToTheListeningOrb() {
    let view = hostOffscreen(makeView(targets: [.claude]))
    view.prepareForPresentation()
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(view.isCompactListeningForTesting)

    view.setVoiceListening(true)
    view.layoutSubtreeIfNeeded()

    XCTAssertTrue(view.isCompactListeningForTesting)
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()
    let orb = view.unifiedSurfaceFrameForTesting
    XCTAssertEqual(orb.width, AgentPaletteMetrics.listeningOrbDiameter, accuracy: 0.5)
    XCTAssertEqual(orb.height, orb.width, accuracy: 0.5, "a ball, not a capsule")
    XCTAssertEqual(view.unifiedSurfaceCornerForTesting, orb.height / 2, accuracy: 1)
    XCTAssertEqual(
      view.voiceGlowForTesting.uniformsForTesting.orb, 1, accuracy: 0.01,
      "the orb's gradient fills the shell the take collapsed"
    )
    XCTAssertEqual(view.listeningWordsForTesting, "", "silence is the orb, with no words in it")

    view.setVoiceListening(false)
  }

  func testAnExistingDraftStillCollapsesToTheCapsule() {
    let view = hostOffscreen(makeView(targets: [.claude]))
    view.prepareForPresentation()
    view.field.setDraft(PromptDraft("already typed"))
    view.setVoiceListening(true)
    view.layoutSubtreeIfNeeded()

    XCTAssertTrue(view.isCompactListeningForTesting)
    XCTAssertTrue(view.voiceGlowForTesting.isListeningForTesting, "the light still lights")

    view.setVoiceListening(false)
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(view.isCompactListeningForTesting)
    XCTAssertEqual(view.field.string, "already typed")
  }

  func testTheGlowIsClippedToTheShell() {
    let view = hostOffscreen(makeView())
    view.setVoiceListening(true)
    view.layoutSubtreeIfNeeded()

    let surface = view.unifiedSurfaceFrameForTesting
    let glow = view.voiceGlowForTesting.frame
    XCTAssertEqual(glow.minX, surface.minX, accuracy: 0.5)
    XCTAssertEqual(glow.maxX, surface.maxX, accuracy: 0.5)
    XCTAssertEqual(glow.minY, surface.minY, accuracy: 0.5)
    XCTAssertEqual(glow.maxY, surface.maxY, accuracy: 0.5)
    view.setVoiceListening(false)
  }

  func testVoiceLevelDrivesTheShellRim() {
    let view = hostOffscreen(makeView())
    view.setVoiceListening(true)
    let idle = view.voiceGlowForTesting.smoothedLevelForTesting
    for _ in 0..<20 { view.applyVoiceLevel(1) }
    XCTAssertGreaterThan(view.voiceGlowForTesting.smoothedLevelForTesting, idle)
    view.setVoiceListening(false)
  }

  func testVoiceTranscriptFillsPromptAndHidesHint() {
    let view = makeView()
    view.applyVoiceTranscript("ship the palette polish")

    XCTAssertEqual(view.field.string, "ship the palette polish")
  }

  func testPromptKeepsTheWhiteCaretAcrossRepaints() {
    let view = makeView()
    let panel = KeyablePanel(
      contentRect: CGRect(origin: .zero, size: AgentPaletteMetrics.panelSize()),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = view
    panel.makeKeyAndOrderFront(nil)
    defer { panel.orderOut(nil) }

    XCTAssertTrue(view.focusField())
    let caret = view.field.caretViewForTesting
    XCTAssertEqual(caret.color, AgentPaletteView.promptTypingTextColor)
    XCTAssertEqual(view.field.insertionPointColor, .clear, "AppKit's caret is not drawn")

    view.openSwitcher()
    XCTAssertEqual(caret.color, AgentPaletteView.promptTypingTextColor)

    view.cancelAllAnimationsAndSettle()
    XCTAssertEqual(caret.color, AgentPaletteView.promptTypingTextColor)
    XCTAssertEqual(view.field.insertionPointColor, .clear)
  }

  func testDismissalIncludesAllPartsOfTheUnifiedSurface() {
    let view = makeView()
    XCTAssertNotNil(view.presentationLayer)
    XCTAssertEqual(view.presentationLayer, view.layer)
  }

  func testPresentationPreparationDoesNotMoveTheScreenSizedRoot() throws {
    let view = makeView()
    let before = view.layer?.position
    let layer = try XCTUnwrap(view.preparePresentationLayer())
    XCTAssertEqual(layer.position, before)
    XCTAssertTrue(CATransform3DIsIdentity(layer.transform))
  }

  func testPromptFieldUsesAppFontInsteadOfMonospacedSystemFont() {
    let view = makeView()
    XCTAssertEqual(view.field.font?.pointSize, AgentPaletteMetrics.promptFontSize)
    let name = view.field.font?.fontName ?? ""
    XCTAssertTrue(
      name.localizedCaseInsensitiveContains("rounded"),
      "typed text must be the rounded face, got \(name)"
    )
    XCTAssertNotEqual(
      view.field.font?.fontName,
      NSFont.monospacedSystemFont(
        ofSize: AgentPaletteMetrics.promptFontSize,
        weight: .regular
      ).fontName
    )
  }

  func testTheSteadyStatePanelNeverNamesTheAgent() throws {
    let view = makeView()
    let id = UUID()
    let answered = ConversationMessage(
      id: "a", role: .agent, createdAt: Date(), completedAt: Date(),
      parts: [.text(TextPart(id: "at", kind: .text, text: "Готово."))]
    )
    let preview = BolttyAISessionPreview(
      id: id, title: "Optimize this video", agent: .opencode, state: .running,
      body: "Готово.", messages: [answered], canStop: true, stopIsAbrupt: true
    )
    view.enterAddressing(preview)
    view.layoutSubtreeIfNeeded()

    let forbidden = AgentId.adapterCases.flatMap { [$0.displayName, $0.shortDisplayName] }
    for text in [view.promptPlaceholderForTesting, view.stopTooltipForTesting ?? ""] {
      for name in forbidden {
        XCTAssertFalse(text.contains(name), "\"\(text)\" names \(name)")
      }
    }
    XCTAssertEqual(view.promptPlaceholderForTesting, AgentPaletteView.chatComposerPlaceholder)
    XCTAssertTrue(view.stopTooltipForTesting?.contains("this turn is lost") == true)
  }

  func testPromptUsesWhiteTypingTextAndFullyOpaqueIcon() throws {
    let view = makeView()
    view.render(agent: .claude, animated: false)

    XCTAssertEqual(view.field.textColor, AgentPaletteView.promptTypingTextColor)
    let white = view.field.textColor?.usingColorSpace(.sRGB)
    XCTAssertEqual(Double(white?.redComponent ?? -1), 1, accuracy: 0.001)
    XCTAssertEqual(Double(white?.greenComponent ?? -1), 1, accuracy: 0.001)
    XCTAssertEqual(Double(white?.blueComponent ?? -1), 1, accuracy: 0.001)

    let icon = try XCTUnwrap(
      view.subviews
        .flatMap { Self.descendants(of: $0) }
        .compactMap { $0 as? NSImageView }
        .first { $0.accessibilityLabel() == "Boltty" }
    )
    XCTAssertEqual(icon.alphaValue, 1, accuracy: 0.001)
    XCTAssertEqual(icon.contentTintColor, AgentPaletteView.promptIconTintColor)
  }

  // MARK: - Prompt vs search

  func testALeadingSlashIsJustText() {
    let view = makeView()
    view.setSessions([.row("research", .claude)], activeSessionID: nil)
    var submitted: PromptDraft?
    view.onSubmit = { submitted = $0 }
    view.field.setDraft(PromptDraft("/research the tests"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))

    XCTAssertEqual(view.mode, .prompt)
    XCTAssertFalse(view.isResultsExpandedForTesting)
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertEqual(submitted?.typedText, "/research the tests")
  }

  func testPlainTextStaysAPromptAndEnterLaunches() {
    let view = makeView()
    view.setSessions([.row("claude", .claude)], activeSessionID: nil)
    var submitted: PromptDraft?
    view.onSubmit = { submitted = $0 }

    view.field.setDraft(PromptDraft("fix the login bug"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))
    XCTAssertEqual(view.mode, .prompt)

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    )
    XCTAssertEqual(submitted?.typedText, "fix the login bug")
  }

  func testShiftEnterInsertsANewlineInsteadOfSubmitting() {
    let view = makeView()
    var submitted = false
    view.onSubmit = { _ in submitted = true }
    view.field.setDraft(PromptDraft("first line"))
    view.field.setSelectedRange(NSRange(location: view.field.string.utf16.count, length: 0))
    view.commandModifierFlagsForTesting = .shift

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    )
    XCTAssertEqual(view.field.string, "first line\n")
    XCTAssertFalse(submitted)
  }

  func testOptionEnterInsertsANewlineInsteadOfSubmitting() {
    let view = makeView()
    var submitted = false
    view.onSubmit = { _ in submitted = true }
    view.field.setDraft(PromptDraft("first line"))
    view.field.setSelectedRange(NSRange(location: view.field.string.utf16.count, length: 0))
    view.commandModifierFlagsForTesting = .option

    XCTAssertTrue(
      view.textView(
        view.field,
        doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
      )
    )
    XCTAssertEqual(view.field.string, "first line\n")
    XCTAssertFalse(submitted)
  }

  func testSlashInsideAPromptDoesNotTriggerSearch() {
    let view = makeView()
    view.field.setDraft(PromptDraft("look at /Users/me/project"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))

    XCTAssertEqual(view.mode, .prompt)
  }

  func testBackspacingPastTheLastCharacterOfASearchLeavesIt() {
    let view = makeView()
    view.setSessions([.row("claude", .claude)], activeSessionID: nil)
    view.openSwitcher()
    view.field.setDraft(PromptDraft("h"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))
    XCTAssertEqual(view.mode, .search)

    view.field.setDraft(PromptDraft())
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
    )

    XCTAssertEqual(view.mode, .prompt)
    XCTAssertFalse(view.isResultsExpandedForTesting)
  }

  func testDownArrowOpensTheSwitcherWithoutTypingAnything() {
    let view = makeView()
    view.setSessions([.row("claude", .claude)], activeSessionID: nil)

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertEqual(view.mode, .picking)
    XCTAssertFalse(view.fieldIsQuery)
    XCTAssertTrue(view.isResultsExpandedForTesting)
    XCTAssertEqual(view.field.string, "")
  }

  func testUpArrowFromTheTopRowReturnsToThePromptAndCanReopen() {
    let view = makeView()
    view.setSessions([.row("claude", .claude)], activeSessionID: nil)

    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    XCTAssertEqual(view.selectedResultIndexForTesting, 0)

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveUp(_:)))
    )
    XCTAssertEqual(view.mode, .prompt)
    XCTAssertFalse(view.isResultsExpandedForTesting)

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertEqual(view.mode, .picking)
    XCTAssertTrue(view.isResultsExpandedForTesting)
  }

  func testVoiceTranscriptAppendsAfterTypedText() {
    let view = makeView()
    view.field.setDraft(PromptDraft("Fix "))
    view.setVoiceListening(true)
    view.applyVoiceTranscript("the login bug")

    XCTAssertEqual(view.field.draft.typedText, "Fix the login bug")
  }

  func testInstallHintsOpenWithoutADownArrowInsideTheFullHistoryShell() {
    let view = makeScreenSizedView(targets: [])
    view.setInstallHints(AgentId.discoverableCases)
    view.revealInstallHintsIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.cancelAllAnimationsAndSettle()

    XCTAssertTrue(view.isResultsExpandedForTesting)
    XCTAssertEqual(view.unifiedSurfaceFrameForTesting.width, AgentPaletteMetrics.promptSize.width, accuracy: 0.5)
    XCTAssertEqual(view.unifiedSurfaceFrameForTesting.height,
      AgentPaletteMetrics.historySurfaceHeight, accuracy: 0.5)
    XCTAssertTrue(view.bounds.contains(view.unifiedSurfaceFrameForTesting))
    XCTAssertTrue(view.resultsStackForTesting.arrangedSubviews.contains { $0 is BolttyAINoAgentsView })
  }

  func testTheNoAgentsCardOffersAWayIntoSettings() throws {
    let view = makeView(targets: [])
    var openedSettings = 0
    view.onOpenSettings = { openedSettings += 1 }
    view.setInstallHints(AgentId.discoverableCases)
    view.revealInstallHintsIfNeeded()
    view.layoutSubtreeIfNeeded()

    let card = try XCTUnwrap(
      view.resultsStackForTesting.arrangedSubviews
        .compactMap { $0 as? BolttyAINoAgentsView }
        .first,
      "the no-agents card is what the palette shows when nothing can be driven"
    )
    XCTAssertEqual(card.buttonTitleForTesting, "Open Settings")

    card.pressOpenSettingsForTesting()
    XCTAssertEqual(openedSettings, 1)
  }

  func testUpArrowOutOfSearchKeepsATypedQueryAsPromptText() {
    let view = makeView()
    view.setSessions([.row("claude", .claude)], activeSessionID: nil)

    view.openSwitcher()
    view.field.setDraft(PromptDraft("zsh"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))
    XCTAssertEqual(view.mode, .search)

    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveUp(_:)))

    XCTAssertEqual(view.mode, .prompt)
    XCTAssertEqual(view.field.string, "zsh")
  }

  func testTypingInThePickerKeepsAndNarrowsTheOpenList() {
    let view = makeView()
    let shell = BolttyAISessionItem.row("fix the login bug", .codex)
    let agent = BolttyAISessionItem.row("write release notes", .claude)
    view.setSessions([shell, agent], activeSessionID: nil)
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))

    view.field.setDraft(PromptDraft("login"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))

    XCTAssertEqual(view.mode, .search)
    XCTAssertTrue(view.fieldIsQuery)
    XCTAssertTrue(view.isResultsExpandedForTesting)
    XCTAssertEqual(view.resultItemsForTesting.map(\.id), [shell.id])
    XCTAssertEqual(view.field.string, "login")
  }

  func testEnterOnAnEmptySearchSendsTheQueryAsANewPrompt() {
    let view = makeView()
    view.setSessions([.row("write release notes", .claude)], activeSessionID: nil)
    var submitted: PromptDraft?
    view.onSubmit = { submitted = $0 }

    view.openSwitcher()
    view.field.setDraft(PromptDraft("fix login"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))

    XCTAssertEqual(view.mode, .search)
    XCTAssertTrue(view.resultItemsForTesting.isEmpty)
    XCTAssertEqual(view.emptyResultsTitleForTesting, "Send as new prompt")
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    )
    XCTAssertEqual(submitted?.typedText, "fix login")
  }

  func testEnterWithAnEmptyPickerStillLaunches() {
    let view = makeView()
    view.setSessions([], activeSessionID: nil)
    var submitted: PromptDraft?
    view.onSubmit = { submitted = $0 }

    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    view.field.setDraft(PromptDraft("fix the login bug"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    )
    XCTAssertEqual(submitted?.typedText, "fix the login bug")
  }

  func testBackspacingAnEmptyPickerClosesTheSwitcher() {
    let view = makeView()
    view.setSessions([.row("claude", .claude)], activeSessionID: nil)
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
    )
    XCTAssertEqual(view.mode, .prompt)
    XCTAssertFalse(view.isResultsExpandedForTesting)
  }

  // MARK: - Tab switching

  func testTabWalksTheFolderThenTheMicrophoneThenTheText() {
    let view = makeView(targets: [.claude, .codex])
    view.setWorkingDirectory(.forNewPrompt(path: "/tmp/repo", honoursWorkingDirectory: true))
    view.field.insertPlainText("hi")
    let tab = #selector(NSResponder.insertTab(_:))
    let folder = view.workingDirectoryChipForTesting
    let mic = view.micButtonForTesting

    XCTAssertFalse(folder.isKeyboardTarget)
    XCTAssertFalse(mic.isKeyboardTarget)
    XCTAssertFalse(view.field.suppressesCaret)

    XCTAssertTrue(view.textView(view.field, doCommandBy: tab))
    XCTAssertEqual(view.agentForNewPrompt, .claude, "Tab does not change the agent")
    XCTAssertTrue(folder.isKeyboardTarget)
    XCTAssertEqual(folder.contentTintColor, ComposerControlGroup.hoverInk)
    XCTAssertFalse(mic.isKeyboardTarget)
    XCTAssertTrue(view.field.suppressesCaret)
    XCTAssertEqual(view.field.string, "hi")

    XCTAssertTrue(view.textView(view.field, doCommandBy: tab))
    XCTAssertTrue(mic.isKeyboardTarget)
    XCTAssertFalse(folder.isKeyboardTarget)
    XCTAssertEqual(mic.contentTintColor, ComposerControlGroup.hoverInk)
    XCTAssertEqual(folder.contentTintColor, ComposerControlGroup.restingInk)
    XCTAssertEqual(view.field.string, "hi")

    XCTAssertTrue(view.textView(view.field, doCommandBy: tab))
    XCTAssertFalse(folder.isKeyboardTarget)
    XCTAssertFalse(mic.isKeyboardTarget)
    XCTAssertFalse(view.field.suppressesCaret)
    XCTAssertEqual(mic.contentTintColor, ComposerControlGroup.restingInk)
    XCTAssertEqual(view.field.string, "hi")
  }

  func testShiftTabChangesTheAgentAndLeavesTheIconWhereItIs() {
    let view = makeView(targets: [.claude, .codex, .grok])
    view.setWorkingDirectory(.forNewPrompt(path: "/tmp/repo", honoursWorkingDirectory: true))
    view.field.insertPlainText("hi")
    XCTAssertTrue(view.textView(view.field, doCommandBy: #selector(NSResponder.insertTab(_:))))
    XCTAssertTrue(view.workingDirectoryChipForTesting.isKeyboardTarget)

    XCTAssertTrue(view.textView(view.field, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
    XCTAssertEqual(view.agentForNewPrompt, .codex)
    XCTAssertTrue(view.workingDirectoryChipForTesting.isKeyboardTarget)
    XCTAssertTrue(view.field.suppressesCaret)
    XCTAssertEqual(view.field.string, "hi")
  }

  func testSpacePressesTheChosenIconAndALetterReturnsToTheText() {
    let view = makeView(targets: [.claude])
    view.setWorkingDirectory(.forNewPrompt(path: "/tmp/repo", honoursWorkingDirectory: true))
    var menus = 0
    var dictated = 0
    view.onWorkingDirectoryMenu = { menus += 1 }
    view.onVoiceToggle = { dictated += 1 }
    let tab = #selector(NSResponder.insertTab(_:))

    XCTAssertTrue(view.textView(view.field, doCommandBy: tab))
    XCTAssertFalse(
      view.textView(view.field, shouldChangeTextIn: view.field.selectedRange(), replacementString: " ")
    )
    XCTAssertEqual(menus, 1)
    XCTAssertEqual(view.field.string, "")
    XCTAssertTrue(view.workingDirectoryChipForTesting.isKeyboardTarget)

    XCTAssertTrue(view.textView(view.field, doCommandBy: tab))
    XCTAssertTrue(view.micButtonForTesting.isKeyboardTarget)
    XCTAssertFalse(
      view.textView(view.field, shouldChangeTextIn: view.field.selectedRange(), replacementString: " ")
    )
    XCTAssertEqual(dictated, 1)
    XCTAssertEqual(view.field.string, "")

    view.field.insertPlainText("a")
    XCTAssertEqual(view.field.string, "a")
    XCTAssertFalse(view.micButtonForTesting.isKeyboardTarget)
    XCTAssertFalse(view.field.suppressesCaret)
  }

  func testReturnStillSendsWhileAnIconIsChosen() {
    let view = makeView(targets: [.claude])
    view.setWorkingDirectory(.forNewPrompt(path: "/tmp/repo", honoursWorkingDirectory: true))
    var submitted: PromptDraft?
    view.onSubmit = { submitted = $0 }
    view.field.setDraft(PromptDraft("review this"))
    XCTAssertTrue(view.textView(view.field, doCommandBy: #selector(NSResponder.insertTab(_:))))
    XCTAssertTrue(view.workingDirectoryChipForTesting.isKeyboardTarget)

    XCTAssertTrue(view.textView(view.field, doCommandBy: #selector(NSTextView.insertNewline(_:))))
    XCTAssertEqual(submitted?.typedText, "review this")
  }

  func testOneAgentConsumesTabAndShiftTab() {
    let view = makeView(targets: [.claude])
    view.field.insertPlainText("hi")

    XCTAssertTrue(view.textView(view.field, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
    XCTAssertEqual(view.agentForNewPrompt, .claude)
    XCTAssertEqual(view.field.string, "hi")

    XCTAssertTrue(view.textView(view.field, doCommandBy: #selector(NSResponder.insertTab(_:))))
    XCTAssertTrue(view.micButtonForTesting.isKeyboardTarget)
    XCTAssertEqual(view.agentForNewPrompt, .claude)
    XCTAssertEqual(view.field.string, "hi")
  }

  func testShiftTabCyclesTheAgentsAndWrapsAround() {
    let view = makeView(targets: [.claude, .codex, .grok])
    XCTAssertEqual(view.agentForNewPrompt, .claude)
    let backtab = #selector(NSResponder.insertBacktab(_:))

    XCTAssertTrue(view.textView(view.field, doCommandBy: backtab))
    XCTAssertEqual(view.agentForNewPrompt, .codex)

    XCTAssertTrue(view.textView(view.field, doCommandBy: backtab))
    XCTAssertEqual(view.agentForNewPrompt, .grok)

    XCTAssertTrue(view.textView(view.field, doCommandBy: backtab))
    XCTAssertEqual(view.agentForNewPrompt, .claude)
  }

  func testReopeningResetsToThePreferredAgent() {
    let view = makeView(targets: [.claude, .codex])
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
    XCTAssertEqual(view.agentForNewPrompt, .codex)

    view.prepareForPresentation()
    view.resetAgentChoice()
    XCTAssertEqual(view.agentForNewPrompt, .claude)
    XCTAssertFalse(view.micButtonForTesting.isKeyboardTarget)
    XCTAssertFalse(view.field.suppressesCaret)
  }

  func testTabIsInertWhileSearching() {
    let view = makeView(targets: [.claude, .codex])
    view.setSessions([.row("claude", .claude)], activeSessionID: nil)
    view.openSwitcher()

    XCTAssertFalse(view.textView(view.field, doCommandBy: #selector(NSResponder.insertTab(_:))))
    XCTAssertFalse(view.textView(view.field, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
    XCTAssertEqual(view.agentForNewPrompt, .claude)
  }

  // MARK: - Prompt typography

  func testPlaceholderSharesTheBaselineOfTypedText() throws {
    let view = makeScreenSizedView()
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.promptPlaceholderForTesting, "Describe your task...")
    let placeholder = view.placeholderBaselineInWindowForTesting

    view.field.setDraft(PromptDraft("j"))
    view.layoutSubtreeIfNeeded()
    let typed = try XCTUnwrap(view.typedBaselineInWindowForTesting, "nothing laid out")

    XCTAssertEqual(placeholder, typed, accuracy: 0.5)
  }

  func testPlainTypeIsCentredInTheRowLikeTheIconBesideIt() {
    let font = PromptTextView.promptFont
    let opticalCentre = PromptTextView.firstBaselineOffsetFromTop - font.capHeight / 2

    XCTAssertEqual(opticalCentre, PromptTextView.lineHeight / 2, accuracy: 0.6)
  }

  func testALineOfPlainTypeIsCentredInAChipsLine() {
    XCTAssertEqual(PromptTextView.verticalInset(hasChips: true), 0)
    XCTAssertEqual(
      PromptTextView.verticalInset(hasChips: false),
      (PromptTextView.lineHeight - PromptTextView.textOnlyLineHeight) / 2
    )
    XCTAssertGreaterThanOrEqual(PromptTextView.lineHeight, PromptTextView.textOnlyLineHeight)
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }

  // MARK: - Keyboard selection in the switcher

  func testTheCardWearsTheCornerItsHeightCanHold() {
    let view = makeScreenSizedView()
    let one = BolttyAISessionItem.row("claude", .claude)
    let two = BolttyAISessionItem.row("ship it", .codex)
    let three = BolttyAISessionItem.row("and again", .opencode)

    view.setSessions([one], activeSessionID: one.id)
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(view.resultsCardHeightForTesting, 0, "the card is open")
    XCTAssertEqual(
      view.resultsCardCornerRadiusForTesting,
      min(AgentPaletteMetrics.listCardCornerRadius, view.resultsCardHeightForTesting / 2),
      accuracy: 0.01,
      "one row asks for the list corner and clamps to what it can draw"
    )

    view.setSessions([one, two, three], activeSessionID: one.id)
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      view.resultsCardCornerRadiusForTesting,
      AgentPaletteMetrics.listCardCornerRadius,
      accuracy: 0.01,
      "three rows are tall enough to wear the list corner in full"
    )
    XCTAssertLessThan(
      view.resultsCardCornerRadiusForTesting * 2,
      view.resultsCardHeightForTesting,
      "and the card is still a rounded rectangle, never the prompt's stadium"
    )
  }

  func testTheNoAgentStateWearsThePreferredAgentsFace() {
    let view = makeView(targets: [])
    view.prepareForPresentation()
    view.layoutSubtreeIfNeeded()

    XCTAssertEqual(view.mascotLookForTesting, MascotLook.face(for: nil))
    XCTAssertEqual(view.mascotEmotionForTesting, .curious)
  }

  func testPickingAnAgentPutsItsFaceOnTheMark() {
    let view = makeView(targets: [])
    view.prepareForPresentation()
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.mascotLookForTesting, MascotLook.face(for: nil))

    view.setAgentChoices([.claude], planned: .claude)
    view.prepareForPresentation()
    view.layoutSubtreeIfNeeded()

    XCTAssertEqual(view.mascotPaletteIDForTesting, MascotPalette.face(for: .claude).id)
  }

  func testTheFaceWithNoAgentReactsToAnErrorTheSameWayAnAgentsWould() {
    let view = makeView(targets: [])
    view.prepareForPresentation()
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.mascotEmotionForTesting, .curious)

    view.showError("Nothing is installed yet.")
    view.layoutSubtreeIfNeeded()

    XCTAssertEqual(view.mascotEmotionForTesting, .sad)
    XCTAssertEqual(view.mascotLookForTesting, MascotLook.face(for: nil), "and it is still the same face")
  }

  func testSearchModeKeepsAFaceInsteadOfAMagnifier() {
    let view = makeScreenSizedView()
    view.openSwitcher()
    view.field.setDraft(PromptDraft("q"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))
    view.layoutSubtreeIfNeeded()

    XCTAssertEqual(view.mascotLookForTesting, MascotLook.face(for: view.agentForNewPrompt))
    XCTAssertEqual(view.mascotEmotionForTesting, .focused)
  }

  func testScanningWearsTheThinkingFace() {
    let view = makeView(targets: [])
    view.prepareForPresentation()
    view.setCatalogScanning(true)
    view.layoutSubtreeIfNeeded()

    XCTAssertEqual(view.mascotEmotionForTesting, .thinking)
    XCTAssertEqual(view.mascotLookForTesting, MascotLook.face(for: nil))

    view.setCatalogScanning(false)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      view.mascotEmotionForTesting,
      .curious,
      "the scan ended with nothing to select, so the face goes back to waiting"
    )
  }

  func testOnlyTheKeyboardSelectedRowIsGivenAnEdge() {
    let view = makeScreenSizedView()
    let first = BolttyAISessionItem.row("claude", .claude)
    let second = BolttyAISessionItem.row("ship it", .claude)
    view.setSessions([first, second], activeSessionID: first.id)

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    let rows = view.resultRowViewsForTesting
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(view.selectedResultIndexForTesting, 0)

    XCTAssertGreaterThan(rows[0].highlightFillAlphaForTesting, 0.05)
    XCTAssertEqual(rows[1].highlightFillAlphaForTesting, 0, accuracy: 0.02)
    XCTAssertGreaterThan(
      rows[0].highlightFillAlphaForTesting,
      rows[1].highlightFillAlphaForTesting,
      "the fill still carries the selection, the edge only makes it readable"
    )
  }

  func testTheEdgeFollowsTheSelectionDownTheList() {
    let view = makeScreenSizedView()
    let first = BolttyAISessionItem.row("claude", .claude)
    let second = BolttyAISessionItem.row("ship it", .claude)
    view.setSessions([first, second], activeSessionID: first.id)

    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))

    let rows = view.resultRowViewsForTesting
    XCTAssertEqual(view.selectedResultIndexForTesting, 1)
    XCTAssertEqual(rows[0].highlightFillAlphaForTesting, 0, accuracy: 0.02)
    XCTAssertGreaterThan(rows[1].highlightFillAlphaForTesting, 0.05)
  }

  // MARK: - Recording controls

  private func makeDictatingView() -> AgentPaletteView {
    let view = hostOffscreen(makeView())
    view.setVoiceListening(true)
    view.applyVoiceTranscript(String(repeating: "кривому криво дуже ", count: 6))
    settlePromptLayout(view)
    return view
  }

  @discardableResult
  private func hostOffscreen(_ view: AgentPaletteView) -> AgentPaletteView {
    let window = NSWindow(
      contentRect: view.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.setFrame(
      NSRect(x: -20_000, y: -20_000, width: view.frame.width, height: view.frame.height),
      display: false
    )
    window.orderFrontRegardless()
    addTeardownBlock { MainActor.assumeIsolated { window.close() } }
    return view
  }

  private func settlePromptLayout(_ view: AgentPaletteView) {
    view.layoutSubtreeIfNeeded()
    RunLoop.current.run(
      until: Date().addingTimeInterval(0.05)
    )
    view.layoutSubtreeIfNeeded()
  }

  func testLongDictationScrollsUnderTheTopRightRecordingOverlay() {
    let view = makeDictatingView()
    XCTAssertTrue(view.isPromptExpandedForTesting)
    XCTAssertFalse(view.isShowingRecordingControlsForTesting)

    view.setRecordingHoverForTesting(true)
    let capsule = view.promptCapsuleFrameForTesting
    let text = view.promptTextFrameForTesting
    let pill = view.recordingControlsFrameForTesting
    let disc = view.convert(view.micButtonForTesting.bounds, from: view.micButtonForTesting)

    XCTAssertEqual(
      capsule.maxY - pill.midY,
      AgentPaletteMetrics.promptSize.height / 2,
      accuracy: 0.5,
      "recording controls must keep the compact row's vertical position"
    )
    XCTAssertEqual(
      capsule.maxX - disc.maxX,
      AgentPaletteMetrics.promptTrailingInset,
      accuracy: 0.5,
      "the disc stays in the idle microphone's gutter"
    )
    XCTAssertEqual(
      pill.maxX,
      disc.maxX + AgentPaletteMetrics.voiceControlsPadding,
      accuracy: 0.5,
      "the pill chrome hangs its padding past the confirm disc"
    )
    XCTAssertEqual(
      capsule.maxY - text.maxY,
      0,
      accuracy: 0.5,
      "the scroll viewport should reach the fading top edge"
    )
    XCTAssertTrue(text.intersects(pill), "text should pass underneath the pill, not wrap around it")
    XCTAssertFalse(view.planRingForTesting.hasReading)
    XCTAssertEqual(
      capsule.maxX - text.maxX,
      AgentPaletteMetrics.restingControlsTrailingInset + ComposerControlGroup.target(chat: false)
        + AgentPaletteMetrics.promptMicTextSpacing,
      accuracy: 0.5
    )
    XCTAssertLessThanOrEqual(capsule.height, AgentPaletteMetrics.expandedPromptMaximumHeight)
  }

  func testALongTypedDraftKeepsTheCompactFont() {
    let view = hostOffscreen(makeView())
    view.field.setDraft(
      PromptDraft(String(repeating: "кривому криво дуже ", count: 6))
    )
    settlePromptLayout(view)
    XCTAssertTrue(view.isPromptExpandedForTesting)
    XCTAssertEqual(
      view.field.storageFontSizeForTesting,
      AgentPaletteMetrics.promptFontSize,
      accuracy: 0.01
    )
  }

  func testStoppingDictationDoesNotReflowTheExpandedDraft() {
    let view = hostOffscreen(makeView())
    view.setWorkingDirectory(.forNewPrompt(path: "/tmp/repo", honoursWorkingDirectory: true))
    view.setUsage(AgentUsage(windows: [AgentUsageWindow(kind: .weekly, usedPercent: 45, resetsAt: nil)]),
                  agent: .codex)
    view.setVoiceListening(true)
    view.applyVoiceTranscript(String(repeating: "Довгий голосовий запит із деталями. ", count: 12))
    settlePromptLayout(view)
    let frame = view.promptTextFrameForTesting
    let height = view.promptCapsuleHeightForTesting
    view.setVoiceListening(false)
    settlePromptLayout(view)
    XCTAssertTrue(view.isPromptExpandedForTesting)
    XCTAssertEqual(view.promptTextFrameForTesting, frame)
    XCTAssertEqual(view.promptCapsuleHeightForTesting, height)
    XCTAssertEqual(
      view.field.storageFontSizeForTesting,
      AgentPaletteMetrics.promptFontSize,
      accuracy: 0.01
    )
    XCTAssertTrue(view.field.isScrollable)
  }

  func testRecognizerRevisionsNeverMoveControlsToAnotherRow() {
    let view = makeDictatingView()
    let original = view.recordingControlsFrameForTesting
    let capsuleTop = view.promptCapsuleFrameForTesting.maxY

    view.applyVoiceTranscript("ага")
    settlePromptLayout(view)
    XCTAssertTrue(view.isPromptExpandedForTesting)
    XCTAssertEqual(view.recordingControlsFrameForTesting.minX, original.minX, accuracy: 0.5)
    XCTAssertEqual(
      view.promptCapsuleFrameForTesting.maxY - view.recordingControlsFrameForTesting.midY,
      capsuleTop - original.midY,
      accuracy: 0.5
    )
  }

  func testClearingTheDraftRestoresTheCompactRow() {
    let view = makeDictatingView()
    view.setVoiceListening(false)
    view.field.clearPrompt()
    view.setVoiceListening(true)
    settlePromptLayout(view)
    XCTAssertFalse(view.isPromptExpandedForTesting)
    XCTAssertEqual(view.promptCapsuleHeightForTesting, AgentPaletteMetrics.promptSize.height)
  }

  func testHoveringSendChangesNeitherTheDiscNorTheGlyph() {
    let controls = VoiceRecordingControls(frame: .zero)
    let confirm = controls.confirmButtonForTesting

    XCTAssertEqual(
      confirm.hoverTint,
      AgentPaletteMetrics.voiceControlsConfirmGlyphColor,
      "the glyph changes colour on hover, which is how it went missing"
    )
    XCTAssertEqual(confirm.restingBackground.alphaComponent, 1, accuracy: 0.001)
    XCTAssertEqual(
      confirm.hoverBackground.alphaComponent,
      confirm.restingBackground.alphaComponent,
      accuracy: 0.001,
      "a dimmed white disc on a dark pill reads as disabled"
    )
  }

  func testHoveringCancelLightsAndFrostsItsDiscInstead() {
    let controls = VoiceRecordingControls(frame: .zero)
    let cancel = controls.cancelButtonForTesting

    XCTAssertEqual(cancel.hoverTint, AgentPaletteMetrics.voiceControlsCancelGlyphColor)
    XCTAssertEqual(cancel.restingBackground.alphaComponent, 0, accuracy: 0.001)
    XCTAssertGreaterThan(
      cancel.hoverBackground.alphaComponent,
      cancel.restingBackground.alphaComponent,
      "nothing appears under the pointer"
    )
    XCTAssertEqual(
      cancel.hoverBackdropBlurRadius,
      AgentPaletteMetrics.voiceControlsCancelHoverBlurRadius,
      accuracy: 0.001
    )
  }

  func testHoverLeavesEveryWhiteDiscWhite() {
    let controls = VoiceRecordingControls(frame: .zero)
    let confirm = controls.confirmButtonForTesting
    let mic = GlassCircleVoiceButton(frame: .zero)

    XCTAssertEqual(mic.restingBackground, mic.hoverBackground)
    for button in [confirm] {
      XCTAssertEqual(button.restingBackground.alphaComponent, 1, accuracy: 0.001)
      XCTAssertEqual(
        button.hoverBackground.alphaComponent,
        button.restingBackground.alphaComponent,
        accuracy: 0.001,
        "a dimmed white disc on a dark surface reads as disabled"
      )
    }
  }

  func testTheMicrophoneWaveformWearsTheLabelColour() {
    XCTAssertEqual(AgentPaletteMetrics.voiceOrbGlyphColor, PaletteInk.primary)
    var glyph: NSColor?
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
      glyph = AgentPaletteMetrics.voiceOrbGlyphColor.usingColorSpace(.sRGB)
    }
    for channel in [glyph?.redComponent, glyph?.greenComponent, glyph?.blueComponent] {
      XCTAssertEqual(channel ?? 0, 1, accuracy: 0.001, "white, never grey")
    }
  }

  // MARK: - Row lifecycle

  private var rowStamps: [UUID: Date] = [:]

  private func stamp(for id: UUID) -> Date {
    if let existing = rowStamps[id] { return existing }
    let stamp = Date().addingTimeInterval(-60 * TimeInterval(rowStamps.count + 1))
    rowStamps[id] = stamp
    return stamp
  }

  private func sessionRow(
    _ title: String,
    id: UUID,
    state: AgentReportedState?,
    agent: AgentId = .opencode
  ) -> BolttyAISessionItem {
    BolttyAISessionItem(
      id: id,
      title: title,
      subtitle: AgentId.opencode.displayName,
      agent: agent,
      isCurrent: false,
      updatedAt: stamp(for: id),
      state: state
    )
  }

  func testASessionChangingStateReusesTheRowItAlreadyHas() {
    let view = makeView()
    let first = UUID()
    let second = UUID()
    view.setSessions([
      sessionRow("fix login", id: first, state: nil),
      sessionRow("write docs", id: second, state: nil),
    ])
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    let before = view.resultRowViewsForTesting
    XCTAssertEqual(before.count, 2)

    view.setSessions([
      sessionRow("fix login", id: first, state: .running),
      sessionRow("write docs", id: second, state: nil),
    ])

    let after = view.resultRowViewsForTesting
    XCTAssertEqual(after.count, 2)
    XCTAssertTrue(after[0] === before[0], "the row for a conversation outlives its state")
    XCTAssertTrue(after[1] === before[1])
    XCTAssertEqual(after[0].item.state, .running, "and it draws the newer state")
    XCTAssertEqual(after[0].item.subtitle, AgentId.opencode.displayName)
  }

  func testAConversationLeavingReleasesItsRowAndArrivingBuildsOne() {
    let view = makeView()
    let stays = UUID()
    let leaves = UUID()
    view.setSessions([
      sessionRow("stays", id: stays, state: nil),
      sessionRow("leaves", id: leaves, state: nil),
    ])
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    let keptRow = view.resultRowViewsForTesting[0]

    let arrives = UUID()
    view.setSessions([
      sessionRow("stays", id: stays, state: nil),
      sessionRow("arrives", id: arrives, state: nil),
    ])

    let rows = view.resultRowViewsForTesting
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0].item.id, arrives)
    XCTAssertTrue(rows[1] === keptRow)
    XCTAssertNotNil(rows[0].superview, "the arriving row is in the card, not just in the array")
  }

  func testAnOpenListHoldsItsOrderAndTheNextOpenTakesTheNewOne() {
    let view = makeView()
    let first = UUID()
    let second = UUID()
    view.setSessions([
      sessionRow("first", id: first, state: nil),
      sessionRow("second", id: second, state: nil),
    ])
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    let secondRow = view.resultRowViewsForTesting[1]

    view.setSessions([
      sessionRow("second", id: second, state: .running),
      sessionRow("first", id: first, state: nil),
    ])

    let rows = view.resultRowViewsForTesting
    XCTAssertEqual(rows.map(\.item.id), [first, second], "the row the pointer is on does not move")
    XCTAssertTrue(rows[1] === secondRow, "the same row, drawing its new state")
    XCTAssertEqual(rows[1].item.state, .running)

    var confirmed: UUID?
    view.onConfirmSession = { confirmed = $0 }
    rows[1].onActivate?()
    XCTAssertEqual(confirmed, second, "activation follows the conversation, not the slot")

    XCTAssertTrue(view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    XCTAssertFalse(view.isResultsExpandedForTesting)
    view.setSessions([
      sessionRow("second", id: second, state: .running),
      sessionRow("first", id: first, state: nil),
    ])
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertEqual(view.resultRowViewsForTesting.map(\.item.id), [second, first], "reopened, the true order")
  }

  func testRowsDrawTheTitleAndTheLastMessage() {
    let view = makeView()
    let chat = Conversation(
      providerID: AgentId.claude.rawValue,
      title: "У да привіт",
      workingDirectory: "/tmp"
    )
    let transcripts = [
      chat.id: ConversationTranscript(
        messages: [
          ConversationMessage(
            id: "m1",
            role: .user,
            createdAt: Date(),
            parts: [.text(TextPart(id: "t1", kind: .text, text: "У да привіт"))]
          ),
          ConversationMessage(
            id: "m2",
            role: .agent,
            createdAt: Date(),
            parts: [.text(TextPart(id: "t2", kind: .text, text: "Привіт! Чим допомогти?"))]
          ),
        ],
        interactions: []
      )
    ]
    view.setSessions(
      BolttyAISessionList.items(conversations: [chat], transcripts: transcripts, selectedID: nil),
      activeSessionID: nil,
      transcripts: transcripts
    )
    view.openSwitcher()

    XCTAssertEqual(view.resultItemsForTesting.map(\.title), ["У да привіт"])
    XCTAssertEqual(view.resultItemsForTesting.map(\.subtitle), ["Привіт! Чим допомогти?"])
  }

  func testUseInFollowUpAttachesTheFileToTheDraft() {
    let view = makeView()
    let id = UUID()
    view.setSessions([.row("Chat", .opencode, id: id)], activeSessionID: id)
    view.enterAddressing(.init(id: id, title: "Chat", agent: .opencode,
                               state: .finished, body: "Done."))
    let url = URL(fileURLWithPath: "/tmp/out.mp4")
    view.previewCardForTesting.onUseFile?(url)

    let attached = view.currentDraft.attachments.map(\.payload)
    XCTAssertEqual(attached, [.file(url)])
    XCTAssertTrue(view.currentDraft.typedText.isEmpty, "no words added, only the chip")
  }

  func testSearchFindsAnOlderMessageInTheTranscript() {    let view = makeView()
    func message(_ id: String, _ text: String) -> ConversationMessage {
      ConversationMessage(
        id: id,
        role: .agent,
        createdAt: Date(),
        parts: [.text(TextPart(id: "text-\(id)", kind: .text, text: text))]
      )
    }
    let billed = Conversation(providerID: AgentId.claude.rawValue, title: "fix login", workingDirectory: "/tmp")
    let other = Conversation(providerID: AgentId.claude.rawValue, title: "write docs", workingDirectory: "/tmp")
    let transcripts = [
      billed.id: ConversationTranscript(messages: [message("m1", "about invoices"), message("m2", "never mind")], interactions: []),
      other.id: ConversationTranscript(messages: [message("m3", "definitely unrelated")], interactions: []),
    ]
    view.setSessions(
      BolttyAISessionList.items(conversations: [billed, other], transcripts: transcripts, selectedID: nil),
      activeSessionID: nil,
      transcripts: transcripts
    )
    view.openSwitcher()
    view.openSwitcher()
    view.field.setDraft(PromptDraft("invoices"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))

    XCTAssertEqual(view.mode, .search)
    XCTAssertEqual(view.resultItemsForTesting.map(\.id), [billed.id])
  }

  // MARK: - Hover and keyboard selection

  func testHoveringARowMakesItTheSelection() {
    let view = makeView()
    view.pointerLocationForTesting = NSPoint(x: 100, y: 100)
    view.setSessions([
      sessionRow("first", id: UUID(), state: nil),
      sessionRow("second", id: UUID(), state: nil),
    ])
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertEqual(view.selectedResultIndexForTesting, 0)

    view.pointerLocationForTesting = NSPoint(x: 140, y: 160)
    view.hoverRowForTesting(at: 1)
    XCTAssertEqual(view.selectedResultIndexForTesting, 1)
  }

  func testARowScrollingUnderAStationaryCursorDoesNotStealTheSelection() {
    let view = makeView()
    view.pointerLocationForTesting = NSPoint(x: 100, y: 100)
    view.setSessions([
      sessionRow("first", id: UUID(), state: nil),
      sessionRow("second", id: UUID(), state: nil),
      sessionRow("third", id: UUID(), state: nil),
    ])
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertEqual(view.selectedResultIndexForTesting, 1)

    view.hoverRowForTesting(at: 2)
    XCTAssertEqual(
      view.selectedResultIndexForTesting, 1,
      "the keyboard keeps the selection until the pointer actually moves"
    )

    view.pointerLocationForTesting = NSPoint(x: 300, y: 400)
    view.hoverRowForTesting(at: 2)
    XCTAssertEqual(view.selectedResultIndexForTesting, 2)
  }

  func testARowScrolledOutFromUnderThePointerStopsBeingHovered() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: true
    )
    let row = BolttyAISessionRowView(item: sessionRow("first", id: UUID(), state: nil))
    row.translatesAutoresizingMaskIntoConstraints = true
    row.frame = NSRect(x: 0, y: 100, width: 400, height: 60)
    window.contentView?.addSubview(row)

    row.setHoveredForTesting(true)
    row.syncHover(pointerInWindow: NSPoint(x: 50, y: 20))
    XCTAssertFalse(row.isHoveredForTesting, "the pointer is no longer over it")

    row.syncHover(pointerInWindow: NSPoint(x: 50, y: 130))
    XCTAssertTrue(row.isHoveredForTesting, "the list slid it under the pointer")

    row.syncHover(pointerInWindow: nil)
    XCTAssertFalse(row.isHoveredForTesting)

    row.setHoveredForTesting(true)
    row.isHidden = true
    XCTAssertFalse(row.isHoveredForTesting, "a tab hid it; it must not come back lit")
    row.syncHover(pointerInWindow: NSPoint(x: 50, y: 130))
    XCTAssertFalse(row.isHoveredForTesting, "a hidden row is under nothing")
  }

  // MARK: - Preview measurement

  func testTheCornerGripResizesTheChatAboutItsCentre() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .claude,
                              state: .finished, body: "Done."))
    view.cancelAllAnimationsAndSettle()
    let before = view.unifiedSurfaceFrameForTesting
    var saved: BolttyAISurfaceSizes?
    var dismissed = false
    view.onSurfaceSizesChange = { saved = $0 }
    view.onCancel = { dismissed = true }
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: view.convert(point, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1
      )!
    }

    let grip = NSPoint(x: before.maxX - 12, y: before.minY + 12)
    XCTAssertTrue(view.hitTest(grip) === view, "the grip takes the press over the composer")
    view.mouseDown(with: mouse(.leftMouseDown, grip))
    view.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: grip.x - 60, y: grip.y + 40)))
    view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: grip.x - 60, y: grip.y + 40)))
    view.cancelAllAnimationsAndSettle()
    let after = view.unifiedSurfaceFrameForTesting

    XCTAssertEqual(after.width, before.width - 120, accuracy: 1)
    XCTAssertEqual(after.height, before.height - 40, accuracy: 1)
    XCTAssertEqual(after.midX, before.midX, accuracy: 1, "the centre stays where it was")
    XCTAssertEqual(after.maxY, before.maxY, accuracy: 1, "the top is the anchor")
    XCTAssertEqual(saved?.chat.width ?? 0, after.width, accuracy: 1)

    view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: after.midX, y: after.minY - 7)))
    view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: after.midX, y: after.minY - 7)))
    view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: after.midX, y: after.maxY + 7)))
    XCTAssertFalse(dismissed, "a press that just misses the edge is not a dismissal")
  }

  func testChatOpensAtFullSizeBeforeItsContentNeedsTheRoom() {
    let view = makeScreenSizedView()
    view.cancelAllAnimationsAndSettle()
    let initial = view.unifiedSurfaceFrameForTesting
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .claude,
                              state: .finished, body: "Done."))
    view.cancelAllAnimationsAndSettle()
    let chat = view.unifiedSurfaceFrameForTesting
    let standard = AgentPaletteMetrics.chatSurfaceSize
    XCTAssertEqual(chat.width, standard.width, accuracy: 0.5)
    XCTAssertEqual(chat.height, min(standard.height, initial.maxY - AgentPaletteMetrics.safeAreaY),
                   accuracy: 0.5)
    XCTAssertEqual(chat.maxY, initial.maxY, accuracy: 0.5)
    XCTAssertEqual(chat.midX, initial.midX, accuracy: 0.5)
  }

  func testChatFrameAndPlacementStayFixedAcrossTranscriptAndServiceUpdates() {
    let view = makeScreenSizedView()
    let id = UUID()
    func preview(_ state: AgentReportedState, _ body: String) -> BolttyAISessionPreview {
      .init(id: id, title: "Chat", agent: .claude, state: state, body: body)
    }
    view.enterAddressing(preview(.finished, "Done."))
    view.cancelAllAnimationsAndSettle()
    let frame = view.unifiedSurfaceFrameForTesting
    var failed = preview(.failed, "The local agent process exited.")
    failed.notice = failed.body
    failed.retryPrompt = "Try the task again"
    var notice = preview(.running, "Still working")
    notice.notice = "Waiting for the local agent connection."
    var queued = preview(.running, "Still working")
    queued.queuedPrompt = "Then review the changes."
    var question = preview(.blocked, "Which approach should I use?")
    question.question = reviewQuestion(count: 12)
    let cases = [
      preview(.finished, String(repeating: "A longer finished answer.\n", count: 200)),
      failed, notice, queued, question, preview(.finished, "Done."),
    ]
    for update in cases {
      view.updateAddressing(update)
      view.cancelAllAnimationsAndSettle()
      XCTAssertEqual(view.unifiedSurfaceFrameForTesting, frame)
      if let prompt = update.queuedPrompt {
        XCTAssertEqual(view.previewCardForTesting.queuedTextForTesting, prompt)
      }
      if let question = update.question {
        XCTAssertEqual(view.previewCardForTesting.optionLabelsForTesting, question.options.map(\.label))
      }
    }
  }

  func testExpandedChatComposerUsesRoomInsideTheSameShell() {
    let view = hostOffscreen(makeScreenSizedView())
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .claude,
                              state: .finished, body: "A finished answer."))
    settlePromptLayout(view)
    view.cancelAllAnimationsAndSettle()
    let shell = view.unifiedSurfaceFrameForTesting
    let composer = view.promptCapsuleFrameForTesting
    view.setChatDraft(PromptDraft(String(repeating: "A follow-up with several wrapped lines. ", count: 24)))
    settlePromptLayout(view)
    view.cancelAllAnimationsAndSettle()
    XCTAssertGreaterThan(view.promptCapsuleFrameForTesting.height, composer.height)
    XCTAssertEqual(view.unifiedSurfaceFrameForTesting, shell)
    XCTAssertTrue(shell.contains(view.promptCapsuleFrameForTesting))
    XCTAssertTrue(view.isComposerVisibleForTesting)
    view.setChatDraft(PromptDraft())
    settlePromptLayout(view)
    view.cancelAllAnimationsAndSettle()
    XCTAssertEqual(view.unifiedSurfaceFrameForTesting, shell)
  }

  func testAQuestionArrivingKeepsTheChatHeightThoughItsRowsChange() {
    let view = makeScreenSizedView()
    let id = UUID()
    let body = "Which of these should I change?"
    view.enterAddressing(
      BolttyAISessionPreview(
        id: id, title: "fix login", agent: .claude, state: .finished, body: body
      )
    )
    let withoutOptions = view.previewCardHeightForTesting

    view.updateAddressing(
      BolttyAISessionPreview(
        id: id, title: "fix login", agent: .claude, state: .blocked,
        body: body, question: reviewQuestion(count: 4)
      )
    )
    let withOptions = view.previewCardHeightForTesting
    XCTAssertEqual(withOptions, withoutOptions, accuracy: 0.5)
    XCTAssertEqual(view.previewCardForTesting.optionLabelsForTesting.count, 4)

    view.updateAddressing(
      BolttyAISessionPreview(
        id: id, title: "fix login", agent: .claude, state: .finished, body: body
      )
    )
    XCTAssertEqual(view.previewCardHeightForTesting, withoutOptions, accuracy: 0.5)
  }

  func testTheCardFollowsThePanelHeightAndIgnoresAWidthOnlyResize() {
    let view = makeScreenSizedView()
    view.enterAddressing(
      BolttyAISessionPreview(
        id: UUID(), title: "fix login", agent: .claude, state: .running,
        body: String(repeating: "Looking at the login flow. ", count: 40)
      )
    )
    let atFullHeight = view.previewCardHeightForTesting
    XCTAssertGreaterThan(atFullHeight, 0)

    view.frame = CGRect(x: 0, y: 0, width: 900, height: 900)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      view.previewCardHeightForTesting, atFullHeight, accuracy: 0.5,
      "the wrap runs against a fixed width, so narrowing the panel changes nothing"
    )

    view.frame = CGRect(x: 0, y: 0, width: 900, height: 520)
    view.layoutSubtreeIfNeeded()
    XCTAssertLessThan(
      view.previewCardHeightForTesting, atFullHeight,
      "less room under the prompt is less card"
    )
  }

  func testAShortReplyReservesFullChatRoom() {
    let view = makeScreenSizedView()
    view.enterAddressing(
      BolttyAISessionPreview(
        id: UUID(), title: "fix login", agent: .claude, state: .finished, body: "Done."
      )
    )

    XCTAssertGreaterThan(
      view.previewCardHeightForTesting,
      AgentPaletteMetrics.previewCardHeight(bodyLineCount: 1)
    )
    XCTAssertGreaterThan(
      view.unifiedSurfaceFrameForTesting.height,
      AgentPaletteMetrics.cardCornerRadius * 2
    )
  }

  func testShortAndLongFinishedRepliesHaveTheSameChatViewport() {
    let view = makeScreenSizedView()
    let id = UUID()
    view.enterAddressing(
      BolttyAISessionPreview(
        id: id, title: "fix login", agent: .claude, state: .finished, body: "One line."
      )
    )
    let atFloor = view.previewCardHeightForTesting

    view.updateAddressing(
      BolttyAISessionPreview(
        id: id, title: "fix login", agent: .claude, state: .finished,
        body: String(repeating: "Looking at the login flow. ", count: 40)
      )
    )
    XCTAssertEqual(view.previewCardHeightForTesting, atFloor, accuracy: 0.5)
  }

  // MARK: - Composer controls

  func testRestingClipAndMicKeepTheirHitTargetsWithoutGlass() {
    let view = makeScreenSizedView()
    view.setAcceptsAttachments(true)
    view.layoutSubtreeIfNeeded()

    XCTAssertFalse(view.isAttachVisibleForTesting, "no clip on the first screen")
    let mic = view.voiceControlFrameForTesting
    let target = ComposerControlGroup.target(chat: false)
    XCTAssertEqual(mic.width, target, accuracy: 0.6)
    XCTAssertEqual(mic.width, mic.height, accuracy: 0.6)
    XCTAssertFalse(view.voiceOrbUsesSystemGlassForTesting)
    XCTAssertEqual(view.micButtonForTesting.restingTint, ComposerControlGroup.restingInk)
    XCTAssertEqual(
      view.composerFieldFrameForTesting.maxX - mic.maxX,
      AgentPaletteMetrics.restingControlsTrailingInset, accuracy: 0.6)
    XCTAssertEqual(AgentPaletteMetrics.restingAttachGlyphPointSize, 15)
    XCTAssertEqual(AgentPaletteMetrics.voiceOrbBarHeight, 22)
  }

  func testProcessingRecordingCannotSendItsPartialTranscript() {
    let view = makeScreenSizedView()
    var submitted = 0
    view.onSubmit = { _ in submitted += 1 }
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .codex, state: .finished, body: "done"))
    view.field.setDraft(PromptDraft("Partial transcription"))
    view.setVoiceListening(false, ending: .processing)
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(view.sendButtonForTesting.isEnabled)
    view.confirmCurrentDraft()
    XCTAssertEqual(submitted, 0)
    view.setVoiceGlowPhase(.completed)
    view.confirmCurrentDraft()
    XCTAssertEqual(submitted, 1)
  }

  func testSendButtonFollowsEnterAndAdvertisesQueueWhileBusy() {
    let view = makeScreenSizedView()
    var submitted: [String] = []
    view.onSubmit = { submitted.append($0.typedText) }
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .codex, state: .running, body: "Working"))
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(view.sendButtonForTesting.isEnabled)
    view.field.setDraft(PromptDraft("Do this next"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(view.sendButtonForTesting.isEnabled)
    XCTAssertTrue(view.sendButtonForTesting.toolTip?.contains("Queue") == true)
    XCTAssertEqual(view.sendButtonForTesting.helpShortcut, "↵")
    view.sendButtonForTesting.performClick(nil)
    XCTAssertEqual(submitted, ["Do this next"])
  }

  func testThePlanRingIsGoneWithoutAReading() {
    let view = makeScreenSizedView()
    view.setWorkingDirectory(.forNewPrompt(path: "/Users/someone", honoursWorkingDirectory: true))
    view.setUsage(
      AgentUsage(windows: [
        AgentUsageWindow(kind: .session, usedPercent: 8, resetsAt: nil),
        AgentUsageWindow(kind: .weekly, usedPercent: 45, resetsAt: nil),
      ]),
      agent: .codex)
    view.layoutSubtreeIfNeeded()
    let pill = view.planRingForTesting
    XCTAssertFalse(pill.isHidden)
    XCTAssertEqual(pill.titleForTesting, "Weekly 45%")
    XCTAssertEqual(pill.tintForTesting, AgentPaletteMetrics.planRingColors[1])
    XCTAssertLessThanOrEqual(
      view.convert(pill.bounds, from: pill).maxX,
      view.convert(view.workingDirectoryChipForTesting.bounds,
        from: view.workingDirectoryChipForTesting).minX + 0.5, "before the folder (2026-10-07)")

    view.setUsage(
      AgentUsage(windows: [AgentUsageWindow(kind: .weekly, usedPercent: 91, resetsAt: nil)]),
      agent: .codex)
    XCTAssertEqual(pill.tintForTesting, AgentPaletteMetrics.planRingColors[3])

    view.setUsage(nil, agent: .opencode)
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(pill.isHidden, "no data, no ring")
    XCTAssertEqual(view.convert(pill.bounds, from: pill).width, 0, "and no slot")
  }

  func testContextAndCompactLiveInThePlanDisclosure() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .claude, state: nil, body: "done"))
    var compacted = 0
    view.onCompact = { compacted += 1 }
    let ring = view.planRingForTesting
    view.setContext(AgentContextUsage(usedTokens: 20_000, limitTokens: 200_000), canCompact: true)
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(ring.detailForTesting.contains("Chat context: 10% used"))
    XCTAssertFalse(ring.offersCompactForTesting)
    view.setContext(AgentContextUsage(usedTokens: 160_000, limitTokens: 200_000), canCompact: false)
    XCTAssertFalse(ring.offersCompactForTesting)
    view.setContext(AgentContextUsage(usedTokens: 160_000, limitTokens: 200_000), canCompact: true)
    XCTAssertTrue(ring.offersCompactForTesting)
    ring.compactForTesting()
    XCTAssertEqual(compacted, 1)
    view.setContext(nil, canCompact: false)
    XCTAssertTrue(ring.detailForTesting.contains("usage is not available"))
    XCTAssertFalse(ring.offersCompactForTesting)
  }

  func testACachelessChatIsOfferedCompactionSooner() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .claude, state: nil, body: "done"))
    let ring = view.planRingForTesting
    let half = AgentContextUsage(usedTokens: 100_000, limitTokens: 200_000)
    view.setContext(half, canCompact: true)
    XCTAssertFalse(ring.offersCompactForTesting, "50% with a warm cache: not yet")
    view.setContext(half, canCompact: true, cacheIsCold: true)
    XCTAssertTrue(ring.offersCompactForTesting)
    XCTAssertTrue(ring.detailForTesting.contains("cache has expired"))
    view.setContext(AgentContextUsage(usedTokens: 40_000, limitTokens: 200_000), canCompact: true, cacheIsCold: true)
    XCTAssertFalse(ring.offersCompactForTesting, "a small chat is cheap to send anyway")
  }

  func testChatControlsLiveInTheComposerAndLatestFloatsIndependently() {
    let view = makeScreenSizedView()
    view.setWorkingDirectory(.forNewPrompt(path: "/Users/someone", honoursWorkingDirectory: true))
    view.setUsage(
      AgentUsage(windows: [AgentUsageWindow(kind: .weekly, usedPercent: 25, resetsAt: nil)]),
      agent: .claude)
    var preview = BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .claude, state: .finished, body: "")
    let long = Array(repeating: "A line of an answer long enough to wrap in the card.", count: 60)
      .joined(separator: "\n\n")
    preview.messages = [
      ConversationMessage(
        id: "a", role: .agent, createdAt: Date(), completedAt: Date(),
        parts: [.text(TextPart(id: "t", kind: .text, text: long))])
    ]
    view.enterAddressing(preview)
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()

    let chip = view.convert(view.workingDirectoryChipForTesting.bounds,
                            from: view.workingDirectoryChipForTesting)
    let usage = view.planRingForTesting
    let plan = view.convert(usage.bounds, from: usage)
    let composer = view.promptCapsuleFrameForTesting
    XCTAssertFalse(usage.isHidden, "the plan rides in the chat's row")
    XCTAssertEqual(usage.titleForTesting, "Weekly 25%")
    XCTAssertEqual(plan.midY, chip.midY, accuracy: 0.5)
    XCTAssertLessThanOrEqual(plan.maxX, chip.minX + 0.5, "the ring before the folder")
    XCTAssertTrue(composer.contains(chip))
    XCTAssertTrue(composer.contains(plan))

    let latest = view.latestPillForTesting
    XCTAssertTrue(latest.isHidden, "at the newest line there is nowhere to go back to")
    view.previewCardForTesting.scrollForTesting(to: 0)
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(view.previewCardForTesting.isLatestPillVisibleForTesting)
    XCTAssertFalse(latest.isHidden, "scrolled up, Latest offers the way back")
    let latestFrame = view.convert(latest.bounds, from: latest)
    XCTAssertEqual(latestFrame.midX, composer.midX, accuracy: 0.5)
    XCTAssertEqual(latestFrame.minY - composer.maxY,
      AgentPaletteMetrics.latestComposerSpacing, accuracy: 0.5)
    latest.button.performClick(nil)
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(latest.isHidden, "and pressing it is the way back")
  }

  func testTheContextPillIsNotOnTheFirstScreen() {
    let view = makeScreenSizedView()
    view.setWorkingDirectory(.forNewPrompt(path: "/Users/someone", honoursWorkingDirectory: true))
    view.setContext(AgentContextUsage(usedTokens: 1, limitTokens: 2), canCompact: true)
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(view.planRingForTesting.detailForTesting.contains("after a chat starts"))
  }

  func testTheFolderIsAGlyphAtHomeAndNamesAnyOtherFolder() {
    let view = makeScreenSizedView()
    let target = ComposerControlGroup.target(chat: false)
    view.setWorkingDirectory(.forNewPrompt(
      path: WorkingDirectoryResolver.homeDirectoryPath, honoursWorkingDirectory: true))
    view.layoutSubtreeIfNeeded()
    let folder = view.workingDirectoryChipForTesting
    XCTAssertEqual(folder.frame.width, target, accuracy: 0.5)
    XCTAssertEqual(folder.frame.height, target, accuracy: 0.5)
    XCTAssertNil(folder.nameForTesting, "home wears no name")
    XCTAssertFalse(folder.showsPillForTesting)

    let path = "/Users/someone/Documents/Projects/boltty"
    view.setWorkingDirectory(.forNewPrompt(path: path, honoursWorkingDirectory: true))
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(folder.nameForTesting, "boltty")
    XCTAssertTrue(folder.nameFitsForTesting, "a short name is drawn whole, not \"bol…\"")
    XCTAssertTrue(folder.showsPillForTesting)
    XCTAssertEqual(folder.fillForTesting, AgentPaletteMetrics.folderChipFill)
    XCTAssertGreaterThan(folder.frame.width, target, "the pill is as wide as its name")
    XCTAssertEqual(folder.frame.height, AgentPaletteMetrics.folderChipHeight(chat: false), accuracy: 0.5)
    XCTAssertTrue(view.promptCapsuleFrameForTesting.contains(view.convert(folder.bounds, from: folder)))
    XCTAssertTrue(folder.toolTip?.contains(path) == true)
    XCTAssertTrue(folder.isEnabled)
    var menus = 0
    view.onWorkingDirectoryMenu = { menus += 1 }
    folder.performClick(nil)
    XCTAssertEqual(menus, 1, "a click opens the folder menu")

    view.setWorkingDirectory(.forNewPrompt(
      path: "/Users/someone/" + String(repeating: "a-rather-long-folder-name-", count: 6),
      honoursWorkingDirectory: true))
    view.layoutSubtreeIfNeeded()
    XCTAssertLessThanOrEqual(
      folder.frame.width,
      AgentPaletteMetrics.folderChipMaxNameWidth + AgentPaletteMetrics.folderChipPadding(chat: false) * 2
        + folder.iconWidthForTesting + AgentPaletteMetrics.folderChipIconGap(chat: false) + 0.5)

    view.setWorkingDirectory(.init(path: path, isEditable: false, isIgnoredByAgent: false))
    XCTAssertTrue(folder.isEnabled)
    XCTAssertEqual(folder.nameForTesting, "boltty")
    XCTAssertTrue(folder.toolTip?.contains("new chat") == true)
    XCTAssertTrue(folder.accessibilityPerformPress())
    XCTAssertEqual(menus, 2)

    view.setWorkingDirectory(WorkingDirectoryChip.forNewPrompt(path: path, honoursWorkingDirectory: true)
      .withBranch("main"))
    XCTAssertEqual(folder.nameForTesting, "boltty · main")
  }

  func testTheWordsStopShortOfANamedFolder() {
    let view = makeScreenSizedView()
    view.setWorkingDirectory(.forNewPrompt(
      path: "/Users/someone/Documents/Projects/a-rather-long-folder-name", honoursWorkingDirectory: true))
    view.field.setDraft(PromptDraft("Sort these clips"))
    view.layoutSubtreeIfNeeded()
    let folder = view.convert(view.workingDirectoryChipForTesting.bounds, from: view.workingDirectoryChipForTesting)
    XCTAssertLessThanOrEqual(view.promptTextFrameForTesting.maxX, folder.minX + 0.5)
  }

  // MARK: - Unread rows

  /// An unread chat wears a dot and a semibold title, on every tab alike —
  /// the dot stands on the trailing edge because Latest's face owns the
  /// leading one.
  private func unreadRowItem(_ title: String, id: UUID, unread: Bool) -> BolttyAISessionItem {
    BolttyAISessionItem(
      id: id,
      title: title,
      subtitle: "a reply",
      agent: .claude,
      isCurrent: false,
      updatedAt: Date(),
      state: nil,
      hasUnread: unread
    )
  }

  private func laidOutRow(unread: Bool) -> BolttyAISessionRowView {
    let row = BolttyAISessionRowView(item: unreadRowItem("fix login", id: UUID(), unread: unread))
    row.frame = NSRect(x: 0, y: 0, width: 400, height: AgentPaletteMetrics.resultsRowHeight)
    row.layout()
    return row
  }

  private func semiboldTitle() -> NSFont {
    roundedAppFont(size: AgentPaletteMetrics.resultsTitleFontSize, weight: .semibold)
  }

  private func mediumTitle() -> NSFont {
    roundedAppFont(size: AgentPaletteMetrics.resultsTitleFontSize, weight: .medium)
  }

  func testAReadRowHasNoDotAndAMediumTitle() {
    let row = laidOutRow(unread: false)
    XCTAssertFalse(row.showsUnreadDotForTesting)
    XCTAssertTrue(row.titleFontForTesting.isEqual(mediumTitle()))
  }

  func testAnUnreadRowWearsADotAndASemiboldTitle() {
    let row = laidOutRow(unread: true)
    XCTAssertTrue(row.showsUnreadDotForTesting)
    XCTAssertTrue(row.titleFontForTesting.isEqual(semiboldTitle()))
    let dot = row.unreadDotFrameForTesting
    XCTAssertEqual(dot.width, AgentPaletteMetrics.resultsUnreadDotDiameter)
    XCTAssertEqual(dot.height, AgentPaletteMetrics.resultsUnreadDotDiameter)
    XCTAssertEqual(
      dot.maxX,
      400 - AgentPaletteMetrics.resultsRowHorizontalInset * 2 - AgentPaletteMetrics.resultsRowTextTrailing,
      accuracy: 0.5,
      "against the pill's trailing edge with its padding past it"
    )
    XCTAssertLessThanOrEqual(row.titleFrameForTesting.maxX, dot.minX, "the text stops short of the dot")
    XCTAssertTrue(row.accessibilityLabel()?.contains("unread") == true)
  }

  func testApplyingAnUnreadItemLightsTheRowAndReadingPutsItAway() {
    let id = UUID()
    let row = BolttyAISessionRowView(item: unreadRowItem("fix login", id: id, unread: false))
    row.frame = NSRect(x: 0, y: 0, width: 400, height: AgentPaletteMetrics.resultsRowHeight)
    row.layout()
    XCTAssertFalse(row.showsUnreadDotForTesting)

    row.apply(item: unreadRowItem("fix login", id: id, unread: true))
    row.layout()
    XCTAssertTrue(row.showsUnreadDotForTesting)
    XCTAssertTrue(row.titleFontForTesting.isEqual(semiboldTitle()))

    row.apply(item: unreadRowItem("fix login", id: id, unread: false))
    XCTAssertFalse(row.showsUnreadDotForTesting)
    XCTAssertTrue(row.titleFontForTesting.isEqual(mediumTitle()))
  }

  func testInitialPromptIsOneCapsuleWithFolderPlanClipAndMicInside() {
    let view = makeScreenSizedView()
    view.setWorkingDirectory(.forNewPrompt(path: "/Users/someone", honoursWorkingDirectory: true))
    view.setAcceptsAttachments(true)
    view.layoutSubtreeIfNeeded()
    let shell = view.unifiedSurfaceFrameForTesting
    let input = view.promptCapsuleFrameForTesting
    XCTAssertEqual(shell.minX, input.minX, accuracy: 0.5)
    XCTAssertEqual(shell.minY, input.minY, accuracy: 0.5)
    XCTAssertEqual(shell.size, input.size)
    XCTAssertEqual(shell.size, AgentPaletteMetrics.promptSize)
    XCTAssertEqual(view.fittingSize, AgentPaletteMetrics.panelSize())
    XCTAssertFalse(view.initialPromptChromeIsVisibleForTesting, "no nested surface")
    XCTAssertFalse(view.isAttachVisibleForTesting, "the clip is a chat's only")
    let folder = view.workingDirectoryChipForTesting
    let ring = view.planRingForTesting
    let frames = [view.convert(ring.bounds, from: ring), view.convert(folder.bounds, from: folder),
      view.voiceControlFrameInPaletteForTesting]
    for frame in frames { XCTAssertTrue(input.contains(frame)) }
    for (left, right) in zip(frames, frames.dropFirst()) {
      XCTAssertLessThanOrEqual(left.maxX, right.minX + 0.5)
      XCTAssertEqual(left.midY, right.midY, accuracy: 0.5)
    }

    view.showError("Pick an available agent")
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.unifiedSurfaceFrameForTesting, shell)
    XCTAssertEqual(shell.minY - view.errorFrameForTesting.maxY,
      AgentPaletteMetrics.noticeShellSpacing, accuracy: 0.5)
    view.setVoiceListening(true)
    view.layoutSubtreeIfNeeded()
    view.setVoiceListening(false)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.unifiedSurfaceFrameForTesting, shell)
  }

  func testPromptChatAndReturnKeepOneFolderControlInsideTheField() {
    let view = makeScreenSizedView()
    view.setWorkingDirectory(.forNewPrompt(path: "/tmp/repo", honoursWorkingDirectory: true))
    view.layoutSubtreeIfNeeded()
    let folder = view.workingDirectoryChipForTesting
    let parent = folder.superview
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .opencode,
      state: .finished, body: "Done."))
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(folder.superview === parent)
    view.leaveAddressing(animated: false)
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(folder.superview === parent)
    XCTAssertTrue(view.promptCapsuleFrameForTesting.contains(view.convert(folder.bounds, from: folder)))
    XCTAssertTrue(view.shellUsesGlassForTesting)
  }

  func testAChatInAutoModeShowsItLitAndItsSwitchTurnsItOff() {
    let view = makeScreenSizedView()
    view.setWorkingDirectory(.forNewPrompt(path: "/tmp/repo", honoursWorkingDirectory: true))
    var changes: [(UUID, Bool)] = []
    view.onSetAutoMode = { changes.append(($0, $1)) }
    let id = UUID()
    view.enterAddressing(.init(id: id, title: "Chat", agent: .claude,
      state: .finished, body: "Done.", autoMode: true))
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(view.isAutoModeVisibleForTesting)
    let button = view.autoModeButtonForTesting.button
    XCTAssertEqual(button.restingTint, ComposerControlGroup.hoverInk, "lit while on")
    XCTAssertEqual(button.accessibilityValue() as? String, "On")
    XCTAssertEqual(button.toolTip, AgentPaletteView.autoModeHelp(on: true, agent: .claude))
    XCTAssertTrue(button.toolTip?.contains(AgentsSettingsPage.autoModeReach(for: .claude).dropFirst()) == true,
      "the help tag names what Auto Mode lets through")
    let field = view.promptCapsuleFrameForTesting
    let glyph = view.convert(view.autoModeButtonForTesting.bounds, from: view.autoModeButtonForTesting)
    XCTAssertTrue(field.contains(glyph))
    let folder = view.convert(view.workingDirectoryChipForTesting.bounds,
      from: view.workingDirectoryChipForTesting)
    XCTAssertLessThanOrEqual(folder.maxX, glyph.minX + 0.5, "after the folder")
    XCTAssertEqual(folder.midY, glyph.midY, accuracy: 0.5)

    view.pressAutoModeForTesting()
    XCTAssertEqual(changes.map(\.0), [id])
    XCTAssertEqual(changes.map(\.1), [false])
    XCTAssertEqual(button.restingTint, ComposerControlGroup.restingInk, "drawn off at once")
    XCTAssertEqual(button.accessibilityValue() as? String, "Off")
  }

  func testNoAutoModeSwitchWhereTheAgentOffersNone() {
    let view = makeScreenSizedView()
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .opencode,
      state: .finished, body: "Done."))
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(view.isAutoModeVisibleForTesting)
    view.leaveAddressing(animated: false)
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(view.isAutoModeVisibleForTesting, "never on the first screen")
  }

  func testGrownChatDraftUsesFullTextWidthWithControlsAlongTheBottom() {
    let view = makeScreenSizedView()
    view.setWorkingDirectory(.forNewPrompt(path: "/tmp/repo", honoursWorkingDirectory: true))
    view.setAcceptsAttachments(true)
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .codex,
      state: .finished, body: "Done."))
    view.setChatDraft(PromptDraft(String(repeating: "A paragraph of follow-up instructions. ", count: 20)))
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()
    let field = view.promptCapsuleFrameForTesting
    let text = view.promptTextFrameForTesting
    let folder = view.convert(view.workingDirectoryChipForTesting.bounds,
      from: view.workingDirectoryChipForTesting)
    XCTAssertGreaterThan(text.width, field.width * 0.8)
    XCTAssertLessThanOrEqual(folder.midY + ComposerControlGroup.glyph / 2, text.minY + 0.5,
                             "text is above the icon row")
    XCTAssertTrue(field.contains(folder))
    XCTAssertTrue(field.contains(view.convert(view.planRingForTesting.bounds, from: view.planRingForTesting)))
    view.setVoiceListening(true)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.promptTextFrameForTesting, text, "recording preserves draft wrapping")
    view.setVoiceListening(false)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.promptTextFrameForTesting, text, "processing keeps that same width")
    XCTAssertEqual(view.promptCapsuleFrameForTesting.height, field.height, accuracy: 0.5)
  }

  // MARK: - ScreenAgents

  private func openHistory(_ view: AgentPaletteView) {
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
  }

  private func tab(_ agent: AgentId?, in view: AgentPaletteView) throws -> AgentHistoryTabView {
    try XCTUnwrap(view.historyTabsForTesting.tabsForTesting.first { $0.agent == agent })
  }

  func testHistoryOpensUnderTheDayItHappenedOnWithTheTabsAboveIt() {
    let view = makeScreenSizedView()
    view.setSessions([
      .row("ship the linter", .claude, updatedAt: Date()),
      .row("last week's bug", .claude, updatedAt: Date().addingTimeInterval(-86400))
    ], activeSessionID: nil)

    openHistory(view)

    XCTAssertEqual(view.historyHeadingsForTesting, ["Today", "Yesterday"])
    XCTAssertFalse(view.historyTabsForTesting.isHidden)
    XCTAssertEqual(
      view.historyTabsForTesting.tabsForTesting.map(\.agent),
      [nil] + AgentHistory.tabOrder.map { Optional($0) },
      "the strip is Latest and the same four wherever the history came from"
    )
  }

  func testTheHistoryOpensOnLatest() {
    let view = makeScreenSizedView()
    view.setSessions([.row("codex work", .codex)], activeSessionID: nil)
    openHistory(view)
    XCTAssertNil(view.activeHistoryAgent)
    XCTAssertEqual(view.historyTabsForTesting.tabsForTesting.first?.title, "All")

    view.setSessions([.row("codex work", .codex), .row("claude work", .claude)], activeSessionID: nil)
    XCTAssertNil(view.activeHistoryAgent)
    XCTAssertEqual(view.resultItemsForTesting.count, 2, "Latest is every agent")
  }

  func testHistoryKeepsItsFullFrameAcrossRowCountsTabsAndSearch() throws {
    let view = makeScreenSizedView()
    view.setSessions([.row("fix login", .claude)], activeSessionID: nil)
    openHistory(view)
    view.cancelAllAnimationsAndSettle()
    let shell = view.unifiedSurfaceFrameForTesting
    let fullHeight = AgentPaletteMetrics.historySurfaceHeight
    XCTAssertEqual(shell.width, AgentPaletteMetrics.promptSize.width, accuracy: 0.5)
    XCTAssertEqual(shell.height, min(fullHeight, shell.maxY - AgentPaletteMetrics.safeAreaY),
                   accuracy: 0.5)

    view.setSessions([.row("fix login", .claude)]
      + (0..<20).map { .row("codex task \($0)", .codex) }, activeSessionID: nil)
    view.layoutSubtreeIfNeeded()
    view.cancelAllAnimationsAndSettle()
    XCTAssertEqual(view.unifiedSurfaceFrameForTesting, shell)
    XCTAssertGreaterThan(view.resultItemsForTesting.count, AgentPaletteMetrics.resultsMaxVisibleRows)

    for agent in [AgentId.claude, .codex, .grok] {
      try tab(agent, in: view).pressForTesting()
      view.layoutSubtreeIfNeeded()
      view.cancelAllAnimationsAndSettle()
      XCTAssertEqual(view.unifiedSurfaceFrameForTesting, shell)
    }
    XCTAssertTrue(view.resultItemsForTesting.isEmpty)

    try tab(nil, in: view).pressForTesting()
    for query in ["login", "no-such-chat"] {
      view.field.setDraft(PromptDraft(query))
      view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))
      view.layoutSubtreeIfNeeded()
      view.cancelAllAnimationsAndSettle()
      XCTAssertEqual(view.mode, .search)
      XCTAssertEqual(view.unifiedSurfaceFrameForTesting, shell)
    }
    XCTAssertTrue(view.resultItemsForTesting.isEmpty)
  }

  func testAChosenTabStaysChosen() throws {
    let view = makeScreenSizedView()
    view.setSessions([.row("claude work", .claude), .row("codex work", .codex)], activeSessionID: nil)
    openHistory(view)
    try tab(.codex, in: view).pressForTesting()

    view.setSessions([.row("claude work", .claude), .row("codex work", .codex),
                      .row("more claude", .claude)], activeSessionID: nil)
    XCTAssertEqual(view.activeHistoryAgent, .codex)
    view.closeSwitcher()
    openHistory(view)
    XCTAssertEqual(view.activeHistoryAgent, .codex)
  }

  func testLatestBringsEveryAgentBackAndTheLitTabIsNotAToggle() throws {
    let view = makeScreenSizedView()
    view.setSessions([
      .row("claude work", .claude),
      .row("codex work", .codex)
    ], activeSessionID: nil)
    openHistory(view)

    try tab(.codex, in: view).pressForTesting()
    XCTAssertEqual(view.activeHistoryAgent, .codex)
    XCTAssertEqual(view.resultItemsForTesting.map(\.title), ["codex work"])

    try tab(.codex, in: view).pressForTesting()
    XCTAssertEqual(view.activeHistoryAgent, .codex, "radio, not a toggle")

    try tab(nil, in: view).pressForTesting()
    XCTAssertNil(view.activeHistoryAgent)
    XCTAssertEqual(view.resultItemsForTesting.map(\.title), ["claude work", "codex work"])
  }

  func testAnEmptyTabIsClickableAndSaysThereIsNothingThere() throws {
    let view = makeScreenSizedView()
    view.setSessions([.row("claude work", .claude)], activeSessionID: nil)
    openHistory(view)

    try tab(.grok, in: view).pressForTesting()

    XCTAssertEqual(view.activeHistoryAgent, .grok)
    XCTAssertTrue(view.resultItemsForTesting.isEmpty)
    XCTAssertTrue(view.historyHeadingsForTesting.isEmpty)
    XCTAssertEqual(view.emptyResultsTitleForTesting, "No chats with Grok yet")
  }

  func testAnEmptyHistorySaysThereAreNoChats() {
    let view = makeScreenSizedView()
    view.setSessions([], activeSessionID: nil)
    openHistory(view)

    XCTAssertNil(view.activeHistoryAgent)
    XCTAssertEqual(view.emptyResultsTitleForTesting, "No chats yet")
  }

  func testSearchDropsTheHistoryChrome() {
    let view = makeScreenSizedView()
    view.setSessions([
      .row("fix login", .claude),
      .row("write docs", .codex)
    ], activeSessionID: nil)
    openHistory(view)
    XCTAssertFalse(view.historyHeadingsForTesting.isEmpty)

    view.field.setDraft(PromptDraft("login"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))

    XCTAssertEqual(view.mode, .search)
    XCTAssertTrue(view.historyTabsForTesting.isHidden)
    XCTAssertTrue(view.historyHeadingsForTesting.isEmpty)
    XCTAssertEqual(view.resultItemsForTesting.map(\.title), ["fix login"])
  }

  func testTheChosenTabIsStillChosenWhenTheHistoryIsReopened() throws {
    let view = makeScreenSizedView()
    view.setSessions([
      .row("claude work", .claude),
      .row("codex work", .codex)
    ], activeSessionID: nil)
    openHistory(view)
    try tab(.codex, in: view).pressForTesting()

    view.closeSwitcher()
    openHistory(view)

    XCTAssertEqual(view.activeHistoryAgent, .codex)
    XCTAssertEqual(view.resultItemsForTesting.map(\.title), ["codex work"])
  }

  func testHeadingsAreNotStepsInTheKeyboardWalk() {
    let view = makeScreenSizedView()
    view.setSessions([
      .row("today", .claude, updatedAt: Date()),
      .row("yesterday", .claude, updatedAt: Date().addingTimeInterval(-86400))
    ], activeSessionID: nil)
    openHistory(view)

    XCTAssertEqual(view.historyHeadingsForTesting.count, 2)
    XCTAssertEqual(view.selectedResultIndexForTesting, 0)
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertEqual(view.selectedResultIndexForTesting, 1)
    XCTAssertEqual(view.resultItemsForTesting[1].title, "yesterday")
  }

  func testANoticeInAWindowKeepsItsWords() {
    let view = makeScreenSizedView()
    let window = NSWindow(
      contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: view.frame.size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .opencode,
      state: .finished, body: "Done."))
    view.layoutSubtreeIfNeeded()
    view.showError("This chat is open in OpenCode right now. Sending from here too would put two of you in it.")
    view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(view.errorFrameForTesting.width, 300)
  }
}

// MARK: - ScreenAgents: the tab strip from the reference

extension AgentPaletteViewTests {
  private func press(_ selector: Selector, in view: AgentPaletteView) -> Bool {
    view.textView(view.field, doCommandBy: selector)
  }

  func testArrowsWalkTheTabsAndStopAtTheEnds() {
    let view = makeScreenSizedView()
    view.setSessions([.row("claude work", .claude), .row("codex work", .codex)], activeSessionID: nil)
    openHistory(view)
    XCTAssertNil(view.activeHistoryAgent, "it opens on Latest")
    XCTAssertTrue(press(#selector(NSResponder.moveLeft(_:)), in: view))
    XCTAssertNil(view.activeHistoryAgent, "← stops there")

    var visited: [AgentId?] = []
    for _ in 0...AgentHistory.tabOrder.count {
      XCTAssertTrue(press(#selector(NSResponder.moveRight(_:)), in: view))
      visited.append(view.activeHistoryAgent)
    }
    XCTAssertEqual(
      visited,
      AgentHistory.tabOrder.map { Optional($0) } + [AgentHistory.tabOrder.last],
      "→ walks every tab in order and stops on the last"
    )

    for _ in 0...AgentHistory.tabOrder.count {
      XCTAssertTrue(press(#selector(NSResponder.moveLeft(_:)), in: view))
    }
    XCTAssertNil(view.activeHistoryAgent, "← ends on Latest")
  }

  func testAnArrowFiltersTheListLikeAClick() {
    let view = makeScreenSizedView()
    view.setSessions([.row("claude work", .claude), .row("codex work", .codex)], activeSessionID: nil)
    openHistory(view)

    let target = AgentHistory.adjacentTab(to: view.activeHistoryAgent, by: 1)
    _ = press(#selector(NSResponder.moveRight(_:)), in: view)

    XCTAssertEqual(view.activeHistoryAgent, target)
    XCTAssertTrue(view.resultItemsForTesting.allSatisfy { $0.agent == target })
  }

  func testArrowsMoveTheCaretInASearch() {
    let view = makeScreenSizedView()
    view.setSessions([.row("fix login", .claude)], activeSessionID: nil)
    openHistory(view)
    let before = view.activeHistoryAgent
    view.field.setDraft(PromptDraft("login"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))

    XCTAssertFalse(press(#selector(NSResponder.moveRight(_:)), in: view))
    XCTAssertFalse(press(#selector(NSResponder.moveLeft(_:)), in: view))
    XCTAssertEqual(view.activeHistoryAgent, before, "the arrows moved the caret, not the tab")
  }

  func testArrowsAreTheFieldsWhileTheHistoryIsClosed() {
    let view = makeScreenSizedView()
    view.setSessions([.row("claude work", .claude)], activeSessionID: nil)
    XCTAssertFalse(press(#selector(NSResponder.moveRight(_:)), in: view))
  }

  func testTheChosenTabStandsOnGlass() throws {
    let view = makeScreenSizedView()
    view.setSessions([.row("claude work", .claude)], activeSessionID: nil)
    openHistory(view)
    let strip = view.historyTabsForTesting
    strip.layoutSubtreeIfNeeded()
    XCTAssertTrue(strip.glassForTesting is NSGlassEffectView)
    XCTAssertEqual(strip.glassFrameForTesting, try tab(nil, in: view).frame)

    try tab(.codex, in: view).pressForTesting()
    strip.layoutSubtreeIfNeeded()

    let codex = try tab(.codex, in: view)
    XCTAssertEqual(strip.glassFrameForTesting, codex.frame)
    XCTAssertEqual(codex.frame.height, AgentPaletteMetrics.historyTabHeight, accuracy: 0.5)
    XCTAssertEqual(
      (strip.glassForTesting as? NSGlassEffectView)?.cornerRadius,
      AgentPaletteMetrics.historyTabCornerRadius,
      "the chosen segment is a capsule"
    )
  }

  func testTheTabStripYieldsToTheShutCardAndKeepsItsHeightOpen() throws {
    let view = hostOffscreen(makeScreenSizedView())
    view.setSessions([.row("claude work", .claude)], activeSessionID: nil)
    view.layoutSubtreeIfNeeded()
    let strip = view.historyTabsForTesting
    let height = try XCTUnwrap(strip.constraints.first {
      $0.firstItem === strip && $0.firstAttribute == .height && $0.secondItem == nil
    })
    XCTAssertLessThan(
      height.priority.rawValue, NSLayoutConstraint.Priority.required.rawValue,
      "a required height cannot stand in a card of height 0"
    )

    openHistory(view)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(strip.frame.height, AgentPaletteMetrics.historyTabStripHeight, accuracy: 0.5)
  }

  func testOnlyTheChosenTabsFacesAreAlive() throws {
    let view = hostOffscreen(makeScreenSizedView())
    view.setSessions([.row("claude work", .claude), .row("codex work", .codex)], activeSessionID: nil)
    openHistory(view)
    let strip = view.historyTabsForTesting
    strip.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      try tab(nil, in: view).liveFaceLooksForTesting,
      try tab(nil, in: view).faceAgents.map { MascotLook.face(for: $0) },
      "Latest, chosen, wears its faces alive"
    )
    XCTAssertTrue(try tab(.claude, in: view).liveFaceLooksForTesting.isEmpty)

    try tab(.claude, in: view).pressForTesting()
    strip.layoutSubtreeIfNeeded()
    XCTAssertEqual(try tab(.claude, in: view).liveFaceLooksForTesting, [MascotLook.face(for: .claude)])
    XCTAssertTrue(try tab(nil, in: view).liveFaceLooksForTesting.isEmpty, "Latest's go back to pictures")
    let alive = strip.tabsForTesting.map(\.liveFaceLooksForTesting.count).reduce(0, +)
    XCTAssertEqual(alive, 1)
  }

  func testOnlyAClickMakesTheChosenTabsFacesReact() throws {
    try XCTSkipIf(MotionPreferences.reduceMotion, "a poke is motion, and Reduce Motion is on")
    let view = hostOffscreen(makeScreenSizedView())
    view.setSessions([.row("claude work", .claude), .row("codex work", .codex)], activeSessionID: nil)
    openHistory(view)
    let latest = try tab(nil, in: view)
    XCTAssertFalse(latest.liveFaceReactionsForTesting.isEmpty, "precondition: Latest's faces are alive")
    XCTAssertTrue(latest.liveFaceReactionsForTesting.allSatisfy { $0 == nil }, "↓ is a keystroke")

    XCTAssertTrue(press(#selector(NSResponder.moveRight(_:)), in: view))
    let walked = try XCTUnwrap(view.historyTabsForTesting.tabsForTesting.first(where: \.isActive))
    XCTAssertNotNil(walked.agent, "precondition: → left Latest")
    XCTAssertEqual(walked.liveFaceReactionsForTesting, [nil], "→ brings the face alive without a reaction")

    let clicked = try tab(.codex, in: view)
    XCTAssertNotEqual(clicked.agent, walked.agent, "precondition: a different tab")
    clicked.pressForTesting()
    XCTAssertEqual(clicked.liveFaceReactionsForTesting.count, 1)
    XCTAssertNotNil(clicked.liveFaceReactionsForTesting.first ?? nil, "a click is answered")
  }

  func testSwitchingTabsSlidesTheGlass() throws {
    let view = hostOffscreen(makeScreenSizedView())
    view.setSessions([.row("claude work", .claude), .row("codex work", .codex)], activeSessionID: nil)
    openHistory(view)
    let strip = view.historyTabsForTesting
    strip.layoutSubtreeIfNeeded()
    try tab(.claude, in: view).pressForTesting()
    strip.layoutSubtreeIfNeeded()
    for _ in 0..<60 { strip.advanceForTesting(by: 1.0 / 60) }
    let start = try XCTUnwrap(strip.glassFrameForTesting)

    try tab(.codex, in: view).pressForTesting()
    strip.layoutSubtreeIfNeeded()
    XCTAssertTrue(strip.isTravellingForTesting)
    strip.advanceForTesting(by: 0.05)

    let midway = try XCTUnwrap(strip.glassFrameForTesting)
    let end = try tab(.codex, in: view).frame
    XCTAssertGreaterThan(midway.minX, start.minX, "it has left the first tab")
    XCTAssertLessThan(midway.minX, end.minX, "and not yet reached the second")
    XCTAssertEqual(midway.width, end.width, accuracy: 0.5, "equal segments: only its place moves")

    for _ in 0..<120 { strip.advanceForTesting(by: 1.0 / 120) }
    XCTAssertFalse(strip.isTravellingForTesting)
    XCTAssertEqual(strip.glassFrameForTesting, try tab(.codex, in: view).frame)
  }

  func testAHistoryOfHundredsBuildsOnlyTheRowsNearTheCard() throws {
    let view = hostOffscreen(makeScreenSizedView())
    let chats = (0..<300).map { BolttyAISessionItem.row("chat \($0)", .claude) }
    view.setSessions(chats, activeSessionID: nil)
    openHistory(view)
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()
    let list = view.resultsStackForTesting
    let clip = try XCTUnwrap(list.superview as? NSClipView)
    func built() -> [BolttyAISessionRowView] {
      list.subviews.compactMap { $0 as? BolttyAISessionRowView }
    }
    func shown(_ chat: BolttyAISessionItem) throws -> BolttyAISessionRowView {
      let row = try XCTUnwrap(built().first { $0.item.id == chat.id }, "\(chat.title) was never built")
      XCTAssertFalse(row.isHidden)
      XCTAssertTrue(clip.bounds.contains(row.frame), "\(chat.title) is in the card")
      return row
    }

    XCTAssertEqual(view.resultItemsForTesting.count, 300)
    XCTAssertLessThan(built().count, 40, "only the rows within reach of the card")
    _ = try shown(chats[0])

    for _ in 0..<60 {
      _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    }
    XCTAssertEqual(view.selectedResultIndexForTesting, 60)
    XCTAssertGreaterThan(try shown(chats[60]).highlightFillAlphaForTesting, 0.05, "and lit as chosen")

    clip.scroll(to: NSPoint(x: 0, y: list.frame.height - clip.bounds.height))
    _ = try shown(chats[299])
    XCTAssertLessThan(built().count, 120, "a scroll builds what it passes near, not the list")
  }

  func testReturningToATabReusesItsRows() throws {
    let view = makeScreenSizedView()
    view.setSessions([.row("claude work", .claude), .row("codex work", .codex)], activeSessionID: nil)
    openHistory(view)
    func rows() -> [BolttyAISessionRowView] {
      view.resultsStackForTesting.arrangedSubviews.compactMap { $0 as? BolttyAISessionRowView }
    }
    try tab(.claude, in: view).pressForTesting()
    let claudeRow = try XCTUnwrap(rows().first)

    try tab(.codex, in: view).pressForTesting()
    XCTAssertEqual(rows().map(\.item.title), ["codex work"])
    XCTAssertTrue(claudeRow.isHidden, "a filtered-out row is hidden in place, not torn out of the window")
    XCTAssertFalse(
      view.resultsStackForTesting.arrangedSubviews.contains(claudeRow),
      "and it is no longer part of the column"
    )

    try tab(.claude, in: view).pressForTesting()
    XCTAssertTrue(try XCTUnwrap(rows().first) === claudeRow)
  }

  func testTheTabsAreEqualSegmentsOfOneTrack() throws {
    let view = makeScreenSizedView()
    view.setSessions([.row("claude work", .claude)], activeSessionID: nil)
    openHistory(view)
    let strip = view.historyTabsForTesting
    strip.layoutSubtreeIfNeeded()

    let track = strip.trackFrameForTesting
    let inset = AgentPaletteMetrics.historyTabTopInset
    let padding = AgentPaletteMetrics.historyTabTrackPadding
    XCTAssertEqual(track.height, AgentPaletteMetrics.historyTabTrackHeight, accuracy: 0.5)
    XCTAssertEqual(track.minX, inset, accuracy: 0.5)
    XCTAssertEqual(track.minY, inset, accuracy: 0.5)
    XCTAssertEqual(track.maxX, strip.bounds.width - inset, accuracy: 0.5)

    let frames = strip.tabsForTesting.map(\.frame)
    XCTAssertEqual(frames.count, 1 + AgentHistory.tabOrder.count)
    XCTAssertEqual(frames.first!.minX, track.minX + padding, accuracy: 0.5)
    XCTAssertEqual(frames.last!.maxX, track.maxX - padding, accuracy: 0.5)
    let widths = frames.map(\.width)
    XCTAssertLessThanOrEqual(widths.max()! - widths.min()!, 1, "every segment is equal")
    for (left, right) in zip(frames, frames.dropFirst()) {
      XCTAssertEqual(left.maxX, right.minX, accuracy: 0.5, "with no gap between them")
    }
    for frame in frames {
      XCTAssertEqual(frame.height, AgentPaletteMetrics.historyTabHeight, accuracy: 0.5)
      XCTAssertEqual(frame.midY, track.midY, accuracy: 0.5)
    }
    XCTAssertEqual(strip.glassFrameForTesting, frames.first, "the glass is the chosen segment")
  }

  func testEachTabStacksItsFacesOverItsName() throws {
    let view = makeScreenSizedView()
    view.setSessions([.row("claude work", .claude)], activeSessionID: nil)
    openHistory(view)
    let strip = view.historyTabsForTesting
    strip.layoutSubtreeIfNeeded()
    for tab in strip.tabsForTesting {
      tab.layoutSubtreeIfNeeded()
      let label = tab.labelFrameForTesting
      for face in tab.faceFramesForTesting {
        XCTAssertLessThanOrEqual(face.maxY, label.minY + 0.5, "\(tab.title): the face is above its name")
        XCTAssertGreaterThanOrEqual(face.minX, -0.5)
        XCTAssertLessThanOrEqual(face.maxX, tab.bounds.width + 0.5)
      }
      let faces = tab.faceFramesForTesting.reduce(NSRect.null) { $0.union($1) }
      XCTAssertEqual(faces.midX, tab.bounds.midX, accuracy: 1, "\(tab.title): centred")
    }
    let latest = try tab(nil, in: view)
    let claude = try tab(.claude, in: view)
    XCTAssertGreaterThan(
      latest.labelFrameForTesting.minY, claude.labelFrameForTesting.minY,
      "Latest's name stands lower, under its taller group"
    )
  }
}

// MARK: - One mascot per agent

extension AgentPaletteViewTests {
  func testEveryTabWearsItsFacesAndLatestWearsEveryAgentThatCanTakeAPrompt() throws {
    let view = makeScreenSizedView(targets: AgentHistory.tabOrder)
    view.setSessions(
      [.row("a", .claude), .row("b", .codex), .row("c", .opencode), .row("d", .grok)],
      activeSessionID: nil
    )
    openHistory(view)
    let strip = view.historyTabsForTesting
    strip.layoutSubtreeIfNeeded()

    try tab(.claude, in: view).pressForTesting()
    strip.layoutSubtreeIfNeeded()

    let latest = try tab(nil, in: view)
    XCTAssertEqual(latest.faceAgents, AgentHistory.tabOrder, "all five, Antigravity too")
    XCTAssertEqual(latest.faceImagesForTesting.count, 5, "one face for each")
    XCTAssertTrue(latest.faceImagesForTesting.allSatisfy { $0 != nil })
    for agent in AgentHistory.tabOrder {
      let images = try tab(agent, in: view).faceImagesForTesting
      XCTAssertEqual(images.count, 1, "\(agent) wears one face")
      XCTAssertNotNil(images.first ?? nil, "\(agent) has a picture")
    }
  }

  /// All wears the agents that can take a prompt — the panel's choices — and
  /// is composed again when they change.
  func testLatestIsComposedOfTheAgentsThatAreOn() throws {
    let view = hostOffscreen(makeScreenSizedView(targets: [.claude, .opencode, .grok]))
    view.setSessions([.row("claude work", .claude)], activeSessionID: nil)
    openHistory(view)
    view.historyTabsForTesting.layoutSubtreeIfNeeded()

    let latest = try tab(nil, in: view)
    XCTAssertEqual(latest.faceAgents, [.claude, .opencode, .grok])
    XCTAssertEqual(latest.faceImagesForTesting.count, 3)

    view.setAgentChoices([.codex], planned: .codex)
    view.historyTabsForTesting.layoutSubtreeIfNeeded()
    XCTAssertEqual(try tab(nil, in: view).faceAgents, [.codex], "one agent on: one face")
    XCTAssertEqual(try tab(nil, in: view).faceImagesForTesting.count, 1)

    view.setAgentChoices([], planned: nil)
    XCTAssertEqual(
      try tab(nil, in: view).faceAgents, AgentHistoryTabView.fallbackFaceAgents,
      "none ready yet: all of them, as the strip's tabs are")
  }

  func testTheFacesOfLatestStandTogetherOnOneSquare() {
    let side: CGFloat = 40
    for count in 1...AgentHistoryTabView.clusterCapacity {
      let frames = AgentHistoryTabView.faceFrames(count: count, in: side)
      XCTAssertEqual(frames.count, count)
      let group = frames.reduce(CGRect.null) { $0.union($1) }
      XCTAssertGreaterThanOrEqual(group.minX, -0.5, "\(count): inside the square")
      XCTAssertGreaterThanOrEqual(group.minY, -0.5)
      XCTAssertLessThanOrEqual(group.maxX, side + 0.5)
      XCTAssertLessThanOrEqual(group.maxY, side + 0.5)
      XCTAssertEqual(group.midX, side / 2, accuracy: 1, "\(count): centred")
      XCTAssertEqual(group.midY, side / 2, accuracy: 1)
      for (index, face) in frames.enumerated() {
        for other in frames.dropFirst(index + 1) {
          XCTAssertLessThan(
            face.intersection(other).width * face.intersection(other).height,
            face.width * face.height * 0.35,
            "\(count): a face is never mostly under another")
        }
      }
    }
    XCTAssertEqual(AgentHistoryTabView.faceFrames(count: 1, in: side), [CGRect(x: 0, y: 0, width: 40, height: 40)])
  }

  func testSegmentsAreEqualWhereTheNamesFitAndGrowWhereTheyDoNot() {
    let needs: [CGFloat] = [49, 60, 56, 85, 44, 85]
    let roomy = AgentHistoryTabStripView.segmentWidths(needs: needs, available: 516)
    XCTAssertEqual(roomy.reduce(0, +), 516, accuracy: 0.01)
    XCTAssertLessThanOrEqual(roomy.max()! - roomy.min()!, 0.01, "room enough: every segment is equal")

    let tight = AgentHistoryTabStripView.segmentWidths(needs: needs, available: 416)
    XCTAssertEqual(tight.reduce(0, +), 416, accuracy: 0.01, "still one track, wall to wall")
    XCTAssertEqual(tight[3], 85, accuracy: 0.01, "OpenCode keeps what its name needs")
    XCTAssertEqual(tight[5], 85, accuracy: 0.01, "and so does Antigravity")
    for index in [0, 1, 2, 4] {
      XCTAssertGreaterThanOrEqual(tight[index], needs[index], "the others still fit their names")
      XCTAssertEqual(tight[index], tight[0], accuracy: 0.01, "and share the rest equally")
    }

    let starved = AgentHistoryTabStripView.segmentWidths(needs: [100, 100], available: 100)
    XCTAssertEqual(starved, [50, 50], "names that cannot all fit shrink together")
  }

  func testEveryAgentsMarkAboveThePromptIsItsOwn() {
    let view = makeView(targets: AgentId.adapterCases)
    view.prepareForPresentation()
    var looks: [MascotLook] = []
    for agent in AgentId.adapterCases {
      view.render(agent: agent, animated: false)
      let look = view.mascotLookForTesting
      XCTAssertEqual(look, MascotLook.face(for: agent), "\(agent)")
      XCTAssertEqual(view.field.caretPalette, MascotLook.face(for: agent).palette, "the caret's light is \(agent)'s")
      if let look { looks.append(look) }
    }
    XCTAssertEqual(Set(looks).count, AgentId.adapterCases.count, "two agents look alike")
  }

  func testWhereNoAgentSpeaksAnAgentsFaceStands() {
    XCTAssertEqual(
      BolttyAIEmptyResultsView(emptyHistoryFor: .grok).mascotLookForTesting, MascotLook.face(for: .grok))
    XCTAssertEqual(
      BolttyAIEmptyResultsView(query: "nothing", agent: .codex).mascotLookForTesting, MascotLook.face(for: .codex))
    XCTAssertEqual(BolttyAIEmptyResultsView(query: "").mascotLookForTesting, MascotLook.face(for: nil))
    XCTAssertEqual(
      BolttyAINoAgentsView().faceLooksForTesting, AgentHistory.tabOrder.map { MascotLook.face(for: $0) })
  }

  func testTheListeningOrbGrowsRoundTheWordsAndWearsTheFaceThePromptWore() {
    let view = hostOffscreen(makeView(targets: [.claude]))
    view.prepareForPresentation()
    view.field.setDraft(PromptDraft("typed before"))
    view.layoutSubtreeIfNeeded()

    view.setVoiceListening(true)
    view.applyVoiceTranscript("fix the failing test")
    view.layoutSubtreeIfNeeded()
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()

    XCTAssertTrue(view.isCompactListeningForTesting)
    let capsule = view.unifiedSurfaceFrameForTesting
    XCTAssertGreaterThan(
      capsule.width, AgentPaletteMetrics.listeningOrbDiameter + 40,
      "the orb grows into a capsule round the words being said"
    )
    XCTAssertLessThanOrEqual(capsule.width, AgentPaletteMetrics.listeningMaxWidth + 0.5)
    XCTAssertEqual(capsule.height, AgentPaletteMetrics.listeningOrbDiameter, accuracy: 0.5)
    XCTAssertEqual(
      view.listeningWordsForTesting, "fix the failing test",
      "the words of this take, not the draft typed before it"
    )
    XCTAssertTrue(view.listeningWordsShownForTesting)

    view.applyVoiceTranscript(String(repeating: "and then some more words ", count: 12))
    view.layoutSubtreeIfNeeded()
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      view.unifiedSurfaceFrameForTesting.width, AgentPaletteMetrics.listeningMaxWidth, accuracy: 0.5,
      "no longer than the prompt the words land in"
    )
    XCTAssertEqual(
      view.voiceGlowForTesting.paletteIDForTesting, view.mascotPaletteIDForTesting,
      "the orb's light is the face the prompt wore"
    )
    view.setVoiceListening(false)
  }
}

extension AgentPaletteViewTests {
  func testALayoutMidTravelDoesNotRestartTheSpring() throws {
    let view = hostOffscreen(makeScreenSizedView())
    view.setSessions([.row("a", .claude), .row("b", .codex)], activeSessionID: nil)
    openHistory(view)
    let strip = view.historyTabsForTesting
    strip.layoutSubtreeIfNeeded()
    try tab(.claude, in: view).pressForTesting()
    strip.layoutSubtreeIfNeeded()
    for _ in 0..<60 { strip.advanceForTesting(by: 1.0 / 60) }
    XCTAssertFalse(strip.isTravellingForTesting)

    try tab(nil, in: view).pressForTesting()
    strip.layoutSubtreeIfNeeded()
    var ticks = 0
    while strip.isTravellingForTesting, ticks < 600 {
      strip.advanceForTesting(by: 1.0 / 60)
      strip.needsLayout = true
      strip.layoutSubtreeIfNeeded()
      ticks += 1
    }
    XCTAssertLessThan(ticks, 40, "it lands in well under a second at 60 Hz, layouts or not")
    XCTAssertEqual(strip.glassFrameForTesting, try tab(nil, in: view).frame)
  }
}


extension AgentPaletteViewTests {
  func testOnlyLatestsRowsWearTheirAgentsFace() throws {
    let view = makeScreenSizedView()
    view.setSessions([.row("claude work", .claude), .row("codex work", .codex)], activeSessionID: nil)
    openHistory(view)
    XCTAssertNil(view.activeHistoryAgent)
    let latest = view.resultRowViewsForTesting
    XCTAssertEqual(latest.count, 2)
    XCTAssertTrue(latest.allSatisfy { $0.faceImageForTesting != nil }, "Latest rows say whose they are")

    try tab(.codex, in: view).pressForTesting()
    let codex = view.resultRowViewsForTesting
    XCTAssertFalse(codex.isEmpty)
    XCTAssertTrue(codex.allSatisfy { $0.faceImageForTesting == nil }, "under an agent's tab the strip already says")

    try tab(nil, in: view).pressForTesting()
    XCTAssertTrue(view.resultRowViewsForTesting.allSatisfy { $0.faceImageForTesting != nil })
  }
}

// MARK: - The keys after the prompt, rendered

extension AgentPaletteViewTests {
  func testRenderTheTrailingHint() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let view = hostOffscreen(makeScreenSizedView())
    view.appearance = NSAppearance(named: .darkAqua)
    view.window?.backgroundColor = NSColor(white: 0.08, alpha: 1)
    view.setAgentChoices([.claude, .codex], planned: .claude)
    view.field.insertPlainText("вфіві")
    view.field.restTrailingHintForTesting()
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()
    view.window?.displayIfNeeded()
    let card = view.unifiedSurfaceFrameForTesting.insetBy(dx: -24, dy: -24)
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: card))
    view.cacheDisplay(in: card, to: rep)
    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: dir).appendingPathComponent("prompt-trailing-hint.png"))
  }
}

// MARK: - The history, rendered

extension AgentPaletteViewTests {
  func testRenderTheHistory() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let view = hostOffscreen(makeScreenSizedView())
    view.appearance = NSAppearance(named: .darkAqua)
    view.window?.backgroundColor = NSColor(white: 0.08, alpha: 1)
    let reply = "I couldn't find anything specific for the great idea is a what we do before"
    func item(_ title: String, _ agent: AgentId, _ age: TimeInterval) -> BolttyAISessionItem {
      BolttyAISessionItem(
        id: UUID(), title: title, subtitle: reply, agent: agent, isCurrent: false,
        updatedAt: Date().addingTimeInterval(-age)
      )
    }
    view.setSessions([
      BolttyAISessionItem(
        id: UUID(), title: "Hello, what about pizza?", subtitle: "Working…", agent: .claude,
        isCurrent: false, updatedAt: Date().addingTimeInterval(-60), state: .running
      ),
      item("SSD and RAM status check", .codex, 120),
      item("Шо ти там?", .opencode, 180),
      item("Додати S06E02 на сервер у H265", .claude, 86_400 + 60),
      item("Удаление Herdr с компьютера", .grok, 86_400 + 120),
      item("Завис завантаження фільму на 70%", .codex, 30),
      item("Ship the linter", .claude, 3 * 86_400),
    ], activeSessionID: nil)
    openHistory(view)
    for agent in [AgentId?.none, .claude] {
      if view.historyTabsForTesting.activeAgent != agent {
        try tab(agent, in: view).pressForTesting()
      }
      let strip = view.historyTabsForTesting
      strip.layoutSubtreeIfNeeded()
      for _ in 0..<120 { strip.advanceForTesting(by: 1.0 / 60) }
      view.cancelAllAnimationsAndSettle()
      view.layoutSubtreeIfNeeded()
      view.window?.displayIfNeeded()
      let card = view.unifiedSurfaceFrameForTesting.insetBy(dx: -24, dy: -24)
      guard let rep = view.bitmapImageRepForCachingDisplay(in: card) else {
        return XCTFail("no bitmap")
      }
      view.cacheDisplay(in: card, to: rep)
      let name = agent.map { "history-\($0.rawValue).png" } ?? "history-latest.png"
      try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
  }
}

@MainActor
final class ComposerInkTests: XCTestCase {
  func testTheChatComposersInkStandsTwentyIn() throws {
    let view = AgentPaletteView()
    view.appearance = NSAppearance(named: .darkAqua)
    view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    view.prepareForPresentation()
    view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .opencode, state: .finished, body: "A reply."))
    view.cancelAllAnimationsAndSettle()
    view.field.setDraft(PromptDraft("Do anything"))
    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.field))
    let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    addTeardownBlock { window.close() }
    window.contentView = view
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()

    let box = view.composerBoxInWindowForTesting
    let ink = try XCTUnwrap(view.typedFirstInkInWindowForTesting)
    XCTAssertEqual(ink.left - box.minX, AgentPaletteMetrics.chatComposerInkInset, accuracy: 0.5, "the first letter's ink, from the left")
    XCTAssertEqual(box.maxY - ink.capTop, AgentPaletteMetrics.chatComposerInkInset, accuracy: 0.5, "the capitals' tops, from the top")
  }
}

@MainActor
final class FolderChipContactSheet: XCTestCase {
  func testRenderTheFolderChip() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let home = WorkingDirectoryResolver.homeDirectoryPath
    let cases: [(String, String, Bool)] = [
      ("folder-home", home, false),
      ("folder-named", home + "/Documents/Projects/boltty", false),
      ("folder-long", home + "/Documents/Projects/a-rather-long-folder-name-for-a-project", false),
      ("folder-chat", home + "/Documents/Projects/boltty", true),
    ]
    for (name, path, chat) in cases {
      let view = AgentPaletteView()
      view.appearance = NSAppearance(named: .darkAqua)
      view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
      view.prepareForPresentation()
      view.setWorkingDirectory(.forNewPrompt(path: path, honoursWorkingDirectory: true))
      view.setUsage(AgentUsage(windows: [AgentUsageWindow(kind: .weekly, usedPercent: 20, resetsAt: nil)]),
                    agent: .claude)
      if chat {
        view.setAcceptsAttachments(true)
        view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .claude, state: .finished, body: "Done."))
      }
      view.cancelAllAnimationsAndSettle()
      let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .darkAqua)
      let ground = NSView(frame: view.bounds)
      ground.wantsLayer = true
      ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
      ground.addSubview(view)
      window.contentView = ground
      view.cancelAllAnimationsAndSettle()
      ground.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      CATransaction.flush()
      let box = view.composerBoxInWindowForTesting.insetBy(dx: -12, dy: -12)
      let bitmap = try XCTUnwrap(ground.bitmapImageRepForCachingDisplay(in: box))
      ground.cacheDisplay(in: box, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
      window.close()
    }
  }
}
