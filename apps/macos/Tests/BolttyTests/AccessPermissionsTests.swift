import AppKit
import XCTest
@testable import Boltty

@MainActor
final class AccessPermissionsTests: XCTestCase {
  @MainActor private final class FakeSystem {
    var statuses: [AccessKind: AccessStatus] = [:]
    var answers: [AccessKind: AccessStatus] = [:]
    private(set) var requested: [AccessKind] = []

    var probe: AccessProbe {
      AccessProbe(
        status: { [unowned self] kind in self.statuses[kind] ?? .notAsked },
        request: { [unowned self] kind in
          self.requested.append(kind)
          self.statuses[kind] = self.answers[kind] ?? .allowed
          return self.statuses[kind]!
        }
      )
    }
  }

  func testTheModelReadsWhereEachPermissionStands() async {
    let system = FakeSystem()
    system.statuses = [.dictation: .allowed, .screen: .refused, .notifications: .notAsked, .finder: .allowed]
    let model = AccessPermissionsModel(probe: system.probe)

    await model.refresh()

    XCTAssertEqual(model.statuses, system.statuses.merging([.notifications: .notAsked]) { $1 })
    XCTAssertFalse(model.allAllowed)
  }

  func testAllowAsksMacOSAndTheRowFollowsTheAnswer() async throws {
    let system = FakeSystem()
    let model = AccessPermissionsModel(probe: system.probe)
    await model.refresh()

    model.act(on: .notifications)
    XCTAssertEqual(model.asking, .notifications, "the row says it is asking while the prompt is up")
    try await waitUntil { model.asking == nil }

    XCTAssertEqual(system.requested, [.notifications])
    XCTAssertEqual(model.statuses[.notifications], .allowed)
  }

  func testAllowAllAsksForEverythingNotYetAskedScreenLast() async throws {
    let system = FakeSystem()
    system.statuses = [.dictation: .notAsked, .screen: .notAsked, .notifications: .allowed, .finder: .refused]
    let model = AccessPermissionsModel(probe: system.probe)
    await model.refresh()
    XCTAssertTrue(model.hasSomethingToAsk)

    model.allowAll()
    try await waitUntil { model.asking == nil && system.requested.count == 2 }

    XCTAssertEqual(system.requested, [.dictation, .screen])
    XCTAssertFalse(model.hasSomethingToAsk)
  }

  func testARefusedPermissionIsNotAskedAgain() async {
    let system = FakeSystem()
    system.statuses = [.finder: .refused]
    let model = AccessPermissionsModel(probe: system.probe)
    await model.refresh()

    model.act(on: .finder)

    XCTAssertNil(model.asking)
    XCTAssertEqual(system.requested, [])
  }

  func testAPermissionOfSeveralPartsIsAllowedOnlyWhenEveryPartIs() {
    XCTAssertEqual(AccessStatus.combined([.allowed, .allowed]), .allowed)
    XCTAssertEqual(AccessStatus.combined([.allowed, .notAsked]), .notAsked)
    XCTAssertEqual(AccessStatus.combined([.notAsked, .refused]), .refused)
  }

  func testShowTheWindowOnScreen() async throws {
    guard ProcessInfo.processInfo.environment["BOLTTY_ACCESS_ONSCREEN"] != nil else {
      throw XCTSkip("set BOLTTY_ACCESS_ONSCREEN to show it")
    }
    let system = FakeSystem()
    system.statuses = [.dictation: .allowed, .screen: .refused, .notifications: .notAsked, .finder: .notAsked]
    let controller = AccessPermissionsWindowController(probe: system.probe)
    await controller.model.refresh()
    let window = try XCTUnwrap(controller.window)
    let screen = try XCTUnwrap(NSScreen.main)
    window.setFrameTopLeftPoint(NSPoint(x: screen.frame.minX + 120, y: screen.frame.maxY - 120))
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(500))
    let frame = window.frame
    let top = (NSScreen.screens.first?.frame.height ?? frame.maxY) - frame.maxY
    print("BOLTTY_ONSCREEN \(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))")
    try await Task.sleep(for: .seconds(6))
    window.orderOut(nil)
  }

  private func waitUntil(_ condition: @escaping () -> Bool) async throws {
    for _ in 0..<100 where !condition() {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition())
  }
}
