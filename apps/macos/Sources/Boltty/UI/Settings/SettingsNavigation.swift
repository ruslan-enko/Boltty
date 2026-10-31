import AppKit
import Combine

enum SettingsPage: String, CaseIterable, Identifiable {
  case general
  case agents
  case usage
  case voice
  /// Stored as "talk", its name before it was Ask Boltty: the raw value is a
  /// storage format.
  case askBoltty = "talk"
  case shortcuts

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .agents: "Agents"
    case .usage: "Usage"
    case .voice: "Voice"
    case .askBoltty: "Ask Boltty"
    case .shortcuts: "Shortcuts"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    // The agents are command-line tools; sparkles said "AI" and nothing more.
    case .agents: "terminal"
    case .usage: "chart.bar"
    case .voice: "mic"
    case .askBoltty: "person.wave.2"
    case .shortcuts: "keyboard"
    }
  }
}

/// Where the window stands: a page, and on Agents, perhaps one agent's own
/// page under it.
struct SettingsLocation: Equatable {
  var page: SettingsPage
  var agent: AgentId?

  init(_ page: SettingsPage, agent: AgentId? = nil) {
    self.page = page
    self.agent = page == .agents ? agent : nil
  }
}

@MainActor
final class SettingsNavigation: ObservableObject {
  static let lastPageKey = "boltty.settings.page"
  /// Read from the arguments only (`-boltty.settings.agent claude`), so a
  /// screenshot can open on an agent's page. Never written.
  static let agentArgumentKey = "boltty.settings.agent"

  @Published private(set) var history: [SettingsLocation]
  @Published private(set) var position = 0

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = defaults.string(forKey: Self.lastPageKey).flatMap(SettingsPage.init(rawValue:))
    let page = stored ?? .general
    history = [SettingsLocation(page)]
    if page == .agents,
       let agent = defaults.string(forKey: Self.agentArgumentKey).flatMap(AgentId.init(rawValue:)),
       AgentId.adapterCases.contains(agent)
    {
      history.append(SettingsLocation(.agents, agent: agent))
      position = 1
    }
  }

  var location: SettingsLocation { history[position] }
  var current: SettingsPage { location.page }
  /// The agent whose own page is open, if one is.
  var agent: AgentId? { location.agent }
  var canGoBack: Bool { position > 0 }
  var canGoForward: Bool { position < history.count - 1 }

  var title: String { agent?.displayName ?? current.title }

  func open(_ page: SettingsPage) {
    open(SettingsLocation(page))
  }

  func open(agent: AgentId) {
    open(SettingsLocation(.agents, agent: agent))
  }

  private func open(_ location: SettingsLocation) {
    guard location != self.location else { return }
    history = Array(history.prefix(position + 1)) + [location]
    position = history.count - 1
    remember()
  }

  func goBack() {
    guard canGoBack else { return }
    position -= 1
    remember()
  }

  func goForward() {
    guard canGoForward else { return }
    position += 1
    remember()
  }

  /// Only the page: Settings opened again starts on its top, not on an agent.
  private func remember() {
    defaults.set(current.rawValue, forKey: Self.lastPageKey)
  }
}
