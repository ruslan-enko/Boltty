import Foundation

struct AgentCapabilities: OptionSet, Sendable, Hashable {
  let rawValue: Int

  init(rawValue: Int) { self.rawValue = rawValue }

  static let modelSelection = AgentCapabilities(rawValue: 1 << 0)
  static let permissions = AgentCapabilities(rawValue: 1 << 1)
  static let questions = AgentCapabilities(rawValue: 1 << 2)
  static let attachments = AgentCapabilities(rawValue: 1 << 3)
  static let images = AgentCapabilities(rawValue: 1 << 4)
  static let interrupt = AgentCapabilities(rawValue: 1 << 5)
  static let resumeSession = AgentCapabilities(rawValue: 1 << 6)
  static let workingDirectory = AgentCapabilities(rawValue: 1 << 7)
  static let reasoningEffort = AgentCapabilities(rawValue: 1 << 8)
  static let autoApproval = AgentCapabilities(rawValue: 1 << 9)
  static let usageReporting = AgentCapabilities(rawValue: 1 << 10)
  static let terminableTurn = AgentCapabilities(rawValue: 1 << 11)

  static let rereadableTranscript = AgentCapabilities(rawValue: 1 << 12)

  static let usageLimits = AgentCapabilities(rawValue: 1 << 13)

  static let contextUsage = AgentCapabilities(rawValue: 1 << 14)

  static let compaction = AgentCapabilities(rawValue: 1 << 15)

  static let steering = AgentCapabilities(rawValue: 1 << 16)

  static let activityHistory = AgentCapabilities(rawValue: 1 << 17)

  static let permissionMessage = AgentCapabilities(rawValue: 1 << 18)

  var canEndTurn: Bool { contains(.interrupt) || contains(.terminableTurn) }

  var endingTurnIsAbrupt: Bool { !contains(.interrupt) && contains(.terminableTurn) }

}

struct AgentInstallation: Identifiable, Equatable, Sendable {
  let provider: AgentId
  var availability: AgentAvailability
  var capabilities: AgentCapabilities

  var id: AgentId { provider }
  var isReady: Bool { availability.isAvailable }

  static func displayVersion(_ raw: String) -> String {
    guard let range = raw.range(of: #"\d+(\.\d+)+([-+][0-9A-Za-z.]+)?"#, options: .regularExpression)
    else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
    return String(raw[range])
  }

  var statusText: String {
    switch availability {
    case let .available(version):
      return version.map { "Ready · \(Self.displayVersion($0))" } ?? "Ready"
    case .notInstalled:
      return "Not installed"
    case let .needsLogin(detail):
      return detail
    case let .unavailable(reason):
      return reason
    }
  }
}
