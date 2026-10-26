import XCTest
@testable import Boltty

final class AgentIdTests: XCTestCase {
  func testDisplayNames() {
    XCTAssertEqual(AgentId.opencode.displayName, "OpenCode")
    XCTAssertEqual(AgentId.pi.displayName, "Pi")
    XCTAssertEqual(AgentId.claude.displayName, "Claude Code")
    XCTAssertEqual(AgentId.codex.displayName, "Codex CLI")
    XCTAssertEqual(AgentId.grok.displayName, "Grok Build")
  }

  func testAntigravityIsBackUnderItsOldIdentity() {
    XCTAssertEqual(AgentId.antigravity.rawValue, "agy", "chats from before its removal carry it")
    XCTAssertEqual(AgentId.antigravity.shortDisplayName, "Antigravity")
    XCTAssertTrue(AgentId.adapterCases.contains(.antigravity))
    XCTAssertTrue(AgentId.discoverableCases.contains(.antigravity))
  }

  func testPiIsDiscoverableButNotAnAdapter() {
    XCTAssertTrue(AgentId.discoverableCases.contains(.pi))
    XCTAssertFalse(AgentId.adapterCases.contains(.pi))
  }

  @MainActor
  func testAgentDiscoveryReturnsOnlyInstalledAgentsInCatalogOrder() {
    let paths = [
      "opencode": "/opt/homebrew/bin/opencode",
      "pi": "/Users/test/.local/bin/pi",
    ]
    let discovery = AgentDiscovery(resolve: { paths[$0] })

    XCTAssertEqual(
      discovery.scan(),
      [
        InstalledAgent(agent: .opencode, executablePath: "/opt/homebrew/bin/opencode"),
        InstalledAgent(agent: .pi, executablePath: "/Users/test/.local/bin/pi"),
      ]
    )
  }
}
