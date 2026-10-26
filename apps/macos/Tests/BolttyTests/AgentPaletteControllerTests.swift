import AppKit
import XCTest
@testable import Boltty

@MainActor
final class AgentPaletteControllerTests: XCTestCase {
  private func makeController() -> (
    model: AppModel,
    controller: AgentPaletteController,
    conversations: FakeBolttyAIConversations
  ) {
    let model = AppModel(settings: AppSettings(bolttyAIHotkey: .optionSpace))
    let conversations = FakeBolttyAIConversations()
    let controller = AgentPaletteController(model: model, conversations: conversations)
    retainedConversations.append(conversations)
    return (model, controller, conversations)
  }

  private var retainedConversations: [FakeBolttyAIConversations] = []

  override func tearDown() async throws {
    retainedConversations.removeAll()
    try await super.tearDown()
  }

  func testSwitcherRowsAreBuiltOnlyWhileTheListIsOpen() throws {
    let (_, controller, conversations) = makeController()
    _ = conversations.addConversation(title: "fix login")
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    let readsAtShow = conversations.switcherReads

    conversations.notifyChanged()
    conversations.notifyChanged()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(conversations.switcherReads, readsAtShow, "the list is closed")

    view.expandResultsForTesting()
    XCTAssertEqual(conversations.switcherReads, readsAtShow + 1, "opening reads them fresh")
    XCTAssertEqual(view.resultItemsForTesting.map(\.title), ["fix login"])

    conversations.notifyChanged()
    conversations.notifyChanged()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(conversations.switcherReads, readsAtShow + 2, "kept current, once per turn")
  }

  func testTheAutoModeSwitchReachesTheConversation() throws {
    let (_, controller, conversations) = makeController()
    let chat = conversations.addConversation(title: "rename")
    let id = chat.id
    conversations.previews[id] = BolttyAISessionPreview(
      id: id, title: chat.title, agent: .claude, state: .finished, body: "Done.", autoMode: true)
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(id)
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(view.isAutoModeVisibleForTesting, "a chat started in Auto Mode shows it")

    view.pressAutoModeForTesting()
    XCTAssertEqual(conversations.autoApproveChanges.map(\.id), [id])
    XCTAssertEqual(conversations.autoApproveChanges.map(\.enabled), [false])
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(view.addressedPreviewForTesting?.autoMode, false, "the store's answer agrees")
  }

  // MARK: - Coming back to the chat it left

  private func thinkingChat(
    _ conversations: FakeBolttyAIConversations, finished: Bool = false
  ) -> UUID {
    let chat = conversations.addConversation(title: "rename")
    var messages = [ConversationMessage(
      id: "u", role: .user, createdAt: Date(), parts: [.text(TextPart(id: "ut", kind: .text, text: "Rename"))])]
    if finished {
      messages.append(ConversationMessage(
        id: "a", role: .agent, createdAt: Date(), completedAt: Date(),
        parts: [.text(TextPart(id: "at", kind: .text, text: "Done."))]))
    }
    conversations.previews[chat.id] = BolttyAISessionPreview(
      id: chat.id, title: chat.title, agent: .claude, state: .running, body: "", messages: messages)
    return chat.id
  }

  func testReopeningWithinAMinuteComesBackToTheChatItLeft() throws {
    let (_, controller, conversations) = makeController()
    let id = thinkingChat(conversations, finished: true)
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(id)
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    controller.hide()
    XCTAssertNil(conversations.addressed, "precondition: nobody reads it while the panel is away")
    XCTAssertFalse(conversations.observed.contains(id))
    controller.show()
    XCTAssertEqual(view.addressedSessionIDForTesting, id, "back on the chat it left")
    XCTAssertEqual(conversations.addressed, id, "read again")
    XCTAssertTrue(conversations.observed.contains(id), "and followed again")
  }

  func testReopeningLaterStartsOnTheFirstScreen() throws {
    let (_, controller, conversations) = makeController()
    controller.resumeWindow = 0
    let id = thinkingChat(conversations, finished: true)
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(id)
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    controller.hide()
    controller.show()
    XCTAssertNil(view.addressedSessionIDForTesting, "the first screen")
    XCTAssertNil(conversations.addressed)
  }

  func testReopeningOnARunningChatStartsItsClockAgain() throws {
    let (_, controller, conversations) = makeController()
    let id = thinkingChat(conversations)
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(id)
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    XCTAssertTrue(view.previewCardForTesting.turnClockIsRunningForTesting, "precondition: the turn keeps time")

    controller.hide()
    XCTAssertFalse(view.previewCardForTesting.turnClockIsRunningForTesting, "stopped with the panel")
    controller.show()
    XCTAssertEqual(view.addressedSessionIDForTesting, id, "precondition: back on the chat")
    XCTAssertTrue(view.previewCardForTesting.turnClockIsRunningForTesting, "and keeping time again")
  }

  func testPanelIsKeyablePanelInstance() {
    let controller = makeController().controller
    guard let panel = controller.window as? KeyablePanel else {
      XCTFail("Window should be KeyablePanel")
      return
    }
    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
  }

  func testPanelStyleMask() {
    let controller = makeController().controller
    guard let panel = controller.window else {
      XCTFail("No window")
      return
    }
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(panel.styleMask.contains(.borderless))
    XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
  }

  func testPanelCollectionBehaviorContainsAcceptedFlags() {
    let controller = makeController().controller
    guard let panel = controller.window else {
      XCTFail("No window")
      return
    }
    XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
    XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
  }

  func testBolttyAIKeepsItsGlassWhileTerminalSurfacesAreOpaque() throws {
    let model = AppModel(settings: AppSettings())
    let controller = AgentPaletteController(model: model)
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    XCTAssertTrue(view.usesSystemGlassBackgroundForTesting)
  }

  func testThePanelCoversTheScreenSoTheSwitcherCannotBeClipped() throws {
    let model = AppModel(settings: AppSettings())
    model.agentCatalog.apply(scannedAgents: [
      InstalledAgent(agent: .claude, executablePath: "/usr/bin/true")
    ])
    let controller = AgentPaletteController(model: model)
    controller.show()
    let window = try XCTUnwrap(controller.window)
    let view = try XCTUnwrap(window.contentView as? AgentPaletteView)
    let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
    let visible = screen.visibleFrame

    XCTAssertEqual(window.frame.width, visible.width, accuracy: 1)
    XCTAssertEqual(window.frame.minY, visible.minY, accuracy: 1)
    XCTAssertEqual(window.frame.maxY, screen.frame.maxY, accuracy: 1)
    XCTAssertEqual(view.topReserve, screen.frame.maxY - visible.maxY, accuracy: 1)

    view.setSessions([.row("me@m1:~")], activeSessionID: nil)
    view.expandResultsForTesting()
    view.layoutSubtreeIfNeeded()

    let card = view.resultsCapsuleFrameForTesting
    XCTAssertFalse(card.isEmpty)
    XCTAssertTrue(
      view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(card),
      "switcher card \(card) escaped the screen panel \(view.bounds)"
    )
    let prompt = view.promptCapsuleFrameForTesting
    XCTAssertTrue(
      view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(prompt),
      "prompt capsule \(prompt) escaped the screen panel \(view.bounds)"
    )
  }

  func testPanelIsReusedAcrossShowHide() {
    let controller = makeController().controller
    let panel = controller.window
    controller.show()
    controller.hide()
    controller.show()
    XCTAssertTrue(controller.window === panel)
  }

