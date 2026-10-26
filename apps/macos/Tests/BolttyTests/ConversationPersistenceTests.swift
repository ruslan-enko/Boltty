import XCTest
@testable import Boltty

@MainActor
final class ConversationPersistenceTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    try await super.setUp()
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-persist-\(UUID().uuidString)")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
    try await super.tearDown()
  }

  private func newStore() -> ConversationStore {
    ConversationStore(persistence: ConversationPersistence(root: root))
  }

  func testPanelDraftKeepsFileChipsAfterTheOriginalIsDeletedAndRelaunches() throws {
    let first = newStore()
    let conversation = first.createConversation(title: "Files", workingDirectory: "/tmp")
    let source = root.appendingPathComponent("source.txt")
    try Data("persistent attachment".utf8).write(to: source)
    let chip = PromptAttachment.file(source, label: "file1")
    first.setPanelDraft(PromptDraft(elements: [.text("Read "), .attachment(chip)]), for: conversation.id)
    first.close()
    try FileManager.default.removeItem(at: source)
    let second = newStore()
    defer { second.close() }
    let draft = try XCTUnwrap(second.conversation(id: conversation.id)?.panelDraft)
    XCTAssertEqual(draft.typedText, "Read ")
    XCTAssertEqual(draft.attachments.first?.id, chip.id)
    guard case let .file(url) = draft.attachments.first?.payload else { return XCTFail("Missing saved file") }
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "persistent attachment")
  }

  func testSentFilesSurviveARelaunchAndLiftTheRequest() throws {
    let first = newStore()
    let conversation = first.createConversation(title: "Files", workingDirectory: "/tmp")
    let report = SentFile(path: "/tmp/report.pdf", label: "file1", name: "report.pdf")
    first.recordSentFiles([report], for: conversation.id)
    first.recordSentFiles(
      [SentFile(path: report.path, label: "file2", name: "again.pdf")], for: conversation.id)
    first.appendUserMessage(
      id: "m", text: "Summarise /tmp/report.pdf", attachments: [], to: conversation.id)
    first.close()

    let second = newStore()
    defer { second.close() }
    XCTAssertEqual(second.conversation(id: conversation.id)?.sentFiles, [report],
                   "a path already remembered keeps its first name")
    let engine = ConversationEngine(store: second, client: FakeAgentClient())
    let panel: any BolttyAIConversations = ChatWorkspaceCoordinator(store: second, engine: engine)
    let request = try XCTUnwrap(panel.preview(for: conversation.id)?.messages.first)
    XCTAssertEqual(request.plainText, "Summarise file1")
    XCTAssertEqual(request.resultFiles, [report.path])
  }

  func testDuplicateIndexRowsCanLaunchCoordinatorWithoutLosingHistory() throws {
    let original = newStore()
    let first = original.createConversation(title: "First", workingDirectory: "/tmp")
    let second = original.createConversation(title: "Second", workingDirectory: "/tmp")
    original.appendUserMessage(id: "saved-message", text: "Saved history", attachments: [], to: first.id)
    original.setDraft("Unsent draft", for: first.id)
    original.select(first.id)
    original.close()

    let indexURL = root.appendingPathComponent("index.json")
    var index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
    var rows = try XCTUnwrap(index["conversations"] as? [[String: Any]])
    let duplicate = try XCTUnwrap(rows.first)
    rows.append(contentsOf: [duplicate, duplicate])
    index["conversations"] = rows
    let duplicatedData = try JSONSerialization.data(withJSONObject: index)
    try duplicatedData.write(to: indexURL)

    let restored = newStore()
    defer { restored.close() }
    let engine = ConversationEngine(store: restored, client: FakeAgentClient())
    let coordinator = ChatWorkspaceCoordinator(store: restored, engine: engine)
    XCTAssertEqual(restored.conversations.map(\.id), [first.id, second.id])
    XCTAssertEqual(restored.selectedConversationID, first.id)
    XCTAssertEqual(restored.conversation(id: first.id)?.draft, "Unsent draft")
    XCTAssertEqual(restored.transcript(id: first.id).messages.map(\.plainText), ["Saved history"])
    let panel: any BolttyAIConversations = coordinator
    XCTAssertNotNil(panel.preview(for: first.id))
    XCTAssertEqual(try Data(contentsOf: indexURL), duplicatedData,
      "loading must not rewrite or delete the original index")
  }

  func testHistoryAndDraftsSurviveARelaunch() {
    let first = newStore()
    let conversation = first.createConversation(title: "Invoices", workingDirectory: "/tmp/w")
    first.attachRemoteSession("ses_1", to: conversation.id, model: nil)
    first.appendUserMessage(id: "msg_1", text: "sort them", attachments: [], to: conversation.id)
    first.setDraft("and then email", for: conversation.id)
    first.select(conversation.id)
    first.close()

    let second = newStore()
    XCTAssertEqual(second.conversations.count, 1)
    let restored = second.conversation(id: conversation.id)
    XCTAssertEqual(restored?.title, "Invoices")
    XCTAssertEqual(restored?.draft, "and then email")
    XCTAssertEqual(restored?.remoteSessionID, "ses_1")
    XCTAssertEqual(second.selectedConversationID, conversation.id)
    XCTAssertEqual(
      second.transcript(id: conversation.id).messages.map(\.plainText),
      ["sort them"]
    )
  }

  func testAnUnfinishedReplyComesBackAsInterruptedAndIsNotRerun() {
    let first = newStore()
    let conversation = first.createConversation(title: "Long job", workingDirectory: "/tmp/w")
    first.attachRemoteSession("ses_1", to: conversation.id, model: nil)
    first.appendUserMessage(id: "msg_1", text: "build it", attachments: [], to: conversation.id)
    first.setExecutionState(.working, for: conversation.id)
    first.close()

    let second = newStore()
    XCTAssertEqual(
      second.conversation(id: conversation.id)?.lastKnownState,
      .interrupted,
      "a spinner for work this process is not doing would be a lie, and idle "
        + "would hide that the task was cut short rather than never started"
    )
    XCTAssertFalse(
      second.conversation(id: conversation.id)?.lastKnownState.blocksSending ?? true,
      "the turn is over — the composer must send"
    )
    XCTAssertEqual(second.transcript(id: conversation.id).messages.count, 1)
  }

  func testACorruptTranscriptCostsOneConversationNotTheApp() {
    let first = newStore()
    let good = first.createConversation(title: "Fine", workingDirectory: "/tmp")
    let bad = first.createConversation(title: "Broken", workingDirectory: "/tmp")
    first.appendUserMessage(id: "m1", text: "ok", attachments: [], to: good.id)
    first.appendUserMessage(id: "m2", text: "also ok", attachments: [], to: bad.id)
    first.close()

    let persistence = ConversationPersistence(root: root, claimingOwnership: false)
    try! Data("{ not json".utf8).write(to: persistence.transcriptURL(bad.id))

    let second = newStore()
    XCTAssertEqual(second.conversations.count, 2, "both rows still exist")
    XCTAssertEqual(second.transcript(id: good.id).messages.map(\.plainText), ["ok"])
    XCTAssertTrue(second.transcript(id: bad.id).messages.isEmpty)
    XCTAssertTrue(second.damagedConversationIDs.contains(bad.id))
    XCTAssertEqual(second.subtitle(for: bad.id), "History could not be read")
  }

  func testAttachmentsAreCopiedIntoTheConversationAndKept() throws {
    let store = newStore()
    let conversation = store.createConversation(title: "Files", workingDirectory: "/tmp")

    let source = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-source-\(UUID().uuidString).txt")
    try Data("payload".utf8).write(to: source)

    let attachment = try XCTUnwrap(store.importAttachment(from: source, into: conversation.id))
    XCTAssertEqual(attachment.displayName, source.lastPathComponent)
    let copy = try XCTUnwrap(attachment.url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))

    try FileManager.default.removeItem(at: source)
    XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    XCTAssertEqual(try Data(contentsOf: copy), Data("payload".utf8))
  }

  func testAnUnsupportedAttachmentIsMarkedRatherThanPromisedAsAnalysed() throws {
    let store = newStore()
    let conversation = store.createConversation(title: "Files", workingDirectory: "/tmp")
    let source = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-\(UUID().uuidString).sqlite3")
    try Data("binary".utf8).write(to: source)

    let attachment = try XCTUnwrap(store.importAttachment(from: source, into: conversation.id))
    XCTAssertFalse(attachment.isAnalysable)
    try? FileManager.default.removeItem(at: source)
  }

  func testDeletingAConversationRemovesItsFiles() {
    let store = newStore()
    let conversation = store.createConversation(title: "Temp", workingDirectory: "/tmp")
    store.appendUserMessage(id: "m", text: "hi", attachments: [], to: conversation.id)
    store.flush()

    let path = ConversationPersistence(root: root, claimingOwnership: false)
      .transcriptURL(conversation.id).path
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))

    store.deleteConversation(id: conversation.id)
    store.flush()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }

  func testASecondInstanceGoesReadOnlyInsteadOfInterleavingWrites() {
    let first = newStore()
    let conversation = first.createConversation(title: "Owned", workingDirectory: "/tmp")
    first.flush()
    XCTAssertFalse(first.isReadOnly)

    let second = newStore()
    XCTAssertTrue(second.isReadOnly, "the directory already has an owner")

    second.createConversation(title: "From the other copy", workingDirectory: "/tmp")
    second.flush()

    let reader = ConversationPersistence(root: root, claimingOwnership: false)
    let onDisk = reader.load()
    XCTAssertEqual(onDisk.conversations.map(\.id), [conversation.id])
  }

  func testOwnershipIsHandedOverWhenTheOwnerCloses() {
    let first = newStore()
    XCTAssertFalse(first.isReadOnly)
    first.close()

    let second = newStore()
    XCTAssertFalse(second.isReadOnly, "a relaunch must be able to take the store")
  }

  func testThirdPartyOpenCodeSessionsAreNotAdopted() {
    let store = newStore()
    XCTAssertFalse(
      store.apply(
        AgentEventEnvelope(
          id: "evt_1",
          sequence: 1,
          event: .messageUpdated(
            sessionID: "ses_from_the_tui",
            message: ConversationMessage(id: "msg_x", role: .agent, createdAt: Date())
          )
        )
      )
    )
    XCTAssertTrue(store.conversations.isEmpty)
  }
}
