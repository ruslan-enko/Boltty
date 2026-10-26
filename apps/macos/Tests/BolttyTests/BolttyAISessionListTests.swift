import XCTest
@testable import Boltty

final class BolttyAISessionListTests: XCTestCase {
  private func conversation(
    _ agent: AgentId,
    title: String,
    state: ConversationExecutionState = .idle,
    workingDirectory: String = "/tmp",
    draft: String = ""
  ) -> Conversation {
    Conversation(
      providerID: agent.rawValue,
      title: title,
      workingDirectory: workingDirectory,
      draft: draft,
      lastKnownState: state
    )
  }

  private func textMessage(_ id: String, _ text: String, role: ConversationMessage.Role = .agent) -> ConversationMessage {
    ConversationMessage(
      id: id,
      role: role,
      createdAt: Date(),
      parts: [.text(TextPart(id: "text-\(id)", kind: .text, text: text))]
    )
  }

  private func transcript(_ messages: ConversationMessage...) -> ConversationTranscript {
    ConversationTranscript(messages: messages, interactions: [])
  }

  func testConversationRowsKeepTheirActualProvider() {
    let claude = conversation(.claude, title: "Claude", state: .working)
    let codex = conversation(.codex, title: "Codex")

    let items = BolttyAISessionList.items(
      conversations: [claude, codex],
      selectedID: nil
    )

    XCTAssertEqual(items.map(\.agent), [.claude, .codex])
    XCTAssertEqual(items.map(\.state), [.running, .finished])
  }

  func testRowsCarryTheUnreadFlag() {
    let read = conversation(.claude, title: "read")
    var unread = conversation(.codex, title: "unread")
    unread.hasUnread = true

    let items = BolttyAISessionList.items(
      conversations: [read, unread],
      selectedID: nil
    )

    XCTAssertEqual(items.map(\.hasUnread), [false, true])
  }

  func testTitleStaysWhileSubtitlePreviewsTheLastMessage() {
    let chat = conversation(.claude, title: "У да привіт")
    let transcripts = [
      chat.id: transcript(
        textMessage("m1", "У да привіт", role: .user),
        textMessage("m2", "Привіт! Чим допомогти?")
      )
    ]

    let items = BolttyAISessionList.items(
      conversations: [chat],
      transcripts: transcripts,
      selectedID: nil
    )

    XCTAssertEqual(items[0].title, "У да привіт")
    XCTAssertEqual(items[0].subtitle, "Привіт! Чим допомогти?")
  }

  func testEmptyConversationShowsNoMessagesYet() {
    let chat = conversation(.claude, title: "New chat")

    let items = BolttyAISessionList.items(
      conversations: [chat],
      selectedID: nil
    )

    XCTAssertEqual(items[0].subtitle, "No messages yet")
  }

  func testUnsentDraftIsThePreviewUntilSomethingIsSaid() {
    let chat = conversation(.claude, title: "New chat", draft: "half-typed thought")

    let items = BolttyAISessionList.items(
      conversations: [chat],
      selectedID: nil
    )

    XCTAssertEqual(items[0].subtitle, "half-typed thought")
  }

  func testMultilineMessageCollapsesToOneLine() {
    let chat = conversation(.claude, title: "Docs")
    let transcripts = [chat.id: transcript(textMessage("m1", "first line\nsecond line"))]

    let items = BolttyAISessionList.items(
      conversations: [chat],
      transcripts: transcripts,
      selectedID: nil
    )

    XCTAssertEqual(items[0].subtitle, "first line second line")
  }

  func testToolOnlyLastMessageFallsBackToEarlierText() {
    let chat = conversation(.claude, title: "Run")
    var toolCall = ConversationMessage(id: "m2", role: .agent, createdAt: Date())
    toolCall.parts = [.activity(AgentActivity(id: "act_1", name: "bash", state: .completed))]
    let transcripts = [chat.id: transcript(textMessage("m1", "about invoices"), toolCall)]

    let items = BolttyAISessionList.items(
      conversations: [chat],
      transcripts: transcripts,
      selectedID: nil
    )

    XCTAssertEqual(items[0].subtitle, "about invoices")
  }