  func testShiftTabChoosesTheAgentANewPromptStartsOn() throws {
    let (_, controller, conversations) = makeController()
    conversations.launchable = [AgentId.claude.rawValue, AgentId.codex.rawValue]
    conversations.plannedProvider = AgentId.claude.rawValue
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    XCTAssertEqual(view.agentForNewPrompt, .claude)
    XCTAssertEqual(view.mascotPaletteIDForTesting, MascotPalette.face(for: .claude).id)

    XCTAssertTrue(view.textView(view.field, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
    XCTAssertEqual(view.agentForNewPrompt, .codex)
    XCTAssertEqual(view.mascotPaletteIDForTesting, MascotPalette.face(for: .codex).id)

    view.field.setDraft(PromptDraft("review this"))
    XCTAssertTrue(view.textView(view.field, doCommandBy: #selector(NSTextView.insertNewline(_:))))
    XCTAssertEqual(conversations.startedIdentities.last?.providerID, AgentId.codex.rawValue)
  }

  func testShiftTabWalksTheAgentsAndReopeningStartsOnThePreferredOne() throws {
    let (_, controller, conversations) = makeController()
    conversations.launchable = [AgentId.claude.rawValue, AgentId.codex.rawValue, AgentId.grok.rawValue]
    conversations.plannedProvider = AgentId.codex.rawValue
    controller.show()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    let backtab = #selector(NSResponder.insertBacktab(_:))
    XCTAssertTrue(view.textView(view.field, doCommandBy: backtab))
    XCTAssertEqual(view.agentForNewPrompt, .grok)
    XCTAssertTrue(view.textView(view.field, doCommandBy: backtab))
    XCTAssertEqual(view.agentForNewPrompt, .claude)
    XCTAssertTrue(view.textView(view.field, doCommandBy: backtab))
    XCTAssertEqual(view.agentForNewPrompt, .codex)

    controller.hide()
    controller.show()
    defer { controller.hide() }
    XCTAssertNil(view.chosenAgent)
    XCTAssertEqual(view.agentForNewPrompt, .codex)

    conversations.launchable = [AgentId.codex.rawValue]
    controller.hide()
    controller.show()
    view.field.insertPlainText("hi")
    XCTAssertTrue(view.textView(view.field, doCommandBy: backtab))
    XCTAssertTrue(view.textView(view.field, doCommandBy: #selector(NSResponder.insertTab(_:))))
    XCTAssertEqual(view.agentForNewPrompt, .codex)
    XCTAssertEqual(view.field.string, "hi")
  }

  func testRepeatedReturnOnlyLaunchesOneAgentSession() throws {
    let (_, controller, conversations) = makeController()
    controller.show()

    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.field.setDraft(PromptDraft("test"))


    let submitSelector = #selector(NSTextView.insertNewline(_:))
    XCTAssertTrue(view.textView(view.field, doCommandBy: submitSelector))
    XCTAssertTrue(view.textView(view.field, doCommandBy: submitSelector))
    XCTAssertTrue(view.textView(view.field, doCommandBy: submitSelector))

    XCTAssertEqual(view.field.string, "")
    XCTAssertTrue(controller.isShowing)
    XCTAssertNotNil(view.addressedSessionIDForTesting)
    XCTAssertEqual(conversations.startedPrompts.count, 1)
    XCTAssertEqual(conversations.startedIdentities.count, 1)
    XCTAssertEqual(conversations.startedIdentities.first?.id, view.addressedSessionIDForTesting)
    XCTAssertEqual(conversations.startedIdentities.first?.providerID, AgentId.opencode.rawValue)
  }

  func testReturnOnAnEmptyFirstScreenStartsNothing() throws {
    let (_, controller, conversations) = makeController()
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    let submit = #selector(NSTextView.insertNewline(_:))
    var refusals = 0
    controller.onPromptRefused = { refusals += 1 }

    _ = view.textView(view.field, doCommandBy: submit)
    view.field.setDraft(PromptDraft("  \n "))
    _ = view.textView(view.field, doCommandBy: submit)

    XCTAssertTrue(conversations.startedPrompts.isEmpty)
    XCTAssertNil(view.addressedSessionIDForTesting)
    XCTAssertEqual(refusals, 2, "each empty Return sounds the alert")

    let clip = URL(fileURLWithPath: "/tmp/boltty-clip.mov")
    var chipOnly = PromptDraft()
    chipOnly.append(PromptAttachment.file(clip, label: "file1"))
    view.field.setDraft(chipOnly)
    _ = view.textView(view.field, doCommandBy: submit)

    XCTAssertEqual(conversations.startedPrompts, [clip.path])
    XCTAssertEqual(refusals, 2, "a chip alone is not refused")
  }

  func testSelectingExistingSessionFocusesItWithoutLaunching() throws {
    let (_, controller, conversations) = makeController()
    let existing = conversations.addConversation(title: "claude")
    conversations.previews[existing.id] = BolttyAISessionPreview(
      id: existing.id,
      title: existing.title,
      agent: .claude,
      state: .finished,
      body: "done"
    )
    controller.show()

    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    var selected: UUID?
    controller.onSelectSession = { selected = $0 }

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    )

    XCTAssertNil(selected)
    XCTAssertTrue(conversations.startedPrompts.isEmpty)
    XCTAssertTrue(view.isAddressingForTesting)
    XCTAssertEqual(view.addressedSessionIDForTesting, existing.id)
  }

  func testChoosingAChatNeverSendsTheUnsentPromptAndBackRestoresIt() throws {
    let (_, controller, conversations) = makeController()
    let chat = conversations.addConversation(title: "Saved chat")
    conversations.previews[chat.id] = .init(id: chat.id, title: chat.title,
      agent: .opencode, state: .finished, body: "Saved answer")
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.field.setDraft(PromptDraft("Unsent new question"))
    view.openSwitcher()
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(view.addressedSessionIDForTesting, chat.id)
    XCTAssertTrue(conversations.followUps.isEmpty)
    XCTAssertTrue(conversations.startedPrompts.isEmpty)
    view.field.setDraft(PromptDraft("Unsent follow-up"))
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertTrue(view.isResultsExpandedForTesting)
    XCTAssertEqual(conversations.conversation(id: chat.id)?.panelDraft?.typedText, "Unsent follow-up")
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertEqual(view.currentDraft.typedText, "Unsent new question")
  }

  func testConfirmingALiveAgentOpensThePreviewInsteadOfTheTab() throws {
    let (_, controller, conversations) = makeController()
    let agent = conversations.addConversation(title: "fix login")
    let preview = BolttyAISessionPreview(
      id: agent.id,
      title: agent.title,
      agent: .claude,
      state: .running,
      body: "Found 3 issues"
    )
    conversations.previews[agent.id] = preview
    controller.show()

    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    var selected: UUID?
    controller.onSelectSession = { selected = $0 }

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    )

    XCTAssertNil(selected)
    XCTAssertTrue(conversations.startedPrompts.isEmpty)
    XCTAssertTrue(view.isAddressingForTesting)
    XCTAssertEqual(view.addressedSessionIDForTesting, agent.id)
    XCTAssertTrue(view.previewBodyForTesting.contains("Found 3 issues"))
  }

  func testEnterOnAnAddressedAgentSendsFollowUpWithoutLaunching() throws {
    let (_, controller, conversations) = makeController()
    let agent = conversations.addConversation(title: "fix login")
    conversations.previews[agent.id] = BolttyAISessionPreview(
      id: agent.id,
      title: "fix login",
      agent: .claude,
      state: .blocked,
      body: "Found 3 issues"
    )
    controller.show()

    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    )
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    )
    view.field.setDraft(PromptDraft("Fix only the first issue."))
    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    )

    XCTAssertEqual(conversations.followUps.last?.id, agent.id)
    XCTAssertEqual(conversations.followUps.last?.prompt, "Fix only the first issue.")
    XCTAssertTrue(conversations.startedPrompts.isEmpty)
  }

  func testEnterOnABusyAgentQueuesInsteadOfSending() throws {
    let (_, controller, conversations) = makeController()
    let agent = conversations.addConversation(title: "fix login")
    conversations.previews[agent.id] = BolttyAISessionPreview(
      id: agent.id,
      title: "fix login",
      agent: .claude,
      state: .running,
      body: "Editing LoginView.swift"
    )
    controller.show()

    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    view.field.setDraft(PromptDraft("Fix only the first issue."))
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))

