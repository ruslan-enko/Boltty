import AppKit
import XCTest
@testable import Boltty

@MainActor
final class NotchMascotTests: XCTestCase {
  private func geometry(origin: CGPoint = .zero) -> NotchMascotGeometry? {
    NotchMascotGeometry(
      screen: CGRect(origin: origin, size: CGSize(width: 1512, height: 982)), topInset: 32,
      left: CGRect(x: origin.x, y: origin.y + 950, width: 660, height: 32),
      right: CGRect(x: origin.x + 852, y: origin.y + 950, width: 660, height: 32))
  }

  func testTheBubbleStandsBesideTheNotchInsideTheTopBand() throws {
    let dock = try XCTUnwrap(geometry())
    XCTAssertEqual(dock.notch, CGRect(x: 660, y: 950, width: 192, height: 32))
    XCTAssertEqual(dock.bubble, CGRect(x: 0, y: 2, width: 28, height: 28))
    XCTAssertEqual(dock.frame, CGRect(x: 626, y: 950, width: 62, height: 32))
    XCTAssertEqual(dock.frame.minX + dock.bubble.maxX + NotchMascotGeometry.gap, dock.notch.minX)
    XCTAssertTrue(dock.bubble.contains(dock.face))
  }

  func testExternalScreenOffsetsArePreserved() throws {
    let origin = CGPoint(x: -1512, y: 982)
    let dock = try XCTUnwrap(geometry(origin: origin))
    let main = try XCTUnwrap(geometry())
    XCTAssertEqual(dock.frame, main.frame.offsetBy(dx: origin.x, dy: origin.y))
  }

