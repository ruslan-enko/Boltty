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

@MainActor
final class SettingsNavigation: ObservableObject {
  static let lastPageKey = "boltty.settings.page"

  @Published private(set) var history: [SettingsPage]
  @Published private(set) var position = 0

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = defaults.string(forKey: Self.lastPageKey).flatMap(SettingsPage.init(rawValue:))
    history = [stored ?? .general]
  }

  var current: SettingsPage { history[position] }
  var canGoBack: Bool { position > 0 }
  var canGoForward: Bool { position < history.count - 1 }

  func open(_ page: SettingsPage) {
    guard page != current else { return }
    history = Array(history.prefix(position + 1)) + [page]
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

  private func remember() {
    defaults.set(current.rawValue, forKey: Self.lastPageKey)
  }
}
