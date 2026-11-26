import Foundation

enum ChatBackdrop: String, CaseIterable, Identifiable, Sendable {
  case standard
  case sky
  case space
  case black

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: String(localized: "Standard")
    case .sky: String(localized: "Sky")
    case .space: String(localized: "Space")
    case .black: String(localized: "Black")
    }
  }

  var sceneIndex: Float {
    switch self {
    case .standard: 0
    case .sky: 1
    case .space: 2
    case .black: 3
    }
  }

  var isStill: Bool { self == .black }

  func pixelsPerPoint(backing: CGFloat) -> CGFloat {
    self == .space ? backing : 0.5
  }

  static let storageKey = "boltty.backdrop"

  nonisolated(unsafe) static var chosenForTesting: ChatBackdrop?

  static func chosen(defaults: UserDefaults = .standard) -> ChatBackdrop {
    if let chosenForTesting { return chosenForTesting }
    return defaults.string(forKey: storageKey).flatMap(ChatBackdrop.init(rawValue:)) ?? .standard
  }
}
