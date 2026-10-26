import Foundation

#if DEBUG
final class FakeAgentClient: AgentClient, @unchecked Sendable {
  var provider = AgentId.opencode
  var capabilities: AgentCapabilities = [
    .modelSelection, .permissions, .questions, .attachments, .images,
    .interrupt, .resumeSession, .workingDirectory
  ]

  func usageLimits() async -> AgentUsage? { usage }
  func contextUsage(sessionID: String) async -> AgentContextUsage? { context }
  func compact(sessionID: String) async throws {
    lock.withLock { compacted.append(sessionID) }
  }
  func activityHistory() async -> AgentActivityHistory? { history }
  func steer(messageID: String, text: String, to sessionID: String) async throws {
    if let steerError { throw steerError }
    lock.withLock { steered.append((messageID, text, sessionID)) }
  }

  private let lock = NSLock()
  private var continuation: AsyncStream<AgentEventEnvelope>.Continuation?
  private var sequence = 0

  private(set) var createdSessions: [RemoteSessionInfo] = []
  private(set) var createdOptions: [AgentSessionOptions] = []
  private(set) var autoApprovalChanges: [(sessionID: String, enabled: Bool)] = []
  private(set) var sentMessages: [(id: String, text: String, sessionID: String)] = []
  private(set) var stopped: [String] = []
  private(set) var released: [String] = []
  private(set) var loadedSessions: [String] = []
  var isStreaming: Bool { lock.withLock { continuation != nil } }
  private(set) var questionReplies: [(requestID: String, answers: [[String]])] = []
  private(set) var permissionReplies: [(requestID: String, decision: PermissionDecision)] = []
  private(set) var permissionMessages: [String?] = []
  private(set) var planReplies: [(requestID: String, decision: PlanDecision, feedback: String?)] = []

  var availability: AgentAvailability = .available(version: "fake")
  var models: [AgentModelOption] = [
    AgentModelOption(
      selection: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"),
      isDefault: true
    )
  ]
  var usage: AgentUsage?
  var context: AgentContextUsage?
  private(set) var compacted: [String] = []
  var history: AgentActivityHistory?
  private(set) var steered: [(id: String, text: String, sessionID: String)] = []
  var steerError: AgentClientError?
  var createSessionError: AgentClientError?
  var sendError: AgentClientError?
  var sendErrorCount: Int?
  var sendHangs = false
  var modelsHang = false
  private var heldModelReads: [CheckedContinuation<Void, Never>] = []
  var existingMessages: Set<String> = []
  var existingMessagesAnswer: (@Sendable (String) -> Bool)?
  var existingMessagesError: AgentClientError?
  var permissionError: AgentClientError?
  var planError: AgentClientError?
  var questionError: AgentClientError?
  var snapshots: [String: RemoteSessionSnapshot] = [:]
  var loadSessionError: AgentClientError?
  var missedAnythingAnswer: Bool?

  func probe() async -> AgentAvailability { availability }

  func availableModels() async throws -> [AgentModelOption] {
    await withCheckedContinuation { continuation in
      let held = lock.withLock { () -> Bool in
        guard modelsHang else { return false }
        heldModelReads.append(continuation)
        return true
      }
      if !held { continuation.resume() }
    }
    return models
  }

