import Foundation

protocol AgentClient: AnyObject, Sendable {
  var provider: AgentId { get }

  var capabilities: AgentCapabilities { get }

  func probe() async -> AgentAvailability

  func availableModels() async throws -> [AgentModelOption]

  func makeSessionID() -> String

  func createSession(
    id: String,
    options: AgentSessionOptions
  ) async throws -> RemoteSessionInfo

  func loadSession(id: String) async throws -> RemoteSessionSnapshot

  func send(
    messageID: String,
    text: String,
    attachments: [OutgoingAttachment],
    to sessionID: String
  ) async throws

  func messageExists(id: String, in sessionID: String) async throws -> Bool

  func stop(sessionID: String) async throws

  func answerQuestion(
    requestID: String,
    sessionID: String,
    answers: [[String]]
  ) async throws

  func rejectQuestion(requestID: String, sessionID: String) async throws

  func answerPermission(
    requestID: String,
    sessionID: String,
    decision: PermissionDecision,
    message: String?
  ) async throws

  func answerPlan(
    requestID: String,
    sessionID: String,
    decision: PlanDecision,
    feedback: String?
  ) async throws

  func events() -> AsyncStream<AgentEventEnvelope>

  func setAutoApproval(_ enabled: Bool, sessionID: String) async throws

  /// nil means "cannot tell": the caller must re-read.
  func missedAnything(sessionID: String) async -> Bool?

  func usageLimits() async -> AgentUsage?

  func contextUsage(sessionID: String) async -> AgentContextUsage?

  func compact(sessionID: String) async throws

  func steer(messageID: String, text: String, to sessionID: String) async throws

  func activityHistory() async -> AgentActivityHistory?

  func shutdown() async

  /// Lets go of what keeps a session open in Boltty — a CLI's process per
  /// conversation — without touching the CLI's record of it. A later send
  /// starts it again. Ask Boltty lets go of every chat it is done with.
  func release(sessionID: String) async

  func setConversationResolver(_ resolve: @escaping @Sendable (String) -> UUID?)
}

extension AgentClient {
  func usageLimits() async -> AgentUsage? { nil }
  func contextUsage(sessionID: String) async -> AgentContextUsage? { nil }
  func activityHistory() async -> AgentActivityHistory? { nil }
  func steer(messageID: String, text: String, to sessionID: String) async throws {
    throw AgentClientError.transport("This agent cannot take words mid-turn.")
  }
  func compact(sessionID: String) async throws {
    throw AgentClientError.transport("This agent cannot compact a conversation.")
  }
  func setConversationResolver(_ resolve: @escaping @Sendable (String) -> UUID?) {}
  func answerPlan(
    requestID: String,
    sessionID: String,
    decision: PlanDecision,
    feedback: String?
  ) async throws {
    throw AgentClientError.requestGone
  }
  func setAutoApproval(_ enabled: Bool, sessionID: String) async throws {}
  func missedAnything(sessionID: String) async -> Bool? { nil }
  func release(sessionID: String) async {}
}

struct AgentSessionOptions: Equatable, Sendable {
  var directory: String
  var model: ModelSelection?
  var effort: String?
  var autoApprove: Bool
  /// Start the agent without the tools that write, where the CLI can be told.
  /// The engine refuses every permission such a chat is asked either way.
  var readOnly: Bool

  init(
    directory: String,
    model: ModelSelection? = nil,
    effort: String? = nil,
    autoApprove: Bool = false,
    readOnly: Bool = false
  ) {
    self.directory = directory
    self.model = model
    self.effort = effort
    self.autoApprove = autoApprove
    self.readOnly = readOnly
  }
}

enum AgentAvailability: Equatable, Sendable {
  case available(version: String?)
  case notInstalled
  case needsLogin(String)
  case unavailable(String)

  var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }

  var isInstalled: Bool {
    switch self {
    case .available, .needsLogin, .unavailable: return true
    case .notInstalled: return false
    }
  }
}

extension AgentClient {
  var providerID: String { provider.rawValue }

  func makeSessionID() -> String { AgentSessionID.opaque() }
}

enum AgentSessionID {
  static func opaque() -> String { "ses_" + suffix() }

  static func uuid() -> String { UUID().uuidString.lowercased() }

  private static func suffix() -> String {
    let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    return String((0..<24).map { _ in alphabet.randomElement()! })
  }
}