    XCTAssertTrue(conversations.followUps.isEmpty, "nothing reaches the agent while its turn is running")
    XCTAssertNil(view.visibleErrorForTesting, "nothing went wrong, so nothing is red")
    XCTAssertEqual(conversations.queued[agent.id], "Fix only the first issue.")
    XCTAssertTrue(view.field.draft.isEffectivelyEmpty)
    XCTAssertEqual(view.addressedSessionIDForTesting, agent.id)
  }

  func testRepeatedEnterNeverOverridesTheBusyGate() throws {
    let (_, controller, conversations) = makeController()
    let agent = conversations.addConversation(title: "fix login")
    conversations.previews[agent.id] = BolttyAISessionPreview(
      id: agent.id,
      title: "fix login",
      agent: .claude,
      state: .running,
      body: "Editing LoginView.swift"
    )
    controller.show()

    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    view.field.setDraft(PromptDraft("Fix only the first issue."))
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))

    XCTAssertTrue(conversations.followUps.isEmpty, "the turn is still running after both presses")
    XCTAssertEqual(conversations.queued[agent.id], "Fix only the first issue.")
    XCTAssertTrue(conversations.startedPrompts.isEmpty, "a follow-up never becomes a new conversation")
  }

  func testAChipSentIsRememberedAsASentFile() throws {
    let (_, controller, conversations) = makeController()
    controller.show()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    let clip = URL(fileURLWithPath: "/tmp/boltty-clip.mov")
    var draft = PromptDraft("Trim ")
    draft.append(PromptAttachment.file(clip, label: "file1"))
    view.field.setDraft(draft)
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    let id = try XCTUnwrap(view.addressedSessionIDForTesting)

    XCTAssertEqual(conversations.startedPrompts, ["Trim /tmp/boltty-clip.mov"])
    XCTAssertEqual(
      conversations.sentFiles[id],
      [SentFile(path: clip.path, label: "file1", name: "boltty-clip.mov")])

    let shot = URL(fileURLWithPath: "/tmp/boltty-shot.png")
    var followUp = PromptDraft("And ")
    followUp.append(PromptAttachment.file(shot, label: "image1"))
    view.field.setDraft(followUp)
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))

    XCTAssertEqual(conversations.sentFiles[id]?.map(\.label), ["file1", "image1"])
  }

  private func frozenScreen(for controller: AgentPaletteController) throws -> FrozenScreen {
    let screen = try XCTUnwrap(controller.window?.screen ?? NSScreen.main)
    let primary = NSScreen.screens.first?.frame.height ?? screen.frame.height
    let display = ScreenRegionCapture.flipped(screen.frame, primaryScreenHeight: primary)
    let context = try XCTUnwrap(CGContext(
      data: nil, width: 400, height: 250, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 250))
    return FrozenScreen(
      image: try XCTUnwrap(context.makeImage()),
      displayFrame: display,
      windows: [FrozenScreen.Window(frame: display, app: "Figma", title: "Boltty")])
  }

  private func makeSelectingController(
    configure: (FakeBolttyAIConversations) -> Void = { _ in }
  ) throws -> (AgentPaletteController, FakeBolttyAIConversations, AgentPaletteView) {
    let (_, controller, conversations) = makeController()
    configure(conversations)
    let store = PromptAttachmentStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-selection-\(UUID().uuidString)"))
    addTeardownBlock { try? FileManager.default.removeItem(at: store.directory) }
    controller.attachmentStore = store
    controller.screenRecordingAccess = { true }
    controller.show()
    addTeardownBlock { controller.hide() }
    let frozen = try frozenScreen(for: controller)
    controller.screenFreeze = { _ in frozen }
    return (controller, conversations, try XCTUnwrap(controller.window?.contentView as? AgentPaletteView))
  }

  func testARegionOnTheFirstScreenPutsTheShellBesideItAndGoesWithTheWords() throws {
    let (_, conversations, view) = try makeSelectingController()
    let region = CGRect(x: 120, y: 200, width: 300, height: 180)

    view.selectScreenRegionForTesting(region)
    XCTAssertEqual(view.screenSelectionPhase, .editing)
    XCTAssertEqual(view.screenSelectionHandleCountForTesting, 8)
    if PaletteEffects.shared != nil {
      XCTAssertEqual(view.screenGlowRegionsForTesting, [region], "the border is the glow's")
    }
    let frozen = expectation(for: NSPredicate { _, _ in view.isScreenFrozenForTesting }, evaluatedWith: nil)
    wait(for: [frozen], timeout: 5)
    view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThanOrEqual(view.shellFrameForTesting.minX, region.maxX, "the shell stands to the region's right")

    view.field.setDraft(PromptDraft("What is this? "))
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    let sent = expectation(
      for: NSPredicate { _, _ in !conversations.startedPrompts.isEmpty }, evaluatedWith: nil)
    wait(for: [sent], timeout: 5)

    let prompt = try XCTUnwrap(conversations.startedPrompts.first)
    XCTAssertTrue(prompt.hasPrefix("What is this? [Selected on screen in Figma — “Boltty”: "), prompt)
    XCTAssertEqual(
      conversations.startedPictures.first?.map(\.displayName), ["image1.png", "image1-screen.png"],
      "both pictures go to the agent as pictures, not only as paths")
    XCTAssertEqual(view.screenSelectionPhase, .idle)
    XCTAssertEqual(view.screenOutlinesForTesting, [])
    XCTAssertFalse(view.isScreenFrozenForTesting)
  }

  func testThePanelTakesPressesOnItsTransparentPixels() throws {
    let (controller, _, _) = try makeSelectingController()

    XCTAssertEqual(controller.window?.ignoresMouseEvents, false)
  }

  func testThePointerStaysTheArrowButOnARegionsHandles() throws {
    let (_, _, view) = try makeSelectingController()
    view.layoutSubtreeIfNeeded()
    let shell = view.shellFrameForTesting
    let glass = CGPoint(x: 40, y: 40)
    XCTAssertFalse(shell.insetBy(dx: -40, dy: -40).contains(glass))

    XCTAssertNil(view.pointerCursorForTesting(at: glass))
    XCTAssertNil(view.pointerCursorForTesting(at: CGPoint(x: shell.midX, y: shell.midY)))

    let region = CGRect(x: 120, y: 200, width: 300, height: 180)
    view.selectScreenRegionForTesting(region)
    view.layoutSubtreeIfNeeded()
    XCTAssertNil(view.pointerCursorForTesting(at: CGPoint(x: region.midX, y: region.midY)))
    XCTAssertNotNil(view.pointerCursorForTesting(at: CGPoint(x: region.maxX, y: region.maxY)),
                    "a handle says it can be pulled")
    XCTAssertNil(view.pointerCursorForTesting(at: glass))
  }

  func testARegionIsOfferedToAnAgentThatTakesNoFiles() throws {
    let (_, _, view) = try makeSelectingController { $0.agentsAcceptingAttachments = [] }

    view.selectScreenRegionForTesting(CGRect(x: 120, y: 200, width: 300, height: 180))

    XCTAssertEqual(view.screenSelectionPhase, .editing)
  }

  func testEscapeLetsTheRegionGoAndKeepsThePanel() throws {
    let (controller, conversations, view) = try makeSelectingController()

    view.selectScreenRegionForTesting(CGRect(x: 120, y: 200, width: 300, height: 180))
    view.pressEscapeForTesting()

    XCTAssertEqual(view.screenSelectionPhase, .idle)
    XCTAssertEqual(view.screenOutlinesForTesting, [])
    XCTAssertTrue(controller.isShowing)
    XCTAssertTrue(conversations.startedPrompts.isEmpty)
  }

  func testAnOpenChatTakesNoRegion() throws {
    let (controller, conversations, view) = try makeSelectingController()
    let chat = conversations.addConversation(title: "Saved chat")
    conversations.previews[chat.id] = .init(
      id: chat.id, title: chat.title, agent: .opencode, state: .finished, body: "Saved answer")
    controller.addressConversation(chat.id)
    XCTAssertEqual(view.addressedSessionIDForTesting, chat.id)

    view.selectScreenRegionForTesting(CGRect(x: 40, y: 60, width: 200, height: 120))

    XCTAssertEqual(view.screenSelectionPhase, .idle)
    XCTAssertTrue(view.field.draft.attachments.isEmpty)
    XCTAssertEqual(view.screenOutlinesForTesting, [])
  }

  func testChoosingAnotherAgentRecoloursADrawnRegion() throws {
    let (_, conversations, view) = try makeSelectingController {
      $0.launchable = [AgentId.claude.rawValue, AgentId.codex.rawValue]
      $0.plannedProvider = AgentId.claude.rawValue
    }
    view.selectScreenRegionForTesting(CGRect(x: 120, y: 200, width: 300, height: 180))
    let before = view.screenSelectionPaletteForTesting

    XCTAssertTrue(view.textView(view.field, doCommandBy: #selector(NSResponder.insertBacktab(_:))))

    XCTAssertEqual(view.agentForNewPrompt, .codex)
    XCTAssertEqual(view.screenSelectionPhase, .editing)
    XCTAssertNotEqual(view.screenSelectionPaletteForTesting, before)
    _ = conversations
  }

  func testARegionWithoutScreenRecordingSaysWhereToAllowIt() throws {
    let (controller, _, view) = try makeSelectingController()
    controller.screenRecordingAccess = { false }
    var freezes = 0
    let frozen = try frozenScreen(for: controller)
    controller.screenFreeze = { _ in
      freezes += 1
      return frozen
    }

    view.selectScreenRegionForTesting(CGRect(x: 40, y: 60, width: 200, height: 120))

    XCTAssertEqual(freezes, 0)
    XCTAssertEqual(view.visibleErrorForTesting, AgentPaletteController.screenRecordingNeeded)
    XCTAssertEqual(view.screenSelectionPhase, .idle)
    XCTAssertEqual(view.screenOutlinesForTesting, [])
  }

  func testAFileSentFromARestoredDraftKeepsItsOwnName() throws {
    let (_, controller, conversations) = makeController()
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.field.setDraft(PromptDraft("First question"))
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    let id = try XCTUnwrap(view.addressedSessionIDForTesting)

    let copy = URL(fileURLWithPath: "/tmp/boltty-conversations/\(id.uuidString)/attachments/3F2A1B2C-report.pdf")
    var restored = PromptDraft("Read ")
    restored.append(PromptAttachment.file(copy, label: "file1"))
    view.field.setDraft(restored)
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))

    XCTAssertEqual(
      conversations.sentFiles[id],
      [SentFile(path: copy.path, label: "file1", name: "report.pdf")])
  }

  func testEscapePreservesChatDraftAndReturnsToNewPromptBeforeHiding() throws {
    let (_, controller, conversations) = makeController()
    controller.show()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.field.setDraft(PromptDraft("First question"))
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    let id = try XCTUnwrap(view.addressedSessionIDForTesting)
    let draft = PromptDraft(elements: [.text("Follow-up "), .attachment(PromptAttachment(kind: .text, payload: .text("pasted content"), label: "text1"))])
    view.field.setDraft(draft)
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertTrue(controller.isShowing)
    XCTAssertNil(view.addressedSessionIDForTesting)
    XCTAssertFalse(view.isResultsExpandedForTesting)
    XCTAssertTrue(view.currentDraft.isEffectivelyEmpty)
    XCTAssertEqual(conversations.conversation(id: id)?.panelDraft, draft)
    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertFalse(controller.isShowing)
    controller.show()
    XCTAssertNil(view.addressedSessionIDForTesting)
    controller.addressConversation(id)
    XCTAssertEqual(view.currentDraft, draft)
    controller.hide()
  }

  func testAddressingAConversationSaysSo() throws {
    let (_, controller, conversations) = makeController()
    let chat = conversations.addConversation(title: "Optimize this video")
    conversations.previews[chat.id] = .init(
      id: chat.id, title: chat.title, agent: .opencode, state: .finished, body: "Done"
    )
    controller.show()

    XCTAssertNil(conversations.addressed)
    controller.addressConversation(chat.id)
    XCTAssertEqual(conversations.addressed, chat.id)
    controller.hide()
  }

  func testLeavingAChatStopsAddressingIt() throws {
    let (_, controller, conversations) = makeController()
    let chat = conversations.addConversation(title: "Optimize this video")
    conversations.previews[chat.id] = .init(
      id: chat.id, title: chat.title, agent: .opencode, state: .finished, body: "Done"
    )
    controller.show()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    controller.addressConversation(chat.id)
    XCTAssertEqual(conversations.addressed, chat.id)

    _ = view.textView(view.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertNil(view.addressedSessionIDForTesting)
    XCTAssertNil(conversations.addressed)
    controller.hide()
  }

  func testHidingThePanelStopsAddressingTheChat() {
    let (_, controller, conversations) = makeController()
    let chat = conversations.addConversation(title: "Optimize this video")
    conversations.previews[chat.id] = .init(
      id: chat.id, title: chat.title, agent: .opencode, state: .finished, body: "Done"
    )
    controller.show()

    controller.addressConversation(chat.id)
    controller.hide()
    XCTAssertNil(conversations.addressed)
    XCTAssertEqual(conversations.addressedHistory, [chat.id, nil])
  }

  func testHidingThePanelHandsTheMacBack() throws {
    let (_, controller, _) = makeController()
    let other = try anotherApplication()
    controller.activatePreviousApplicationForTesting = { _ in }
    controller.show()
    controller.setPreviousApplicationForTesting(other)

    controller.hide()

    XCTAssertEqual(
      controller.applicationPendingRestoreForTesting?.processIdentifier,
      other.processIdentifier
    )
  }

  func testYieldingToSettingsDoesNotHandTheMacBack() throws {
    let (_, controller, _) = makeController()
    let other = try anotherApplication()
    controller.activatePreviousApplicationForTesting = { _ in }
    controller.show()
    controller.setPreviousApplicationForTesting(other)

    controller.yieldToAppWindow()

    XCTAssertNil(controller.applicationPendingRestoreForTesting)
    XCTAssertFalse(controller.isShowing)
  }

  func testResigningAfterYieldingDoesNotHandTheMacBack() throws {
    let (_, controller, _) = makeController()
    let other = try anotherApplication()
    controller.activatePreviousApplicationForTesting = { _ in }
    controller.show()
    controller.setPreviousApplicationForTesting(other)
    controller.yieldToAppWindow()

    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    let settled = expectation(description: "resign settled")
    DispatchQueue.main.async { settled.fulfill() }
    wait(for: [settled], timeout: 1)

    XCTAssertNil(controller.applicationPendingRestoreForTesting)
  }

  private func anotherApplication() throws -> NSRunningApplication {
    let own = ProcessInfo.processInfo.processIdentifier
    return try XCTUnwrap(
      NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != own && $0.bundleIdentifier != nil
      }
    )
  }

  func testASendThatRoutedPastThePreferredAgentSaysSo() throws {
    let (_, controller, conversations) = makeController()
    conversations.fallback = AgentRoutingFallback(
      preferred: .claude,
      used: .opencode,
      reason: "Signed out — run `claude` in a terminal and sign in."
    )
    var openedSettings = 0
    controller.onOpenSettings = { openedSettings += 1 }
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    view.field.setDraft(PromptDraft("optimize this video"))
    _ = view.textView(view.field, doCommandBy: #selector(NSTextView.insertNewline(_:)))

    let line = try XCTUnwrap(view.routingFallbackTextForTesting)
    XCTAssertTrue(line.contains(AgentId.claude.displayName), line)
    XCTAssertTrue(line.contains(AgentId.opencode.displayName), line)

    view.pressRoutingSettingsForTesting()
    XCTAssertEqual(openedSettings, 1)
  }

  func testASendOnThePreferredAgentSaysNothing() throws {
    let (_, controller, conversations) = makeController()
    conversations.fallback = nil
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    view.field.setDraft(PromptDraft("optimize this video"))
    _ = view.textView(view.field, doCommandBy: #selector(NSTextView.insertNewline(_:)))

    XCTAssertNil(view.routingFallbackTextForTesting)
  }

  func testAttachingAFilePutsAChipInTheDraft() throws {
    let (_, controller, conversations) = makeController()
    conversations.plannedProvider = AgentId.opencode.rawValue
    conversations.agentsAcceptingAttachments = [AgentId.opencode.rawValue]
    let chat = conversations.addConversation(title: "task")
    let preview = BolttyAISessionPreview(id: chat.id, title: "task", agent: .opencode,
                                          state: .finished, body: "Done.")
    conversations.previews[chat.id] = preview
    let file = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("clip-\(UUID().uuidString).mov")
    try Data("x".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    controller.attachmentPicker = { _ in [file] }
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    XCTAssertFalse(view.isAttachVisibleForTesting, "no clip on the first screen")
    controller.addressConversation(chat.id)
    view.layoutSubtreeIfNeeded()

    XCTAssertTrue(view.isAttachVisibleForTesting)
    view.pressAttachForTesting()
    XCTAssertEqual(view.currentDraft.attachments.count, 1)
  }

  func testNoPaperclipForAnAgentThatCannotTakeFiles() throws {
    let (_, controller, conversations) = makeController()
    conversations.plannedProvider = AgentId.grok.rawValue
    conversations.agentsAcceptingAttachments = []
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    XCTAssertFalse(view.isAttachVisibleForTesting)
  }

  private func finderFile() -> URL {
    let file = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("selected-\(UUID().uuidString).mov")
    try? Data("x".utf8).write(to: file)
    return file
  }

  private actor ReadCounter {
    private(set) var count = 0
    func record() { count += 1 }
  }

  private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
  }

  func testComingFromFinderBringsTheSelectionAsAChip() throws {
    let (_, controller, _) = makeController()
    let file = finderFile()
    defer { try? FileManager.default.removeItem(at: file) }
    controller.finderSelection.readSelection = { [file] }
    controller.frontmostBundleIDForTesting = FinderSelectionService.finderBundleID
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    settle()
    XCTAssertEqual(view.currentDraft.attachments.count, 1)
  }

  func testComingFromAnotherAppBringsNothing() async throws {
    let (_, controller, _) = makeController()
    let file = finderFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let reads = ReadCounter()
    controller.finderSelection.readSelection = { await reads.record(); return [file] }
    controller.frontmostBundleIDForTesting = "com.apple.Safari"
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    settle()
    let count = await reads.count
    XCTAssertEqual(count, 0, "Finder is not even asked when it is not where we came from")
    XCTAssertTrue(view.currentDraft.isEffectivelyEmpty)
  }

  func testADraftAlreadyInProgressIsLeftAlone() throws {
    let (_, controller, _) = makeController()
    let file = finderFile()
    defer { try? FileManager.default.removeItem(at: file) }
    controller.finderSelection.readSelection = { [file] }
    controller.frontmostBundleIDForTesting = FinderSelectionService.finderBundleID
    controller.show()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.field.setDraft(PromptDraft("вже почав писати"))
    controller.hide()

    controller.show()
    defer { controller.hide() }
    settle()
    XCTAssertTrue(view.currentDraft.attachments.isEmpty)
  }

  func testThePanelFollowsTheKeyboardNotThePointer() throws {
    let screens = NSScreen.screens
    guard let main = screens.first(where: { $0 === NSScreen.main }) else {
      throw XCTSkip("no main screen in this environment")
    }
    let offscreen = NSPoint(x: -99_999, y: -99_999)
    XCTAssertTrue(
      AgentPaletteController.presentationScreen(
        main: main, pointer: offscreen, screens: screens
      ) === main
    )
  }

  func testWithNoMainScreenThePointerDecides() throws {
    let screens = NSScreen.screens
    let target = try XCTUnwrap(screens.first)
    let inside = NSPoint(x: target.frame.midX, y: target.frame.midY)
    XCTAssertTrue(
      AgentPaletteController.presentationScreen(
        main: nil, pointer: inside, screens: screens
      ) === target
    )
  }

  func testSuccessfulSubmitClearsPromptBeforeNextPresentation() throws {
    let (_, controller, _) = makeController()
    controller.show()

    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.field.setDraft(PromptDraft("summarize this repository"))

    let submitSelector = #selector(NSTextView.insertNewline(_:))
    XCTAssertTrue(view.textView(view.field, doCommandBy: submitSelector))

    XCTAssertEqual(view.field.string, "")
  }

  func testHidingCancelsThePendingVoiceConfirmationBeforeReopening() async throws {
    let (_, controller, conversations) = makeController()
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.field.setDraft(PromptDraft("old dictated prompt"))
    view.onVoiceConfirm?()
    controller.hide()
    controller.show()
    view.field.setDraft(PromptDraft("new unsent draft"))
    try await Task.sleep(for: .seconds(AgentPaletteMetrics.voiceConfirmGraceInterval + 0.6))
    XCTAssertTrue(
      conversations.startedPrompts.isEmpty,
      "the old timer must not submit the new draft"
    )
    XCTAssertEqual(view.field.string, "new unsent draft")
  }

  func testFailedFollowUpKeepsTheDraftAndPaletteOpen() throws {
    let (_, controller, conversations) = makeController()
    let agent = conversations.addConversation(title: "task")
    let preview = BolttyAISessionPreview(id: agent.id, title: "task", agent: .claude,
                                         state: .blocked, body: "Ready")
    conversations.previews[agent.id] = preview
    conversations.followUpResult = false
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.enterAddressing(preview)
    view.field.setDraft(PromptDraft("Please continue"))
    view.confirmCurrentDraft()
    XCTAssertTrue(controller.isShowing)
    XCTAssertEqual(view.field.string, "Please continue")
    XCTAssertNotNil(view.visibleErrorForTesting)
  }

  func testEditingWhileVoiceFinalizesCancelsTheScheduledSend() async throws {
    let (_, controller, conversations) = makeController()
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.setVoiceListening(true)
    view.applyVoiceTranscript("dictated prompt")
    view.onVoiceConfirm?()
    XCTAssertFalse(view.isVoiceListeningForTesting)
    view.field.insertPlainText(" still editing")
    view.applyVoiceTranscript("late final transcript")
    try await Task.sleep(for: .seconds(AgentPaletteMetrics.voiceConfirmGraceInterval + 0.15))
    XCTAssertTrue(
      conversations.startedPrompts.isEmpty,
      "editing withdraws the pending confirmation"
    )
    XCTAssertTrue(controller.isShowing)
    XCTAssertEqual(view.field.string, "dictated prompt still editing")
  }

  func testNoAvailableAgentIsRefusedWithoutLaunchingAnything() throws {
    let (_, controller, conversations) = makeController()
    conversations.canStart = false
    controller.show()

    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.field.setDraft(PromptDraft("do the thing"))

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSTextView.insertNewline(_:)))
    )

    XCTAssertTrue(conversations.startedPrompts.isEmpty)
    XCTAssertTrue(controller.isShowing, "the panel stays up so the text is not lost")
    XCTAssertEqual(view.field.draft.typedText, "do the thing")
    XCTAssertNotNil(view.visibleErrorForTesting)
  }

  func testAnUnavailableProviderIsReportedRatherThanReportedAsLaunched() throws {
    let (_, controller, conversations) = makeController()
    conversations.canStart = false
    controller.show()

    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.field.setDraft(PromptDraft("do the thing"))

    XCTAssertTrue(
      view.textView(view.field, doCommandBy: #selector(NSTextView.insertNewline(_:)))
    )

    XCTAssertTrue(conversations.startedPrompts.isEmpty)
    XCTAssertTrue(controller.isShowing)
    XCTAssertEqual(view.field.draft.typedText, "do the thing")
    XCTAssertNotNil(view.visibleErrorForTesting)
  }

  func testTheSwitcherFollowsTheConversationStore() throws {
    let (model, controller, conversations) = makeController()
    model.agentCatalog.apply(scannedAgents: [
      InstalledAgent(agent: .opencode, executablePath: "/usr/bin/true")
    ])
    controller.show()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    conversations.addConversation(title: "rename the invoices")
    view.expandResultsForTesting()
    view.setSessions(conversations.switcherItems())

    XCTAssertEqual(view.resultItemsForTesting.map(\.title), ["rename the invoices"])
  }

  func testAnswerIsSentOnceAndItsCompletionCannotCloseAReopenedPalette() async throws {
    let (model, _, conversations) = makeController()
    let agent = conversations.addConversation(title: "task")
    let question = AgentQuestion(
      kind: .question, requestID: "review",
      header: nil, prompt: "Choose", options: [.init(label: "First", detail: nil)],
      allowsMultiple: false, allowsCustom: false
    )
    let preview = BolttyAISessionPreview(id: agent.id, title: "task", agent: .opencode,
                                         state: .blocked, body: "Choose", question: question)
    var sends = 0
    var pending: CheckedContinuation<Void, Error>?
    let started = expectation(description: "answer reached transport")
    let controller = AgentPaletteController(
      model: model,
      conversations: conversations,
      sendAnswer: { (_: AgentQuestion, _: [String]) in
        sends += 1
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          pending = continuation
          started.fulfill()
        }
        return true
      }
    )
    conversations.previews[agent.id] = preview
    controller.show()
    defer { controller.hide() }
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.enterAddressing(preview)
    view.confirmCurrentDraft()
    view.confirmCurrentDraft()
    await fulfillment(of: [started], timeout: 2)
    XCTAssertEqual(sends, 1)
    controller.hide()
    controller.show()
    view.field.setDraft(PromptDraft("new draft"))
    pending?.resume()
    for _ in 0..<5 { await Task.yield() }
    XCTAssertTrue(controller.isShowing)
    XCTAssertEqual(view.field.string, "new draft")
  }

  func testAnOldSpeechPermissionCallbackCannotCancelANewRecordingAttempt() async {
    var callbacks: [VoiceDictationService.SpeechAuthorizationCompletion] = []
    let service = VoiceDictationService(usageDescription: { _ in "Testing" },
                                       requestSpeechAuthorization: { callbacks.append($0) })
    service.toggle()
    service.cancel()
    service.toggle()
    XCTAssertEqual(callbacks.count, 2)
    callbacks[0](.denied)
    for _ in 0..<5 { await Task.yield() }
    XCTAssertEqual(service.state, .requestingPermission)
    service.cancel()
  }
}

