import AppKit
import SwiftUI
import XCTest
@testable import Boltty

/// Films Settings' own "how it works" samples for the website: each sample on
/// its SettingsStage over the desktop picture, looping through its states.
/// Set TEST_RUNNER_BOLTTY_SITE_FILMS=<dir>.
@MainActor
final class SiteFilmsOnScreen: XCTestCase {
  private var directory = ""
  private static let stage = CGSize(width: 400, height: 250)

  override func setUp() async throws {
    guard let directory = ProcessInfo.processInfo.environment["BOLTTY_SITE_FILMS"] else {
      throw XCTSkip("set TEST_RUNNER_BOLTTY_SITE_FILMS=<dir> to film the website's samples")
    }
    self.directory = directory
    // The desktop as the person has it: an Aerials video has no picture to read,
    // so a still of it is handed in and stands for the wallpaper.
    if let path = ProcessInfo.processInfo.environment["BOLTTY_SITE_WALLPAPER"],
       let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
       let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
      DesktopPicture.cached = DesktopPicture(image: image, source: DesktopPicture.sources().first)
    }
  }

  func testFilmFaces() async throws {
    try await film("site-faces", seconds: 9) { FacesFilm() }
  }

  func testFilmFinder() async throws {
    try await film("site-finder", seconds: 9) { FinderFilm() }
  }

  func testFilmDictation() async throws {
    try await film("site-dictation", seconds: 10) { DictationFilm() }
  }

  func testFilmAnswer() async throws {
    try await film("site-answer", seconds: 10) { AnswerFilm() }
  }

  /// The real panel, its face turning into each agent's on ⇧Tab, over the
  /// desktop picture at full size: the README's prompt film, framed for the site.
  func testFilmPanelFaces() async throws {
    let screen = try XCTUnwrap(NSScreen.main)
    let backdrop = try desktop(on: screen)
    defer { backdrop.orderOut(nil) }
    let model = AppModel(settings: AppSettings(), defaults: isolatedDefaults("boltty.tests.siteFilms"))
    let conversations = FakeBolttyAIConversations()
    conversations.plannedProvider = AgentId.claude.rawValue
    conversations.launchable = AgentId.adapterCases.map(\.rawValue)
    conversations.inheritedDirectory = NSHomeDirectory()
    let controller = AgentPaletteController(model: model, conversations: conversations)
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    controller.show()
    try await Task.sleep(for: .seconds(2))
    let area = try frame(around: view, on: screen)
    let reel = try record(area, seconds: 10, to: "site-panel-faces.mov")
    try await Task.sleep(for: .seconds(1.4))
    for _ in 0..<5 {
      _ = view.textView(view.field, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
      try await Task.sleep(for: .seconds(1.6))
    }
    reel.waitUntilExit()
    controller.hide()
    try await Task.sleep(for: .seconds(0.5))
    _ = conversations
  }

  /// A task typed into the panel; Return, and the same panel is the chat with the agent's answer.
  func testFilmPanelChat() async throws {
    let screen = try XCTUnwrap(NSScreen.main)
    let backdrop = try desktop(on: screen)
    defer { backdrop.orderOut(nil) }
    let (controller, conversations) = makePanel()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    controller.show()
    view.surfaceSizes = Self.compactSizes
    try await Task.sleep(for: .seconds(2))
    let area = try frame(around: view, on: screen, size: Self.compactFilm)
    let reel = try record(area, seconds: 12, to: "site-panel-chat.mov")
    try await Task.sleep(for: .seconds(1.2))
    var typed = ""
    for character in "Rename the screenshots on my Desktop by the date they were taken" {
      typed.append(character)
      view.field.setDraft(PromptDraft(typed))
      try await Task.sleep(for: .seconds(0.04))
    }
    try await Task.sleep(for: .seconds(0.9))
    controller.addressConversation(addChat(to: conversations))
    reel.waitUntilExit()
    controller.hide()
    try await Task.sleep(for: .seconds(0.5))
  }

  /// A task typed in; the agent stops and asks before running a command.
  func testFilmPanelApprove() async throws {
    let screen = try XCTUnwrap(NSScreen.main)
    let backdrop = try desktop(on: screen)
    defer { backdrop.orderOut(nil) }
    let (controller, conversations) = makePanel()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    controller.show()
    view.surfaceSizes = Self.compactSizes
    try await Task.sleep(for: .seconds(2))
    let area = try frame(around: view, on: screen, size: Self.compactFilm)
    let reel = try record(area, seconds: 10, to: "site-panel-approve.mov")
    try await Task.sleep(for: .seconds(1.2))
    var typed = ""
    for character in "Update every app I installed with Homebrew" {
      typed.append(character)
      view.field.setDraft(PromptDraft(typed))
      try await Task.sleep(for: .seconds(0.045))
    }
    try await Task.sleep(for: .seconds(0.9))
    controller.addressConversation(addPermission(to: conversations))
    reel.waitUntilExit()
    controller.hide()
    try await Task.sleep(for: .seconds(0.5))
  }

  private func addPermission(to conversations: FakeBolttyAIConversations) -> UUID {
    let id = UUID()
    let permission = AgentQuestion(
      kind: .permission, requestID: "site", header: "Approval",
      prompt: "Run this command?",
      detail: "brew upgrade --cask --greedy",
      options: [.init(label: "Allow Once", detail: nil, value: "once"),
                .init(label: "Always Allow", detail: "For this conversation.", value: "always"),
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

  /// Talk to it: the prompt listens, the words arrive as they are said.
  func testFilmPanelVoice() async throws {
    let screen = try XCTUnwrap(NSScreen.main)
    let backdrop = try desktop(on: screen)
    defer { backdrop.orderOut(nil) }
    let (controller, _) = makePanel()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    controller.show()
    try await Task.sleep(for: .seconds(2))
    let area = try frame(around: view, on: screen)
    let reel = try record(area, seconds: 10, to: "site-panel-voice.mov")
    try await Task.sleep(for: .seconds(1.2))
    view.setVoiceListening(true)
    try await Task.sleep(for: .seconds(0.9))
    var said = ""
    for word in ["Turn", "this", "screen", "recording", "into", "a", "GIF", "and", "drop", "it", "in", "Slack"] {
      said += said.isEmpty ? word : " \(word)"
      view.applyVoiceTranscript(said)
      try await Task.sleep(for: .seconds(0.34))
    }
    try await Task.sleep(for: .seconds(1.4))
    view.setVoiceListening(false)
    reel.waitUntilExit()
    controller.hide()
    try await Task.sleep(for: .seconds(0.5))
  }

  /// Keep an eye on things: ↓ opens the recent chats, a tab per agent.
  func testFilmPanelHistory() async throws {
    let screen = try XCTUnwrap(NSScreen.main)
    let backdrop = try desktop(on: screen)
    defer { backdrop.orderOut(nil) }
    let (controller, _) = makePanel()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    controller.show()
    view.surfaceSizes = Self.compactSizes
    try await Task.sleep(for: .seconds(2))
    let area = try frame(around: view, on: screen, size: Self.compactFilm)
    let reel = try record(area, seconds: 11, to: "site-panel-history.mov")
    try await Task.sleep(for: .seconds(1.2))
    view.expandResultsForTesting()
    try await Task.sleep(for: .seconds(1.8))
    for agent in [AgentId.claude, .codex, .opencode, .grok] {
      view.historyTabsForTesting.onSelect?(agent)
      try await Task.sleep(for: .seconds(1.4))
    }
    view.historyTabsForTesting.onSelect?(nil)
    reel.waitUntilExit()
    controller.hide()
    try await Task.sleep(for: .seconds(0.5))
  }

  /// Ask about the screen: a heading selected, the question said out loud, the face answers beside the pointer.
  func testFilmAskScreen() async throws {
    let screen = try XCTUnwrap(NSScreen.main)
    let backdrop = try desktop(on: screen)
    defer { backdrop.orderOut(nil) }
    let note = makeNote(on: screen)
    defer { note.orderOut(nil) }
    let heading = CGPoint(x: note.frame.minX + 92, y: note.frame.maxY - 80)
    let region = CGRect(x: heading.x - 70, y: heading.y - 30, width: 300, height: 60)
    let size = Self.compactFilm
    let area = CGRect(x: (note.frame.midX + 110 - size.width / 2).rounded(),
                      y: (note.frame.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    let (controller, _) = makePanel()
    let view = try XCTUnwrap(controller.window?.contentView as? AgentPaletteView)
    view.onScreenRegionReady = nil
    let frozen = try frozenScene(on: screen)
    controller.screenFreeze = { _ in frozen }
    let overlay = AskBolttyOverlayController()
    let pointer = CGPoint(x: heading.x + 90, y: heading.y - 90)
    overlay.pointer = { pointer }
    overlay.restHint = { AskBolttyController.restHint(launchKey: "⌥Space") }
    let top = NSScreen.screens.first?.frame.maxY ?? pointer.y
    CGWarpMouseCursorPosition(CGPoint(x: pointer.x, y: top - pointer.y))
    let reel = try record(area, seconds: 14, to: "site-ask-screen.mov")
    try await Task.sleep(for: .seconds(0.8))
    controller.askAgain(about: region, agent: .claude)
    try await Task.sleep(for: .seconds(1))
    view.setVoiceListening(true)
    var said = ""
    for word in ["how", "do", "I", "make", "this", "heading", "bigger"] {
      said += said.isEmpty ? word : " \(word)"
      view.applyVoiceTranscript(said)
      try await Task.sleep(for: .seconds(0.35))
    }
    try await Task.sleep(for: .seconds(1.2))
    let closed = expectation(description: "the shell closed round the face")
    view.collapseToFace { closed.fulfill() }
    view.setVoiceListening(false, ending: .cancelled)
    await fulfillment(of: [closed], timeout: 2)
    let face = view.promptFaceOnScreen
    controller.hide()
    overlay.show(.thinking, caption: "", agent: .claude)
    overlay.arrive(from: face)
    try await Task.sleep(for: .seconds(1.8))
    overlay.show(.speaking, caption: "Select the heading, then press ⌘T and pick a bigger size.", agent: .claude)
    overlay.point(at: CGPoint(x: note.frame.minX + 152, y: heading.y))
    try await Task.sleep(for: .seconds(7))
    reel.waitUntilExit()
    overlay.hide()
  }

  private func frozenScene(on screen: NSScreen) throws -> FrozenScreen {
    let file = "\(directory)/frozen-scene.png"
    defer { try? FileManager.default.removeItem(atPath: file) }
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
    shot.arguments = ["-x", "-R", "\(Int(screen.frame.minX)),\(Int(top - screen.frame.maxY)),\(Int(screen.frame.width)),\(Int(screen.frame.height))", file]
    try shot.run()
    shot.waitUntilExit()
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let frame = CGRect(x: screen.frame.minX, y: top - screen.frame.maxY,
                       width: screen.frame.width, height: screen.frame.height)
    return FrozenScreen(image: image, displayFrame: frame, windows: [])
  }

  private func makeNote(on screen: NSScreen) -> NSWindow {
    let size = CGSize(width: 520, height: 260)
    let frame = CGRect(x: screen.frame.midX - size.width / 2 - 110, y: screen.frame.midY - size.height / 2,
                       width: size.width, height: size.height)
    let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
    window.title = "Trip to Lviv"
    window.appearance = NSAppearance(named: .aqua)
    window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
    let text = NSTextView(frame: CGRect(origin: .zero, size: size))
    text.textContainerInset = CGSize(width: 36, height: 30)
    let body = NSMutableAttributedString(
      string: "Trip to Lviv\n",
      attributes: [.font: NSFont.preferredFont(forTextStyle: .title1), .foregroundColor: NSColor.labelColor])
    body.append(NSAttributedString(
      string: """



      Friday: the 7:40 train from Kyiv, arriving just after one.
      Saturday: the old town and the opera at seven.
      Sunday: the lake, then home on the evening train.
      """,
      attributes: [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor]))
    text.textStorage?.setAttributedString(body)
    window.contentView = text
    window.orderFrontRegardless()
    return window
  }

  /// The site's frame: one fixed 16:10 size for every film, big enough for the
  /// tallest panel (the chat, 672 × 659) with room round it, hanging from the panel's top.
  private static let filmSize = CGSize(width: 1248, height: 780)
  private static let filmMargin: CGFloat = 60

  /// The chat as a person might size it for a quick task: the prompt's width, not much taller.
  private static let compactSizes = BolttyAISurfaceSizes(
    chat: CGSize(width: 540, height: 420), history: CGSize(width: 540, height: 420))
  /// The frame for films that open the compact chat or list: 16:10 round 540 × 420.
  private static let compactFilm = CGSize(width: 896, height: 560)

  private func frame(around view: AgentPaletteView, on screen: NSScreen, size: CGSize = filmSize) throws -> CGRect {
    let window = try XCTUnwrap(view.window)
    view.layoutSubtreeIfNeeded()
    let surface = window.convertToScreen(view.convert(view.unifiedSurfaceFrameForTesting, to: nil))
    let top = min(surface.maxY + Self.filmMargin, screen.frame.maxY)
    return CGRect(x: (surface.midX - size.width / 2).rounded(), y: top - size.height, width: size.width, height: size.height)
  }

  private var retained: [FakeBolttyAIConversations] = []

  private func makePanel() -> (AgentPaletteController, FakeBolttyAIConversations) {
    let model = AppModel(settings: AppSettings(), defaults: isolatedDefaults("boltty.tests.siteFilms"))
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
    retained.append(conversations)
    return (AgentPaletteController(model: model, conversations: conversations), conversations)
  }

  private func addChat(to conversations: FakeBolttyAIConversations) -> UUID {
    let id = UUID()
    let start = Date().addingTimeInterval(-48)
    func step(_ id: String, _ name: String, _ summary: String, _ at: TimeInterval) -> AgentActivity {
      AgentActivity(
        id: id, name: name, summary: summary, state: .completed, files: [],
        startedAt: start.addingTimeInterval(at), endedAt: start.addingTimeInterval(at + 3))
    }
    let question = "Rename the screenshots on my Desktop by the date they were taken"
    let answer = """
    Done. I renamed **14 screenshots** to `2026-10-24 18.02.11.png` and so on, \
    using the date each one was taken rather than when it was copied.

    - Two were taken in the same second, so the second one ends in ` (2)`.
    - Nothing else on the Desktop was touched.
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

  private func desktop(on screen: NSScreen) throws -> NSWindow {
    let path = try XCTUnwrap(ProcessInfo.processInfo.environment["BOLTTY_SITE_DESKTOP"], "set TEST_RUNNER_BOLTTY_SITE_DESKTOP")
    let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]
    let image = NSImageView(frame: CGRect(origin: .zero, size: screen.frame.size))
    image.image = NSImage(contentsOfFile: path)
    image.imageScaling = .scaleAxesIndependently
    window.contentView = image
    window.setFrame(screen.frame, display: true)
    window.orderFrontRegardless()
    return window
  }

  private func record(_ area: CGRect, seconds: Int, to name: String) throws -> Process {
    let top = NSScreen.screens.first?.frame.maxY ?? area.maxY
    let region = "\(Int(area.minX)),\(Int(top - area.maxY)),\(Int(area.width)),\(Int(area.height))"
    let reel = Process()
    reel.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    reel.arguments = ["-x", "-v", "-V", "\(seconds)", "-R", region, "\(directory)/\(name)"]
    try reel.run()
    return reel
  }

  // MARK: - Filming

  private func film<V: View>(_ name: String, seconds: Int, @ViewBuilder content: () -> V) async throws {
    let sample = content()
    let screen = try XCTUnwrap(NSScreen.main)
    let size = Self.stage
    let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                       width: size.width, height: size.height)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
    window.isOpaque = true
    window.backgroundColor = .black
    window.contentView = NSHostingView(rootView:
      SettingsStage(width: size.width, height: size.height, corner: 0) { sample }
        .environment(\.colorScheme, .dark))
    window.setFrame(frame, display: true)
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    // The desktop picture loads, then the sample settles before the reel starts.
    try await Task.sleep(for: .seconds(2.5))
    let top = NSScreen.screens.first?.frame.maxY ?? frame.maxY
    let region = "\(Int(frame.minX)),\(Int(top - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
    let reel = Process()
    reel.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    reel.arguments = ["-x", "-v", "-V", "\(seconds)", "-R", region, "\(directory)/\(name).mov"]
    try reel.run()
    try await Task.sleep(for: .seconds(Double(seconds) + 1.5))
  }
}

private let agents: [AgentId] = [.claude, .codex, .opencode, .grok, .antigravity]

private func look(_ agent: AgentId) -> MascotLook { MascotLook.face(for: agent) }

/// The prompt, its face turning into each agent's, as ⇧Tab does.
private struct FacesFilm: View {
  @State private var index = 0
  var body: some View {
    PromptSample(clearGlass: false, look: look(agents[index % agents.count]))
      .frame(width: PromptSampleView.size.width, height: PromptSampleView.size.height)
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1.6))
          index += 1
        }
      }
  }
}

/// Opened over Finder: the selected files arrive as cards over the line.
private struct FinderFilm: View {
  @State private var attaches = false
  var body: some View {
    FinderSelectionSample(attaches: attaches, look: look(.claude), clearGlass: false)
      .frame(width: FinderSelectionSampleView.size.width, height: FinderSelectionSampleView.size.height)
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1.2))
          attaches = true
          try? await Task.sleep(for: .seconds(3.2))
          attaches = false
        }
      }
  }
}

/// Dictation: the words arrive as they are heard.
private struct DictationFilm: View {
  @State private var phrase = SampleText.spoken
  var body: some View {
    DictationSample(phrase: phrase, look: look(.claude), clearGlass: false)
      .frame(width: DictationSampleView.size.width, height: DictationSampleView.size.height)
      .task {
        let phrases = [SampleText.spoken, "Turn this video into a GIF and drop it in Slack"]
        var i = 0
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(4.5))
          i += 1
          phrase = phrases[i % phrases.count]
        }
      }
  }
}

/// Ask Boltty: the face beside the pointer, its answer word by word.
private struct AnswerFilm: View {
  @State private var canMakeChanges = false
  var body: some View {
    AskAnswerSample(canMakeChanges: canMakeChanges, look: look(.claude))
      .frame(width: AskAnswerSampleView.size.width, height: AskAnswerSampleView.size.height)
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(4.5))
          canMakeChanges.toggle()
        }
      }
  }
}
