import XCTest
@testable import Boltty

@MainActor
final class AgentCatalogServiceTests: XCTestCase {
  func testGUIProcessSearchesGroksNativeInstallDirectory() {
    let guiPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    let grokBin = NSHomeDirectory() + "/.grok/bin"
    let paths = JSONLineProcess.searchPath(adding: guiPath).split(separator: ":").map(String.init)

    XCTAssertTrue(paths.contains(grokBin), "Grok's native installer lives outside a GUI app's PATH")
    XCTAssertEqual(Array(paths.prefix(4)), guiPath.split(separator: ":").map(String.init))
    let repeated = JSONLineProcess.searchPath(adding: grokBin + ":" + guiPath)
    XCTAssertEqual(repeated.split(separator: ":").filter { $0 == grokBin }.count, 1)
  }

  func testTheCatalogueAndTheAdaptersSearchTheSamePlaces() {
    let gui = "/usr/bin:/bin:/usr/sbin:/sbin"
    let directories = ExecutableLookup.searchDirectories(path: gui)

    XCTAssertEqual(JSONLineProcess.searchPath(adding: gui), directories.joined(separator: ":"))
    XCTAssertTrue(directories.contains(NSHomeDirectory() + "/.opencode/bin"))
    XCTAssertTrue(directories.contains(NSHomeDirectory() + "/.local/share/mise/shims"))
    XCTAssertEqual(Set(directories).count, directories.count, "each directory once")
  }

  private func discovery(finding agents: [AgentId]) -> AgentDiscovery {
    let names = Set(agents.map(\.program))
    return AgentDiscovery(resolve: { name in
      names.contains(name) ? "/usr/local/bin/\(name)" : nil
    })
  }

  private func makeModel(_ settings: AppSettings) -> AppModel {
    AppModel(settings: settings, defaults: isolatedDefaults("boltty.tests.catalog"))
  }

  func testAdoptsTheFirstInstalledAgentWhenNothingWasChosen() {
    let model = makeModel(AppSettings(agentPreset: nil))
    let service = AgentCatalogService(model: model, discovery: nil)
    let found = discovery(finding: [.claude]).scan()

    service.apply(scannedAgents: found)

    XCTAssertEqual(model.settings.agentPreset, .claude)
  }

  func testLeavesAnExplicitCustomChoiceAlone() {
    let model = makeModel(AppSettings(agentPreset: .custom))
    let service = AgentCatalogService(model: model, discovery: nil)
    let found = discovery(finding: [.claude]).scan()

    service.apply(scannedAgents: found)

    XCTAssertEqual(model.settings.agentPreset, .custom)
  }

  func testKeepsAnInstalledPresetTheUserAlreadyPicked() {
    let model = makeModel(AppSettings(agentPreset: .codex))
    let service = AgentCatalogService(model: model, discovery: nil)
    let found = discovery(finding: [.claude, .codex]).scan()

    service.apply(scannedAgents: found)

    XCTAssertEqual(model.settings.agentPreset, .codex)
  }

  func testNoInstalledAgentsLeavesNothingToLaunch() {
    let model = makeModel(AppSettings(agentPreset: nil))
    let service = AgentCatalogService(model: model, discovery: nil)
    let found = discovery(finding: []).scan()

    service.apply(scannedAgents: found)

    XCTAssertTrue(service.launchableAgents.isEmpty)
  }

  func testOnlyEnabledAdaptersAreLaunchable() {
    let model = makeModel(AppSettings())
    let service = AgentCatalogService(model: model, discovery: nil)
    let found = discovery(finding: [.claude, .pi]).scan()

    service.apply(scannedAgents: found)

    XCTAssertEqual(service.launchableAgents, [.claude])
  }

  func testADisabledAdapterIsNotLaunchable() {
    let model = makeModel(
      AppSettings(
        agentPreset: .claude,
        enabledProviderIDs: [AgentId.codex.rawValue]
      )
    )
    let service = AgentCatalogService(model: model, discovery: nil)
    let found = discovery(finding: [.claude, .codex]).scan()

    service.apply(scannedAgents: found)

    XCTAssertEqual(service.launchableAgents, [.codex])
  }

  func testCustomPresetStillFallsBackToAnInstalledAgent() {
    let model = makeModel(AppSettings(agentPreset: .custom))
    let service = AgentCatalogService(model: model, discovery: nil)
    let found = discovery(finding: [.claude, .codex]).scan()

    service.apply(scannedAgents: found)

    XCTAssertEqual(model.settings.agentPreset, .custom, "an explicit choice is not overwritten")
    XCTAssertEqual(service.launchableAgents, [.claude, .codex])
  }

  func testDisablingAnAgentRemovesItFromThePreferredPicker() {
    let model = makeModel(AppSettings(agentPreset: .custom, enabledProviderIDs: ["codex"]))
    let service = AgentCatalogService(model: model, discovery: nil)
    let found = discovery(finding: [.claude, .codex]).scan()

    service.apply(scannedAgents: found)

    XCTAssertEqual(service.launchableAgents, [.codex])
  }
}