// MARK: - The folder chip

@MainActor
final class BolttyAIWorkingDirectoryTests: XCTestCase {
  private var retained: [FakeBolttyAIConversations] = []

  override func tearDown() async throws {
    retained.removeAll()
    try await super.tearDown()
  }

  private func makeController() -> (AgentPaletteController, FakeBolttyAIConversations) {
    let model = AppModel(settings: AppSettings(bolttyAIHotkey: .optionSpace))
    let conversations = FakeBolttyAIConversations()
    let controller = AgentPaletteController(model: model, conversations: conversations)
    retained.append(conversations)
    return (controller, conversations)
  }

  private func view(_ controller: AgentPaletteController) throws -> AgentPaletteView {
    try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
  }

  func testTheChipShowsTheInheritedFolderBeforeAnythingIsSent() throws {
    let (controller, conversations) = makeController()
    conversations.inheritedDirectory = "/Users/someone/Code/boltty"
    controller.show()
    defer { controller.hide() }

    let chip = try view(controller).workingDirectoryChipForTesting
    XCTAssertTrue(try view(controller).isWorkingDirectoryChipVisibleForTesting)
    XCTAssertEqual(chip.chip?.path, "/Users/someone/Code/boltty")
    XCTAssertTrue(chip.isEditableForTesting)
  }

