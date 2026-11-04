import AppKit
import XCTest
@testable import Boltty

/// Photographs the notch face in every state it can be in, on the real screen: a
/// live face does not draw offscreen with its line, rims and badges. The dock
/// stands beside a stand-in notch drawn 300 pt below the menu bar, so a Boltty
/// running on this Mac does not show through. `TEST_RUNNER_BOLTTY_NOTCH_SHOTS=<dir>`
/// writes one PNG per state, named in order.
@MainActor
final class NotchStatesOnScreen: XCTestCase {
  private let drop: CGFloat = 300

  private struct Scene {
    let name: String
    let chats: [Conversation]
    var waitingOn: [UUID: PendingInteraction.Kind] = [:]
    var hover: UUID?
    var folded = false
  }

  func testPhotographEveryState() async throws {
    guard let directory = ProcessInfo.processInfo.environment["BOLTTY_NOTCH_SHOTS"] else {
      throw XCTSkip("set TEST_RUNNER_BOLTTY_NOTCH_SHOTS=<dir> to photograph it")
    }
    let screen = try XCTUnwrap(NSScreen.screens.first)
    let real = try XCTUnwrap(NotchMascotGeometry(screen: screen), "needs a screen with a notch")
    let lowered = screen.frame.offsetBy(dx: 0, dy: -drop)
    let left = try XCTUnwrap(screen.auxiliaryTopLeftArea).offsetBy(dx: 0, dy: -drop)
    let right = try XCTUnwrap(screen.auxiliaryTopRightArea).offsetBy(dx: 0, dy: -drop)
    let geometry = try XCTUnwrap(NotchMascotGeometry(
      screen: lowered, topInset: screen.safeAreaInsets.top, left: left, right: right))
    let stage = standIn(for: geometry.notch, band: real.notch.height, on: screen)
    defer { stage.orderOut(nil) }

    let dock = NotchMascotController()
    dock.geometryProvider = { geometry }
    defer { dock.shutdown() }
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    let roster = MascotRoster.load(defaults: .standard)

    for (index, scene) in scenes().enumerated() {
      dock.update(conversations: [], roster: roster)
      try await Task.sleep(for: .milliseconds(400))
      dock.lineDuration = scene.folded ? 0.2 : 60
      dock.update(conversations: scene.chats, roster: roster, waitingOn: scene.waitingOn)
      try await Task.sleep(for: .milliseconds(900))
      if let hover = scene.hover {
        dock.hoverForTesting(hover)
        try await Task.sleep(for: .milliseconds(700))
      }
      if scene.folded { try await Task.sleep(for: .milliseconds(900)) }
      let name = String(format: "%02d-%@.png", index + 1, scene.name)
      try photograph(geometry.notch, band: real.notch.height, on: screen, to: "\(directory)/\(name)")
      print("BOLTTY_SHOT \(directory)/\(name)")
      dock.hoverForTesting(nil)
    }
  }

