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
  static let usageReporting = AgentCapabilities(rawValue: 1 << 10)
  static let terminableTurn = AgentCapabilities(rawValue: 1 << 11)

  static let rereadableTranscript = AgentCapabilities(rawValue: 1 << 12)

  static let usageLimits = AgentCapabilities(rawValue: 1 << 13)

  static let contextUsage = AgentCapabilities(rawValue: 1 << 14)

  static let compaction = AgentCapabilities(rawValue: 1 << 15)

  static let steering = AgentCapabilities(rawValue: 1 << 16)

  static let activityHistory = AgentCapabilities(rawValue: 1 << 17)

  static let permissionMessage = AgentCapabilities(rawValue: 1 << 18)

  static let modelSwitching = AgentCapabilities(rawValue: 1 << 19)

  static let effortReset = AgentCapabilities(rawValue: 1 << 20)

  static let folderMoving = AgentCapabilities(rawValue: 1 << 21)

  static let commands = AgentCapabilities(rawValue: 1 << 22)

  static let planMode = AgentCapabilities(rawValue: 1 << 23)

  static let planInReply = AgentCapabilities(rawValue: 1 << 24)

  static let forking = AgentCapabilities(rawValue: 1 << 25)

  static let fileUndo = AgentCapabilities(rawValue: 1 << 26)

  static let computerUse = AgentCapabilities(rawValue: 1 << 27)

  var canEndTurn: Bool { contains(.interrupt) || contains(.terminableTurn) }

  var endingTurnIsAbrupt: Bool { !contains(.interrupt) && contains(.terminableTurn) }

}

/// One of the permission modes an agent's own CLI offers, in its own words and order.
/// The first asks before acting; a chat with no mode chosen runs it.
struct PermissionMode: Equatable, Sendable, Identifiable {
  let id: String
  let title: String
  let summary: String
  var isAuto = false

  static let legacyAuto = "auto"

  static func ladder(for agent: AgentId?) -> [PermissionMode] {
    switch agent {
    case .claude:
      [
        PermissionMode(id: "default", title: String(localized: "Ask"),
                       summary: String(localized: "Asks before each edit and command.")),
        PermissionMode(id: "acceptEdits", title: String(localized: "Accept Edits"),
                       summary: String(localized: "Edits files without asking. Commands still ask.")),
        PermissionMode(id: "auto", title: String(localized: "Auto"),
                       summary: String(localized: "Claude Code decides what is safe to run and asks only about the rest."),
                       isAuto: true),
        PermissionMode(id: "bypassPermissions", title: String(localized: "Bypass Permissions"),
                       summary: String(localized: "Runs everything without asking.")),
      ]
    case .codex:
      [
        PermissionMode(id: "ask", title: String(localized: "Ask for Approval"),
                       summary: String(localized: "Always asks to edit external files and use the internet.")),
        PermissionMode(id: "approveForMe", title: String(localized: "Approve for Me"),
                       summary: String(localized: "Only asks for actions Codex's reviewer finds potentially unsafe."),
                       isAuto: true),
        PermissionMode(id: "fullAccess", title: String(localized: "Full Access"),
                       summary: String(localized: "Unrestricted access to the internet and any file on your computer.")),
      ]
    case .grok:
      [
        PermissionMode(id: "ask", title: String(localized: "Ask"),
                       summary: String(localized: "Asks before commands and edits.")),
        PermissionMode(id: "auto", title: String(localized: "Auto-review"),
                       summary: String(localized: "A classifier approves safe actions; dangerous ones may still ask."),
                       isAuto: true),
        PermissionMode(id: "alwaysApprove", title: String(localized: "Always Approve"),
                       summary: String(localized: "Skips all permission prompts.")),
      ]
    case .antigravity:
      [
        PermissionMode(id: "default", title: String(localized: "Default"),
                       summary: String(localized: "Asks before edits and commands.")),
        PermissionMode(id: "accept-edits", title: String(localized: "Accept Edits"),
                       summary: String(localized: "Edits files without asking. Commands still ask.")),
        PermissionMode(id: "auto", title: String(localized: "Auto"),
                       summary: String(localized: "Approves edits and safe commands; asks before irreversible actions."),
                       isAuto: true),
        PermissionMode(id: "skip", title: String(localized: "Skip Permissions"),
                       summary: String(localized: "Approves every tool request without asking.")),
      ]
    case .opencode, .pi, .custom, nil:
      []
    }
  }

  /// A stored id the ladder no longer has falls back to the first mode; the pre-ladder
  /// Auto Mode reads as the agent's own auto.
  static func resolved(_ id: String?, for agent: AgentId?) -> PermissionMode? {
    let ladder = ladder(for: agent)
    if let id, let mode = ladder.first(where: { $0.id == id }) { return mode }
    if id == legacyAuto, let auto = ladder.first(where: \.isAuto) { return auto }
    return ladder.first
  }

  /// The word the model chip carries; the asking mode carries none, as in the CLIs.
  static func chipWord(_ id: String?, for agent: AgentId?) -> String? {
    guard let mode = resolved(id, for: agent), mode != ladder(for: agent).first else { return nil }
    return mode.title
  }
}

struct AgentInstallation: Identifiable, Equatable, Sendable {
  let provider: AgentId
  var availability: AgentAvailability
  var capabilities: AgentCapabilities

  var id: AgentId { provider }
  var isReady: Bool { availability.isAvailable }
  var isInstalled: Bool { availability.isInstalled }

  var needsLogin: Bool {
    if case .needsLogin = availability { return true }
    return false
  }

  static func displayVersion(_ raw: String) -> String {
    guard let range = raw.range(of: #"\d+(\.\d+)+([-+][0-9A-Za-z.]+)?"#, options: .regularExpression)
    else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
    return String(raw[range])
  }

  var statusText: String {
    switch availability {
    case let .available(version):
      return version.map { String(localized: "Ready · \(Self.displayVersion($0))") } ?? String(localized: "Ready")
    case .notInstalled:
      return String(localized: "Not installed")
    case let .needsLogin(detail):
      return detail
    case let .unavailable(reason):
      return reason
    }
  }
}