  func testTheFolderMenuChoosesARecentFolderOrNone() throws {
    let (controller, conversations) = makeController()
    conversations.inheritedDirectory = "/Users/someone"
    conversations.recentFolders = ["/Users/someone/Code/boltty", "/Users/someone/Code/vdl"]
    controller.show()
    defer { controller.hide() }
    let panel = try view(controller)

    let menu = try XCTUnwrap(controller.workingDirectoryMenu())
    XCTAssertEqual(menu.items.map(\.title),
                   ["Show in Finder", "Copy Path", "",
                    "No Folder", "", "Recent", "boltty", "vdl", "", "Open Folder…"])
    func row(_ title: String, in menu: NSMenu) -> Int { menu.indexOfItem(withTitle: title) }
    XCTAssertEqual(menu.items[row("No Folder", in: menu)].state, .on)

    menu.performActionForItem(at: row("boltty", in: menu))
    XCTAssertEqual(panel.workingDirectoryChipForTesting.chip?.path, "/Users/someone/Code/boltty")
    XCTAssertEqual(panel.workingDirectoryChipForTesting.nameForTesting, "boltty")

    let again = try XCTUnwrap(controller.workingDirectoryMenu())
    XCTAssertEqual(again.items[row("No Folder", in: again)].state, .off)
    XCTAssertEqual(again.items[row("boltty", in: again)].state, .on)
    again.performActionForItem(at: row("No Folder", in: again))
    XCTAssertEqual(panel.workingDirectoryChipForTesting.chip?.path, "/Users/someone")
  }

