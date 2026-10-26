import AppKit
import XCTest
@testable import Boltty

/// The pictures in the README, taken from the real panel and overlay on the real
/// screen (glass and live faces do not draw offscreen). Boltty's own sunset is
/// laid over the whole display first, menu bar and Dock included, so nothing of
/// the desktop underneath gets into a picture.
///
/// `TEST_RUNNER_BOLTTY_README_SHOTS=<dir>` writes `prompt.png`, `chat.png`,
/// `permission.png`, `history.png`, `ask-boltty.png`, and three short recordings,
/// `faces.mov` (the history tabs, one face after another), `prompt-faces.mov`
/// (⇧Tab round the agents on the prompt) and `ask-boltty.mov`.
@MainActor
final class ReadmeShotsOnScreen: XCTestCase {
  private var directory = ""
  private var backdrop: NSWindow?

  override func setUp() async throws {
    guard let directory = ProcessInfo.processInfo.environment["BOLTTY_README_SHOTS"] else {
      throw XCTSkip("set TEST_RUNNER_BOLTTY_README_SHOTS=<dir> to take the README's pictures")
    }
    self.directory = directory
    let screen = try XCTUnwrap(NSScreen.main)
    let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    // Over the menu bar and the Dock, under the panel (`.popUpMenu`).
    window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]
    let sunset = SunsetView(frame: CGRect(origin: .zero, size: screen.frame.size))
    sunset.ended()
    window.contentView = sunset
    window.setFrame(screen.frame, display: true)
    window.orderFrontRegardless()
    sunset.dawn()
    backdrop = window
    try await Task.sleep(for: .seconds(2.5))
  }

  override func tearDown() async throws {
    backdrop?.orderOut(nil)
    backdrop = nil
    try await super.tearDown()
  }

  // MARK: - The panel

  func testPhotographThePanel() async throws {
    let (controller, conversations) = makePanel()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)

    controller.show()
    try await Task.sleep(for: .seconds(1.5))
    view.field.setDraft(PromptDraft("Find the biggest files in Downloads and tell me which ones are safe to delete"))
    try await Task.sleep(for: .seconds(2))
    try photograph(view, to: "prompt.png")

    let chat = addChat(to: conversations)
    controller.addressConversation(chat)
    try await Task.sleep(for: .seconds(2.5))
    try photograph(view, to: "chat.png")

    let ask = addPermission(to: conversations)
    controller.addressConversation(ask)
    try await Task.sleep(for: .seconds(2))
    try photograph(view, to: "permission.png")
    controller.hide()
    try await Task.sleep(for: .seconds(1))
  }

  /// ⇧Tab on an empty prompt, round every agent: the face turns into each one's.
  func testRecordThePromptChangingFaces() async throws {
    let (controller, _) = makePanel()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    controller.show()
    try await Task.sleep(for: .seconds(2))
    let window = try XCTUnwrap(view.window)
    view.layoutSubtreeIfNeeded()
    let surface = window.convertToScreen(view.convert(view.unifiedSurfaceFrameForTesting, to: nil))
    let reel = try record(surface.insetBy(dx: -60, dy: -44), seconds: 9, to: "prompt-faces.mov")
    try await Task.sleep(for: .seconds(1.2))
    for _ in 0..<5 {
      _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
      try await Task.sleep(for: .seconds(1.5))
    }
    reel.waitUntilExit()
    controller.hide()
  }

  func testPhotographTheHistory() async throws {
    // A panel of its own: one reopened within a minute goes back to its chat.
    let (controller, _) = makePanel()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    controller.show()
    try await Task.sleep(for: .seconds(1))
    view.expandResultsForTesting()
    try await Task.sleep(for: .seconds(2))
    try photograph(view, to: "history.png")

    // Each tab wakes its own face; walking them is the mascot reel.
    let reel = try record(view, seconds: 9, to: "faces.mov")
    try await Task.sleep(for: .seconds(1))
    for agent in [AgentId.claude, .codex, .opencode, .grok, .antigravity] {
      view.historyTabsForTesting.onSelect?(agent)
      try await Task.sleep(for: .seconds(1.4))
    }
    view.historyTabsForTesting.onSelect?(nil)
    reel.waitUntilExit()
    controller.hide()
  }

  private func makePanel() -> (AgentPaletteController, FakeBolttyAIConversations) {
    let model = AppModel(settings: AppSettings(), defaults: isolatedDefaults("boltty.tests.readmeShots"))
    let conversations = FakeBolttyAIConversations()
    conversations.plannedProvider = AgentId.claude.rawValue
    conversations.launchable = AgentId.adapterCases.map(\.rawValue)
    conversations.inheritedDirectory = NSHomeDirectory()
    let hour: TimeInterval = 3600
    let rows: [(String, AgentId, TimeInterval, AgentReportedState?, Bool)] = [
      ("Rename the screenshots on my Desktop by date", .claude, 0.1, nil, false),
      ("Why is the build slower since Tuesday?", .codex, 0.5, .running, false),
      ("Summarise this PDF in five bullet points", .antigravity, 1.2, nil, true),
      ("Write a regex for Ukrainian phone numbers", .grok, 3, nil, false),
      ("Convert the recordings folder to m4a", .opencode, 5, nil, false),
      ("Draft a reply to the landlord about the heating", .claude, 26, nil, false),
      ("Set up a cron job that backs up ~/Notes", .codex, 30, nil, false),
      ("Which image upscaler works well on a Mac?", .opencode, 50, nil, false),
    ]
    conversations.rows = rows.map { title, agent, ago, state, unread in
      BolttyAISessionItem(
        id: UUID(), title: title, subtitle: agent.displayName, agent: agent, isCurrent: false,
        updatedAt: Date().addingTimeInterval(-ago * hour), state: state, hasUnread: unread)
    }
    let controller = AgentPaletteController(model: model, conversations: conversations)
    retained.append(conversations)
    return (controller, conversations)
  }

  private var retained: [FakeBolttyAIConversations] = []

  private func addChat(to conversations: FakeBolttyAIConversations) -> UUID {
    let id = UUID()
    let start = Date().addingTimeInterval(-48)
    func step(_ id: String, _ name: String, _ summary: String, _ at: TimeInterval, files: [String] = []) -> AgentActivity {
      AgentActivity(
        id: id, name: name, summary: summary, state: .completed, files: files,
        startedAt: start.addingTimeInterval(at), endedAt: start.addingTimeInterval(at + 3))
    }
    let question = "Rename the screenshots on my Desktop by the date they were taken"
    let answer = """
    Done. I renamed **14 screenshots** to `2026-10-24 18.02.11.png` and so on, \
    using the date each one was taken rather than when it was copied.

    - Two were taken in the same second, so the second one ends in ` (2)`.
    - Nothing else on the Desktop was touched.

    Want me to move them into a `Screenshots` folder as well?
    """
    let messages = [
      ConversationMessage(
        id: "u1", role: .user, createdAt: start,
        parts: [.text(TextPart(id: "u1-text", kind: .text, text: question))]),
      ConversationMessage(
        id: "a1", role: .agent, createdAt: start, completedAt: start.addingTimeInterval(41),
        parts: [
          .activity(step("t1", "bash", "ls ~/Desktop", 2)),
          .activity(step("t2", "bash", "mdls -name kMDItemContentCreationDate *.png", 6)),
          .activity(step("t3", "bash", "mv -n … (14 files)", 18)),
          .text(TextPart(id: "a1-text", kind: .text, text: answer)),
        ]),
    ]
    conversations.conversationsByID[id] = Conversation(
      id: id, providerID: AgentId.claude.rawValue, title: question, workingDirectory: NSHomeDirectory())
    conversations.previews[id] = BolttyAISessionPreview(
      id: id, title: "Rename the screenshots", agent: .claude, state: .finished, body: "", messages: messages)
    return id
  }

  private func addPermission(to conversations: FakeBolttyAIConversations) -> UUID {
    let id = UUID()
    let permission = AgentQuestion(
      kind: .permission, requestID: "readme", header: "Approval",
      prompt: "Run this command?",
      detail: "brew upgrade --cask --greedy",
      options: [.init(label: "Allow once", detail: nil, value: "once"),
                .init(label: "Always allow", detail: "For this conversation.", value: "always"),
                .init(label: "Reject", detail: nil, value: "reject")],
      allowsMultiple: false, allowsCustom: false)
    let request = "Update every app I installed with Homebrew"
    conversations.conversationsByID[id] = Conversation(
      id: id, providerID: AgentId.codex.rawValue, title: request, workingDirectory: NSHomeDirectory())
    conversations.previews[id] = BolttyAISessionPreview(
      id: id, title: "Update Homebrew apps", agent: .codex, state: .blocked, body: permission.prompt,
      question: permission,
      messages: [ConversationMessage(
        id: "u1", role: .user, createdAt: Date(),
        parts: [.text(TextPart(id: "u1-text", kind: .text, text: request))])])
    return id
  }

  // MARK: - Ask Boltty

  func testPhotographAskBoltty() async throws {
    let screen = try XCTUnwrap(NSScreen.main)
    let note = makeNote(on: screen)
    defer { note.orderOut(nil) }
    // "Trip to Lviv", the document's first line.
    let heading = CGPoint(x: note.frame.minX + 92, y: note.frame.maxY - 60)

    let started = Date()
    let overlay = AskBolttyOverlayController()
    let loopCentre = heading
    overlay.pointer = {
      let t = min(1, Date().timeIntervalSince(started) / 2.4)
      let angle = t * 2 * .pi * 1.05
      return CGPoint(x: loopCentre.x + 90 * cos(angle), y: loopCentre.y + 26 * sin(angle))
    }
    let area = CGRect(x: note.frame.minX - 140, y: note.frame.minY - 60,
                      width: note.frame.width + 520, height: note.frame.height + 120)
    let reel = try record(area, seconds: 10, to: "ask-boltty.mov")
    overlay.show(.listening, heard: "how do I make this heading bigger", caption: "", agent: .claude)
    try await Task.sleep(for: .seconds(2.6))
    overlay.show(.thinking, heard: "", caption: "", agent: .claude)
    try await Task.sleep(for: .seconds(1.2))
    overlay.show(.speaking, heard: "",
                 caption: "Select the heading, then press ⌘T and pick a bigger size.", agent: .claude)
    overlay.point(at: CGPoint(x: note.frame.minX + 152, y: heading.y))
    // Long enough for the sentence to type out in full.
    try await Task.sleep(for: .seconds(5))
    try photograph(area, to: "ask-boltty.png")
    reel.waitUntilExit()
    overlay.hide()
  }

  /// A plain document to ask about: nothing of anyone's own.
  private func makeNote(on screen: NSScreen) -> NSWindow {
    let size = CGSize(width: 620, height: 300)
    let frame = CGRect(x: screen.frame.midX - size.width / 2 - 160, y: screen.frame.midY - size.height / 2,
                       width: size.width, height: size.height)
    let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
    window.title = "Trip to Lviv"
    window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
    let text = NSTextView(frame: CGRect(origin: .zero, size: size))
    text.textContainerInset = CGSize(width: 36, height: 30)
    let body = NSMutableAttributedString(
      string: "Trip to Lviv\n",
      attributes: [.font: NSFont.preferredFont(forTextStyle: .title1), .foregroundColor: NSColor.labelColor])
    body.append(NSAttributedString(
      string: """



      Friday: the 7:40 train from Kyiv, arriving just after one.
      Saturday: the old town, coffee at the market square, the opera at seven.
      Sunday: the lake in the morning, back home on the evening train.

      Pack: umbrella, chargers, the good camera.
      """,
      attributes: [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor]))
    text.textStorage?.setAttributedString(body)
    window.contentView = text
    window.orderFrontRegardless()
    return window
  }

  // MARK: - Taking the pictures

  private func photograph(_ view: AgentPaletteView, to name: String) throws {
    try photograph(area(around: view), to: name)
  }

  private func area(around view: AgentPaletteView) throws -> CGRect {
    let window = try XCTUnwrap(view.window)
    view.layoutSubtreeIfNeeded()
    let surface = window.convertToScreen(view.convert(view.unifiedSurfaceFrameForTesting, to: nil))
    return surface.insetBy(dx: -90, dy: -70)
  }

  private func photograph(_ area: CGRect, to name: String) throws {
    let shot = try screencapture(["-x", "-R", rect(area), "\(directory)/\(name)"])
    shot.waitUntilExit()
  }

  private func record(_ view: AgentPaletteView, seconds: Int, to name: String) throws -> Process {
    try record(area(around: view), seconds: seconds, to: name)
  }

  private func record(_ area: CGRect, seconds: Int, to name: String) throws -> Process {
    try screencapture(["-x", "-v", "-V", "\(seconds)", "-R", rect(area), "\(directory)/\(name)"])
  }

  /// `screencapture -R` takes points from the top left of the main display.
  private func rect(_ area: CGRect) -> String {
    let top = NSScreen.screens.first?.frame.maxY ?? area.maxY
    let clipped = area.intersection(NSScreen.main?.frame ?? area)
    return "\(Int(clipped.minX)),\(Int(top - clipped.maxY)),\(Int(clipped.width)),\(Int(clipped.height))"
  }

  private func screencapture(_ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = arguments
    try process.run()
    return process
  }
}