  func testRunStatesOverrideThePreview() {
    let working = conversation(.claude, title: "one", state: .working)
    let waiting = conversation(.claude, title: "two", state: .waiting)
    let failed = conversation(.claude, title: "three", state: .failed)
    let transcripts = [
      working.id: transcript(textMessage("m", "said")),
      waiting.id: transcript(textMessage("m", "said")),
      failed.id: transcript(textMessage("m", "said")),
    ]

    let items = BolttyAISessionList.items(
      conversations: [working, waiting, failed],
      transcripts: transcripts,
      selectedID: nil
    )

    XCTAssertEqual(items.map(\.subtitle), ["Working…", "Waiting for you", "Stopped with an error"])
  }

  func testDamagedHistorySaysSo() {
    let chat = conversation(.claude, title: "Old chat")

    let items = BolttyAISessionList.items(
      conversations: [chat],
      damagedIDs: [chat.id],
      selectedID: nil
    )

    XCTAssertEqual(items[0].subtitle, "History could not be read")
  }

  func testTheSelectedConversationIsTheCurrentRow() {
    let first = conversation(.claude, title: "one")
    let second = conversation(.codex, title: "two")

    let items = BolttyAISessionList.items(
      conversations: [first, second],
      selectedID: second.id
    )

    XCTAssertFalse(items[0].isCurrent)
    XCTAssertTrue(items[1].isCurrent)
  }

  func testFiltersByTitleAndMessageText() {
    let claude = conversation(.claude, title: "fix login")
    let opencode = conversation(.opencode, title: "refactor palette")
    let transcripts = [
      claude.id: transcript(textMessage("m1", "about invoices")),
      opencode.id: transcript(textMessage("m1", "definitely unrelated")),
    ]

    let byTitle = BolttyAISessionList.items(
      conversations: [claude, opencode],
      transcripts: transcripts,
      selectedID: nil,
      query: "refactor"
    )
    XCTAssertEqual(byTitle.map(\.id), [opencode.id])

    let byOlderMessage = BolttyAISessionList.items(
      conversations: [claude, opencode],
      transcripts: transcripts,
      selectedID: nil,
      query: "invoices"
    )
    XCTAssertEqual(byOlderMessage.map(\.id), [claude.id])

    let byAgentName = BolttyAISessionList.items(
      conversations: [claude, opencode],
      transcripts: transcripts,
      selectedID: nil,
      query: "opencode"
    )
    XCTAssertEqual(byAgentName.map(\.id), [])
  }

  func testFilterFallsBackToTheVisibleSubtitle() {
    let row = BolttyAISessionItem(
      id: UUID(),
      title: "fix login",
      subtitle: "about invoices",
      agent: .claude,
      isCurrent: false,
      updatedAt: Date()
    )

    XCTAssertEqual(BolttyAISessionList.filter([row], query: "invoices").count, 1)
    XCTAssertEqual(BolttyAISessionList.filter([row], query: "claude").count, 0)
  }

  func testBlankQueryReturnsEveryConversation() {
    let first = conversation(.claude, title: "one")
    let second = conversation(.pi, title: "two")

    let items = BolttyAISessionList.items(
      conversations: [first, second],
      selectedID: first.id,
      query: "   "
    )

    XCTAssertEqual(items.count, 2)
    XCTAssertTrue(items[0].isCurrent)
  }

  func testTheSwitcherCarriesThePreview() {
    let row = conversation(.claude, title: "Hello, what about pizza?")
    let transcripts = [row.id: transcript(textMessage("m1", "Mushroom it is"))]

    let items = BolttyAISessionList.items(
      conversations: [row],
      transcripts: transcripts,
      selectedID: nil
    )

    XCTAssertEqual(items[0].title, "Hello, what about pizza?")
    XCTAssertEqual(items[0].subtitle, "Mushroom it is")
  }

  func testDisplayPathStripsHomePrefixWithoutTilde() {
    let home = WorkingDirectoryResolver.homeDirectoryPath
    XCTAssertEqual(BolttyAISessionList.displayPath(home), "~")
    XCTAssertEqual(
      BolttyAISessionList.displayPath(home + "/Documents/Projects/boltty"),
      "Documents/Projects/boltty"
    )
    XCTAssertEqual(BolttyAISessionList.displayPath("/"), "/")
  }

