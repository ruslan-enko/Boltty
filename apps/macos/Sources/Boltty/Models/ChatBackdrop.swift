import Foundation

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

  var sceneIndex: Float {
    switch self {
    case .standard: 0
    case .sky: 1
    case .space: 2
    }
  }

  func pixelsPerPoint(backing: CGFloat) -> CGFloat {
    self == .space ? backing : 0.5
  }

  static func storageKey(for agent: AgentId) -> String {
    "boltty.chatBackdrop.\(agent.rawValue)"
  }

  nonisolated(unsafe) static var chosenForTesting: ChatBackdrop?

  static func chosen(for agent: AgentId?, defaults: UserDefaults = .standard) -> ChatBackdrop {
    if let chosenForTesting { return chosenForTesting }
    guard let agent else { return .standard }
    return defaults.string(forKey: storageKey(for: agent)).flatMap(ChatBackdrop.init(rawValue:)) ?? .standard
  }
}
