import SQLite3
import XCTest
@testable import Boltty

final class NativeSessionStoreTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("native-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: - Codex fixtures

  @discardableResult
  private func writeRollout(
    id: String,
    day: String = "2026/09/20",
    stamp: String = "2026-09-20T13-25-55",
    cwd: String = "/Users/me/Projects/thing",
    userTexts: [String] = ["make the button blue"],
    modified: Date = Date()
  ) throws -> URL {
    let directory = root.appendingPathComponent("sessions/\(day)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("rollout-\(stamp)-\(id).jsonl")

    var lines = [
      #"{"type":"session_meta","payload":{"session_id":"\#(id)","cwd":"\#(cwd)"}}"#,
      #"{"type":"event_msg","payload":{"type":"task_started"}}"#
    ]
    for text in userTexts {
      let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
      lines.append(
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(escaped)"}]}}"#
      )
    }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
  }

  private func writeIndex(_ entries: [(id: String, name: String)]) throws {
    let lines = entries.map {
      #"{"id":"\#($0.id)","thread_name":"\#($0.name)","updated_at":"2026-09-20T13:00:00Z"}"#
    }
    try (lines.joined(separator: "\n") + "\n").write(
      to: root.appendingPathComponent("session_index.jsonl"),
      atomically: true, encoding: .utf8
    )
  }

  private func codexSessions(limit: Int = 50) throws -> [NativeSession] {
    try CodexSessionStore(root: root).sessions(limit: limit)
  }

  private let idA = "01a0be59-db33-7562-bd41-fcea8dc7bd2e"
  private let idB = "01a0b432-1111-2222-3333-444455556666"

  // MARK: - Codex

  func testACodexSessionIsReadFromItsRolloutRatherThanFromTheIndex() throws {
    try writeRollout(id: idA, cwd: "/Users/me/Projects/alpha")
    try writeIndex([])

    let sessions = try codexSessions()

    XCTAssertEqual(sessions.map(\.id), [idA])
    XCTAssertEqual(sessions[0].agent, .codex)
    XCTAssertEqual(sessions[0].workingDirectory, "/Users/me/Projects/alpha")
    XCTAssertEqual(sessions[0].title, "make the button blue")
  }

  func testCodexsOwnNameForAThreadWinsOverItsFirstLine() throws {
    try writeRollout(id: idA, userTexts: ["make the button blue"])
    try writeIndex([(idA, "Blue button and the hover state")])

    XCTAssertEqual(try codexSessions()[0].title, "Blue button and the hover state")
  }

  func testTextCodexInjectedAsTheUserIsNotTheTitle() throws {
    try writeRollout(id: idA, userTexts: [
      "# AGENTS.md instructions for /Users/me/Projects/thing",
      "The following is the Codex agent history whose request action…",
      "## Memory",
      "<environment_context>cwd</environment_context>",
      "actually fix the crash on launch"
    ])
    try writeIndex([])

    XCTAssertEqual(try codexSessions()[0].title, "actually fix the crash on launch")
  }

  func testASessionWithNothingToCallItIsNamedAfterWhereItRan() throws {
    try writeRollout(id: idA, cwd: "/Users/me/Projects/thing", userTexts: [])
    try writeIndex([])

    XCTAssertEqual(try codexSessions()[0].title, "thing")
  }

  func testTheNewestSessionIsFirstAndTheLimitIsHonoured() throws {
    let now = Date()
    try writeRollout(id: idA, stamp: "2026-09-19T10-00-00",
                     userTexts: ["older"], modified: now.addingTimeInterval(-3600))
    try writeRollout(id: idB, stamp: "2026-09-20T10-00-00",
                     userTexts: ["newer"], modified: now)
    try writeIndex([])

    XCTAssertEqual(try codexSessions().map(\.title), ["newer", "older"])
    XCTAssertEqual(try codexSessions(limit: 1).map(\.title), ["newer"])
  }

  func testAFileThatIsNotARolloutIsIgnored() throws {
    try writeRollout(id: idA)
    try writeIndex([])
    let stray = root.appendingPathComponent("sessions/2026/09/20/notes.jsonl")
    try "{}\n".write(to: stray, atomically: true, encoding: .utf8)

    XCTAssertEqual(try codexSessions().count, 1)
  }

  func testNoCodexDirectoryIsAnEmptyListRatherThanAnError() throws {
    let store = CodexSessionStore(root: root.appendingPathComponent("never-used"))
    XCTAssertEqual(try store.sessions(limit: 10), [])
  }

  func testOneUnreadableRolloutDoesNotLoseTheRest() throws {
    try writeRollout(id: idA, stamp: "2026-09-20T10-00-00", userTexts: ["good"])
    let broken = root.appendingPathComponent(
      "sessions/2026/09/20/rollout-2026-09-20T11-00-00-\(idB).jsonl"
    )
    try "{ this is not json".write(to: broken, atomically: true, encoding: .utf8)

    let sessions = try codexSessions()
    XCTAssertEqual(sessions.count, 2)
    XCTAssertEqual(sessions.first { $0.id == idA }?.title, "good")
    XCTAssertEqual(sessions.first { $0.id == idB }?.title, "Codex session")
  }

  // MARK: - Reading the head of a file

  func testTheHeadReaderStopsAtItsLineLimit() throws {
    let url = root.appendingPathComponent("big.jsonl")
    try (0..<5000).map { "line \($0)" }
      .joined(separator: "\n")
      .write(to: url, atomically: true, encoding: .utf8)

    let lines = try FileHead.lines(of: url, maxLines: 7)

    XCTAssertEqual(lines.count, 7)
    XCTAssertEqual(lines.last, "line 6")
  }

  func testTheHeadReaderStopsAtItsByteLimitWhenThereAreNoNewlines() throws {
    let url = root.appendingPathComponent("one-line.jsonl")
    try String(repeating: "x", count: 400_000).write(to: url, atomically: true, encoding: .utf8)

    let lines = try FileHead.lines(of: url, maxLines: 600, maxBytes: 64 << 10)

    XCTAssertEqual(lines.count, 1)
    XCTAssertLessThan(lines[0].count, 400_000, "the reader gave up rather than loading the file")
  }

  func testTheLastLineCountsWithoutATrailingNewline() throws {
    let url = root.appendingPathComponent("open.jsonl")
    try "first\nsecond".write(to: url, atomically: true, encoding: .utf8)

    XCTAssertEqual(try FileHead.lines(of: url, maxLines: 10), ["first", "second"])
  }

  // MARK: - Reading the tail of a file

  private func tailLines(of url: URL, maxBytes: Int) throws -> (lines: [String], complete: Bool) {
    var lines: [String] = []
    let complete = try FileTail.forEachLine(of: url, maxBytes: maxBytes) { line in
      lines.append(String(decoding: line, as: UTF8.self))
      return true
    }
    return (lines, complete)
  }

  func testTheTailReaderKeepsTheEndAndSaysTheHeadWasCut() throws {
    let url = root.appendingPathComponent("long.jsonl")
    try (0..<5000).map { "line \($0)" }
      .joined(separator: "\n")
      .write(to: url, atomically: true, encoding: .utf8)

    let (lines, complete) = try tailLines(of: url, maxBytes: 4 << 10)

    XCTAssertFalse(complete, "the file is far bigger than the window")
    XCTAssertEqual(lines.last, "line 4999", "the last line is the one that matters")
    XCTAssertFalse(lines.contains("line 0"), "the head is what got dropped")
    XCTAssertGreaterThan(lines.count, 100)
  }

  func testTheTailReaderDropsTheRecordItLandedInsideOf() throws {
    let url = root.appendingPathComponent("cut.jsonl")
    try "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbbbb\ncccc".write(to: url, atomically: true, encoding: .utf8)

    let (lines, complete) = try tailLines(of: url, maxBytes: 12)

    XCTAssertFalse(complete)
    XCTAssertEqual(lines, ["bbbb", "cccc"], "no half of a record survives")
  }

  func testATailWindowWithNoRecordInItYieldsNothing() throws {
    let url = root.appendingPathComponent("one-huge-line.jsonl")
    try String(repeating: "x", count: 100_000).write(to: url, atomically: true, encoding: .utf8)

    let (lines, complete) = try tailLines(of: url, maxBytes: 1 << 10)

    XCTAssertFalse(complete)
    XCTAssertTrue(lines.isEmpty)
  }

  func testAFileInsideTheWindowIsReadWholeEitherWay() throws {
    let url = root.appendingPathComponent("small.jsonl")
    try "first\nsecond\nthird".write(to: url, atomically: true, encoding: .utf8)
    let open = try tailLines(of: url, maxBytes: 1 << 20)
    XCTAssertTrue(open.complete)
    XCTAssertEqual(open.lines, ["first", "second", "third"])

    try "first\nsecond\nthird\n".write(to: url, atomically: true, encoding: .utf8)
    let closed = try tailLines(of: url, maxBytes: 1 << 20)
    XCTAssertTrue(closed.complete)
    XCTAssertEqual(closed.lines, ["first", "second", "third"])
  }

  func testALongClaudeTranscriptStillKnowsItsTitle() throws {
    let url = root.appendingPathComponent("titled.jsonl")
    var records = [claudeUserRecord(uuid: "u0", text: "rename the invoices")]
    records += (1...400).map {
      claudeUserRecord(uuid: "u\($0)", text: String(repeating: "filler ", count: 40))
    }
    try records.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

    let parsed = ClaudeCodeTranscript.read(at: url)

    XCTAssertEqual(parsed.title, "rename the invoices")
    XCTAssertFalse(parsed.messages.isEmpty)
  }

  func testWordsSentMidTurnAreTheUsersMessage() throws {
    let url = root.appendingPathComponent("steered.jsonl")
    let records = [
      #"{"type":"user","uuid":"1d606640-aa11-49fb-bd76-3d6fddcd3595","timestamp":"2026-10-13T20:11:17.275Z","message":{"role":"user","content":[{"type":"text","text":"Run the shell command `sleep 8` with the Bash tool. After it finishes, reply with one short sentence."}]}}"#,
      #"{"type":"attachment","uuid":"16d6e825-9235-4617-a0d0-4a425a726df2","timestamp":"2026-10-13T20:11:23.542Z","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"Also: end your reply with the single word PINEAPPLE."}],"source_uuid":"926bd3fa-74c3-4582-a0fa-d4562aa574d3"}}"#,
      #"{"type":"attachment","uuid":"49c920a3","timestamp":"2026-10-13T20:11:27.150Z","attachment":{"type":"total_tokens_reminder","text":"<total_tokens>14965084 tokens left</total_tokens>"}}"#,
      #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-13T20:11:30.000Z","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"The 8-second sleep finished with no output. PINEAPPLE"}]}}"#,
    ]
    try records.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

    let parsed = ClaudeCodeTranscript.read(at: url)
    XCTAssertEqual(parsed.messages.map(\.role), [.user, .user, .agent], "other attachments are not messages")
    XCTAssertEqual(parsed.messages[1].plainText, "Also: end your reply with the single word PINEAPPLE.")
    XCTAssertEqual(parsed.messages[1].id, "16d6e825-9235-4617-a0d0-4a425a726df2")
  }

  func testTheCLIsNoteAboutWhereItPutThePicturesIsNotAMessage() throws {
    let url = root.appendingPathComponent("images.jsonl")
    let real = #"{"type":"user","uuid":"u1","timestamp":"2026-09-21T09:15:42.123Z","message":{"role":"user","content":[{"type":"text","text":"[Image #57] the copy button belongs under the text"},{"type":"image"}]}}"#
    let note = #"{"type":"user","uuid":"u2","timestamp":"2026-09-21T09:15:43.123Z","message":{"role":"user","content":[{"type":"text","text":"[Image: source: /Users/me/.claude/image-cache/x/57.png]"},{"type":"text","text":"[Image: source: /Users/me/.claude/image-cache/x/58.png]"}]}}"#
    try [real, note].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

    let parsed = ClaudeCodeTranscript.read(at: url)

    XCTAssertEqual(parsed.messages.map(\.plainText),
                   ["[Image #57] the copy button belongs under the text"])
  }

  func testAMessageThatMentionsAnImageIsStillAMessage() {
    XCTAssertTrue(ClaudeCodeTranscript.isImageBookkeeping(
      "[Image: source: /x/57.png]\n[Image: source: /x/58.png]"))
    XCTAssertFalse(ClaudeCodeTranscript.isImageBookkeeping("[Image #57] look at this"))
    XCTAssertFalse(ClaudeCodeTranscript.isImageBookkeeping(
      "[Image: source: /x/57.png]\nand fix the button"))
    XCTAssertFalse(ClaudeCodeTranscript.isImageBookkeeping(""))
  }

  func testTheHarnessTalkingToItselfIsNotAMessage() throws {
    let url = root.appendingPathComponent("noise.jsonl")
    let records = [
      claudeUserRecord(uuid: "u1", text: "<task-notification>\\n<task-id>abc</task-id>"),
      claudeUserRecord(uuid: "u2", text: "<command-name>/clear</command-name>"),
      claudeUserRecord(uuid: "u3", text: "<local-command-stdout>Compacted</local-command-stdout>"),
      claudeUserRecord(uuid: "u4", text: "[Request interrupted by user for tool use]"),
      claudeUserRecord(uuid: "u5", text: "Base directory for this skill: /tmp/design"),
      claudeUserRecord(uuid: "u6", text: "[Image: original 3600x2338, displayed at 2000x1299.]"),
      claudeUserRecord(uuid: "u7", text: "the copy button belongs under the text"),
    ]
    try records.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

    let parsed = ClaudeCodeTranscript.read(at: url)

    XCTAssertEqual(parsed.messages.map(\.plainText),
                   ["the copy button belongs under the text"])
  }

  func testCodexShowsTheRequestRatherThanTheBlockAroundIt() throws {
    let url = try writeRollout(id: idA, userTexts: [])
    let wrapped = """
      # In app browser:\\n- The user has the in-app browser open with 1 tab.\\n\
      - Current URL: http://localhost:4173/\\n\\n## My request for Codex:\\n\
      the cursor should stay a pointer while the volume changes
      """
    let lines = [
      ##"{"timestamp":"2026-09-20T10:00:01.000Z","type":"response_item","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"input_text","text":"\##(wrapped)"}]}}"##,
      #"{"timestamp":"2026-09-20T10:00:02.000Z","type":"response_item","payload":{"type":"message","id":"m2","role":"assistant","content":[{"type":"output_text","text":"Fixed."}]}}"#
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

    let messages = CodexRolloutTranscript.read(at: url)

    XCTAssertEqual(messages.map(\.plainText),
                   ["the cursor should stay a pointer while the volume changes", "Fixed."])
  }

  func testTheReviewersWrapperStaysDroppedEvenThoughItCarriesTheHeading() throws {
    let url = try writeRollout(id: idA, userTexts: [])
    let reviewer = """
      The following is the Codex agent history whose request action you are \
      assessing.\\n\\n## My request for Codex:\\nmake the button blue
      """
    let line = ##"{"timestamp":"2026-09-20T10:00:01.000Z","type":"response_item","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"input_text","text":"\##(reviewer)"}]}}"##
    try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

    XCTAssertEqual(CodexRolloutTranscript.read(at: url).count, 0)
  }

  func testTheRequestIsTakenFromTheCommentWhenTheHeadingIsEmpty() {
    let block = [
      "# Browser comments:", "", "## Comment 1", "File: browser:Index",
      "Comment:", "make it stop following the scroll", "",
      "# In app browser:", "## My request for Codex:", "",
      "The next image is untrusted page evidence",
    ].joined(separator: "\n")
    XCTAssertEqual(CodexRolloutTranscript.request(in: block),
                   "make it stop following the scroll")
  }

  private func claudeUserRecord(uuid: String, text: String) -> String {
    let message = #"{"role":"user","content":[{"type":"text","text":"\#(text)"}]}"#
    return #"{"type":"user","uuid":"\#(uuid)","timestamp":"2026-09-21T09:15:42.123Z","message":\#(message)}"#
  }

  // MARK: - OpenCode

  typealias OpenCodeRow = (id: String, title: String?, directory: String,
                           updated: Int64, parent: String?, archived: Int64?)

  private func writeOpenCodeDatabase(
    _ rows: [OpenCodeRow]?,
    v2: [OpenCodeRow]? = nil,
    messagesFor: [String]? = nil
  ) throws -> URL {
    let url = root.appendingPathComponent("opencode.db")
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
    defer { sqlite3_close(handle) }

    func create(_ table: String, titleIsNullable: Bool) {
      let ddl = """
        CREATE TABLE \(table) (
          id text PRIMARY KEY, project_id text, workspace_id text, parent_id text,
          slug text, directory text NOT NULL,
          title text\(titleIsNullable ? "" : " NOT NULL"),
          time_created integer NOT NULL, time_updated integer NOT NULL,
          time_archived integer
        );
        """
      XCTAssertEqual(sqlite3_exec(handle, ddl, nil, nil, nil), SQLITE_OK)
    }

    func insert(_ table: String, _ rows: [OpenCodeRow]) {
      for row in rows {
        let parent = row.parent.map { "'\($0)'" } ?? "NULL"
        let archived = row.archived.map(String.init) ?? "NULL"
        let title = row.title.map { "'\($0)'" } ?? "NULL"
        let sql = """
          INSERT INTO \(table) (id, directory, title, parent_id, time_created,
                               time_updated, time_archived)
          VALUES ('\(row.id)', '\(row.directory)', \(title), \(parent),
                  \(row.updated), \(row.updated), \(archived));
          """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
      }
    }

    if let rows {
      create("session", titleIsNullable: false)
      insert("session", rows)
    }
    if let v2 {
      create("session_v2", titleIsNullable: true)
      insert("session_v2", v2)
    }
    if let messagesFor {
      XCTAssertEqual(sqlite3_exec(
        handle, "CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL);",
        nil, nil, nil), SQLITE_OK)
      for (index, session) in messagesFor.enumerated() {
        XCTAssertEqual(sqlite3_exec(
          handle, "INSERT INTO message (id, session_id) VALUES ('msg_\(index)', '\(session)');",
          nil, nil, nil), SQLITE_OK)
      }
    }
    if rows == nil, v2 == nil {
      XCTAssertEqual(
        sqlite3_exec(handle, "CREATE TABLE migration (id text);", nil, nil, nil), SQLITE_OK
      )
    }
    return url
  }

  func testOpenCodeSessionsComeBackNewestFirstWithTheirDirectory() throws {
    let url = try writeOpenCodeDatabase([
      ("ses_old", "First thing", "/Users/me/one", 1_789_900_000_000, nil, nil),
      ("ses_new", "Second thing", "/Users/me/two", 1_789_913_860_435, nil, nil)
    ])

    let sessions = try OpenCodeSessionStore(database: url).sessions(limit: 10)

    XCTAssertEqual(sessions.map(\.id), ["ses_new", "ses_old"])
    XCTAssertEqual(sessions[0].agent, .opencode)
    XCTAssertEqual(sessions[0].workingDirectory, "/Users/me/two")
    XCTAssertEqual(sessions[0].updatedAt.timeIntervalSince1970, 1_789_913_860.435, accuracy: 0.01)
  }

  func testSubSessionsAndArchivedSessionsAreNotChats() throws {
    let url = try writeOpenCodeDatabase([
      ("ses_top", "Real chat", "/Users/me", 1_789_913_000_000, nil, nil),
      ("ses_child", "Sub-agent", "/Users/me", 1_789_913_500_000, "ses_top", nil),
      ("ses_gone", "Archived", "/Users/me", 1_789_913_900_000, nil, 1_789_914_000_000)
    ])

    XCTAssertEqual(try OpenCodeSessionStore(database: url).sessions(limit: 10).map(\.id),
                   ["ses_top"])
  }

  func testTwoPointZeroChatsAreRead_AndTheFrozenCopyIsNotShownTwice() throws {
    let url = try writeOpenCodeDatabase(
      [
        ("ses_copied", "As it was at the upgrade", "/Users/me/one",
         1_789_900_000_000, nil, nil),
        ("ses_stranded", "Never copied forward", "/Users/me/two",
         1_789_901_000_000, nil, nil)
      ],
      v2: [
        ("ses_copied", "As it is now", "/Users/me/one", 1_789_913_000_000, nil, nil),
        ("ses_fresh", "Written after the upgrade", "/Users/me/three",
         1_789_914_000_000, nil, nil)
      ]
    )

    let sessions = try OpenCodeSessionStore(database: url).sessions(limit: 10)

    XCTAssertEqual(sessions.map(\.id), ["ses_fresh", "ses_copied", "ses_stranded"])
    XCTAssertEqual(sessions[1].title, "As it is now")
  }

  func testAChatDeletedOnTwoPointZeroDoesNotComeBackFromTheFrozenTable() throws {
    let url = try writeOpenCodeDatabase(
      [
        ("ses_stranded", "Never copied forward", "/Users/me/two", 1_789_901_000_000, nil, nil),
        ("ses_deleted", "Deleted since", "/Users/me/two", 1_789_902_000_000, nil, nil)
      ],
      v2: [("ses_fresh", "Written after", "/Users/me", 1_789_914_000_000, nil, nil)],
      messagesFor: ["ses_stranded", "ses_stranded"]
    )

    XCTAssertEqual(try OpenCodeSessionStore(database: url).sessions(limit: 10).map(\.id),
                   ["ses_fresh", "ses_stranded"])
  }

  func testAStoreWithOnlyTheNewTableStillReads() throws {
    let url = try writeOpenCodeDatabase(
      nil,
      v2: [("ses_new", "Only ever 2.0", "/Users/me", 1_789_913_000_000, nil, nil)]
    )

    XCTAssertEqual(try OpenCodeSessionStore(database: url).sessions(limit: 10).map(\.id),
                   ["ses_new"])
  }

  func testAnUntitledTwoPointZeroChatIsNamedAfterItsDirectory() throws {
    let url = try writeOpenCodeDatabase(
      nil,
      v2: [("ses_bare", nil, "/Users/me/boltty", 1_789_913_000_000, nil, nil)]
    )

    XCTAssertEqual(try OpenCodeSessionStore(database: url).sessions(limit: 10).map(\.title),
                   ["boltty"])
  }

  func testSubSessionsAndArchivedSessionsAreNotChatsInTheNewTableEither() throws {
    let url = try writeOpenCodeDatabase(
      nil,
      v2: [
        ("ses_top", "Real chat", "/Users/me", 1_789_913_000_000, nil, nil),
        ("ses_child", "Sub-agent", "/Users/me", 1_789_913_500_000, "ses_top", nil),
        ("ses_gone", "Archived", "/Users/me", 1_789_913_900_000, nil, 1_789_914_000_000)
      ]
    )

    XCTAssertEqual(try OpenCodeSessionStore(database: url).sessions(limit: 10).map(\.id),
                   ["ses_top"])
  }

  func testADatabaseWithNoSessionTableSaysSoRatherThanReadingAsEmpty() throws {
    let url = try writeOpenCodeDatabase(nil)

    XCTAssertThrowsError(try OpenCodeSessionStore(database: url).sessions(limit: 10)) { error in
      guard case .unreadable = error as? NativeSessionStoreError else {
        return XCTFail("expected .unreadable, got \(error)")
      }
    }
  }

  func testNoOpenCodeDatabaseIsAnEmptyListRatherThanAnError() throws {
    let store = OpenCodeSessionStore(database: root.appendingPathComponent("absent.db"))
    XCTAssertEqual(try store.sessions(limit: 10), [])
  }

  func testADatabaseThatIsNotADatabaseThrowsRatherThanReadingAsEmpty() throws {
    let url = root.appendingPathComponent("broken.db")
    try Data("this is not a database".utf8).write(to: url)

    XCTAssertThrowsError(try OpenCodeSessionStore(database: url).sessions(limit: 10)) { error in
      guard case .unreadable = error as? NativeSessionStoreError else {
        return XCTFail("expected .unreadable, got \(error)")
      }
    }
  }
  // MARK: - Claude Code

  @discardableResult
  private func writeClaudeSession(
    id: String,
    project: String = "-Users-me-Projects-thing",
    cwd: String = "/Users/me/Projects/thing",
    entries: [String],
    modified: Date = Date()
  ) throws -> URL {
    let directory = root.appendingPathComponent("projects/\(project)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(id).jsonl")
    let header = #"{"type":"mode","mode":"normal","sessionId":"\#(id)","cwd":"\#(cwd)"}"#
    try (([header] + entries).joined(separator: "\n") + "\n")
      .write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
  }

  private func claudeUserLine(_ text: String, meta: Bool = false, sidechain: Bool = false) -> String {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return #"{"type":"user","isMeta":\#(meta),"isSidechain":\#(sidechain),"message":{"role":"user","content":"\#(escaped)"}}"#
  }

  private func claudeSessions(limit: Int = 50) throws -> [NativeSession] {
    try ClaudeCodeSessionStore(root: root.appendingPathComponent("projects"))
      .sessions(limit: limit)
  }

  func testAClaudeCodeSessionIsNamedByItsFileAndPlacedByItsCwd() throws {
    try writeClaudeSession(
      id: "708838fe-6798-47e5-aca3-e7624d9e60a1",
      project: "-Users-me-Documents-Projects-me-work",
      cwd: "/Users/me/Documents/Projects/me.work",
      entries: [claudeUserLine("fix the footer")]
    )

    let sessions = try claudeSessions()

    XCTAssertEqual(sessions.map(\.id), ["708838fe-6798-47e5-aca3-e7624d9e60a1"])
    XCTAssertEqual(sessions[0].agent, .claude)
    XCTAssertEqual(sessions[0].workingDirectory, "/Users/me/Documents/Projects/me.work")
    XCTAssertEqual(sessions[0].title, "fix the footer")
  }

  func testTheCaveatAndTheSlashCommandAreNotTheTitle() throws {
    try writeClaudeSession(id: "aaaaaaaa-0000-0000-0000-000000000001", entries: [
      claudeUserLine("<local-command-caveat>Caveat: the messages below…", meta: true),
      claudeUserLine("<command-name>/clear</command-name>"),
      claudeUserLine("<system-reminder>You are in a worktree</system-reminder>"),
      claudeUserLine("what broke the build?")
    ])

    XCTAssertEqual(try claudeSessions()[0].title, "what broke the build?")
  }

  func testTheTitleSkipsWhatTheTranscriptSkips() throws {
    try writeClaudeSession(id: "aaaaaaaa-0000-0000-0000-000000000005", entries: [
      claudeUserLine("Base directory for this skill: /Users/me/.claude/skills/research"),
      claudeUserLine("<command-args>--deep</command-args>"),
      claudeUserLine("[Request interrupted by user]"),
      claudeUserLine("summarise the release notes")
    ])

    XCTAssertEqual(try claudeSessions()[0].title, "summarise the release notes")
  }

  func testAPastedTagAndAMarkdownHeadingAreStillTheUsersWords() throws {
    try writeClaudeSession(id: "aaaaaaaa-0000-0000-0000-000000000002", entries: [
      claudeUserLine("<div data-layer=\"Frame\" className=\"Frame\">")
    ])
    try writeClaudeSession(id: "aaaaaaaa-0000-0000-0000-000000000003", entries: [
      claudeUserLine("# Task: Implement Native Voice Glow")
    ])

    let titles = try claudeSessions().map(\.title)
    XCTAssertTrue(titles.contains("<div data-layer=\"Frame\" className=\"Frame\">"), "\(titles)")
    XCTAssertTrue(titles.contains("# Task: Implement Native Voice Glow"), "\(titles)")
  }

  func testASidechainTurnIsNotTheTitle() throws {
    try writeClaudeSession(id: "aaaaaaaa-0000-0000-0000-000000000004", entries: [
      claudeUserLine("Explore the settings surface and report", sidechain: true),
      claudeUserLine("now make it green")
    ])

    XCTAssertEqual(try claudeSessions()[0].title, "now make it green")
  }

  func testNoClaudeProjectsDirectoryIsAnEmptyList() throws {
    let store = ClaudeCodeSessionStore(root: root.appendingPathComponent("nope"))
    XCTAssertEqual(try store.sessions(limit: 10), [])
  }

  // MARK: - Grok

  @discardableResult
  private func writeGrokSession(
    id: String,
    place: String = "%2FUsers%2Fme",
    cwd: String = "/Users/me",
    summary: String = "",
    messages: Int,
    history: [String] = [],
    updated: String = "2026-09-11T08:25:32.646947Z"
  ) throws -> URL {
    let directory = root.appendingPathComponent("sessions/\(place)/\(id)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let json = """
      {"info":{"id":"\(id)","cwd":"\(cwd)"},"session_summary":"\(summary)",\
      "num_messages":\(messages),"last_active_at":"\(updated)"}
      """
    try json.write(
      to: directory.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8
    )
    if !history.isEmpty {
      try (history.joined(separator: "\n") + "\n").write(
        to: directory.appendingPathComponent("chat_history.jsonl"),
        atomically: true, encoding: .utf8
      )
    }
    return directory
  }

  private func grokSessions(limit: Int = 50) throws -> [NativeSession] {
    try GrokSessionStore(root: root.appendingPathComponent("sessions")).sessions(limit: limit)
  }

  func testGroksAbandonedShellsAreNotChats() throws {
    try writeGrokSession(id: "01a0bb32-shell", messages: 1, history: [
      #"{"type":"system","content":"You are Grok"}"#,
      #"{"type":"user","synthetic_reason":"system_reminder","content":[{"type":"text","text":"<system-reminder>skills</system-reminder>"}]}"#
    ])
    try writeGrokSession(id: "01a0bb32-real", summary: "Tray unread gone", messages: 595)

    XCTAssertEqual(try grokSessions().map(\.title), ["Tray unread gone"])
  }

  func testAGrokChatWithNoNameYetFallsBackToWhatWasTyped() throws {
    try writeGrokSession(id: "01a0bb32-unnamed", messages: 12, history: [
      #"{"type":"system","content":"You are Grok"}"#,
      #"{"type":"user","synthetic_reason":"system_reminder","content":[{"type":"text","text":"<system-reminder>x</system-reminder>"}]}"#,
      #"{"type":"user","content":[{"type":"text","text":"why is the tray icon blank"}]}"#
    ])

    XCTAssertEqual(try grokSessions()[0].title, "why is the tray icon blank")
  }

  func testGrokSessionsAreNewestFirstAndCarryTheirDirectory() throws {
    try writeGrokSession(
      id: "01a0-older", cwd: "/Users/me/one", summary: "Older",
      messages: 4, updated: "2026-09-10T08:00:00.123456Z"
    )
    try writeGrokSession(
      id: "01a0-newer", cwd: "/Users/me/two", summary: "Newer",
      messages: 4, updated: "2026-09-19T08:00:00.123456Z"
    )

    let sessions = try grokSessions()
    XCTAssertEqual(sessions.map(\.title), ["Newer", "Older"])
    XCTAssertEqual(sessions[0].workingDirectory, "/Users/me/two")
    XCTAssertEqual(sessions[0].agent, .grok)
  }

  func testGrokTimestampsWithMicrosecondsParse() throws {
    let parsed = GrokSessionStore.date("2026-09-11T08:25:32.646947Z")
    XCTAssertEqual(try XCTUnwrap(parsed).timeIntervalSince1970, 1_789_115_132, accuracy: 1)
    XCTAssertNil(GrokSessionStore.date("not a date"))
  }

  func testNoGrokDirectoryIsAnEmptyList() throws {
    let store = GrokSessionStore(root: root.appendingPathComponent("nope"))
    XCTAssertEqual(try store.sessions(limit: 10), [])
  }

  // MARK: - Re-reading one chat

  func testOneChangedRolloutIsReReadOnItsOwn() throws {
    try writeRollout(id: idA, userTexts: ["the first thing"])
    try writeIndex([])
    let store = CodexSessionStore(root: root)
    let change = NativeStoreChange.chat(
      id: idA,
      at: root.appendingPathComponent(
        "sessions/2026/09/20/rollout-2026-09-20T13-25-55-\(idA).jsonl"
      )
    )

    let session = try XCTUnwrap(store.session(for: change))

    XCTAssertEqual(session.id, idA)
    XCTAssertEqual(session.title, "the first thing")
  }

  func testAChatThatIsGoneReReadsAsNothing() throws {
    let store = CodexSessionStore(root: root)
    let missing = NativeStoreChange.chat(
      id: idA,
      at: root.appendingPathComponent("sessions/2026/09/20/rollout-x-\(idA).jsonl")
    )

    XCTAssertNil(try store.session(for: missing))
  }

  func testTheDatabaseStoreHasNoSingleChatToReRead() throws {
    XCTAssertNil(
      try OpenCodeSessionStore(database: root.appendingPathComponent("x.db"))
        .session(for: .chat(id: "ses_1", at: root))
    )
  }

  // MARK: - Reading a transcript out of the CLI's own file

  func testACodexTranscriptIsRebuiltFromItsRollout() throws {
    let url = try writeRollout(id: idA, userTexts: [])
    let lines = [
      #"{"type":"session_meta","payload":{"session_id":"\#(idA)","cwd":"/tmp"}}"#,
      #"{"timestamp":"2026-09-20T10:00:00.000Z","type":"response_item","payload":{"type":"message","id":"m1","role":"developer","content":[{"type":"input_text","text":"<model_switch>ignore me"}]}}"#,
      ##"{"timestamp":"2026-09-20T10:00:02.000Z","type":"response_item","payload":{"type":"message","id":"m2","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /x"}]}}"##,
      #"{"timestamp":"2026-09-20T10:00:02.000Z","type":"response_item","payload":{"type":"message","id":"m3","role":"user","content":[{"type":"input_text","text":"make the button blue"}]}}"#,
      #"{"timestamp":"2026-09-20T10:00:03.000Z","type":"response_item","payload":{"type":"message","id":"m4","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

    let messages = CodexRolloutTranscript.read(at: url)

    XCTAssertEqual(messages.map(\.role), [.user, .agent])
    XCTAssertEqual(messages.map(\.plainText), ["make the button blue", "Done."])
  }

  func testACodexMessageSentWithAPictureKeepsItsWords() throws {
    let url = try writeRollout(id: idA, userTexts: [])
    let marker = #"<image name=[Image #1] path=\"/tmp/codex-clipboard-a.png\">  </image> "#
    let lines = [
      ##"{"timestamp":"2026-09-20T10:00:02.000Z","type":"response_item","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"input_text","text":"\##(marker)the settings window opens twice"}]}}"##,
      ##"{"timestamp":"2026-09-20T10:00:03.000Z","type":"response_item","payload":{"type":"message","id":"m2","role":"user","content":[{"type":"input_text","text":"<image name=[Image #2] path=\"/tmp/b.png\"></image>"}]}}"##,
      #"{"timestamp":"2026-09-20T10:00:04.000Z","type":"response_item","payload":{"type":"message","id":"m3","role":"assistant","content":[{"type":"output_text","text":"Fixed."}]}}"#
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

    let messages = CodexRolloutTranscript.read(at: url)

    XCTAssertEqual(messages.map(\.role), [.user, .agent])
    XCTAssertEqual(messages[0].plainText, "the settings window opens twice")
  }

  func testTakingATagOutLeavesTheSentenceAndSpotsALookalike() {
    XCTAssertEqual(
      InjectedText.without("<image name=x></image> what is this", tag: "image"),
      "what is this"
    )
    XCTAssertEqual(InjectedText.without("<image name=x> what is this", tag: "image"),
                   "what is this")
    XCTAssertEqual(InjectedText.without("<imagery> kept", tag: "image"), "<imagery> kept")
  }

  func testACodexToolCallAndItsOutputAreOneActivity() throws {
    let url = try writeRollout(id: idA, userTexts: [])
    let lines = [
      #"{"timestamp":"2026-09-20T10:00:00.000Z","type":"response_item","payload":{"type":"message","id":"m1","role":"assistant","content":[{"type":"output_text","text":"Looking."}]}}"#,
      #"{"timestamp":"2026-09-20T10:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call","id":"ctc1","call_id":"c1","name":"exec","input":"ls"}}"#,
      #"{"timestamp":"2026-09-20T10:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","id":"ctco1","call_id":"c1","output":[{"type":"input_text","text":"two files"}]}}"#
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

    let messages = CodexRolloutTranscript.read(at: url)

    XCTAssertEqual(messages.count, 1, "the tool call joins the turn that asked for it")
    let activities = messages[0].parts.compactMap { part -> AgentActivity? in
      guard case let .activity(activity) = part else { return nil }
      return activity
    }
    XCTAssertEqual(activities.count, 1)
    XCTAssertEqual(activities[0].name, "exec")
    XCTAssertEqual(activities[0].detail, "two files")
    XCTAssertEqual(activities[0].state, .completed)
  }

  func testTheCodexStoreCarriesThePathItsTranscriptIsReadFrom() throws {
    try writeRollout(id: idA, userTexts: ["hello"])
    try writeIndex([])
    let store = CodexSessionStore(root: root)

    let session = try XCTUnwrap(store.sessions(limit: 10).first)

    XCTAssertNotNil(session.sourceURL)
    XCTAssertEqual(try store.transcript(for: session)?.map(\.plainText), ["hello"])
  }

  func testAStoreWithNoTranscriptReaderSaysSoRatherThanClaimingEmpty() throws {
    let store = OpenCodeSessionStore(database: root.appendingPathComponent("x.db"))
    let session = NativeSession(
      id: "ses_1", agent: .opencode, title: "t", workingDirectory: "/tmp", updatedAt: Date()
    )

    XCTAssertNil(try store.transcript(for: session))
  }

  func testTheRealCodexTranscriptsRebuild() throws {
    let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: home.appendingPathComponent("sessions").path),
      "Codex has never run on this machine"
    )
    let store = CodexSessionStore(root: home)
    let sessions = try store.sessions(limit: 12)
    try XCTSkipIf(sessions.isEmpty, "no Codex sessions")

    let started = Date()
    var withMessages = 0
    for session in sessions where try store.transcript(for: session)?.isEmpty == false {
      withMessages += 1
    }
    print("""
      [real codex transcripts] \(withMessages)/\(sessions.count) rebuilt in \
      \(String(format: "%.2f", Date().timeIntervalSince(started)))s
      """)
    XCTAssertGreaterThan(withMessages, 0, "a real rollout must rebuild into something")

    for session in sessions {
      guard let url = session.sourceURL, codexPastedAPicture(in: url) else { continue }
      let spoken = try store.transcript(for: session)?.filter { $0.role == .user } ?? []
      XCTAssertFalse(spoken.isEmpty, "\(session.id) pasted a picture and says nothing")
    }
  }

  private func codexPastedAPicture(in url: URL) -> Bool {
    guard let file = try? String(contentsOf: url, encoding: .utf8) else { return false }
    for line in file.split(separator: "\n") {
      guard let data = line.data(using: .utf8),
            let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = record["payload"] as? [String: Any],
            payload["role"] as? String == "user",
            let parts = payload["content"] as? [[String: Any]],
            let text = parts.compactMap({ $0["text"] as? String }).first
      else { continue }
      if text.hasPrefix("<image ") { return true }
    }
    return false
  }

  // MARK: - Grok's transcript

  func testAGrokTranscriptIsRebuiltFromItsChatHistory() throws {
    let directory = try writeGrokSession(id: "01a0-real", messages: 12, history: [
      #"{"type":"system","content":"You are Grok"}"#,
      #"{"type":"user","synthetic_reason":"system_reminder","content":[{"type":"text","text":"reminder"}]}"#,
      #"{"type":"user","content":[{"type":"text","text":"<user_info>OS: macos</user_info>"}]}"#,
      #"{"type":"user","content":[{"type":"text","text":"why is the tray blank"}]}"#,
      #"{"type":"reasoning","id":"rs1","summary":[{"type":"summary_text","text":"They mean the menu bar."}]}"#,
      #"{"type":"assistant","content":"Looking now.","tool_calls":[{"id":"c1","name":"read_file","arguments":"{}"}]}"#,
      #"{"type":"tool_result","tool_call_id":"c1","content":"three matches"}"#
    ])

    let messages = GrokChatHistoryTranscript.read(
      at: directory.appendingPathComponent("chat_history.jsonl")
    )

    XCTAssertEqual(messages.map(\.role), [.user, .agent, .agent])
    XCTAssertEqual(messages[0].plainText, "why is the tray blank")
    XCTAssertTrue(messages[1].parts.contains { part in
      guard case let .reasoning(text) = part else { return false }
      return text.text == "They mean the menu bar."
    })
    XCTAssertEqual(messages[2].plainText, "Looking now.")
    let activity = messages[2].parts.compactMap { part -> AgentActivity? in
      guard case let .activity(activity) = part else { return nil }
      return activity
    }.first
    XCTAssertEqual(activity?.name, "read_file")
    XCTAssertEqual(activity?.detail, "three matches")
  }

  func testTheGrokStoreReadsItsOwnTranscript() throws {
    try writeGrokSession(id: "01a0-chat", summary: "Tray", messages: 4, history: [
      #"{"type":"user","content":[{"type":"text","text":"hello"}]}"#
    ])
    let store = GrokSessionStore(root: root.appendingPathComponent("sessions"))
    let session = try XCTUnwrap(store.sessions(limit: 10).first)

    XCTAssertNotNil(session.sourceURL)
    XCTAssertEqual(try store.transcript(for: session)?.map(\.plainText), ["hello"])
  }


  func testWhatTheUserTypedSurvivesGroksOwnEnvelope() throws {
    let directory = try writeGrokSession(id: "01a0-wrapped", messages: 4, history: [
      #"{"type":"user","content":[{"type":"text","text":"<user_info>OS: macos</user_info>"}]}"#,
      #"{"type":"user","content":[{"type":"text","text":"<user_query>\nReply with exactly one word: pong\n</user_query>"}]}"#,
      #"{"type":"assistant","content":"pong"}"#
    ])

    let messages = GrokChatHistoryTranscript.read(
      at: directory.appendingPathComponent("chat_history.jsonl")
    )

    XCTAssertEqual(messages.map(\.role), [.user, .agent])
    XCTAssertEqual(messages[0].plainText, "Reply with exactly one word: pong")
  }

  func testAnUnnamedGrokChatIsTitledByWhatWasTypedInsideTheEnvelope() throws {
    try writeGrokSession(id: "01a0-untitled", messages: 4, history: [
      #"{"type":"user","content":[{"type":"text","text":"<user_query>\nwhy is the tray blank\n</user_query>"}]}"#
    ])
    let store = GrokSessionStore(root: root.appendingPathComponent("sessions"))

    XCTAssertEqual(try store.sessions(limit: 10).map(\.title), ["why is the tray blank"])
  }

  func testAMessageSentWithAnImageIsStillWhatTheUserTyped() throws {
    let wrapped = """
      <image_files>\\nsaved to the workspace\\n</image_files>\\n\\n\
      <user_query>\\nremove that green notification\\n</user_query>\\n\\n\
      <system-reminder>\\nImage 1 was re-encoded\\n</system-reminder>
      """
    let directory = try writeGrokSession(id: "01a0-image", messages: 4, history: [
      #"{"type":"user","content":[{"type":"text","text":"\#(wrapped)"},{"type":"image_url"}]}"#,
      #"{"type":"assistant","content":"Removed."}"#
    ])

    let messages = GrokChatHistoryTranscript.read(
      at: directory.appendingPathComponent("chat_history.jsonl")
    )

    XCTAssertEqual(messages.map(\.role), [.user, .agent])
    XCTAssertEqual(messages[0].plainText, "remove that green notification")
  }

  func testTheEnvelopeIsFoundWhereverItIsAndMissingWhenItIsNotThere() {
    XCTAssertEqual(InjectedText.inside("<user_query>\nhalf a line", tag: "user_query"),
                   "half a line")
    XCTAssertNil(InjectedText.inside("<user_info>OS: macos</user_info>", tag: "user_query"))
  }

  func testTheRealGrokTranscriptsRebuild() throws {
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/sessions")
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: root.path), "Grok has never run here"
    )
    let store = GrokSessionStore(root: root)
    let sessions = try store.sessions(limit: 30)
    try XCTSkipIf(sessions.isEmpty, "no Grok chats")

    var rebuilt = 0
    for session in sessions where try store.transcript(for: session)?.isEmpty == false {
      rebuilt += 1
    }
    print("[real grok transcripts] \(rebuilt)/\(sessions.count) rebuilt")
    XCTAssertGreaterThan(rebuilt, 0)

    for session in sessions {
      let history = try XCTUnwrap(session.sourceURL)
        .appendingPathComponent("chat_history.jsonl")
      guard let file = try? String(contentsOf: history, encoding: .utf8),
            file.contains("<user_query>")
      else { continue }
      let spoken = try store.transcript(for: session)?.filter { $0.role == .user } ?? []
      XCTAssertFalse(spoken.isEmpty, "\(session.id) has a typed message and shows none")
    }
  }

  // MARK: - The adapters read the same files

  func testTheCodexAdapterReadsEveryRealThreadWithoutStartingCodex() async throws {
    let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: home.path), "Codex has never run here")
    let sessions = try CodexSessionStore(root: home).sessions(limit: 20)
    try XCTSkipIf(sessions.isEmpty, "no Codex chats")
    let client = CodexClient(executable: "/nonexistent/codex", codexHome: home)

    for session in sessions {
      let snapshot = try await client.loadSession(id: session.id)
      let fromStore = try CodexSessionStore(root: home).transcript(for: session) ?? []
      XCTAssertEqual(snapshot.messages.map(\.plainText), fromStore.map(\.plainText),
                     "\(session.id): the adapter and the switcher disagree about this chat")
    }
  }

  func testTheGrokAdapterReadsEveryRealSessionWithoutStartingGrok() async throws {
    let root = GrokChatHistoryTranscript.defaultRoot
    try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path), "Grok has never run here")
    let sessions = try GrokSessionStore(root: root).sessions(limit: 30)
    try XCTSkipIf(sessions.isEmpty, "no Grok chats")
    let client = ACPClient(agent: .grok, executable: "/nonexistent/grok")

    var withUserTurns = 0
    for session in sessions {
      let snapshot = try await client.loadSession(id: session.id)
      let fromStore = try GrokSessionStore(root: root).transcript(for: session) ?? []
      XCTAssertEqual(snapshot.messages.map(\.plainText), fromStore.map(\.plainText),
                     "\(session.id): the adapter and the switcher disagree about this chat")
      if snapshot.messages.contains(where: { $0.role == .user }) { withUserTurns += 1 }
    }
    XCTAssertGreaterThan(withUserTurns, 0, "not one real Grok chat showed anything typed")
  }

  // MARK: - Against the real stores

  func testTheRealCodexStoreReadsAsSessions() throws {
    let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: home.appendingPathComponent("sessions").path),
      "Codex has never run on this machine"
    )

    let started = Date()
    let sessions = try CodexSessionStore(root: home).sessions(limit: 400)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertFalse(sessions.isEmpty)
    XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count, "ids are unique")
    XCTAssertTrue(sessions.allSatisfy { !$0.title.isEmpty }, "every row has something to show")
    XCTAssertTrue(
      sessions.allSatisfy { $0.updatedAt < Date().addingTimeInterval(60) },
      "nothing is dated in the future"
    )
    XCTAssertEqual(sessions, sessions.sorted { $0.updatedAt > $1.updatedAt }, "newest first")
    let named = sessions.filter { $0.title != "Codex session" }.count
    let placed = sessions.filter { !$0.workingDirectory.isEmpty }.count
    print("""
      [real codex] \(sessions.count) sessions in \(String(format: "%.2f", elapsed))s \
      — \(named) named, \(placed) placed
      """)
  }

  func testTheRealOpenCodeStoreReadsAsSessions() throws {
    let database = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".local/share/opencode/opencode.db")
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: database.path),
      "OpenCode has never run on this machine"
    )

    let sessions = try OpenCodeSessionStore(database: database).sessions(limit: 400)

    XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count)
    XCTAssertTrue(sessions.allSatisfy { $0.id.hasPrefix("ses_") }, "OpenCode's own spelling")
    XCTAssertTrue(sessions.allSatisfy { !$0.title.isEmpty })
    XCTAssertEqual(sessions, sessions.sorted { $0.updatedAt > $1.updatedAt })

    let tables = try openCodeSessionTables(in: database)
    XCTAssertFalse(tables.isEmpty, "this database has no session table at all")
    var expected: Set<String> = []
    for table in tables { expected.formUnion(try openCodeChatIDs(in: database, table: table)) }
    if tables.contains("session_v2") {
      expected.subtract(try openCodeQuery(database, """
        SELECT id FROM session
         WHERE id NOT IN (SELECT id FROM session_v2)
           AND id NOT IN (SELECT session_id FROM message)
        """))
    }
    if expected.count <= 400 {
      XCTAssertEqual(Set(sessions.map(\.id)), expected,
                     "read \(sessions.count) of \(expected.count) across \(tables)")
    } else {
      XCTAssertEqual(sessions.count, 400, "the cap, not a missed table")
    }
    print("[real opencode] \(sessions.count) sessions across \(tables.sorted())")
  }

  private func openCodeSessionTables(in database: URL) throws -> Set<String> {
    try openCodeQuery(
      database,
      """
      SELECT name FROM sqlite_master
       WHERE type = 'table' AND name IN ('session', 'session_v2')
      """
    )
  }

  private func openCodeChatIDs(in database: URL, table: String) throws -> Set<String> {
    try openCodeQuery(
      database,
      "SELECT id FROM \(table) WHERE parent_id IS NULL AND time_archived IS NULL"
    )
  }

  private func openCodeQuery(_ database: URL, _ sql: String) throws -> Set<String> {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(
      "file:\(database.path)?mode=ro", &handle,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
    ) == SQLITE_OK, let handle else {
      sqlite3_close(handle)
      throw NativeSessionStoreError.unreadable(path: database.path, reason: "open")
    }
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw NativeSessionStoreError.unreadable(path: database.path, reason: "prepare")
    }
    defer { sqlite3_finalize(statement) }

    var values: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let raw = sqlite3_column_text(statement, 0) { values.insert(String(cString: raw)) }
    }
    return values
  }

  func testTheRealClaudeCodeStoreReadsAsSessions() throws {
    let projects = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".claude/projects")
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: projects.path),
      "Claude Code has never run on this machine"
    )

    let started = Date()
    let sessions = try ClaudeCodeSessionStore(root: projects).sessions(limit: 400)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count)
    XCTAssertTrue(sessions.allSatisfy { !$0.title.isEmpty })
    XCTAssertEqual(sessions, sessions.sorted { $0.updatedAt > $1.updatedAt })
    let placed = sessions.filter { !$0.workingDirectory.isEmpty }.count
    print("""
      [real claude] \(sessions.count) sessions in \(String(format: "%.2f", elapsed))s \
      — \(placed) placed
      """)
  }

  func testTheRealGrokStoreReadsAsSessions() throws {
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/sessions")
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: root.path),
      "Grok has never run on this machine"
    )

    let started = Date()
    let sessions = try GrokSessionStore(root: root).sessions(limit: 400)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count)
    XCTAssertTrue(sessions.allSatisfy { !$0.title.isEmpty })
    XCTAssertEqual(sessions, sessions.sorted { $0.updatedAt > $1.updatedAt })
    let directories = (try? FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    ).count) ?? 0
    print("""
      [real grok] \(sessions.count) chats from \(directories) places in \
      \(String(format: "%.2f", elapsed))s
      """)
  }
}