  func testThePreviewLineDropsMarkdown() {
    XCTAssertEqual(
      BolttyAISessionList.plainPreview("All three videos are done and verified in `/Users/me/Desktop`."),
      "All three videos are done and verified in /Users/me/Desktop.")
    XCTAssertEqual(
      BolttyAISessionList.plainPreview("## Done\n\n- **Saved** `clip.mp4` (7.9M)\n> see [the log](https://x.y)"),
      "Done Saved clip.mp4 (7.9M) see the log")
    XCTAssertEqual(
      BolttyAISessionList.plainPreview("Run:\n```bash\nmake\n```\n1. then *wait*"),
      "Run: make then wait")
    XCTAssertEqual(BolttyAISessionList.plainPreview("see my_file_name.txt"), "see my_file_name.txt")
  }

  func testThePreviewReadsATableAsItsCellsAndDropsRules() {
    XCTAssertEqual(
      BolttyAISessionList.plainPreview(
        "Done. Output: `out.mp4`\n\n| | Source (.mkv) | Output (.mp4) |\n|---|:---:|---|\n| Size | 1.2 GB | 240 MB |\n\n---\nAll good."
      ),
      "Done. Output: out.mp4 Source (.mkv) · Output (.mp4) Size · 1.2 GB · 240 MB All good.")
    XCTAssertEqual(BolttyAISessionList.plainPreview("a\n***\nb\n___\nc"), "a b c")
  }

  // MARK: The row's title

  private func sent(_ text: String) -> ConversationTranscript {
    transcript(textMessage("u1", text, role: .user), textMessage("a1", "ok"))
  }

  @MainActor func testARowsTitleIsTheWholeRequestWhereTheStoredOneIsItsCut() {
    let request = "Чи можемо ми зараз щось зробити щоб цей сервер ввімкнув"
    let chat = conversation(.claude, title: ConversationEngine.title(from: request))
    XCTAssertTrue(chat.title.hasSuffix("…"), "the stored title is the cut")

    let items = BolttyAISessionList.items(
      conversations: [chat], transcripts: [chat.id: sent(request)], selectedID: nil)

    XCTAssertEqual(items[0].title, request)
  }

  func testAStoredTitleThatIsNotACutOfTheRequestIsKept() {
    let chat = conversation(.opencode, title: "Fix the login redirect")
    let items = BolttyAISessionList.items(
      conversations: [chat], transcripts: [chat.id: sent("the login page loops, why?")],
      selectedID: nil)

    XCTAssertEqual(items[0].title, "Fix the login redirect")
  }

  func testARowsTitleLeavesOutTheScreenRegionAndBolttysCopies() {
    let region = "/Users/me/Library/Application Support/Boltty/Pasteboard/image1-82226C17.png"
    let screen = "/Users/me/Library/Application Support/Boltty/Pasteboard/image1-82226C17-screen.png"
    let bracket = "[Selected on screen in Figma — “WORK PAGE”: \"\(region)\". "
      + "The whole screen, the selection outlined: \"\(screen)\". "
      + "Text read from the selection: <screen-text>Or hold ^ and ask.</screen-text>]"
    let request = "можеш мені дати це текстом " + bracket
    var chat = conversation(.claude, title: "можеш мені дати це текстом [Selected on…")
    chat.sentFiles = [
      SentFile(path: region, label: "image1", name: "image1.png", expansion: bracket),
      SentFile(path: screen, label: "image1", name: "image1-screen.png"),
    ]

    let items = BolttyAISessionList.items(
      conversations: [chat], transcripts: [chat.id: sent(request)], selectedID: nil)

    XCTAssertEqual(items[0].title, "можеш мені дати це текстом")
    XCTAssertEqual(ChatTitle.clean(chat.title), "можеш мені дати це текстом", "the cut stored title too")
  }

  func testAFileTheyChoseIsNamedByItsOwnNameAndAPastedPictureByNothing() {
    var mkv = conversation(.claude, title: "/Users/me/Desktop/2320001-0053.mkv…")
    mkv.sentFiles = [SentFile(
      path: "/Users/me/Desktop/2320001-0053.mkv", label: "file1", name: "2320001-0053.mkv")]
    let picture = "/Users/me/Library/Application Support/Boltty/Pasteboard/image1-DBD450AF.png"
    var pasted = conversation(.claude, title: "як мені зробити так щоб білий бг був…")
    pasted.sentFiles = [SentFile(path: picture, label: "image1", name: "image1.png")]

    let items = BolttyAISessionList.items(
      conversations: [mkv, pasted],
      transcripts: [
        mkv.id: sent("/Users/me/Desktop/2320001-0053.mkv transcode it in mp4"),
        pasted.id: sent("як мені зробити так щоб білий бг був чорним? \"\(picture)\""),
      ],
      selectedID: nil)

    XCTAssertEqual(items.map(\.title), [
      "2320001-0053.mkv transcode it in mp4",
      "як мені зробити так щоб білий бг був чорним?",
    ])
  }