  func testAHistoryRowsMenuOffersWhatTheChatHas() throws {
    let (controller, conversations) = makeController()
    let own = UUID(), bare = UUID()
    conversations.finderLocations = [own: URL(fileURLWithPath: "/tmp/own")]
    conversations.deletableChats = [own]

    XCTAssertEqual(try XCTUnwrap(controller.sessionMenu(for: own)).items.map(\.title),
                   ["Open Chat", "Show in Finder", "", "Delete Chat…"])
    XCTAssertEqual(try XCTUnwrap(controller.sessionMenu(for: bare)).items.map(\.title),
                   ["Open Chat"])
  }

  func testChoosingAFolderBeforeTheFirstSendIsWhatTheConversationStartsIn() throws {
    let (controller, conversations) = makeController()
    conversations.inheritedDirectory = "/Users/someone"
    controller.directoryPicker = { _ in "/Users/someone/Movies" }
    controller.show()
    defer { controller.hide() }
    let panel = try view(controller)

    panel.onChooseWorkingDirectory?()
    XCTAssertEqual(panel.workingDirectoryChipForTesting.chip?.path, "/Users/someone/Movies")

    panel.field.setDraft(PromptDraft("Sort these clips"))
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))

    XCTAssertEqual(conversations.startedDirectories, ["/Users/someone/Movies"])
  }

  func testThePickerOpensOnTheFolderTheChipIsShowing() throws {
    let (controller, conversations) = makeController()
    conversations.inheritedDirectory = "/Users/someone/Code"
    var openedAt: String?
    controller.directoryPicker = { current in
      openedAt = current
      return nil
    }
    controller.show()
    defer { controller.hide() }

    try view(controller).onChooseWorkingDirectory?()
    XCTAssertEqual(openedAt, "/Users/someone/Code")
  }

  func testCancellingThePickerChangesNothing() throws {
    let (controller, conversations) = makeController()
    conversations.inheritedDirectory = "/Users/someone/Code"
    controller.directoryPicker = { _ in nil }
    controller.show()
    defer { controller.hide() }
    let panel = try view(controller)

    panel.onChooseWorkingDirectory?()
    XCTAssertEqual(panel.workingDirectoryChipForTesting.chip?.path, "/Users/someone/Code")
  }

  func testASessionLocksTheChipAndTheStoreIsNeverAsked() throws {
    let (controller, conversations) = makeController()
    var chat = conversations.addConversation(title: "Live chat")
    chat.remoteSessionID = "ses_live"
    conversations.conversationsByID[chat.id] = chat
    conversations.previews[chat.id] = .init(
      id: chat.id, title: chat.title, agent: .opencode, state: .finished, body: "Done"
    )
    controller.directoryPicker = { _ in "/Users/someone/Elsewhere" }
    controller.show()
    defer { controller.hide() }
    let panel = try view(controller)

    controller.addressConversation(chat.id)
    let chip = try XCTUnwrap(panel.workingDirectoryChipForTesting.chip)
    XCTAssertFalse(chip.isEditable)
    XCTAssertTrue(chip.tooltip.contains("Fixed when the conversation started"))

    panel.onChooseWorkingDirectory?()
    XCTAssertTrue(
      conversations.directoryChanges.isEmpty,
      "a refused change must not reach the store at all"
    )
  }

  func testLeavingALockedChatGivesTheChipBackToTheNewPrompt() throws {
    let (controller, conversations) = makeController()
    conversations.inheritedDirectory = "/Users/someone"
    var chat = conversations.addConversation(title: "Live chat")
    chat.workingDirectory = "/Users/someone/Code/vdl"
    chat.remoteSessionID = "ses_live"
    conversations.conversationsByID[chat.id] = chat
    conversations.previews[chat.id] = .init(
      id: chat.id, title: chat.title, agent: .opencode, state: .finished, body: "Done"
    )
    controller.show()
    defer { controller.hide() }
    let panel = try view(controller)

    controller.addressConversation(chat.id)
    XCTAssertEqual(panel.workingDirectoryChipForTesting.chip?.isEditable, false, "precondition")

    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertNil(panel.addressedSessionIDForTesting)
    let chip = try XCTUnwrap(panel.workingDirectoryChipForTesting.chip)
    XCTAssertEqual(chip.path, "/Users/someone")
    XCTAssertTrue(chip.isEditable)
    XCTAssertFalse(chip.tooltip.contains("Fixed when the conversation started"))
  }

  func testAChatWithNoSessionYetCanStillBeMoved() throws {
    let (controller, conversations) = makeController()
    let chat = conversations.addConversation(title: "Draft chat")
    conversations.previews[chat.id] = .init(
      id: chat.id, title: chat.title, agent: .opencode, state: .finished, body: ""
    )
    controller.directoryPicker = { _ in "/Users/someone/Elsewhere" }
    controller.show()
    defer { controller.hide() }
    let panel = try view(controller)

    controller.addressConversation(chat.id)
    panel.onChooseWorkingDirectory?()

    XCTAssertEqual(conversations.directoryChanges.map(\.path), ["/Users/someone/Elsewhere"])
    XCTAssertEqual(panel.workingDirectoryChipForTesting.chip?.path, "/Users/someone/Elsewhere")
  }

  func testAnAgentThatIgnoresTheFolderWarnsOnTheChip() throws {
    let (controller, conversations) = makeController()
    conversations.plannedProvider = AgentId.antigravity.rawValue
    conversations.agentsIgnoringWorkingDirectory = [AgentId.antigravity.rawValue]
    controller.show()
    defer { controller.hide() }

    let chip = try XCTUnwrap(try view(controller).workingDirectoryChipForTesting.chip)
    XCTAssertNotNil(chip.warning)
    XCTAssertTrue(try view(controller).workingDirectoryChipForTesting.showsWarningForTesting)
  }

  func testAnAgentThatHonoursTheFolderCarriesNoWarning() throws {
    let (controller, conversations) = makeController()
    conversations.plannedProvider = AgentId.claude.rawValue
    controller.show()
    defer { controller.hide() }

    XCTAssertNil(try view(controller).workingDirectoryChipForTesting.chip?.warning)
    XCTAssertFalse(try view(controller).workingDirectoryChipForTesting.showsWarningForTesting)
  }

  func testTheChipLeavesWithTheComposer() throws {
    let (controller, conversations) = makeController()
    conversations.rows = [.row("A saved chat")]
    controller.show()
    defer { controller.hide() }
    let panel = try view(controller)
    XCTAssertTrue(panel.isWorkingDirectoryChipVisibleForTesting)

    panel.openSwitcher()
    panel.layoutSubtreeIfNeeded()
    XCTAssertFalse(panel.isWorkingDirectoryChipVisibleForTesting)
  }
}