  func testNoFakeNotchOnAnOrdinaryDisplay() {
    XCTAssertNil(NotchMascotGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                    topInset: 0, left: nil, right: nil))
  }

  private func conversation(_ state: ConversationExecutionState, unread: Bool = false) -> Conversation {
    Conversation(title: "Task", workingDirectory: "/tmp", hasUnread: unread, lastKnownState: state)
  }

  private func permission() -> PendingInteraction.Kind {
    .permission(PermissionPrompt(action: "bash", resources: ["ls"], savePatterns: [], toolCallID: nil))
  }

  private func question() -> PendingInteraction.Kind {
    .question(QuestionPrompt(items: [], toolCallID: nil))
  }

  func testApprovalTakesPriorityOverWorkInAnotherChat() {
    let working = conversation(.working)
    let waiting = conversation(.waiting)
    let status = NotchMascotStatus.select(from: [working, waiting], preferredID: working.id)
    XCTAssertEqual(status.conversationID, waiting.id)
    XCTAssertEqual(status.emotion, .concerned)
  }

  func testReadFailuresDoNotMaskCurrentWorkOrLeaveASadFaceForever() {
    let failure = conversation(.failed)
    let working = conversation(.working)
    XCTAssertEqual(NotchMascotStatus.select(from: [failure, working], preferredID: nil).emotion, .thinking)
    XCTAssertEqual(NotchMascotStatus.select(from: [failure], preferredID: nil).emotion, .sleeping)
  }

  func testUnreadCompletionAndFailureRemainVisibleUntilRead() {
    for (state, emotion) in [(ConversationExecutionState.idle, MascotEmotion.curious), (.failed, .sad)] {
      let chat = conversation(state, unread: true)
      let status = NotchMascotStatus.select(from: [chat], preferredID: nil)
      XCTAssertEqual(status.conversationID, chat.id)
      XCTAssertEqual(status.emotion, emotion)
    }
  }

  func testTheIslandSaysWhatIsHappeningAndOnlyAWaitingChatHoldsIt() {
    let chat = conversation(.waiting)
    let waiting = NotchMascotStatus.select(from: [chat], preferredID: nil, waitingOn: [chat.id: permission()])
    XCTAssertTrue(waiting.line?.hasPrefix("Needs your approval · ") == true, waiting.line ?? "nil")
    XCTAssertTrue(waiting.holdsLine)
    let working = NotchMascotStatus.select(from: [conversation(.working)], preferredID: nil)
    XCTAssertTrue(working.line?.hasPrefix("Working · ") == true)
    XCTAssertFalse(working.holdsLine)
    XCTAssertEqual(NotchMascotStatus.select(from: [conversation(.idle, unread: true)], preferredID: nil).line,
                   "Done · Task")
    XCTAssertEqual(NotchMascotStatus.select(from: [conversation(.failed, unread: true)], preferredID: nil).line,
                   "Didn't finish · Task")
    XCTAssertNil(NotchMascotStatus.select(from: [], preferredID: nil).line, "asleep says nothing")
  }

  func testAQuestionIsAskedForAnAnswerNotAnApproval() {
    let chat = conversation(.waiting)
    let asked = NotchMascotStatus.select(from: [chat], preferredID: nil, waitingOn: [chat.id: question()])
    XCTAssertTrue(asked.line?.hasPrefix("Needs your answer · ") == true, asked.line ?? "nil")
    XCTAssertTrue(asked.label.hasPrefix("Needs your answer — "), asked.label)
    XCTAssertTrue(asked.holdsLine, "a question holds its line as an approval does")

    let permitted = NotchMascotStatus.select(from: [chat], preferredID: nil, waitingOn: [chat.id: permission()])
    XCTAssertTrue(permitted.label.hasPrefix("Needs your approval — "), permitted.label)

    let unknown = NotchMascotStatus.select(from: [chat], preferredID: nil)
    XCTAssertTrue(unknown.line?.hasPrefix("Needs your answer · ") == true, unknown.line ?? "nil")
    let elsewhere = NotchMascotStatus.select(from: [chat], preferredID: nil, waitingOn: [UUID(): permission()])
    XCTAssertTrue(elsewhere.line?.hasPrefix("Needs your answer · ") == true,
                  "another chat's permission is not this one's")
  }

  func testAPlanIsAskedForApproval() {
    let chat = conversation(.waiting)
    let planned = NotchMascotStatus.select(
      from: [chat], preferredID: nil,
      waitingOn: [chat.id: .plan(PlanPrompt(markdown: "# Steps", toolCallID: "call-1"))])
    XCTAssertTrue(planned.line?.hasPrefix("Needs your approval · ") == true, planned.line ?? "nil")
    XCTAssertTrue(planned.label.hasPrefix("Needs your approval — "), planned.label)
  }

  func testAChatAsksWhatIsOpenOrWhatItLastAsked() {
    let chat = conversation(.waiting)
    func ask(_ id: String, _ kind: PendingInteraction.Kind, answered: Bool = false) -> PendingInteraction {
      PendingInteraction(id: id, conversationID: chat.id, remoteSessionID: "session", kind: kind,
                         resolution: answered ? .permission(.once) : nil)
    }
    func asks(_ interactions: [PendingInteraction]) -> [UUID: PendingInteraction.Kind] {
      NotchMascotStatus.asks(in: [chat.id: ConversationTranscript(interactions: interactions)])
    }

    let justAnswered = asks([ask("per", permission(), answered: true)])
    XCTAssertEqual(justAnswered, [chat.id: permission()])
    let between = NotchMascotStatus.select(from: [chat], preferredID: nil, waitingOn: justAnswered)
    XCTAssertTrue(between.line?.hasPrefix("Needs your approval · ") == true,
                  "still the approval until the chat says it works: \(between.line ?? "nil")")

    XCTAssertEqual(asks([ask("per", permission(), answered: true), ask("que", question())]),
                   [chat.id: question()], "a question open behind an answered approval")
    XCTAssertEqual(asks([ask("per", permission()), ask("que", question())]),
                   [chat.id: permission()], "the oldest open ask, the one the card draws")
    XCTAssertEqual(asks([]), [:], "nothing asked, nothing said")
  }

  func testALineIsSaidOnArrivalAndFoldsAwayAfterAMoment() async throws {
    let dock = NotchMascotController()
    dock.geometryProvider = { self.geometry() }
    dock.lineDuration = 0.1
    defer { dock.shutdown() }
    let base = try XCTUnwrap(geometry()).frame
    dock.update(conversations: [conversation(.idle, unread: true)], roster: MascotRoster())
    dock.setPanelVisible(false, screen: nil, conversationID: nil)

    XCTAssertEqual(dock.lineForTesting, "Done · Task")
    XCTAssertGreaterThan(dock.windowForTesting.frame.width, base.width)
    XCTAssertEqual(dock.windowForTesting.frame.maxX, base.maxX, "it grows leftward; the face stays")

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline,
          dock.lineForTesting != nil || dock.windowForTesting.frame != base {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertNil(dock.lineForTesting, "folded back to the face")
    XCTAssertEqual(dock.windowForTesting.frame, base, "and the window no wider than the face")
  }

  func testAnApprovalHoldsItsLine() async throws {
    let dock = NotchMascotController()
    dock.geometryProvider = { self.geometry() }
    dock.lineDuration = 0.1
    defer { dock.shutdown() }
    let chat = conversation(.waiting)
    dock.update(conversations: [chat], roster: MascotRoster(), waitingOn: [chat.id: permission()])
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertTrue(dock.lineForTesting?.hasPrefix("Needs your approval") == true)

    dock.update(conversations: [chat], roster: MascotRoster(), waitingOn: [chat.id: question()])
    XCTAssertTrue(dock.lineForTesting?.hasPrefix("Needs your answer") == true,
                  "a question after the approval is asked for as one")
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertNotNil(dock.lineForTesting, "and held as well")

    var answered = chat
    answered.lastKnownState = .working
    dock.update(conversations: [answered], roster: MascotRoster())
    XCTAssertTrue(dock.lineForTesting?.hasPrefix("Working") == true, "the line swaps to what is next")
  }

  func testReopeningDuringDismissalCannotHideTheNextDock() async throws {
    let dock = NotchMascotController()
    dock.geometryProvider = { self.geometry() }
    defer { dock.shutdown() }
    XCTAssertFalse(dock.windowForTesting.isVisible, "launch must not reveal the companion")
    dock.update(conversations: [conversation(.working)], roster: MascotRoster())
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    XCTAssertTrue(dock.isDocked)
    XCTAssertTrue(dock.windowForTesting.isVisible)
    XCTAssertEqual(dock.windowForTesting.frame.maxX, geometry()?.frame.maxX)
    XCTAssertEqual(dock.windowForTesting.frame.minY, geometry()?.frame.minY)
    XCTAssertFalse(dock.windowForTesting.canBecomeKey)
    XCTAssertFalse(dock.windowForTesting.canBecomeMain)
    dock.setPanelVisible(true, screen: nil, conversationID: nil)
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(dock.windowForTesting.isVisible, "the old exit must not order the new dock out")
    XCTAssertTrue(dock.isDocked)
    dock.shutdown()
    XCTAssertFalse(dock.windowForTesting.isVisible)
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    XCTAssertFalse(dock.isDocked, "quitting must never re-open the companion")
  }

  func testReDockingMidExitStillFoldsTheLine() async throws {
    let dock = NotchMascotController()
    dock.geometryProvider = { self.geometry() }
    dock.lineDuration = 0.2
    defer { dock.shutdown() }
    let base = try XCTUnwrap(geometry()).frame
    dock.update(conversations: [conversation(.working)], roster: MascotRoster())
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    XCTAssertTrue(dock.lineForTesting?.hasPrefix("Working · ") == true)

    dock.setPanelVisible(true, screen: nil, conversationID: nil)
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    XCTAssertTrue(dock.windowForTesting.isVisible)
    XCTAssertTrue(dock.lineForTesting?.hasPrefix("Working · ") == true, "still said on the way back")

    try await Task.sleep(for: .milliseconds(800))
    XCTAssertTrue(dock.windowForTesting.isVisible, "the cancelled exit did not order it out")
    XCTAssertNil(dock.lineForTesting, "folded back to the face")
    XCTAssertEqual(dock.windowForTesting.frame, base, "and the window no wider than the face")
  }

  func testALongerLineGrowsTheIslandFromWhereItStands() async throws {
    try XCTSkipIf(MotionPreferences.reduceMotion, "Reduce Motion has no slide to start")
    let dock = NotchMascotController()
    dock.geometryProvider = { self.geometry() }
    defer { dock.shutdown() }
    let resting = try XCTUnwrap(geometry())
    var chat = conversation(.working)
    dock.update(conversations: [chat], roster: MascotRoster())
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    try await Task.sleep(for: .milliseconds(400))
    let said = dock.windowForTesting.frame
    XCTAssertLessThan(said.minX, resting.frame.minX, "the working line is said")

    chat.lastKnownState = .waiting
    dock.update(conversations: [chat], roster: MascotRoster(), waitingOn: [chat.id: permission()])
    XCTAssertLessThan(dock.windowForTesting.frame.minX, said.minX, "the longer line widens the window")
    let start = try XCTUnwrap(dock.backdropSlideStartForTesting)
    XCTAssertEqual(start.minX, said.minX, accuracy: 0.5, "the slide starts from the black on screen")
    XCTAssertEqual(start.maxX, resting.frame.minX + resting.bubble.maxX, accuracy: 0.5,
                   "with its right edge round the face")
  }

  func testNothingToSayMeansNoIsland() async throws {
    let dock = NotchMascotController()
    dock.geometryProvider = { self.geometry() }
    defer { dock.shutdown() }
    dock.update(conversations: [conversation(.idle)], roster: MascotRoster())
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    XCTAssertFalse(dock.isDocked, "an idle, read chat is nothing to say")
    XCTAssertFalse(dock.windowForTesting.isVisible)

    var chat = conversation(.working)
    dock.update(conversations: [chat], roster: MascotRoster())
    XCTAssertTrue(dock.isDocked, "a turn starting brings the island out")
    XCTAssertTrue(dock.lineForTesting?.hasPrefix("Working · ") == true, "and it says so as it arrives")

    chat.lastKnownState = .idle
    dock.update(conversations: [chat], roster: MascotRoster())
    XCTAssertFalse(dock.isDocked, "read and idle, it goes back under the notch")
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline, dock.windowForTesting.isVisible {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertFalse(dock.windowForTesting.isVisible)
  }

  // MARK: The row of faces

  private func chat(_ agent: AgentId, _ state: ConversationExecutionState,
                    updated: TimeInterval = 0) -> Conversation {
    Conversation(providerID: agent.rawValue, title: "\(agent.rawValue) task", workingDirectory: "/tmp",
                 updatedAt: Date(timeIntervalSince1970: 1_000_000 + updated), lastKnownState: state)
  }

  func testTheRowWidensLeftwardByHalfAFace() throws {
    let one = try XCTUnwrap(geometry())
    XCTAssertEqual(one.bubble.width, one.bubble.height, "one face is a circle")
    XCTAssertEqual(one.slotSide, (one.diameter * NotchMascotGeometry.slotShare).rounded())
    for count in 1...4 {
      let row = one.withFaces(count)
      XCTAssertEqual(row.slots.count, count)
      XCTAssertEqual(row.bubble.width, row.margin * 2 + row.slotSide + row.step * CGFloat(count - 1))
      XCTAssertEqual(row.frame.minX + row.bubble.maxX + NotchMascotGeometry.gap, row.notch.minX,
                     "the gap to the notch holds with \(count)")
      XCTAssertEqual(row.face, try XCTUnwrap(row.slots.last), "the line speaks for the face by the notch")
      for slot in row.slots { XCTAssertTrue(row.bubble.contains(slot)) }
    }
    XCTAssertEqual(one.withFaces(9).faces, NotchMascotGeometry.maximumFaces)
  }

  func testOneFacePerAgentTheMostUrgentNearestTheNotch() {
    let claudeA = chat(.claude, .working, updated: 1)
    let claudeB = chat(.claude, .working, updated: 2)
    let codex = chat(.codex, .waiting)
    let grokRead = chat(.grok, .idle)
    let status = NotchMascotStatus.select(from: [claudeA, codex, claudeB, grokRead], preferredID: nil,
                                          waitingOn: [codex.id: permission()])
    XCTAssertEqual(status.faces.map(\.agent), [.claude, .codex], "an idle, read chat has no face")
    XCTAssertEqual(status.faces.last?.conversationID, status.conversationID)
    XCTAssertEqual(status.faces.first?.conversationID, claudeB.id, "the newer of Claude's two")
    XCTAssertEqual(status.faces.map(\.chats), [2, 1])
    XCTAssertEqual(status.faces.last?.line, "Needs your approval · Codex")
  }

  func testTheRowShowsEveryAgentAndHoverSaysThatFacesLine() async throws {
    let dock = NotchMascotController()
    dock.geometryProvider = { self.geometry() }
    defer { dock.shutdown() }
    let claude = chat(.claude, .working)
    dock.update(conversations: [claude], roster: MascotRoster())
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    let single = dock.windowForTesting.frame
    let codex = chat(.codex, .waiting)
    dock.update(conversations: [claude, codex], roster: MascotRoster(), waitingOn: [codex.id: question()])
    XCTAssertEqual(dock.shownFacesForTesting, [claude.id, codex.id])
    XCTAssertLessThan(dock.windowForTesting.frame.minX, single.minX, "the row widened leftward")
    XCTAssertEqual(dock.windowForTesting.frame.maxX, single.maxX, accuracy: 0.5, "by the notch it stays")
    XCTAssertEqual(dock.lineForTesting, "Needs your answer · Codex")

    dock.hoverForTesting(claude.id)
    XCTAssertEqual(dock.lineForTesting, "Working · Claude", "the face under the pointer speaks")
    dock.hoverForTesting(nil)
    XCTAssertEqual(dock.lineForTesting, "Needs your answer · Codex", "and hands back on leaving")

    dock.update(conversations: [codex], roster: MascotRoster(), waitingOn: [codex.id: question()])
    XCTAssertEqual(dock.shownFacesForTesting, [codex.id], "a face leaves when its chat has nothing to say")
  }

  func testNoNotchMeansNoCompanionWindow() {
    let dock = NotchMascotController()
    dock.geometryProvider = { nil }
    defer { dock.shutdown() }
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    XCTAssertFalse(dock.isDocked)
    XCTAssertFalse(dock.windowForTesting.isVisible)
  }

  func testFirstDockHasVisibleMetalSurface() async throws {
    let dock = NotchMascotController()
    dock.geometryProvider = { self.geometry() }
    defer { dock.shutdown() }
    dock.update(conversations: [conversation(.working)], roster: MascotRoster())
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    try await Task.sleep(for: .milliseconds(500))
    let root = try XCTUnwrap(dock.windowForTesting.contentView)
    let mascot = try XCTUnwrap(root.subviews.first as? MascotNSView)
    let canvas = try XCTUnwrap(mascot.subviews.first as? MascotCanvas)
    let layers = try XCTUnwrap(root.layer?.sublayers)
    let black = NSColor.black.cgColor
    let backdropIndex = try XCTUnwrap(layers.firstIndex {
      $0.backgroundColor == black || $0.sublayers?.contains { $0.backgroundColor == black } == true
    })
    let faceIndex = try XCTUnwrap(layers.firstIndex { $0 === mascot.layer })
    XCTAssertGreaterThan(faceIndex, backdropIndex, "the black background must be behind the mascot")
    XCTAssertFalse(canvas.visibleRect.isEmpty)
    XCTAssertGreaterThan(canvas.drawableSize.width, 0)
    XCTAssertEqual(mascot.layer?.transform.m41, 0)
    XCTAssertEqual(root.layer?.opacity, 1)
    XCTAssertEqual(canvas.layer?.contentsScale, dock.windowForTesting.backingScaleFactor)
  }

  func testDrawingRepairsZeroMetalScaleInAnAttachedPanel() throws {
    let dock = NotchMascotController()
    dock.geometryProvider = { self.geometry() }
    defer { dock.shutdown() }
    dock.update(conversations: [conversation(.working)], roster: MascotRoster())
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    let mascot = try XCTUnwrap(dock.windowForTesting.contentView?.subviews.first as? MascotNSView)
    let canvas = try XCTUnwrap(mascot.subviews.first as? MascotCanvas)
    let layer = try XCTUnwrap(canvas.layer)
    layer.contentsScale = 0
    mascot.render()
    XCTAssertEqual(layer.contentsScale, dock.windowForTesting.backingScaleFactor)
    XCTAssertGreaterThan(layer.contentsScale, 0)
  }

  func testNativeDockRender() throws {
    let dock = NotchMascotController()
    dock.geometryProvider = { self.geometry() }
    defer { dock.shutdown() }
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    for (name, state) in [("working", ConversationExecutionState.working), ("waiting", .waiting), ("failed", .failed), ("finished", .idle)] {
      dock.update(conversations: [conversation(state, unread: true)], roster: MascotRoster())
      let image = try XCTUnwrap(dock.snapshotForTesting())
      XCTAssertEqual(image.width, 248)
      XCTAssertEqual(image.height, 128)
      let pixels = NSBitmapImageRep(cgImage: image)
      var litPixels = 0
      for y in 0..<pixels.pixelsHigh {
        for x in 0..<pixels.pixelsWide {
          if let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
             max(color.redComponent, color.greenComponent, color.blueComponent) > 0.3 {
            litPixels += 1
          }
        }
      }
      XCTAssertGreaterThan(litPixels, 500, "\(name) must draw a face, not just the black wing")
      if let directory = ProcessInfo.processInfo.environment["BOLTTY_NOTCH_PREVIEW"] {
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("notch-\(name).png"))
      }
    }
  }
}