  @MainActor func testARequestThatWasOnlyAPictureIsNamedByIt() {
    let picture = "/Users/me/Library/Application Support/Boltty/Pasteboard/image1-DBD450AF.png"
    var chat = conversation(.claude, title: ConversationEngine.title(from: "\"\(picture)\""))
    chat.sentFiles = [SentFile(path: picture, label: "image1", name: "image1.png")]

    let items = BolttyAISessionList.items(
      conversations: [chat], transcripts: [chat.id: sent("\"\(picture)\"")], selectedID: nil)

    XCTAssertEqual(items[0].title, "image1.png")
  }

  func testATitleKeepsAddressesAndShortensOtherPaths() {
    XCTAssertEqual(
      ChatTitle.clean("compare https://example.com/a/b with ~/Desktop/notes/plan.md and/or /tmp"),
      "compare https://example.com/a/b with plan.md and/or /tmp")
    XCTAssertEqual(ChatTitle.clean("  two\n\nlines\t here "), "two lines here")
    XCTAssertEqual(ChatTitle.clean("fix this <pasted-text>let a = 1</pasted-text> please"), "fix this please")
  }

  func testThePreviewLineBreaksOnCRLFAndBareCarriageReturns() {
    XCTAssertEqual(
      BolttyAISessionList.plainPreview("# Title\r\n- item `code`\r\n**bold**"),
      "Title item code bold")
    XCTAssertEqual(
      BolttyAISessionList.plainPreview("Run:\r\n```bash\r\nmake\r\n```\r\n\r\n1. then *wait*"),
      "Run: make then wait")
    XCTAssertEqual(BolttyAISessionList.plainPreview("> quoted\r- listed"), "quoted listed")
  }

  func testARowsPreviewStopsOnceItHoldsMoreThanARowCanShow() {
    let line = "- a **bold** line with `code` and a [link](https://x.y)"
    let reply = Array(repeating: line, count: 5_000).joined(separator: "\n")
    let chat = conversation(.claude, title: "Long")
    let items = BolttyAISessionList.items(
      conversations: [chat],
      transcripts: [chat.id: transcript(textMessage("m1", reply))],
      selectedID: nil
    )
    let whole = BolttyAISessionList.plainPreview(reply)
    let row = items[0].subtitle

    XCTAssertTrue(whole.hasPrefix(row), "the start of the whole preview, not another one")
    XCTAssertGreaterThan(row.count, BolttyAISessionList.rowPreviewLimit, "more than a row can show")
    XCTAssertLessThan(row.count, BolttyAISessionList.rowPreviewLimit + line.count + 1, "and one line more at most")
    XCTAssertGreaterThan(whole.count, 100 * row.count)
  }
  func testAnOpenListHoldsItsOrderWhileAChatWorks() {
    func row(_ title: String, _ hoursAgo: Double, state: AgentReportedState? = nil) -> BolttyAISessionItem {
      var item = BolttyAISessionItem(id: UUID(), title: title, subtitle: "", agent: .claude,
                                      isCurrent: false, updatedAt: Date(timeIntervalSinceNow: -hoursAgo * 3600))
      item.state = state
      return item
    }
    let a = row("a", 1), b = row("b", 30), c = row("c", 60)
    var bNow = b
    bNow.updatedAt = Date()
    bNow.state = .running
    let fresh = row("new", 0)
    let held = BolttyAISessionList.holding([fresh, bNow, a], to: [a, b, c])
    XCTAssertEqual(held.map(\.title), ["new", "a", "b"], "b keeps its place; c is gone; the new chat leads")
    XCTAssertEqual(held[2].state, .running, "what changed inside the row is taken")
    XCTAssertEqual(held[2].updatedAt, b.updatedAt, "and it stays under its day")
  }
}
