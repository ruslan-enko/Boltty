import AppKit
import XCTest
@testable import Boltty

/// Puts Ask Boltty's overlay on the real screen and photographs it: glass and a live
/// face do not draw offscreen. `TEST_RUNNER_BOLTTY_TALK_SHOT=<dir>` writes
/// `talk-listening.png` (the face beside a pointer tracing a loop) and
/// `talk-pointing.png` (the face landed beside a spot, the sentence beside it).
@MainActor
final class AskBolttyOverlayOnScreen: XCTestCase {
  func testPhotographTheFaceBesideThePointer() async throws {
    guard let directory = ProcessInfo.processInfo.environment["BOLTTY_TALK_SHOT"] else {
      throw XCTSkip("set TEST_RUNNER_BOLTTY_TALK_SHOT=<dir> to photograph it")
    }
    let screen = try XCTUnwrap(NSScreen.screens.first)
    let centre = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
    let loop = CGPoint(x: centre.x - 220, y: centre.y)
    let started = Date()
    let overlay = AskBolttyOverlayController()
    overlay.pointer = {
      let t = min(1, Date().timeIntervalSince(started) / 1.2)
      let angle = t * 2 * .pi * 1.05
      return CGPoint(x: loop.x + 130 * cos(angle), y: loop.y + 80 * sin(angle))
    }
    overlay.show(.listening, heard: "what is this button for", caption: "", agent: .claude)
    try await Task.sleep(for: .seconds(1.6))
    try photograph(around: centre, on: screen, to: "\(directory)/talk-listening.png")

    overlay.show(.speaking, heard: "", caption: "Click Share in the top right, then pick Mail.", agent: .claude)
    overlay.point(at: CGPoint(x: centre.x + 260, y: centre.y + 160))
    try await Task.sleep(for: .seconds(1.4))
    try photograph(around: centre, on: screen, to: "\(directory)/talk-pointing.png")
    overlay.hide()
  }

  private func photograph(around centre: CGPoint, on screen: NSScreen, to path: String) throws {
    let size = CGSize(width: 1000, height: 600)
    let x = Int(centre.x - size.width / 2)
    let y = Int(screen.frame.height - centre.y - size.height / 2)
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-R", "\(x),\(y),\(Int(size.width)),\(Int(size.height))", path]
    try shot.run()
    shot.waitUntilExit()
  }
}
