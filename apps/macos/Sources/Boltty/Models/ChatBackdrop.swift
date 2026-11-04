import Foundation

/// What an agent's open chat wears behind its transcript, chosen per agent in
/// Settings › Agents. Standard is the shell's own glass and black ramp; the
/// others are scenes of `AgentBackdropShaders.metal`, each in the sky of the
/// agent's face (`AgentBackdropSky`). A stored `matrix`, a scene since
/// removed, reads as Standard.
enum ChatBackdrop: String, CaseIterable, Identifiable, Sendable {
  case standard
  case sky
  case space

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: "Standard"
    case .sky: "Sky"
    case .space: "Space"
    }
  }

  /// The number the shader switches on (`AgentBackdropUniforms.scene`).
  var sceneIndex: Float {
    switch self {
    case .standard: 0
    case .sky: 1
    case .space: 2
    }
  }

  /// Pixels drawn per point. Stars are sharp and take the display's scale;
  /// the sky is all soft edges and takes a pixel per two points, which shows
  /// nothing and costs a sixteenth of a Retina pass.
  func pixelsPerPoint(backing: CGFloat) -> CGFloat {
    self == .space ? backing : 0.5
  }

  static func storageKey(for agent: AgentId) -> String {
    "boltty.chatBackdrop.\(agent.rawValue)"
  }

  /// The README's pictures show what a new install has, whatever this Mac chose.
  nonisolated(unsafe) static var chosenForTesting: ChatBackdrop?

  static func chosen(for agent: AgentId?, defaults: UserDefaults = .standard) -> ChatBackdrop {
    if let chosenForTesting { return chosenForTesting }
    guard let agent else { return .standard }
    return defaults.string(forKey: storageKey(for: agent)).flatMap(ChatBackdrop.init(rawValue:)) ?? .standard
  }
}