@MainActor
final class PickerPanelPresentationTests: XCTestCase {
  func testPickerTemporarilyOutranksTheBolttyAIPanel() {
    let host = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    host.level = .popUpMenu
    let picker = NSOpenPanel()

    PickerPanelPresentation.attach(picker, above: host)

    XCTAssertEqual(host.level, .normal)
    XCTAssertEqual(picker.level, .modalPanel)
    XCTAssertGreaterThan(picker.level.rawValue, host.level.rawValue)

    PickerPanelPresentation.detach(picker, from: host)
    XCTAssertEqual(host.level, .popUpMenu, "closing the picker restores Boltty AI's level")
  }
}

// MARK: - Enter while the agent is working

@MainActor
final class BolttyAIBusyQueueTests: XCTestCase {
  private var retained: [FakeBolttyAIConversations] = []

  override func tearDown() async throws {
    retained.removeAll()
    try await super.tearDown()
  }

  private func makeController() -> (AgentPaletteController, FakeBolttyAIConversations) {
    let model = AppModel(settings: AppSettings(bolttyAIHotkey: .optionSpace))
    let conversations = FakeBolttyAIConversations()
    let controller = AgentPaletteController(model: model, conversations: conversations)
    retained.append(conversations)
    return (controller, conversations)
  }

  private func view(_ controller: AgentPaletteController) throws -> AgentPaletteView {
    try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
  }

  private func busyChat(
    _ conversations: FakeBolttyAIConversations,
    _ controller: AgentPaletteController
  ) throws -> UUID {
    let chat = conversations.addConversation(title: "Working chat", state: .working)
    conversations.previews[chat.id] = .init(
      id: chat.id, title: chat.title, agent: .opencode, state: .running,
      body: "", messages: [], canStop: true
    )
    controller.show()
    controller.addressConversation(chat.id)
    return chat.id
  }

