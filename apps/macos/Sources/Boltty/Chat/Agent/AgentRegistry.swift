import Combine
import Foundation

@MainActor
final class AgentRegistry: ObservableObject {
  @Published private(set) var installations: [AgentInstallation] = []

  private let clientsByProvider: [AgentId: AgentClient]
  private let order: [AgentId]

  init(clients: [AgentClient]) {
    order = clients.map(\.provider)
    clientsByProvider = Dictionary(
      clients.map { ($0.provider, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    installations = clients.map {
      AgentInstallation(
        provider: $0.provider,
        availability: .unavailable("Checking…"),
        capabilities: $0.capabilities
      )
    }
  }

  static func live() -> AgentRegistry {
    AgentRegistry(clients: [
      OpenCodeClient(),
      ClaudeCodeClient(),
      CodexClient(),
      ACPClient(agent: .grok),
      AntigravityClient(),
    ])
  }

  var clients: [AgentClient] { order.compactMap { clientsByProvider[$0] } }

  func client(forProviderID providerID: String) -> AgentClient? {
    AgentId(rawValue: providerID).flatMap { clientsByProvider[$0] }
  }

  func client(for provider: AgentId) -> AgentClient? { clientsByProvider[provider] }

  func installation(for provider: AgentId) -> AgentInstallation? {
    installations.first { $0.provider == provider }
  }

  func installation(forProviderID providerID: String) -> AgentInstallation? {
    AgentId(rawValue: providerID).flatMap(installation(for:))
  }

  func capabilities(forProviderID providerID: String) -> AgentCapabilities {
    installation(forProviderID: providerID)?.capabilities ?? []
  }

  var ready: [AgentInstallation] { installations.filter(\.isReady) }

  var defaultProvider: AgentId? { ready.first?.provider }

  func probeAll() async {
    await withTaskGroup(of: (AgentId, AgentAvailability, AgentCapabilities).self) { group in
      for client in clients {
        group.addTask { (client.provider, await client.probe(), client.capabilities) }
      }
      for await (provider, availability, capabilities) in group {
        apply(availability, capabilities: capabilities, to: provider)
      }
    }
  }

  func refresh(_ provider: AgentId) async {
    guard let client = clientsByProvider[provider] else { return }
    apply(await client.probe(), capabilities: client.capabilities, to: provider)
  }

  private func apply(
    _ availability: AgentAvailability,
    capabilities: AgentCapabilities,
    to provider: AgentId
  ) {
    guard let index = installations.firstIndex(where: { $0.provider == provider }) else { return }
    installations[index].availability = availability
    installations[index].capabilities = capabilities
  }
}
