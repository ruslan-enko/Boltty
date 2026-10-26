import Combine
import Foundation

@MainActor
final class AgentCatalogService: ObservableObject {
  @Published private(set) var installedAgents: [InstalledAgent] = []
  @Published private(set) var isScanning = false

  private let discovery: AgentDiscovery?
  private unowned let model: AppModel

  init(model: AppModel, discovery: AgentDiscovery? = .live) {
    self.model = model
    self.discovery = discovery
  }

  var installedAgentIDs: [AgentId] { installedAgents.map(\.agent) }

  var launchableAgents: [AgentId] {
    installedAgentIDs.filter { agent in
      AgentId.adapterCases.contains(agent) && model.settings.isProviderEnabled(agent.rawValue)
    }
  }

  func scan() {
    Task { await scanAndWait() }
  }

  func scanAndWait() async {
    guard let discovery else { return }
    isScanning = true
    let scanned = await Task.detached { discovery.scan() }.value
    apply(scannedAgents: scanned)
    isScanning = false
  }

  func apply(scannedAgents: [InstalledAgent]) {
    installedAgents = scannedAgents
    adoptPresetIfNeeded()
  }

  private func adoptPresetIfNeeded() {
    let available = installedAgentIDs
    let current = model.settings.agentPreset

    if let current,
       available.contains(current),
       model.settings.isProviderEnabled(current.rawValue)
    {
      return
    }

    if current == .custom { return }

    let replacement = launchableAgents.first
    guard model.settings.agentPreset != replacement else { return }
    model.updateSettings { settings in
      settings.agentPreset = replacement
    }
  }
}