struct AgentModelOption: Identifiable, Equatable, Sendable {
  let selection: ModelSelection
  var isDefault: Bool
  var effortOptions: [AgentEffortOption] = []
  var id: String { "\(selection.providerID)/\(selection.modelID)" }
}

struct AgentEffortOption: Identifiable, Equatable, Sendable {
  let value: String
  var label: String
  var detail: String?

  var id: String { value }

  init(value: String, label: String? = nil, detail: String? = nil) {
    self.value = value
    self.label = label ?? AgentEffortOption.title(for: value)
    self.detail = detail
  }

  static func title(for value: String) -> String {
    switch value {
    case "low": return "Low"
    case "medium": return "Medium"
    case "high": return "High"
    case "xhigh": return "Extra high"
    case "max": return "Max"
    case "minimal", "none": return "Minimal"
    default: return value.prefix(1).uppercased() + value.dropFirst()
    }
  }
}

struct RemoteSessionInfo: Equatable, Sendable {
  let id: String
  var title: String
  var directory: String
  var model: ModelSelection?
}

struct RemoteSessionSnapshot: Equatable, Sendable {
  var info: RemoteSessionInfo
  var messages: [ConversationMessage]
  var state: ConversationExecutionState
  var openInteractions: [PendingInteraction]
}

struct OutgoingAttachment: Equatable, Sendable {
  var url: URL
  var displayName: String
  var mimeType: String?
}

struct AgentEventEnvelope: Equatable, Sendable {
  var providerID: String?
  let id: String?
  let sequence: Int?
  let event: AgentEvent

  init(
    providerID: String? = nil,
    id: String? = nil,
    sequence: Int? = nil,
    event: AgentEvent
  ) {
    self.providerID = providerID
    self.id = id
    self.sequence = sequence
    self.event = event
  }

  func stamped(with providerID: String) -> AgentEventEnvelope {
    var copy = self
    copy.providerID = providerID
    return copy
  }
}

enum AgentEvent: Equatable, Sendable {
  case connection(AgentConnectionState)
  case messageUpdated(sessionID: String, message: ConversationMessage)
  case messageRemoved(sessionID: String, messageID: String)
  case partUpdated(sessionID: String, messageID: String, part: ConversationPart)
  case partDelta(
    sessionID: String,
    messageID: String,
    partID: String,
    kind: ConversationPart.TextKind,
    delta: String
  )
  case partRemoved(sessionID: String, messageID: String, partID: String)
  case executionStateChanged(sessionID: String, state: ConversationExecutionState)
  case sessionFailed(sessionID: String, failure: MessageFailure)
  case interactionAsked(PendingInteraction)
  case interactionResolved(
    sessionID: String,
    requestID: String,
    resolution: PendingInteraction.Resolution
  )
  case fileChanged(sessionID: String, path: String)
  case sessionDeleted(sessionID: String)

  var sessionID: String? {
    switch self {
    case .connection: return nil
    case let .messageUpdated(id, _), let .messageRemoved(id, _),
         let .partUpdated(id, _, _), let .partDelta(id, _, _, _, _),
         let .partRemoved(id, _, _), let .executionStateChanged(id, _),
         let .sessionFailed(id, _), let .fileChanged(id, _),
         let .sessionDeleted(id):
      return id
    case let .interactionAsked(interaction):
      return interaction.remoteSessionID
    case let .interactionResolved(id, _, _):
      return id
    }
  }
}

enum AgentClientError: LocalizedError, Equatable {
  case notInstalled
  case serverStartFailed(String)
  case startupTimedOut
  case processExited(Int32)
  case unauthorized
  case sessionNotFound
  case requestGone
  /// May or may not have been accepted: resolve by asking, never retry.
  case indeterminate(String)
  case transport(String)

  var errorDescription: String? {
    switch self {
    case .notInstalled:
      return "That agent is not installed."
    case let .serverStartFailed(detail):
      return "The agent could not start: \(detail)"
    case .startupTimedOut:
      return "The agent did not become ready in time."
    case let .processExited(code):
      return "The agent process exited (status \(code))."
    case .unauthorized:
      return "The agent rejected Boltty's credentials."
    case .sessionNotFound:
      return "This conversation is no longer on the agent's server."
    case .requestGone:
      return "That request is no longer open."
    case let .indeterminate(detail):
      return "Boltty could not confirm whether that was sent: \(detail)"
    case let .transport(detail):
      return detail
    }
  }
}