  func testEnterDuringATurnQueuesInsteadOfRaisingAnError() throws {
    let (controller, conversations) = makeController()
    let id = try busyChat(conversations, controller)
    defer { controller.hide() }
    let panel = try view(controller)

    panel.field.setDraft(PromptDraft("And run the tests"))
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))

    XCTAssertEqual(conversations.queued[id], "And run the tests")
    XCTAssertNil(panel.visibleErrorForTesting, "nothing went wrong, so nothing is red")
    XCTAssertTrue(conversations.followUps.isEmpty, "the turn is still running")
    XCTAssertTrue(panel.currentDraft.isEffectivelyEmpty, "the composer handed it over")
  }

  func testASecondEnterReplacesTheWaitingMessage() throws {
    let (controller, conversations) = makeController()
    let id = try busyChat(conversations, controller)
    defer { controller.hide() }
    let panel = try view(controller)

    panel.field.setDraft(PromptDraft("First thought"))
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    panel.field.setDraft(PromptDraft("Actually, this instead"))
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))

    XCTAssertEqual(conversations.queued[id], "Actually, this instead")
  }

  func testTheWaitingMessageIsOnScreen() throws {
    let (controller, conversations) = makeController()
    let id = try busyChat(conversations, controller)
    defer { controller.hide() }
    let panel = try view(controller)

    panel.field.setDraft(PromptDraft("And run the tests"))
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    panel.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      panel.previewCardForTesting.queuedTextForTesting,
      "And run the tests"
    )
    XCTAssertFalse(
      conversations.previews[id]?.withholdsAnswer ?? true,
      "a queued message opens the card"
    )
  }

  func testCancellingPutsTheWordsBackInTheComposer() throws {
    let (controller, conversations) = makeController()
    let id = try busyChat(conversations, controller)
    defer { controller.hide() }
    let panel = try view(controller)

    panel.field.setDraft(PromptDraft("And run the tests"))
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    panel.previewCardForTesting.cancelQueuedForTesting()

    XCTAssertNil(conversations.queued[id])
    XCTAssertEqual(panel.currentDraft.typedText, "And run the tests")
  }

  func testAnOpenQuestionStillRefusesOutLoud() throws {
    let (controller, conversations) = makeController()
    let chat = conversations.addConversation(title: "Asking chat", state: .waiting)
    conversations.previews[chat.id] = .init(
      id: chat.id, title: chat.title, agent: .codex, state: .blocked, body: "",
      question: AgentQuestion(
        kind: .question, requestID: "q1",
        header: "Approach", prompt: "Which one?",
        options: [AgentQuestion.Option(label: "SwiftUI", detail: nil, value: "swiftui")],
        allowsMultiple: false, allowsCustom: false
      )
    )
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(chat.id)
    let panel = try view(controller)

    panel.field.setDraft(PromptDraft("Never mind that"))
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))

    XCTAssertNil(conversations.queued[chat.id])
    XCTAssertTrue(conversations.answered.isEmpty)
    XCTAssertNotNil(panel.visibleErrorForTesting)
  }

  func testWordsOnAPermissionAreARefusalNotAFollowUp() async throws {
    let (controller, conversations) = makeController()
    let chat = conversations.addConversation(title: "Asking chat", state: .waiting)
    let question = AgentQuestion(
      kind: .permission, requestID: "p1",
      header: "Permission", prompt: "Run rm?",
      options: [AgentQuestion.Option(label: "Deny", detail: nil, value: "reject")],
      allowsMultiple: false, allowsCustom: false
    )
    conversations.previews[chat.id] = .init(
      id: chat.id, title: chat.title, agent: .opencode, state: .blocked, body: "",
      question: question
    )
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(chat.id)
    let panel = try view(controller)

    panel.field.setDraft(PromptDraft("Never mind that"))
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    for _ in 0..<100 where conversations.answered.isEmpty { await Task.yield() }

    XCTAssertNil(conversations.queued[chat.id])
    XCTAssertEqual(conversations.answered.map(\.values), [["reject", "Never mind that"]])
  }

  private func askingPlan(_ conversations: FakeBolttyAIConversations) -> UUID {
    let chat = conversations.addConversation(title: "Planning chat", state: .waiting)
    conversations.previews[chat.id] = .init(
      id: chat.id, title: chat.title, agent: .grok, state: .blocked, body: "",
      question: PlanCardTests.plan()
    )
    return chat.id
  }

  func testReturnApprovesAPlan() async throws {
    let (controller, conversations) = makeController()
    let id = askingPlan(conversations)
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(id)
    let panel = try view(controller)

    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    for _ in 0..<100 where conversations.answered.isEmpty { await Task.yield() }

    XCTAssertEqual(conversations.answered.map(\.values), [["approved"]])
  }

  func testReturnWithWordsRequestsChangesToAPlan() async throws {
    let (controller, conversations) = makeController()
    let id = askingPlan(conversations)
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(id)
    let panel = try view(controller)

    panel.field.setDraft(PromptDraft("smaller steps"))
    XCTAssertEqual(panel.trailingHintForTesting, ["Request changes ↵"])
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    for _ in 0..<100 where conversations.answered.isEmpty { await Task.yield() }

    XCTAssertNil(conversations.queued[id])
    XCTAssertEqual(conversations.answered.map(\.values), [["cancelled", "smaller steps"]])
  }

  func testRequestChangesClickedTakesTheComposersWords() async throws {
    let (controller, conversations) = makeController()
    let id = askingPlan(conversations)
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(id)
    let panel = try view(controller)
    let bar = try XCTUnwrap(panel.previewCardForTesting.approvalBarForTesting)

    panel.field.setDraft(PromptDraft("smaller steps"))
    bar.pressForTesting(1)
    for _ in 0..<100 where conversations.answered.isEmpty { await Task.yield() }

    XCTAssertEqual(conversations.answered.map(\.values), [["cancelled", "smaller steps"]])
  }

  func testChangesThatWereNotDeliveredKeepTheirWords() async throws {
    let (controller, conversations) = makeController()
    let id = askingPlan(conversations)
    conversations.answerDelivers = false
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(id)
    let panel = try view(controller)

    panel.field.setDraft(PromptDraft("smaller steps"))
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    for _ in 0..<100 where panel.visibleErrorForTesting == nil { await Task.yield() }

    XCTAssertEqual(conversations.answered.map(\.values), [["cancelled", "smaller steps"]])
    XCTAssertEqual(panel.currentDraft.typedText, "smaller steps")
  }

  private func askingPermission(_ conversations: FakeBolttyAIConversations) -> UUID {
    let chat = conversations.addConversation(title: "Asking chat", state: .waiting)
    conversations.previews[chat.id] = .init(
      id: chat.id, title: chat.title, agent: .opencode, state: .blocked, body: "",
      question: AgentQuestion(
        kind: .permission, requestID: "p1",
        header: "Permission", prompt: "Run rm?",
        options: [AgentQuestion.Option(label: "Deny", detail: nil, value: "reject")],
        allowsMultiple: false, allowsCustom: false
      )
    )
    return chat.id
  }

  func testARefusalIntoAnAskAnsweredElsewhereKeepsItsWords() async throws {
    let (controller, conversations) = makeController()
    let id = askingPermission(conversations)
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(id)
    let panel = try view(controller)

    panel.field.setDraft(PromptDraft("use pnpm"))
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    conversations.previews[id]?.question = nil
    for _ in 0..<100 where panel.visibleErrorForTesting == nil { await Task.yield() }

    XCTAssertTrue(conversations.answered.isEmpty, "nothing was left to refuse")
    XCTAssertEqual(panel.currentDraft.typedText, "use pnpm")
    XCTAssertEqual(panel.visibleErrorForTesting, "This question is no longer waiting for an answer.")
  }

  func testARefusalThatWasNotDeliveredKeepsItsWords() async throws {
    let conversations = FakeBolttyAIConversations()
    retained.append(conversations)
    let id = askingPermission(conversations)
    var sent: [[String]] = []
    let controller = AgentPaletteController(
      model: AppModel(settings: AppSettings(bolttyAIHotkey: .optionSpace)),
      conversations: conversations,
      sendAnswer: { (_: AgentQuestion, values: [String]) in
        sent.append(values)
        conversations.previews[id]?.question = nil
        return false
      }
    )
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(id)
    let panel = try view(controller)

    panel.field.setDraft(PromptDraft("use pnpm"))
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    for _ in 0..<100 where panel.visibleErrorForTesting == nil { await Task.yield() }

    XCTAssertEqual(sent, [["reject", "use pnpm"]])
    XCTAssertEqual(panel.currentDraft.typedText, "use pnpm")
    XCTAssertEqual(panel.visibleErrorForTesting, "This question is no longer waiting for an answer.")
  }

  func testARefusalTheConversationLayerDidNotDeliverKeepsItsWords() async throws {
    let (controller, conversations) = makeController()
    let id = askingPermission(conversations)
    conversations.answerDelivers = false
    controller.show()
    defer { controller.hide() }
    controller.addressConversation(id)
    let panel = try view(controller)

    panel.field.setDraft(PromptDraft("use pnpm"))
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    for _ in 0..<100 where panel.visibleErrorForTesting == nil { await Task.yield() }

    XCTAssertEqual(conversations.answered.map(\.values), [["reject", "use pnpm"]])
    XCTAssertEqual(panel.currentDraft.typedText, "use pnpm")
    XCTAssertEqual(panel.visibleErrorForTesting, "That reply was not delivered. Try again.")
  }
}

// MARK: - Managing chats from the switcher

@MainActor
final class BolttyAISessionManagementTests: XCTestCase {
  private var retained: [FakeBolttyAIConversations] = []

  override func tearDown() async throws {
    retained.removeAll()
    try await super.tearDown()
  }

  private func makeController() -> (AgentPaletteController, FakeBolttyAIConversations) {
    let model = AppModel(settings: AppSettings(bolttyAIHotkey: .optionSpace))
    let conversations = FakeBolttyAIConversations()
    let controller = AgentPaletteController(model: model, conversations: conversations)
    retained.append(conversations)
    return (controller, conversations)
  }

  private func view(_ controller: AgentPaletteController) throws -> AgentPaletteView {
    try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
  }

  private func switcherWithOneChat() throws -> (
    AgentPaletteController, FakeBolttyAIConversations, AgentPaletteView, Conversation
  ) {
    let (controller, conversations) = makeController()
    let chat = conversations.addConversation(title: "Saved chat")
    controller.show()
    let panel = try view(controller)
    _ = panel.textView(panel.field, doCommandBy: #selector(NSResponder.moveDown(_:)))
    panel.layoutSubtreeIfNeeded()
    return (controller, conversations, panel, chat)
  }

  private func chord(_ characters: String) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: 0, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
    )!
  }

}
