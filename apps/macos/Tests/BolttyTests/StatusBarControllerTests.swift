import XCTest
@testable import Boltty

@MainActor
final class StatusBarControllerTests: XCTestCase {
  func testDynamicAgentRowsAndUnreadCommandsFollowSnapshot() {
    let controller = StatusBarController()
    controller.install()
    defer { controller.remove() }
    let id = UUID()
    controller.apply(snapshot: StatusBarSnapshot(
      iconState: .attention,
      agentRows: [.init(id: id, agent: .codex, prompt: "write tests")],
      latestUnreadSessionID: id,
      latestUnreadTitle: "Done",
      accessibilityLabel: "Boltty — attention required"
    ))

    XCTAssertTrue(controller.menuTitlesForTesting.contains("write tests"))
    XCTAssertTrue(controller.menuTitlesForTesting.contains("Jump to Latest Unread"))
    XCTAssertFalse(controller.menuTitlesForTesting.contains("No Unread Chats"))
    XCTAssertFalse(controller.menuTitlesForTesting.contains("Background Windows"))

    let unread = controller.menuItemsForTesting.first(where: { $0.title == "write tests" })
    XCTAssertNotNil(unread)
  }

  func testTheSameSnapshotDoesNotRebuildTheMenu() {
    let controller = StatusBarController()
    controller.install()
    defer { controller.remove() }
    let running = StatusBarSnapshot(
      iconState: .idle,
      agentRows: [.init(id: UUID(), agent: .claude, prompt: "count to thirty")],
      latestUnreadSessionID: nil,
      latestUnreadTitle: nil,
      accessibilityLabel: "Boltty"
    )
    controller.apply(snapshot: running)
    let built = controller.menuItemsForTesting.first

    controller.apply(snapshot: running)
    XCTAssertTrue(controller.menuItemsForTesting.first === built, "an unchanged snapshot is a no-op")

    controller.apply(snapshot: .idle)
    XCTAssertFalse(controller.menuItemsForTesting.first === built, "a changed one redraws")
    XCTAssertFalse(controller.menuTitlesForTesting.contains("count to thirty"))
  }

  func testMenuItemsCarryIcons() {
    let controller = StatusBarController()
    controller.install()
    defer { controller.remove() }

    let agentID = UUID()
    controller.apply(snapshot: StatusBarSnapshot(
      iconState: .idle,
      agentRows: [.init(id: agentID, agent: .opencode, prompt: "review PR")],
      latestUnreadSessionID: nil,
      latestUnreadTitle: nil,
      accessibilityLabel: "Boltty"
    ))

    let items = controller.menuItemsForTesting
    let bolttyAI = items.first(where: { $0.title == "Boltty AI" })
    let agentRow = items.first(where: { $0.title == "review PR" })
    let settings = items.first(where: { $0.title == "Settings…" })
    let quit = items.first(where: { $0.title == "Quit Boltty" })

    XCTAssertNotNil(bolttyAI?.image)
    XCTAssertNil(items.first(where: { $0.title == "Show Boltty" }))
    XCTAssertNil(items.first(where: { $0.title == "New Conversation" }))
    XCTAssertNotNil(agentRow?.image)
    XCTAssertNotNil(settings?.image)
    XCTAssertNotNil(quit?.image)
  }

  func testQuitCarriesNoKeyEquivalent() {
    let controller = StatusBarController()
    controller.install()
    defer { controller.remove() }

    controller.apply(snapshot: .idle)

    let quit = controller.menuItemsForTesting.first(where: { $0.title == "Quit Boltty" })
    XCTAssertNotNil(quit)
    XCTAssertEqual(quit?.keyEquivalent, "")
  }
  func testTheUpdaterRowFollowsTheOffer() {
    let controller = StatusBarController()
    controller.install()
    defer { controller.remove() }

    XCTAssertFalse(controller.menuTitlesForTesting.contains("Check for Updates…"), "not until wired")

    controller.updateOffer = .check(enabled: false)
    let check = controller.menuItemsForTesting.first(where: { $0.title == "Check for Updates…" })
    XCTAssertNotNil(check)
    XCTAssertEqual(check?.isEnabled, false, "not while a check is out")

    controller.updateOffer = .download(version: "0.2.0")
    XCTAssertFalse(controller.menuTitlesForTesting.contains("Check for Updates…"))
    let download = controller.menuItemsForTesting.first(where: { $0.title == "Download Boltty 0.2.0…" })
    XCTAssertEqual(download?.isEnabled, true)
    let titles = controller.menuTitlesForTesting
    XCTAssertEqual(titles.firstIndex(of: "Download Boltty 0.2.0…").map { $0 + 1 },
                   titles.firstIndex(of: "Settings…"), "it stands right above Settings")
  }
}
