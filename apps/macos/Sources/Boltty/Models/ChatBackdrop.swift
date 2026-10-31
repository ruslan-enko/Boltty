import Foundation

/// What an agent's open chat wears behind its transcript, chosen per agent in
/// Settings › Agents. Standard is the shell's own glass and black ramp; the
/// others are scenes of `AgentBackdropShaders.metal`, drawn in the agent's
/// face colours.
enum ChatBackdrop: String, CaseIterable, Identifiable, Sendable {
  case standard
  case sky
  case space
  case matrix

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: "Standard"
    case .sky: "Sky"
    case .space: "Space"
    case .matrix: "Matrix"
    }
  }

  /// The number the shader switches on (`AgentBackdropUniforms.scene`).
  var sceneIndex: Float {
    switch self {
    case .standard: 0
    case .sky: 1
    case .space: 2
    case .matrix: 3
    }
  }

  /// Sharp scenes draw at the display's scale; soft ones at a pixel a point,
  /// which loses nothing and costs a quarter of a Retina pass.
  var drawsAtFullScale: Bool { self == .space || self == .matrix }

  static func storageKey(for agent: AgentId) -> String {
    "boltty.chatBackdrop.\(agent.rawValue)"
  }

  static func chosen(for agent: AgentId?, defaults: UserDefaults = .standard) -> ChatBackdrop {
    guard let agent else { return .standard }
    return defaults.string(forKey: storageKey(for: agent)).flatMap(ChatBackdrop.init(rawValue:)) ?? .standard
  }
}
