import XCTest
@testable import Boltty

@MainActor
final class AgentInstallerTests: XCTestCase {
  func testEveryAdapterHasARecipeOverHTTPS() {
    for agent in AgentHistory.tabOrder {
      XCTAssertEqual(AgentInstaller.recipe(for: agent)?.script.scheme, "https", agent.rawValue)
    }
    XCTAssertEqual(
      AgentInstaller.recipe(for: .claude)?.command, "curl -fsSL https://claude.ai/install.sh | bash")
  }

  func testInstallingFindsTheAgentBeforeItsStateGoes() async {
    let installer = AgentInstaller(
      fetch: { _ in "#!/bin/sh" }, run: { _, _ in .init(exitCode: 0, output: "") }, locate: { _ in true })
    var during: AgentInstaller.State?
    await installer.install(.codex) { during = installer.states[.codex] }
    XCTAssertEqual(during, .installing)
    XCTAssertNil(installer.states[.codex])
  }

  func testAFailureKeepsTheInstallersLastWords() async {
    let installer = AgentInstaller(
      fetch: { _ in "#!/bin/sh" },
      run: { _, _ in .init(exitCode: 1, output: "Downloading\n\u{1B}[0;31mNo space left\u{1B}[0m\n\n") },
      locate: { _ in true })
    var found = false
    await installer.install(.grok) { found = true }
    XCTAssertEqual(installer.states[.grok], .failed("No space left"))
    XCTAssertFalse(found)
  }

  func testAnInstallerThatLeftNothingFailed() async {
    let installer = AgentInstaller(
      fetch: { _ in "#!/bin/sh" }, run: { _, _ in .init(exitCode: 0, output: "") }, locate: { _ in false })
    await installer.install(.claude) {}
    guard case .failed = installer.states[.claude] else { return XCTFail("expected a failure") }
  }

  func testTheScriptRunsOffStandardInput() async {
    let recipe = AgentInstaller.Recipe(script: URL(string: "https://example.com")!, shell: "/bin/sh")
    let result = await AgentInstaller.execute(recipe, script: "#!/bin/sh\necho ready; exit 3\n")
    XCTAssertEqual(result, .init(exitCode: 3, output: "ready\n"))
  }

  func testWithNoAgentsThereIsNoFaceToGive() {
    XCTAssertFalse(SetupStep.steps(hasNoAgents: true).contains(.mascots))
    XCTAssertEqual(SetupStep.steps(hasNoAgents: false), SetupStep.allCases)
  }

  func testTheRealInstallersRunWithNoTerminal() async throws {
    guard ProcessInfo.processInfo.environment["BOLTTY_LIVE_INSTALL"] == "1" else {
      throw XCTSkip("set TEST_RUNNER_BOLTTY_LIVE_INSTALL=1")
    }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let realHome = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    setenv("HOME", home.path, 1)
    defer {
      setenv("HOME", realHome, 1)
      try? FileManager.default.removeItem(at: home)
    }
    let places: [(AgentId, String)] = [
      (.claude, ".local/bin/claude"), (.codex, ".local/bin/codex"), (.opencode, ".opencode/bin/opencode"),
      (.antigravity, ".local/bin/agy"), (.grok, ".grok/bin/grok"),
    ]
    for (agent, place) in places {
      let path = home.appendingPathComponent(place).path
      let installer = AgentInstaller(locate: { _ in FileManager.default.isExecutableFile(atPath: path) })
      var found = false
      await installer.install(agent) { found = true }
      XCTAssertTrue(found, "\(agent.rawValue): \(String(describing: installer.states[agent]))")
    }
  }
}