  private func scenes() -> [Scene] {
    func chat(_ agent: AgentId, _ state: ConversationExecutionState, _ title: String = "Fix the login form",
              age: TimeInterval = 0) -> Conversation {
      Conversation(providerID: agent.rawValue, title: title, workingDirectory: "/tmp",
                   updatedAt: Date().addingTimeInterval(-age), hasUnread: true, lastKnownState: state)
    }
    let permission = PendingInteraction.Kind.permission(
      PermissionPrompt(action: "bash", resources: ["ls"], savePatterns: [], toolCallID: nil))
    let question = PendingInteraction.Kind.question(QuestionPrompt(items: [], toolCallID: nil))

    var scenes: [Scene] = []
    let working = chat(.grok, .working)
    scenes.append(Scene(name: "working", chats: [working]))
    let approval = chat(.claude, .waiting)
    scenes.append(Scene(name: "needs-approval", chats: [approval], waitingOn: [approval.id: permission]))
    let answer = chat(.codex, .waiting)
    scenes.append(Scene(name: "needs-answer", chats: [answer], waitingOn: [answer.id: question]))
    scenes.append(Scene(name: "failed", chats: [chat(.claude, .failed)]))
    scenes.append(Scene(name: "interrupted", chats: [chat(.codex, .interrupted)]))
    scenes.append(Scene(name: "rate-limited", chats: [chat(.antigravity, .rateLimited)]))
    scenes.append(Scene(name: "done", chats: [chat(.opencode, .idle)]))
    scenes.append(Scene(name: "done-long-title", chats: [
      chat(.claude, .idle, "Rewrite the onboarding flow so the permissions step comes last"),
    ]))
    scenes.append(Scene(name: "working-folded", chats: [chat(.grok, .working)], folded: true))

    let two = [chat(.claude, .working), chat(.grok, .working, age: 10)]
    scenes.append(Scene(name: "two-agents-working", chats: two))
    let threeAsk = chat(.codex, .waiting)
    let three = [chat(.claude, .working), threeAsk, chat(.grok, .working, age: 10)]
    scenes.append(Scene(name: "three-agents-one-asks", chats: three, waitingOn: [threeAsk.id: permission]))
    let fourAsk = chat(.claude, .waiting)
    let four = [fourAsk, chat(.codex, .working), chat(.grok, .failed), chat(.opencode, .idle, age: 20)]
    scenes.append(Scene(name: "four-agents-mixed", chats: four, waitingOn: [fourAsk.id: question]))
    let fiveAsk = chat(.grok, .waiting)
    let five = [fiveAsk, chat(.claude, .working), chat(.codex, .working, age: 5),
                chat(.antigravity, .working, age: 10), chat(.opencode, .working, age: 15)]
    scenes.append(Scene(name: "five-agents-capped-at-four", chats: five, waitingOn: [fiveAsk.id: permission]))
    let badged = [chat(.claude, .working), chat(.claude, .working, "Second Claude chat", age: 5),
                  chat(.codex, .working, age: 10)]
    scenes.append(Scene(name: "two-claude-chats-badge", chats: badged))
    let hovered = chat(.grok, .failed)
    let hoverScene = [chat(.claude, .waiting), chat(.codex, .working), hovered]
    scenes.append(Scene(name: "hover-back-face", chats: hoverScene,
                        waitingOn: [hoverScene[0].id: permission], hover: hovered.id))
    scenes.append(Scene(name: "four-agents-folded", chats: [
      chat(.claude, .working), chat(.codex, .working, age: 5),
      chat(.grok, .working, age: 10), chat(.opencode, .working, age: 15),
    ], folded: true))
    return scenes
  }

  /// A menu-bar band and a black notch where the dock expects them.
  private func standIn(for notch: CGRect, band: CGFloat, on screen: NSScreen) -> NSWindow {
    let frame = CGRect(x: screen.frame.minX, y: notch.minY, width: screen.frame.width, height: band)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = .statusBar
    window.ignoresMouseEvents = true
    window.isOpaque = true
    window.backgroundColor = NSColor(srgbRed: 0.04, green: 0.06, blue: 0.2, alpha: 1)
    let shape = NSView(frame: CGRect(x: notch.minX - frame.minX, y: 0, width: notch.width, height: band))
    shape.wantsLayer = true
    shape.layer?.backgroundColor = NSColor.black.cgColor
    shape.layer?.cornerRadius = 10
    shape.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    window.contentView?.addSubview(shape)
    window.orderFrontRegardless()
    return window
  }

  private func photograph(_ notch: CGRect, band: CGFloat, on screen: NSScreen, to path: String) throws {
    let width: CGFloat = 620
    let x = Int(notch.maxX - width + 40 - screen.frame.minX)
    let y = Int(screen.frame.maxY - notch.maxY - 10)
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-R", "\(x),\(y),\(Int(width)),\(Int(band + 20))", path]
    try shot.run()
    shot.waitUntilExit()
  }
}
