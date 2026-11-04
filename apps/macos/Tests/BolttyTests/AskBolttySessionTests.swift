import AppKit
import XCTest
@testable import Boltty

@MainActor
final class AskBolttySessionTests: XCTestCase {
  private final class Voice: AskBolttySpeaking {
    var said: [String] = []
    var saying: String?
    /// Starts each piece at once, unless told to hold them.
    var holds = false
    var held: [() -> Void] = []
    var speaks = true
    func canSpeak(_ language: String?) -> Bool { speaks }
    func say(_ piece: String, id: String, language: String?, onStart: (() -> Void)?) {
      said.append(piece)
      saying = id
      if holds { held.append { onStart?() } } else { onStart?() }
    }
    func isSaying(_ id: String) -> Bool { saying == id }
    func stop() { saying = nil }
  }

  private var store: ConversationStore!
  private var client: FakeAgentClient!
  private var engine: ConversationEngine!
  private var coordinator: ChatWorkspaceCoordinator!
  private var voice: Voice!
  private var askBoltty: AskBolttySession!
  private var directory: URL!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("talk-tests-\(UUID().uuidString)", isDirectory: true)
    store = ConversationStore(persistence: ConversationPersistence(
      root: directory.appendingPathComponent("store"),
      trash: { try FileManager.default.removeItem(at: $0) }))
    client = FakeAgentClient()
    client.provider = .claude
    client.availability = .available(version: "test")
    engine = ConversationEngine(store: store, registry: AgentRegistry(clients: [client]))
    engine.start()
    for _ in 0..<200 where !client.isStreaming { await Task.yield() }
    coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    voice = Voice()
    askBoltty = AskBolttySession(coordinator: coordinator, speech: voice)
    askBoltty.pictureDirectory = directory.appendingPathComponent("pictures")
    askBoltty.reader.schedule = { _, work in DispatchQueue.main.async { MainActor.assumeIsolated(work) } }
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private static func frozenScreen() -> FrozenScreen {
    let context = CGContext(
      data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    return FrozenScreen(
      image: context.makeImage()!, displayFrame: CGRect(x: 0, y: 0, width: 40, height: 20),
      windows: [FrozenScreen.Window(frame: CGRect(x: 0, y: 0, width: 40, height: 20),
                                    app: "Preview", title: "Anatomy.png")])
  }

  private let target = AskBolttyTarget(
    providerID: AgentId.claude.rawValue, model: nil, effort: nil, readOnly: true)
  /// The frozen display is 40 × 20 at the top left of the primary screen.
  private var top: CGFloat { NSScreen.screens.first?.frame.height ?? 20 }
  private var displayFrame: CGRect { CGRect(x: 0, y: top - 20, width: 40, height: 20) }

  /// The left half of the frozen display, as the panel cuts it.
  private func selection(whole: Bool = false) throws -> ScreenSelection {
    let frame = whole ? displayFrame
      : CGRect(x: displayFrame.minX, y: displayFrame.minY, width: 20, height: 20)
    return try ScreenRegionCapture.selection(frame, in: Self.frozenScreen(), primaryScreenHeight: top)
  }

  /// A region drawn, then `words` said about it.
  private func ask(_ words: String, whole: Bool = false) throws {
    askBoltty.warmUp(target)
    askBoltty.ask(words, about: try selection(whole: whole), on: displayFrame, target: target,
                  speaksAloud: true)
  }

  private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
    for _ in 0..<2_000 where !condition() {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(condition(), "timed out waiting for \(what)")
  }

  func testDrawingARegionStartsTheAgentAndTheQuestionGoesWithTheScreenAndTheArea() async throws {
    askBoltty.warmUp(target)
    let id = try XCTUnwrap(askBoltty.conversationID)
    XCTAssertEqual(store.conversation(id: id)?.readOnly, true)
    try await waitFor("the session to start while the person speaks") { !self.client.createdSessions.isEmpty }

    askBoltty.ask("what is this muscle called?", about: try selection(), on: displayFrame,
                  target: target, speaksAloud: true)
    XCTAssertEqual(askBoltty.phase, .thinking)
    try await waitFor("the question") { !self.client.sentMessages.isEmpty }

    let sent = try XCTUnwrap(client.sentMessages.first?.text)
    XCTAssertTrue(sent.hasSuffix("what is this muscle called?"))
    XCTAssertTrue(sent.contains("Preview — “Anatomy.png”"), "the window under the region is named")
    XCTAssertTrue(sent.contains("red outline"), "the area is said to be outlined")
    XCTAssertTrue(sent.contains("do not run commands"), "a read-only question says so")
    XCTAssertEqual(client.createdSessions.count, 1, "the warm session is the one asked")
    XCTAssertEqual(askBoltty.conversationID, id)
    let pictures = store.transcript(id: id).messages.first?.parts.filter { part in
      if case let .attachment(file) = part { return file.mimeType == "image/png" }
      return false
    }
    XCTAssertEqual(pictures?.count, 2, "the screen and the area go as pictures")
  }

  func testTheWholeScreenGoesAsOnePicture() async throws {
    try ask("what is on my screen?", whole: true)
    try await waitFor("the question") { !self.client.sentMessages.isEmpty }
    let sent = try XCTUnwrap(client.sentMessages.first?.text)
    XCTAssertTrue(sent.contains("about the whole screen"))
    let id = try XCTUnwrap(askBoltty.conversationID)
    XCTAssertEqual(store.transcript(id: id).messages.first?.parts.filter { part in
      if case .attachment = part { return true }
      return false
    }.count, 1)
  }

  func testTheAnswerIsSaidASentenceAtATimeAsItArrives() async throws {
    try ask("how do I share this?")
    try await waitFor("the question") { !self.client.sentMessages.isEmpty }
    let remote = try XCTUnwrap(client.sentMessages.first?.sessionID)

    client.streamReply(
      sessionID: remote, messageID: "a1",
      chunks: ["Click **Share** in the", " top right. Then", " pick Mail."], finish: false)
    try await waitFor("the first sentence") { self.voice.said.count == 1 }
    XCTAssertEqual(voice.said, ["Click Share in the top right."])
    XCTAssertEqual(askBoltty.phase, .speaking)

    client.emit(.executionStateChanged(sessionID: remote, state: .idle))
    try await waitFor("the rest") { self.voice.said.count == 2 }
    XCTAssertEqual(voice.said.last, "Then pick Mail.")

    voice.stop()
    askBoltty.speechFinished()
    XCTAssertEqual(askBoltty.phase, .idle)
  }

  func testARegionLetGoOfWithoutAQuestionLeavesNoChat() throws {
    askBoltty.warmUp(target)
    let id = try XCTUnwrap(askBoltty.conversationID)
    askBoltty.cancel()
    XCTAssertEqual(askBoltty.phase, .idle)
    XCTAssertNil(store.conversation(id: id))
  }

  func testNoWordsAskNothing() throws {
    askBoltty.warmUp(target)
    askBoltty.ask("   ", about: try selection(), on: displayFrame, target: target, speaksAloud: true)
    XCTAssertEqual(askBoltty.phase, .idle)
    XCTAssertTrue(client.sentMessages.isEmpty)
  }

  func testAQuestionSoonAfterTheAnswerContinuesTheSameChat() async throws {
    try ask("what is this?")
    try await waitFor("the question") { !self.client.sentMessages.isEmpty }
    let first = try XCTUnwrap(askBoltty.conversationID)
    let remote = try XCTUnwrap(client.sentMessages.first?.sessionID)
    client.streamReply(sessionID: remote, messageID: "a1", chunks: ["A deltoid."])
    try await waitFor("the answer") { !self.voice.said.isEmpty }

    askBoltty.warmUp(target)
    XCTAssertEqual(askBoltty.conversationID, first)
    XCTAssertNil(voice.saying, "drawing again stops the voice")
  }

  func testANewRegionBargesInOnTheVoice() async throws {
    try ask("what is this?")
    try await waitFor("the question") { !self.client.sentMessages.isEmpty }
    let remote = try XCTUnwrap(client.sentMessages.first?.sessionID)
    client.streamReply(sessionID: remote, messageID: "a1", chunks: ["It is long. And it goes on"], finish: false)
    try await waitFor("the voice") { self.voice.saying != nil }

    askBoltty.warmUp(target)
    XCTAssertNil(voice.saying)
    XCTAssertEqual(askBoltty.phase, .idle)
  }

  // MARK: - Pointing, and staying quiet

  func testTheMascotPointsWhenTheVoiceReachesTheSentenceThatNamesIt() async throws {
    voice.holds = true
    try ask("where do I share this?")
    try await waitFor("the question") { !self.client.sentMessages.isEmpty }
    let remote = try XCTUnwrap(client.sentMessages.first?.sessionID)
    client.streamReply(
      sessionID: remote, messageID: "a1",
      chunks: [#"It is open. <point x="500" y="250" label="Share"/>Click Share."#])
    try await waitFor("both sentences") { self.voice.said.count == 2 }
    XCTAssertEqual(voice.said, ["It is open.", "Click Share."], "the tag is never said")
    XCTAssertNil(askBoltty.pointing, "nothing is pointed at before the voice gets there")

    voice.held[0]()
    XCTAssertEqual(askBoltty.caption, "It is open.", "the caption is what is being heard")
    XCTAssertNil(askBoltty.pointing)
    voice.held[1]()
    let pointing = try XCTUnwrap(askBoltty.pointing)
    XCTAssertEqual(pointing.location.x, 20, accuracy: 0.01)
    XCTAssertEqual(pointing.location.y, top - 5, accuracy: 0.01)
    XCTAssertEqual(pointing.label, "Share")

    askBoltty.warmUp(target)
    XCTAssertNil(askBoltty.pointing, "a new region calls the mascot back")
  }

  func testAnAskBolttyAnswerRaisesNoBannerAndLeavesNothingUnread() async throws {
    var banners: [SystemAttentionNotification] = []
    coordinator.notificationDelivery = { banners.append($0) }

    try ask("what is this?")
    let id = try XCTUnwrap(askBoltty.conversationID)
    try await waitFor("the question") { !self.client.sentMessages.isEmpty }
    let remote = try XCTUnwrap(client.sentMessages.first?.sessionID)
    client.streamReply(sessionID: remote, messageID: "a1", chunks: ["A deltoid."])
    try await waitFor("the answer") { self.store.conversation(id: id)?.lastKnownState == .idle }

    // An ordinary chat finishing in the same harness does raise one.
    let other = coordinator.startConversationInBackground(prompt: "hi", providerID: AgentId.claude.rawValue)
    try await waitFor("the other chat's send") { self.client.sentMessages.count == 2 }
    let otherRemote = try XCTUnwrap(client.sentMessages.last?.sessionID)
    client.streamReply(sessionID: otherRemote, messageID: "b1", chunks: ["Hello."])
    try await waitFor("the other chat's banner") { !banners.isEmpty }

    XCTAssertEqual(banners.map(\.sessionID), [other.id], "only the ordinary chat says it is done")
    let askBolttyChat = try XCTUnwrap(store.conversation(id: id))
    XCTAssertTrue(askBolttyChat.isAskBoltty)
    XCTAssertFalse(askBolttyChat.hasUnread)
    XCTAssertEqual(askBolttyChat.title, "what is this?")
    XCTAssertTrue(store.conversation(id: other.id)?.hasUnread ?? false)
  }

  func testTheCardShowsTheQuestionAndTheAreaNotTheBracket() async throws {
    try ask("what is this?")
    let id = try XCTUnwrap(askBoltty.conversationID)
    try await waitFor("the question") { !self.client.sentMessages.isEmpty }
    let asked = try XCTUnwrap(store.transcript(id: id).messages.first { $0.role == .user })
    let lifted = SentFile.lift(asked, files: store.conversation(id: id)?.sentFiles ?? [])
    XCTAssertEqual(lifted.copyableText, "what is this?")
    XCTAssertEqual(store.conversation(id: id)?.sentFiles.map(\.name), ["Area.png"])
  }

  // MARK: - Shown, not said; and gone when done

  func testAnAnswerInALanguageBolttyDoesNotSpeakIsShownWhole() async throws {
    voice.speaks = false
    try ask("що це за кнопка?")
    try await waitFor("the question") { !self.client.sentMessages.isEmpty }
    let remote = try XCTUnwrap(client.sentMessages.first?.sessionID)
    client.streamReply(
      sessionID: remote, messageID: "a1",
      chunks: ["Це кнопка «Поділитися». ", #"<point x="500" y="250"/>Натисни її."#])
    try await waitFor("the answer to settle") { self.askBoltty.phase == .idle }
    XCTAssertTrue(voice.said.isEmpty, "nothing is said")
    XCTAssertFalse(askBoltty.readsAloud)
    XCTAssertEqual(askBoltty.caption, "Натисни її.", "it is read, a sentence at a time")
    XCTAssertNotNil(askBoltty.pointing, "it still points")
  }

  func testAFinishedAskBolttyIsForgottenWhenTheNextOneBegins() async throws {
    try ask("what is this?")
    try await waitFor("the question") { !self.client.sentMessages.isEmpty }
    let first = try XCTUnwrap(askBoltty.conversationID)
    let remote = try XCTUnwrap(client.sentMessages.first?.sessionID)
    let picture = try XCTUnwrap(store.conversation(id: first)?.sentFiles.first?.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: picture))
    client.streamReply(sessionID: remote, messageID: "a1", chunks: ["A deltoid."])
    try await waitFor("the answer") { self.store.conversation(id: first)?.lastKnownState == .idle }
    XCTAssertTrue(
      BolttyAISessionList.items(conversations: store.orderedConversations, selectedID: nil).isEmpty,
      "an Ask Boltty is never a row")

    askBoltty.now = { Date().addingTimeInterval(AskBolttySession.followUpWindow + 1) }
    askBoltty.warmUp(target)
    XCTAssertNotEqual(askBoltty.conversationID, first)
    XCTAssertNil(store.conversation(id: first), "its record goes at once")
    try await waitFor("its process to be let go") { self.client.released == [remote] }
    try await waitFor("its screenshot to be deleted") { !FileManager.default.fileExists(atPath: picture) }
  }

  func testChatsAskBolttyMadeBeforeItMarkedThemAreForgottenAndNothingElse() async throws {
    let old = store.createConversation(
      title: "[Talk: the person asked this out loud…", workingDirectory: "/tmp",
      providerID: AgentId.claude.rawValue)
    let kept = store.createConversation(
      title: "Fix the build", workingDirectory: "/tmp", providerID: AgentId.claude.rawValue)
    coordinator.forgetAskBolttyChats()
    XCTAssertNil(store.conversation(id: old.id))
    XCTAssertNotNil(store.conversation(id: kept.id))
  }

  func testTheCaptionIsTheSentenceBeingSaidAndTheAnswerStopsAtTwo() async throws {
    voice.holds = true
    try ask("how do I share this?")
    try await waitFor("the question") { !self.client.sentMessages.isEmpty }
    let remote = try XCTUnwrap(client.sentMessages.first?.sessionID)
    client.streamReply(
      sessionID: remote, messageID: "a1",
      chunks: ["Open the file. Click Share in the top right. Then pick Mail."])
    try await waitFor("two sentences") { self.voice.said.count == 2 }
    voice.held[0]()
    XCTAssertEqual(askBoltty.caption, "Open the file.")
    voice.held[1]()
    XCTAssertEqual(askBoltty.caption, "Click Share in the top right.", "one at a time")
    try await waitFor("the answer to settle") {
      self.store.conversation(id: self.askBoltty.conversationID!)?.lastKnownState == .idle
    }
    XCTAssertEqual(voice.said.count, 2, "two sentences at most")
  }
}