  func releaseModels() {
    let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      modelsHang = false
      defer { heldModelReads.removeAll() }
      return heldModelReads
    }
    for continuation in held { continuation.resume() }
  }

  func createSession(
    id: String,
    options: AgentSessionOptions
  ) async throws -> RemoteSessionInfo {
    if let createSessionError { throw createSessionError }
    let info = RemoteSessionInfo(
      id: id, title: "Untitled", directory: options.directory, model: options.model
    )
    lock.withLock {
      createdSessions.append(info)
      createdOptions.append(options)
    }
    return info
  }

  func setAutoApproval(_ enabled: Bool, sessionID: String) async throws {
    lock.withLock { autoApprovalChanges.append((sessionID, enabled)) }
  }

  func missedAnything(sessionID: String) async -> Bool? { missedAnythingAnswer }

  func clearLoadedSessions() { lock.withLock { loadedSessions.removeAll() } }

  func loadSession(id: String) async throws -> RemoteSessionSnapshot {
    lock.withLock { loadedSessions.append(id) }
    if let loadSessionError { throw loadSessionError }
    guard let snapshot = snapshots[id] else { throw AgentClientError.sessionNotFound }
    return snapshot
  }

  func send(
    messageID: String,
    text: String,
    attachments: [OutgoingAttachment],
    to sessionID: String
  ) async throws {
    if let sendError, takeSendFailure() { throw sendError }
    if sendHangs { try await Task.sleep(nanoseconds: 60_000_000_000) }
    lock.withLock { sentMessages.append((messageID, text, sessionID)) }
    existingMessages.insert(messageID)
  }

  private func takeSendFailure() -> Bool {
    lock.withLock {
      guard let remaining = sendErrorCount else { return true }
      guard remaining > 0 else { return false }
      sendErrorCount = remaining - 1
      return true
    }
  }

  func messageExists(id: String, in sessionID: String) async throws -> Bool {
    if let existingMessagesError { throw existingMessagesError }
    if let existingMessagesAnswer { return existingMessagesAnswer(id) }
    return existingMessages.contains(id)
  }

  func stop(sessionID: String) async throws {
    lock.withLock { stopped.append(sessionID) }
  }

  func release(sessionID: String) async {
    lock.withLock { released.append(sessionID) }
  }

  func answerQuestion(requestID: String, sessionID: String, answers: [[String]]) async throws {
    if let questionError { throw questionError }
    lock.withLock { questionReplies.append((requestID, answers)) }
  }

  func rejectQuestion(requestID: String, sessionID: String) async throws {
    if let questionError { throw questionError }
    lock.withLock { questionReplies.append((requestID, [])) }
  }

  func answerPermission(
    requestID: String,
    sessionID: String,
    decision: PermissionDecision,
    message: String?
  ) async throws {
    if let permissionError { throw permissionError }
    lock.withLock {
      permissionReplies.append((requestID, decision))
      permissionMessages.append(message)
    }
  }

  func answerPlan(
    requestID: String,
    sessionID: String,
    decision: PlanDecision,
    feedback: String?
  ) async throws {
    if let planError { throw planError }
    lock.withLock { planReplies.append((requestID, decision, feedback)) }
  }

  func events() -> AsyncStream<AgentEventEnvelope> {
    AsyncStream { continuation in
      lock.withLock { self.continuation = continuation }
    }
  }

  func shutdown() async {
    lock.withLock { continuation?.finish() }
  }

  // MARK: - Driving it from a test

  func emit(_ event: AgentEvent, id: String? = nil, sequence explicit: Int? = nil) {
    let envelope = lock.withLock { () -> AgentEventEnvelope in
      self.sequence += 1
      return AgentEventEnvelope(
        id: id ?? "evt_\(self.sequence)",
        sequence: explicit ?? self.sequence,
        event: event
      )
    }
    continuation?.yield(envelope)
  }

  func streamReply(
    sessionID: String,
    messageID: String,
    partID: String = "prt_1",
    chunks: [String],
    finish: Bool = true
  ) {
    emit(.executionStateChanged(sessionID: sessionID, state: .working))
    emit(
      .messageUpdated(
        sessionID: sessionID,
        message: ConversationMessage(id: messageID, role: .agent, createdAt: Date())
      )
    )
    for chunk in chunks {
      emit(
        .partDelta(
          sessionID: sessionID,
          messageID: messageID,
          partID: partID,
          kind: .text,
          delta: chunk
        )
      )
    }
    guard finish else { return }
    emit(.executionStateChanged(sessionID: sessionID, state: .idle))
  }
}
#endif
