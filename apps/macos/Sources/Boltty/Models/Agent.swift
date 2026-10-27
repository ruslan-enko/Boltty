import Foundation

enum AgentId: String, CaseIterable, Codable, Sendable, Equatable {
  case opencode
  case pi
  case claude
  case codex
  case grok
  case antigravity = "agy"
  case custom

  static var discoverableCases: [AgentId] {
    [.opencode, .claude, .codex, .pi, .grok, .antigravity]
  }

  static var adapterCases: [AgentId] {
    [.opencode, .claude, .codex, .grok, .antigravity]
  }

  var displayName: String {
    switch self {
    case .opencode: "OpenCode"
    case .pi: "Pi"
    case .claude: "Claude Code"
    case .codex: "Codex CLI"
    case .grok: "Grok Build"
    case .antigravity: "Google Antigravity"
    case .custom: "Custom"
    }
  }

  var shortDisplayName: String {
    switch self {
    case .opencode: "OpenCode"
    case .pi: "Pi"
    case .claude: "Claude"
    case .codex: "Codex"
    case .grok: "Grok"
    case .antigravity: "Antigravity"
    case .custom: "Custom"
    }
  }

  var program: String {
    switch self {
    case .opencode: "opencode"
    case .pi: "pi"
    case .codex: "codex"
    case .claude: "claude"
    case .grok: "grok"
    case .antigravity: "agy"
    case .custom: ""
    }
  }

  /// What signs this CLI in from a terminal, read off each CLI's own help
  /// (claude 2.1.296, codex 0.164, grok 1.0.70). `agy` has no such
  /// subcommand and OpenCode never reports a sign-in of its own.
  var signInCommand: String? {
    switch self {
    case .claude: "claude auth login"
    case .codex: "codex login"
    case .grok: "grok login"
    default: nil
    }
  }

  var iconAssetName: String { rawValue }

  var fallbackSymbolName: String {
    switch self {
    case .opencode: "sparkles"
    case .pi: "circle.hexagongrid"
    case .codex: "chevron.left.forwardslash.chevron.right"
    case .claude: "brain.head.profile"
    case .grok: "bolt.fill"
    case .antigravity: "arrow.up.circle"
    case .custom: "sparkles"
    }
  }
}

struct InstalledAgent: Identifiable, Equatable, Sendable {
  let agent: AgentId
  let executablePath: String

  var id: AgentId { agent }
}

struct AgentDiscovery: Sendable {
  private let resolve: @Sendable (String) -> String?

  init(resolve: @escaping @Sendable (String) -> String?) {
    self.resolve = resolve
  }

  func scan() -> [InstalledAgent] {
    AgentId.discoverableCases.compactMap { agent in
      resolve(agent.program).map { InstalledAgent(agent: agent, executablePath: $0) }
    }
  }

  static let live = AgentDiscovery(resolve: { ExecutableLookup.resolve($0) })
}
