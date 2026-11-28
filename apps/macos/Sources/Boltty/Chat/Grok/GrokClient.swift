import Foundation
import os

struct ACPAgent: Sendable {
  let provider: AgentId
  let displayName: String
  var arguments: [String]
  let capabilities: AgentCapabilities
  var history: (@Sendable (String) throws -> DiskTranscript?)?
  var recordedName: (@Sendable (String) -> String?)? = nil
  var usage: (method: String, read: @Sendable (JSONObject) -> AgentUsage?)?
  var planMethod: String? = nil
  var askMethods: Set<String> = []
  var elicitMethods: Set<String> = []
  var alwaysApproveCommand = false
  var effortConfigID = "reasoning_effort"
  /// Set where the agent takes its model as a config option (`session/set_config_option`).
  var modelConfigID: String? = nil
  var modeID: @Sendable (AgentSessionOptions) -> String = { $0.planMode && !$0.readOnly ? "plan" : "default" }
  /// A plan the agent writes to a file rather than asks about; becomes the plan card when its turn ends.
  var planFile: (@Sendable (JSONObject) -> String?)? = nil

  static let grok = ACPAgent(
    provider: .grok,
    displayName: "Grok",
    arguments: ["--permission-mode", "default", "agent", "stdio"],
    capabilities: [
      .modelSelection, .modelSwitching, .permissions, .attachments, .images, .interrupt, .resumeSession,
      .workingDirectory, .reasoningEffort, .usageReporting,
      .rereadableTranscript, .usageLimits, .questions, .commands, .planMode, .computerUse,
    ],
    history: { try GrokChatHistoryTranscript.transcript(sessionID: $0) },
    recordedName: { GrokChatHistoryTranscript.recordedName(sessionID: $0) },
    usage: ("_x.ai/billing", { AgentUsage.grok($0) }),
    planMethod: "x.ai/exit_plan_mode",
    askMethods: ["x.ai/ask_user_question", "_x.ai/ask_user_question"],
    elicitMethods: ["x.ai/mcp/elicit", "_x.ai/mcp/elicit"],
    alwaysApproveCommand: true
  )

  /// Grok's Auto-review is a launch flag for the whole process, so its chats run in a second one.
  static let grokAutoReview: ACPAgent = {
    var agent = ACPAgent.grok
    agent.arguments = ["--permission-mode", "auto", "agent", "stdio"]
    return agent
  }()
}

final class ACPClient: AgentClient, @unchecked Sendable {
  let agent: ACPAgent
  var provider: AgentId { agent.provider }

  func chatTitle(sessionID: String, material: ChatNaming.Material) async -> String? {
    guard let read = agent.recordedName else { return nil }
    return await ChatNaming.fromRecord { read(sessionID) }
  }

  var capabilities: AgentCapabilities { agent.capabilities }

  private let log = Logger(subsystem: "com.boltty", category: "acp-client")
  private let lock = NSLock()
  private var process: JSONLineProcess?
  private var startTask: Task<JSONObject, Error>?
  private var readerTask: Task<Void, Never>?
  private var eventContinuation: AsyncStream<AgentEventEnvelope>.Continuation?
  private var pending: [Int: CheckedContinuation<JSONObject, Error>] = [:]
  private var rpcCounter = 0
  private var sessions: [String: LiveSession] = [:]
  private var commandsByFolder: [String: [AgentCommand]] = [:]
  private var commandsBySession: [String: [AgentCommand]] = [:]
  private var personalCommands: [AgentCommand] = []
  private var wantedOptions: [String: AgentSessionOptions] = [:]
  private var permissions: [String: PendingPermission] = [:]
  private var plans: [String: PendingPlan] = [:]
  private var asks: [String: PendingAsk] = [:]
  private var conversationResolver: (@Sendable (String) -> UUID?)?
  private let executableOverride: String?
  var idleExitDelay: TimeInterval = 600
  private var restToken: UUID?

  init(agent: ACPAgent = .grok, executable: String? = nil) {
    self.agent = agent
    executableOverride = executable
  }

  func setConversationResolver(_ resolve: @escaping @Sendable (String) -> UUID?) {
    lock.withLock { conversationResolver = resolve }
  }

  private final class LiveSession {
    let id: String
    var directory: String
    var model: ModelSelection?
    var effort: String?
    var pendingMessageID: String?
    var messages: [ConversationMessage] = []
    var textSegment = 0
    var planToolCalls: Set<String> = []
    var alwaysApproves: Bool?
    var planning = false
    var modeID = "default"
    var planFile: String?

    init(id: String, directory: String, model: ModelSelection?) {
      self.id = id
      self.directory = directory
      self.model = model
    }
  }

  private struct PendingPermission {
    let rpcID: Int
    let sessionID: String
    let optionsByDecision: [PermissionDecision: String]
    let rejectOptionID: String?
    var isElicitation = false
    var isPicture = false
  }

  private struct PendingPlan {
    let rpcID: Int
    let sessionID: String
  }

  private struct PendingAsk {
    let rpcID: Int
    let sessionID: String
    let parts: [(question: String, labels: [String], previews: [String: String], multiple: Bool)]
  }

  func probe() async -> AgentAvailability {
    guard locate() != nil else { return .notInstalled }
    do {
      let result = try await connect()
      _ = result
      guard let version = await version() else {
        return .unavailable("`\(provider.program)` is installed but did not answer `--version`.")
      }
      return .available(version: version)
    } catch {
      return .unavailable("`\(([provider.program] + agent.arguments).joined(separator: " "))` did not answer: \(error.localizedDescription)")
    }
  }

  func availableModels() async throws -> [AgentModelOption] {
    let initialized = try await connect()
    let models: JSONObject
    if let state = initialized.object("_meta")?.object("modelState"),
       !state.array("availableModels").isEmpty {
      models = state
    } else {
      let result = try await request("session/new", params: [
        "cwd": FileManager.default.currentDirectoryPath,
        "mcpServers": []
      ])
      guard let listed = result.object("models") else {
        throw AgentClientError.transport("\(agent.displayName) opened a session without a model list.")
      }
      models = listed
    }
    let current = models.string("currentModelId")
    let options = models.array("availableModels").compactMap { model -> AgentModelOption? in
      guard let id = model.string("modelId") else { return nil }
      return AgentModelOption(
        selection: ModelSelection(providerID: provider.rawValue, modelID: id),
        isDefault: id == current,
        effortOptions: Self.efforts(in: model)
      )
    }
    guard !options.isEmpty else {
      throw AgentClientError.transport("\(agent.displayName) listed no models.")
    }
    return options
  }

  func usageLimits() async -> AgentUsage? {
    guard let usage = agent.usage,
          (try? await connect()) != nil,
          let result = try? await request(usage.method, params: [:])
    else { return nil }
    return usage.read(result)
  }

  private static func efforts(in model: JSONObject) -> [AgentEffortOption] {
    model.object("_meta")?.array("reasoningEfforts").compactMap { effort in
      guard let value = effort.string("value") ?? effort.string("id") else { return nil }
      return AgentEffortOption(
        value: value,
        label: effort.string("label"),
        detail: effort.string("description")
      )
    } ?? []
  }

  func createSession(id: String, options: AgentSessionOptions) async throws -> RemoteSessionInfo {
    _ = try await connect()
    let result = try await request("session/new", params: [
      "cwd": options.directory,
      "mcpServers": ComputerUseServer.acpServers(options.computerUseSocket)
    ])
    guard let sessionID = result.string("sessionId") else {
      throw AgentClientError.transport("\(agent.displayName) did not return a session id.")
    }

    let session = LiveSession(id: sessionID, directory: options.directory, model: options.model)
    session.effort = options.effort
    lock.withLock {
      sessions[sessionID] = session
      wantedOptions[sessionID] = options
    }
    await applyLeniently(model: options.model, effort: options.effort, to: sessionID)
    if agent.modeID(options) != "default" { try? await set(mode: agent.modeID(options), on: sessionID) }
    try? await set(alwaysApproving: Self.alwaysApproves(options), on: sessionID)

    return RemoteSessionInfo(
      id: sessionID,
      title: provider.shortDisplayName,
      directory: options.directory,
      model: options.model
    )
  }

  private func applyLeniently(model: ModelSelection?, effort: String?, to sessionID: String) async {
    if let model { try? await set(model: model, on: sessionID) }
    if let effort { try? await set(effort: effort, on: sessionID) }
  }

  private func set(model: ModelSelection, on sessionID: String) async throws {
    if let config = agent.modelConfigID {
      _ = try await request("session/set_config_option", params: [
        "sessionId": sessionID, "configId": config, "value": model.modelID
      ])
      return
    }
    _ = try await request("session/set_model", params: [
      "sessionId": sessionID, "modelId": model.modelID
    ])
  }

  private func set(mode: String, on sessionID: String) async throws {
    _ = try await request("session/set_mode", params: ["sessionId": sessionID, "modeId": mode])
    lock.withLock {
      sessions[sessionID]?.modeID = mode
      sessions[sessionID]?.planning = mode == "plan"
    }
  }

  static let alwaysApproveMode = "alwaysApprove"

  static func alwaysApproves(_ options: AgentSessionOptions) -> Bool {
    options.permissionMode == alwaysApproveMode && !options.readOnly
  }

  /// Grok's `/always-approve` is a command of the session it is sent to: no model
  /// turn, and other sessions in the process still ask.
  private func set(alwaysApproving: Bool, on sessionID: String) async throws {
    guard agent.alwaysApproveCommand,
          lock.withLock({ sessions[sessionID]?.alwaysApproves }) != alwaysApproving
    else { return }
    _ = try await request("session/prompt", params: [
      "sessionId": sessionID,
      "prompt": [["type": "text", "text": "/always-approve " + (alwaysApproving ? "on" : "off")]],
    ])
    lock.withLock { sessions[sessionID]?.alwaysApproves = alwaysApproving }
  }

  private func set(effort: String, on sessionID: String) async throws {
    _ = try await request("session/set_config_option", params: [
      "sessionId": sessionID, "configId": agent.effortConfigID, "value": effort
    ])
  }

  func prepareSession(_ id: String, options: AgentSessionOptions) async throws {
    lock.withLock {
      if wantedOptions[id]?.computerUseSocket != options.computerUseSocket, sessions[id]?.pendingMessageID == nil {
        sessions[id] = nil
      }
      wantedOptions[id] = options
    }
    _ = try await connect()
    try await ensureLoaded(id)
    let current = lock.withLock { () -> (model: ModelSelection?, effort: String?, mode: String) in
      let session = sessions[id]
      defer {
        session?.directory = options.directory
      }
      return (session?.model, session?.effort, session?.modeID ?? "default")
    }
    if agent.modeID(options) != current.mode {
      try await set(mode: agent.modeID(options), on: id)
    }
    if let model = options.model, model.modelID != current.model?.modelID {
      try await set(model: model, on: id)
      lock.withLock { sessions[id]?.model = model }
    }
    if let effort = options.effort, effort != current.effort {
      try await set(effort: effort, on: id)
    }
    lock.withLock { sessions[id]?.effort = options.effort }
    try await set(alwaysApproving: Self.alwaysApproves(options), on: id)
  }

  func setPermissionMode(_ mode: String?, sessionID: String) async throws {
    lock.withLock { wantedOptions[sessionID]?.permissionMode = mode }
  }

  func loadSession(id: String) async throws -> RemoteSessionSnapshot {
    let live = lock.withLock { sessions[id] }
    let state: ConversationExecutionState = live?.pendingMessageID == nil ? .idle : .working
    let found: DiskTranscript?
    do {
      found = try agent.history?(id)
    } catch {
      throw AgentClientError.transport(String(describing: error))
    }
    if let disk = found {
      return RemoteSessionSnapshot(
        info: RemoteSessionInfo(
          id: id,
          title: disk.title ?? provider.shortDisplayName,
          directory: live?.directory ?? disk.directory ?? NSHomeDirectory(),
          model: live?.model
        ),
        messages: disk.messages,
        state: state,
        openInteractions: []
      )
    }
    if agent.history != nil, live == nil { throw AgentClientError.sessionNotFound }
    if live == nil { try await ensureLoaded(id) }
    let session = lock.withLock { sessions[id] } ?? LiveSession(
      id: id, directory: FileManager.default.currentDirectoryPath, model: nil
    )
    return RemoteSessionSnapshot(
      info: RemoteSessionInfo(
        id: session.id,
        title: provider.shortDisplayName,
        directory: session.directory,
        model: session.model
      ),
      messages: session.messages,
      state: state,
      openInteractions: []
    )
  }

  private func ensureLoaded(_ id: String) async throws {
    guard lock.withLock({ sessions[id] }) == nil else { return }
    let wanted = lock.withLock { wantedOptions[id] }
    let directory = wanted?.directory ?? FileManager.default.currentDirectoryPath
    do {
      _ = try await request("session/load", params: [
        "sessionId": id, "cwd": directory, "mcpServers": ComputerUseServer.acpServers(wanted?.computerUseSocket)
      ])
    } catch {
      log.debug("session/load refused \(id, privacy: .public): \(String(describing: error), privacy: .public)")
      throw AgentClientError.sessionNotFound
    }
    lock.withLock {
      if sessions[id] == nil {
        let session = LiveSession(id: id, directory: directory, model: wanted?.model)
        session.effort = wanted?.effort
        sessions[id] = session
      }
    }
    await applyLeniently(model: wanted?.model, effort: wanted?.effort, to: id)
    // A process let go at rest forgets the session's mode with it.
    if let wanted {
      if agent.modeID(wanted) != "default" { try? await set(mode: agent.modeID(wanted), on: id) }
      if Self.alwaysApproves(wanted) { try? await set(alwaysApproving: true, on: id) }
    }
  }

  func messageExists(id: String, in sessionID: String) async throws -> Bool {
    lock.withLock { sessions[sessionID]?.messages.contains { $0.id == id } ?? false }
  }

  static func promptBlocks(text: String, attachments: [OutgoingAttachment]) -> [[String: Any]] {
    var blocks: [[String: Any]] = []
    if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
    for attachment in attachments {
      let mime = attachment.mimeType ?? MIMEType.guess(for: attachment.url) ?? ""
      if mime.hasPrefix("image/"), let data = try? Data(contentsOf: attachment.url) {
        blocks.append(["type": "image", "mimeType": mime, "data": data.base64EncodedString()])
      } else {
        blocks.append(["type": "text", "text": "Attached file: \(attachment.url.path)"])
      }
    }
    return blocks
  }

  func send(
    messageID: String,
    text: String,
    attachments: [OutgoingAttachment],
    to sessionID: String
  ) async throws {
    _ = try await connect()
    try await ensureLoaded(sessionID)
    guard lock.withLock({ sessions[sessionID] }) != nil else {
      throw AgentClientError.sessionNotFound
    }

    lock.withLock {
      sessions[sessionID]?.pendingMessageID = messageID
      sessions[sessionID]?.textSegment = 0
      sessions[sessionID]?.messages.append(
        ConversationMessage(id: messageID, role: .user, createdAt: Date(), parts: [
          .text(TextPart(id: "\(messageID)-text", kind: .text, text: text))
        ])
      )
    }
    emit(.executionStateChanged(sessionID: sessionID, state: .working))

    Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await self.request("session/prompt", params: [
          "sessionId": sessionID,
          "prompt": Self.promptBlocks(text: text, attachments: attachments)
        ], deadline: nil)
        self.finishTurn(sessionID: sessionID, stopReason: result.string("stopReason"))
      } catch {
        self.emit(.sessionFailed(sessionID: sessionID, failure: MessageFailure(
          name: "\(agent.displayName)TurnError",
          message: error.localizedDescription
        )))
        self.finishTurn(sessionID: sessionID, stopReason: nil)
      }
    }
  }

  private func finishTurn(sessionID: String, stopReason: String?) {
    let planFile = lock.withLock { () -> String? in
      defer { sessions[sessionID]?.planFile = nil }
      return sessions[sessionID]?.planning == true ? sessions[sessionID]?.planFile : nil
    }
    if stopReason == "end_turn", let planFile,
       let markdown = try? String(contentsOfFile: planFile, encoding: .utf8),
       !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let conversationID = lock.withLock({ conversationResolver })?(sessionID) {
      emit(.interactionAsked(PendingInteraction(
        id: "plan-\(UUID().uuidString)", conversationID: conversationID, remoteSessionID: sessionID,
        kind: .plan(PlanPrompt(markdown: markdown, toolCallID: nil, endedTurn: true, answers: [.proceed]))
      )))
    }
    let reply: ConversationMessage? = lock.withLock {
      guard let session = sessions[sessionID], let messageID = session.pendingMessageID
      else { return nil }
      session.pendingMessageID = nil
      let replyID = "\(messageID)-reply"
      guard let index = session.messages.firstIndex(where: { $0.id == replyID }) else { return nil }
      session.messages[index].completedAt = Date()
      return session.messages[index]
    }
    if let reply {
      emit(.messageUpdated(sessionID: sessionID, message: reply))
    }
    emit(.executionStateChanged(sessionID: sessionID, state: .idle))
  }

  func stop(sessionID: String) async throws {
    notify("session/cancel", params: ["sessionId": sessionID])
  }

  func answerQuestion(requestID: String, sessionID: String, answers: [[String]]) async throws {
    guard let ask = lock.withLock({ asks.removeValue(forKey: requestID) }) else {
      throw AgentClientError.requestGone
    }
    respond(to: ask.rpcID, result: Self.askResult(ask.parts, answers: answers))
  }

  func rejectQuestion(requestID: String, sessionID: String) async throws {
    guard let ask = lock.withLock({ asks.removeValue(forKey: requestID) }) else {
      throw AgentClientError.requestGone
    }
    respond(to: ask.rpcID, result: ["outcome": "cancelled"])
  }

  static func askResult(
    _ parts: [(question: String, labels: [String], previews: [String: String], multiple: Bool)],
    answers: [[String]]
  ) -> [String: Any] {
    var chosen: [String: [String]] = [:]
    var annotations: [String: [String: String]] = [:]
    for (index, part) in parts.enumerated() {
      let values = (index < answers.count ? answers[index] : [])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      guard !values.isEmpty else { continue }
      let labels = values.filter(part.labels.contains)
      let notes = values.filter { !part.labels.contains($0) }
      chosen[part.question] = labels.isEmpty ? ["Other"] : labels
      var annotation: [String: String] = [:]
      if !part.multiple, let preview = labels.compactMap({ part.previews[$0] }).first { annotation["preview"] = preview }
      if !notes.isEmpty { annotation["notes"] = notes.joined(separator: "\n") }
      if !annotation.isEmpty { annotations[part.question] = annotation }
    }
    var result: [String: Any] = ["outcome": "accepted", "answers": chosen]
    if !annotations.isEmpty { result["annotations"] = annotations }
    return result
  }

  func answerPermission(
    requestID: String,
    sessionID: String,
    decision: PermissionDecision,
    message: String?
  ) async throws {
    guard let waiting = lock.withLock({ permissions[requestID] }) else {
      throw AgentClientError.requestGone
    }
    let option = waiting.isElicitation ? nil : Self.option(for: decision, among: waiting.optionsByDecision)
    guard waiting.isElicitation || option != nil else {
      throw AgentClientError.transport("\(agent.displayName) offered no option for that answer.")
    }
    guard lock.withLock({ permissions.removeValue(forKey: requestID) }) != nil else {
      throw AgentClientError.requestGone
    }
    if waiting.isElicitation {
      respond(to: waiting.rpcID, result: Self.elicitationResult(decision))
      emit(.interactionResolved(
        sessionID: sessionID, requestID: requestID, resolution: .permission(decision)))
      return
    }
    respond(to: waiting.rpcID, result: [
      "outcome": ["outcome": "selected", "optionId": option ?? ""]
    ])
    emit(.interactionResolved(
      sessionID: sessionID,
      requestID: requestID,
      resolution: .permission(decision)
    ))
  }

  func answerPlan(
    requestID: String,
    sessionID: String,
    decision: PlanDecision,
    feedback: String?
  ) async throws {
    guard let waiting = lock.withLock({ plans[requestID] }) else {
      throw AgentClientError.requestGone
    }
    try deliver(to: waiting.rpcID, result: Self.planResult(decision, feedback: feedback))
    lock.withLock { _ = plans.removeValue(forKey: requestID) }
    if decision == .approved, var options = lock.withLock({ wantedOptions[sessionID] }),
       lock.withLock({ sessions[sessionID]?.planning ?? false }) {
      options.planMode = false
      lock.withLock { wantedOptions[sessionID] = options }
      try? await set(mode: agent.modeID(options), on: sessionID)
    }
    emit(.interactionResolved(
      sessionID: sessionID,
      requestID: requestID,
      resolution: .plan(decision)
    ))
  }

  static func option(
    for decision: PermissionDecision, among offered: [PermissionDecision: String]
  ) -> String? {
    offered[decision]
  }

  static func elicitationResult(_ decision: PermissionDecision) -> [String: Any] {
    decision == .reject ? ["outcome": "decline"] : ["outcome": "accept", "content": [String: Any]()]
  }

  static func planResult(_ decision: PlanDecision, feedback: String?) -> [String: Any] {
    var result: [String: Any] = ["outcome": decision.rawValue]
    let words = feedback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if decision == .cancelled, !words.isEmpty { result["feedback"] = words }
    return result
  }

  func events() -> AsyncStream<AgentEventEnvelope> {
    AsyncStream { continuation in
      lock.withLock { self.eventContinuation = continuation }
    }
  }

  func shutdown() async {
    let (task, process) = lock.withLock { (readerTask, self.process) }
    task?.cancel()
    process?.closeInput()
    process?.terminate()
    lock.withLock {
      self.process = nil
      self.startTask = nil
      self.readerTask = nil
      sessions.removeAll()
      permissions.removeAll()
      plans.removeAll()
    }
  }

  func restartIdleProcess() async { await shutdown() }

  func release(sessionID: String) async {
    lock.withLock {
      sessions[sessionID] = nil
      wantedOptions[sessionID] = nil
    }
  }

  @discardableResult
  private func connect() async throws -> JSONObject {
    let task = lock.withLock { () -> Task<JSONObject, Error> in
      if let startTask { return startTask }
      let task = Task { try await self.launch() }
      startTask = task
      return task
    }
    do {
      return try await task.value
    } catch {
      lock.withLock { startTask = nil }
      throw error
    }
  }

  private func launch() async throws -> JSONObject {
    guard let executable = locate() else { throw AgentClientError.notInstalled }

    let process = JSONLineProcess(
      executable: executable,
      arguments: agent.arguments,
      category: agent.provider.rawValue
    )
    process.onExit = { [weak self, weak process] status, stderr in
      guard let self else { return }
      self.lock.withLock {
        if let process, self.process === process {
          self.process = nil
          self.startTask = nil
        }
      }
      self.failPending(with: AgentClientError.serverStartFailed(
        JSONLineProcess.exitDetail(status: status, stderr: stderr)
      ))
    }
    try process.start()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.read(process)
    }
    lock.withLock {
      self.process = process
      self.readerTask = task
    }

    let answer = try await request("initialize", params: [
      "protocolVersion": 1,
      "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]]
    ])
    scheduleRest()
    return answer
  }

  private func scheduleRest() {
    let token = UUID()
    lock.withLock { restToken = token }
    let delay = idleExitDelay
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      await self?.restIfUnused(token)
    }
  }

  private func restIfUnused(_ token: UUID) async {
    let unused = lock.withLock {
      restToken == token && process != nil && pending.isEmpty && permissions.isEmpty
        && plans.isEmpty && asks.isEmpty && !sessions.values.contains { $0.pendingMessageID != nil }
    }
    guard unused else { return }
    log.debug("letting the idle \(self.provider.rawValue, privacy: .public) process go")
    await shutdown()
  }

  private func read(_ process: JSONLineProcess) async {
    for await line in process.lines {
      guard let frame = JSONObject(line: line) else { continue }
      if let id = frame.int("id"), frame["method"] == nil {
        resolve(id: id, frame: frame)
      } else if let method = frame.string("method") {
        if let id = frame.int("id") {
          handleRequest(method, id: id, params: frame.object("params") ?? JSONObject([:]))
        } else {
          handleNotification(method, params: frame.object("params") ?? JSONObject([:]))
        }
      }
    }
    let asked = lock.withLock { () -> [(sessionID: String, requestID: String)]? in
      guard self.process == nil || self.process === process else { return nil }
      let asked = permissions.map { ($0.value.sessionID, $0.key) }
        + plans.map { ($0.value.sessionID, $0.key) }
        + asks.map { ($0.value.sessionID, $0.key) }
      permissions.removeAll()
      plans.removeAll()
      asks.removeAll()
      sessions.removeAll()
      return asked
    }
    guard let asked else { return }
    for ask in asked {
      emit(.interactionResolved(sessionID: ask.sessionID, requestID: ask.requestID, resolution: .expired))
    }
    failPending(with: AgentClientError.transport("\(agent.displayName) stopped responding."))
    emit(.connection(.offline))
  }

  private func failPending(with error: Error) {
    let waiting = lock.withLock { () -> [CheckedContinuation<JSONObject, Error>] in
      let values = Array(pending.values)
      pending.removeAll()
      return values
    }
    for continuation in waiting { continuation.resume(throwing: error) }
  }

  private func resolve(id: Int, frame: JSONObject) {
    guard let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
    if let error = frame.object("error") {
      continuation.resume(throwing: AgentClientError.transport(
        error.string("message") ?? "\(agent.displayName) refused the call."
      ))
    } else {
      continuation.resume(returning: frame.object("result") ?? JSONObject([:]))
    }
  }

  private func handleRequest(_ method: String, id: Int, params: JSONObject) {
    if let planMethod = agent.planMethod, method == planMethod || method == "_" + planMethod {
      return handlePlan(id: id, params: params)
    }
    if agent.askMethods.contains(method) {
      return handleAsk(id: id, params: params)
    }
    if agent.elicitMethods.contains(method) {
      return handleElicitation(id: id, params: params)
    }
    guard method == "session/request_permission" else {
      // Answer -32601, never an empty result: the agent waits on it, and empty reads as success.
      respond(to: id, errorCode: -32601, message: "Boltty does not implement \(method).")
      return
    }
    guard let sessionID = params.string("sessionId") else {
      return respond(to: id, errorCode: -32602, message: "A permission request names its session.")
    }

    let options = params.array("options")
    var byDecision: [PermissionDecision: String] = [:]
    var reject: String?
    for option in options {
      guard let optionID = option.string("optionId") else { continue }
      switch option.string("kind") {
      case "allow_once": byDecision[.once] = optionID
      case "allow_always": byDecision[.always] = optionID
      case "reject_once":
        byDecision[.reject] = optionID
        reject = optionID
      case "reject_always":
        byDecision[.rejectAlways] = optionID
        if reject == nil { reject = optionID }
      default: continue
      }
    }

    let isPicture = Self.makesPicture(params.object("toolCall"))

    let requestID = params.object("toolCall")?.string("toolCallId") ?? UUID().uuidString
    lock.withLock {
      permissions[requestID] = PendingPermission(
        rpcID: id,
        sessionID: sessionID,
        optionsByDecision: byDecision,
        rejectOptionID: reject,
        isPicture: isPicture
      )
    }

    guard let conversationID = lock.withLock({ conversationResolver })?(sessionID) else {
      if let reject { respond(to: id, result: ["outcome": ["outcome": "selected", "optionId": reject]]) }
      lock.withLock { _ = permissions.removeValue(forKey: requestID) }
      return
    }
    let tool = params.object("toolCall")
    let asked = Self.permissionSubject(of: tool)
    emit(.interactionAsked(PendingInteraction(
      id: requestID,
      conversationID: conversationID,
      remoteSessionID: sessionID,
      kind: .permission(PermissionPrompt(
        action: asked.action,
        resources: asked.resources,
        savePatterns: [],
        toolCallID: tool?.string("toolCallId"),
        offersAlways: byDecision[.always] != nil,
        alwaysReach: byDecision[.always] == nil ? nil : Self.alwaysReach(of: tool),
        offersRejectAlways: byDecision[.rejectAlways] != nil
      ))
    )))
  }

  /// Measured on 1.0.92: whatever its label says, Grok's "always" remembers that exact
  /// command, in every Grok chat, past a restart of the process.
  static func alwaysReach(of tool: JSONObject?) -> String {
    guard let command = tool?.object("rawInput")?.string("command"), !command.isEmpty else {
      return String(localized: "every Grok chat")
    }
    return String(localized: "every Grok chat, for \(command)")
  }

  static func makesPicture(_ tool: JSONObject?) -> Bool {
    let name = tool?.object("_meta")?.object("x.ai/tool")?.string("name")
    return name == "image_gen" || name == "image_edit"
  }

  static func permissionSubject(of tool: JSONObject?) -> (action: String, resources: [String]) {
    let command = tool?.object("rawInput")?.string("command")
    let paths = (tool?.array("locations") ?? []).compactMap { $0.string("path") }
    let title = tool?.string("title")
    let kind = tool?.string("kind")
    let label = tool?.object("_meta")?.object("x.ai/tool")?.string("label")
    let action = (kind == "other" ? label : nil) ?? kind ?? (command == nil ? title : "execute") ?? "run a tool"
    if let command { return (action, [command]) }
    if !paths.isEmpty { return (action, paths) }
    if let title, title != action { return (action, [title]) }
    return (action, [])
  }

  private func handleAsk(id: Int, params outer: JSONObject) {
    let params = outer.object("params").flatMap { $0.raw["questions"] != nil ? $0 : nil } ?? outer
    guard let sessionID = params.string("sessionId") else {
      return respond(to: id, errorCode: -32602, message: "A question names its session.")
    }
    guard let conversationID = lock.withLock({ conversationResolver })?(sessionID) else {
      return respond(to: id, result: ["outcome": "cancelled"])
    }
    let questions = params.array("questions")
    var parts: [(question: String, labels: [String], previews: [String: String], multiple: Bool)] = []
    var items: [QuestionItem] = []
    for question in questions {
      let text = question.string("question") ?? ""
      var options = question.array("options")
      if options.isEmpty { options = [JSONObject(["label": "OK", "description": "Continue"])] }
      let labels = options.compactMap { $0.string("label") }
      var previews: [String: String] = [:]
      for option in options {
        if let label = option.string("label"), let preview = option.string("preview") { previews[label] = preview }
      }
      let multiple = question.bool("multiSelect") ?? false
      parts.append((text, labels, previews, multiple))
      items.append(QuestionItem(
        key: question.string("id"),
        header: "",
        question: text,
        choices: options.compactMap { option in
          guard let label = option.string("label") else { return nil }
          return AgentChoice(value: label, label: label, detail: option.string("description"))
        },
        allowsMultiple: multiple,
        allowsCustom: true
      ))
    }
    let requestID = params.string("toolCallId") ?? UUID().uuidString
    lock.withLock { asks[requestID] = PendingAsk(rpcID: id, sessionID: sessionID, parts: parts) }
    emit(.interactionAsked(PendingInteraction(
      id: requestID,
      conversationID: conversationID,
      remoteSessionID: sessionID,
      kind: .question(QuestionPrompt(items: items, toolCallID: params.string("toolCallId")))
    )))
  }

  private func handleElicitation(id: Int, params: JSONObject) {
    let toolCallID = params.string("toolCallId")
    guard let sessionID = params.string("sessionId"),
          let conversationID = lock.withLock({ conversationResolver })?(sessionID),
          let prompt = PermissionPrompt.elicitation(
            server: params.string("serverName") ?? "MCP", mode: params.string("mode"),
            message: params.string("message"), schema: params.object("requestedSchema"), toolCallID: toolCallID)
    else { return respond(to: id, result: ["outcome": "decline"]) }
    let requestID = toolCallID ?? UUID().uuidString
    lock.withLock {
      permissions[requestID] = PendingPermission(
        rpcID: id, sessionID: sessionID, optionsByDecision: [:], rejectOptionID: nil, isElicitation: true)
    }
    emit(.interactionAsked(PendingInteraction(
      id: requestID, conversationID: conversationID, remoteSessionID: sessionID, kind: .permission(prompt)
    )))
  }

  private func handlePlan(id: Int, params: JSONObject) {
    guard let sessionID = params.string("sessionId") else {
      return respond(to: id, errorCode: -32602, message: "A plan names its session.")
    }
    let toolCallID = params.string("toolCallId")
    let markdown = params.string("planContent") ?? ""
    guard let conversationID = lock.withLock({ conversationResolver })?(sessionID) else {
      return respond(to: id, result: Self.planResult(.abandoned, feedback: nil))
    }
    let requestID = toolCallID ?? UUID().uuidString
    lock.withLock { plans[requestID] = PendingPlan(rpcID: id, sessionID: sessionID) }
    writePlan(markdown, toolCallID: toolCallID, in: sessionID)
    emit(.interactionAsked(PendingInteraction(
      id: requestID,
      conversationID: conversationID,
      remoteSessionID: sessionID,
      kind: .plan(PlanPrompt(markdown: markdown, toolCallID: toolCallID, answers: [.approve, .requestChanges, .quit]))
    )))
  }

  private func writePlan(_ markdown: String, toolCallID: String?, in sessionID: String) {
    guard let messageID = lock.withLock({ sessions[sessionID]?.pendingMessageID }) else { return }
    let replyID = "\(messageID)-reply"
    if let toolCallID {
      lock.withLock { _ = sessions[sessionID]?.planToolCalls.insert(toolCallID) }
      let rowID = "\(replyID)-\(toolCallID)"
      let hadRow: Bool = lock.withLock {
        guard let session = sessions[sessionID],
              let index = session.messages.firstIndex(where: { $0.id == replyID }),
              session.messages[index].parts.contains(where: { $0.id == rowID }) else { return false }
        session.messages[index].removePart(id: rowID)
        return true
      }
      if hadRow { emit(.partRemoved(sessionID: sessionID, messageID: replyID, partID: rowID)) }
    }
    guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let part = ConversationPart.text(TextPart(
      id: "\(replyID)-plan-\(toolCallID ?? UUID().uuidString)", kind: .text, text: markdown
    ))
    upsert(part, in: sessionID, replyID: replyID)
    lock.withLock { sessions[sessionID]?.textSegment += 1 }
    emit(.partUpdated(sessionID: sessionID, messageID: replyID, part: part))
  }

  private func isPlanTool(_ update: JSONObject, id toolID: String, in sessionID: String) -> Bool {
    guard agent.planMethod != nil else { return false }
    if lock.withLock({ sessions[sessionID]?.planToolCalls.contains(toolID) ?? false }) { return true }
    let isPlan = update.object("_meta")?.object("x.ai/tool")?.string("kind") == "exit_plan"
      || update.string("title") == "exit_plan_mode"
    if isPlan { lock.withLock { _ = sessions[sessionID]?.planToolCalls.insert(toolID) } }
    return isPlan
  }

  func commands(folder: String) async -> [AgentCommand] {
    lock.withLock {
      if let known = commandsByFolder[folder] { return known }
      for (id, session) in sessions where session.directory == folder {
        if let listed = commandsBySession[id] { return listed }
      }
      return personalCommands
    }
  }

  static func commands(in listed: [JSONObject]) -> (all: [AgentCommand], personal: [AgentCommand]) {
    var all: [AgentCommand] = []
    var personal: [AgentCommand] = []
    var seen = Set<String>()
    for entry in listed {
      guard let meta = entry.object("_meta"), meta.string("path") != nil,
            let name = entry.string("name"), seen.insert(name).inserted
      else { continue }
      let hint = entry.object("input")?.string("hint")
      let command = AgentCommand(name: name, summary: entry.string("description") ?? "", argumentHint: hint)
      all.append(command)
      if meta.string("scope") != "project" { personal.append(command) }
    }
    return (all, personal)
  }

  private func rememberCommands(_ listed: [JSONObject], of sessionID: String) {
    let found = Self.commands(in: listed)
    // It can come before `session/new` answers and the session is known here.
    lock.withLock {
      commandsBySession[sessionID] = found.all
      personalCommands = found.personal
      if let folder = sessions[sessionID]?.directory { commandsByFolder[folder] = found.all }
    }
  }

  private func handleNotification(_ method: String, params: JSONObject) {
    guard method == "session/update" else { return }
    guard let sessionID = params.string("sessionId"),
          let update = params.object("update") else { return }

    if update.string("sessionUpdate") == "current_mode_update" {
      let mode = update.string("currentModeId") ?? "default"
      lock.withLock {
        sessions[sessionID]?.modeID = mode
        sessions[sessionID]?.planning = mode == "plan"
      }
      return
    }
    if update.string("sessionUpdate") == "available_commands_update" {
      rememberCommands(update.array("availableCommands"), of: sessionID)
      return
    }

    let messageID = lock.withLock { sessions[sessionID]?.pendingMessageID }
    guard let messageID else { return }
    let replyID = "\(messageID)-reply"

    switch update.string("sessionUpdate") {
    case "agent_message_chunk":
      appendDelta(update, to: sessionID, replyID: replyID, kind: .text)
    case "agent_thought_chunk":
      appendDelta(update, to: sessionID, replyID: replyID, kind: .reasoning)
    case "tool_call", "tool_call_update":
      guard let toolID = update.string("toolCallId"),
            !isPlanTool(update, id: toolID, in: sessionID) else { return }
      let state: AgentActivity.State = switch update.string("status") {
      case "completed": .completed
      case "failed": .failed
      default: .running
      }
      if let path = update.object("rawInput").flatMap({ agent.planFile?($0) }) {
        lock.withLock { sessions[sessionID]?.planFile = path }
      }
      let id = "\(replyID)-\(toolID)"
      let known = lock.withLock { () -> AgentActivity? in
        guard let parts = sessions[sessionID]?.messages.first(where: { $0.id == replyID })?.parts else { return nil }
        for case let .activity(activity) in parts where activity.id == id { return activity }
        return nil
      }
      let activity = AgentActivity(
        id: id,
        name: update.string("title") ?? known?.name ?? update.string("kind") ?? "tool",
        summary: update.string("kind") ?? known?.summary,
        state: state
      )
      upsert(.activity(activity), in: sessionID, replyID: replyID)
      emit(.partUpdated(sessionID: sessionID, messageID: replyID, part: .activity(activity)))
    default:
      return
    }
  }

  private func appendDelta(
    _ update: JSONObject,
    to sessionID: String,
    replyID: String,
    kind: ConversationPart.TextKind
  ) {
    guard let delta = update.object("content")?.string("text"), !delta.isEmpty else { return }
    let segment = lock.withLock { sessions[sessionID]?.textSegment ?? 0 }
    let partID = "\(replyID)-\(kind.rawValue)" + (segment > 0 ? "-\(segment)" : "")
    let created = ensureReply(in: sessionID, replyID: replyID)
    lock.withLock {
      guard let session = sessions[sessionID],
            let index = session.messages.firstIndex(where: { $0.id == replyID }) else { return }
      session.messages[index].appendDelta(delta, toPart: partID, kind: kind)
    }
    if let created { emit(.messageUpdated(sessionID: sessionID, message: created)) }
    emit(.partDelta(
      sessionID: sessionID,
      messageID: replyID,
      partID: partID,
      kind: kind,
      delta: delta
    ))
  }

  private func upsert(_ part: ConversationPart, in sessionID: String, replyID: String) {
    let created = ensureReply(in: sessionID, replyID: replyID)
    lock.withLock {
      guard let session = sessions[sessionID],
            let index = session.messages.firstIndex(where: { $0.id == replyID }) else { return }
      session.messages[index].upsert(part)
    }
    if let created { emit(.messageUpdated(sessionID: sessionID, message: created)) }
  }

  private func ensureReply(in sessionID: String, replyID: String) -> ConversationMessage? {
    lock.withLock {
      guard let session = sessions[sessionID] else { return nil }
      if session.messages.contains(where: { $0.id == replyID }) { return nil }
      let reply = ConversationMessage(id: replyID, role: .agent, createdAt: Date(), parts: [])
      session.messages.append(reply)
      return reply
    }
  }

  static let requestDeadline: TimeInterval = 120

  private func request(
    _ method: String,
    params: [String: Any],
    deadline: TimeInterval? = requestDeadline
  ) async throws -> JSONObject {
    let id: Int = lock.withLock {
      rpcCounter += 1
      return rpcCounter
    }
    guard let line = JSONObject.encode([
      "jsonrpc": "2.0", "id": id, "method": method, "params": params
    ]) else {
      throw AgentClientError.transport(String(localized: "That call could not be encoded."))
    }
    return try await withCheckedThrowingContinuation { continuation in
      lock.withLock { pending[id] = continuation }
      do {
        guard let process = lock.withLock({ process }) else {
          throw AgentClientError.transport("\(agent.displayName) is not running.")
        }
        try process.writeLine(line)
      } catch {
        lock.withLock { _ = pending.removeValue(forKey: id) }
        continuation.resume(throwing: error)
        return
      }
      guard let deadline else { return }
      let name = agent.displayName
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) { [weak self] in
        guard let waiting = self?.lock.withLock({ self?.pending.removeValue(forKey: id) }) else { return }
        waiting.resume(throwing: AgentClientError.transport("\(name) did not answer \(method) in time."))
      }
    }
  }

  private func notify(_ method: String, params: [String: Any]) {
    guard let line = JSONObject.encode(["jsonrpc": "2.0", "method": method, "params": params])
    else { return }
    try? lock.withLock({ process })?.writeLine(line)
  }

  private func respond(to id: Int, result: [String: Any]) {
    guard let line = JSONObject.encode(["jsonrpc": "2.0", "id": id, "result": result])
    else { return }
    try? lock.withLock({ process })?.writeLine(line)
  }

  private func deliver(to id: Int, result: [String: Any]) throws {
    guard let line = JSONObject.encode(["jsonrpc": "2.0", "id": id, "result": result]) else {
      throw AgentClientError.transport(String(localized: "That answer could not be encoded."))
    }
    guard let process = lock.withLock({ process }) else {
      throw AgentClientError.transport("\(agent.displayName) stopped responding.")
    }
    try process.writeLine(line)
  }

  private func respond(to id: Int, errorCode: Int, message: String) {
    guard let line = JSONObject.encode([
      "jsonrpc": "2.0", "id": id, "error": ["code": errorCode, "message": message]
    ]) else { return }
    try? lock.withLock({ process })?.writeLine(line)
  }

  private func emit(_ event: AgentEvent) {
    let continuation = lock.withLock { eventContinuation }
    continuation?.yield(
      AgentEventEnvelope(providerID: provider.rawValue, id: nil, sequence: nil, event: event)
    )
    if case let .executionStateChanged(_, state) = event, !state.blocksSending { scheduleRest() }
  }

  private func locate() -> String? {
    executableOverride ?? JSONLineProcess.locate(provider.program)
  }

  private func version() async -> String? {
    guard let executable = locate(),
          let answer = await OneShotCommand.run(
            executable, ["--version"], deadline: OneShotCommand.versionDeadline
          )
    else { return nil }
    return answer.output
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: .newlines).first
  }
}

/// One CLI run as two processes, where a permission mode is a launch flag for the whole
/// process: each chat runs in the process of its mode and moves before its next send.
final class ModeSplitClient: AgentClient, @unchecked Sendable {
  private let main: AgentClient
  private let second: AgentClient
  private let runsInSecond: @Sendable (String?) -> Bool
  private let lock = NSLock()
  private var placedInSecond: Set<String> = []

  init(main: AgentClient, second: AgentClient, runsInSecond: @escaping @Sendable (String?) -> Bool) {
    self.main = main
    self.second = second
    self.runsInSecond = runsInSecond
  }

  var provider: AgentId { main.provider }
  var capabilities: AgentCapabilities { main.capabilities }
  var modelListLifetime: TimeInterval { main.modelListLifetime }

  private func wantsSecond(_ options: AgentSessionOptions) -> Bool {
    !options.readOnly && runsInSecond(options.permissionMode)
  }

  private func client(for sessionID: String) -> AgentClient {
    lock.withLock { placedInSecond.contains(sessionID) } ? second : main
  }

  func probe() async -> AgentAvailability { await main.probe() }
  func availableModels() async throws -> [AgentModelOption] { try await main.availableModels() }
  func makeSessionID() -> String { main.makeSessionID() }

  func createSession(id: String, options: AgentSessionOptions) async throws -> RemoteSessionInfo {
    let inSecond = wantsSecond(options)
    let info = try await (inSecond ? second : main).createSession(id: id, options: options)
    lock.withLock { placedInSecond.toggle(info.id, on: inSecond) }
    return info
  }

  func prepareSession(_ id: String, options: AgentSessionOptions) async throws {
    let inSecond = wantsSecond(options)
    let wasInSecond = lock.withLock { placedInSecond.contains(id) }
    if inSecond != wasInSecond {
      await (wasInSecond ? second : main).release(sessionID: id)
      lock.withLock { placedInSecond.toggle(id, on: inSecond) }
    }
    try await (inSecond ? second : main).prepareSession(id, options: options)
  }

  func loadSession(id: String) async throws -> RemoteSessionSnapshot {
    try await client(for: id).loadSession(id: id)
  }

  func send(messageID: String, text: String, attachments: [OutgoingAttachment], to sessionID: String) async throws {
    try await client(for: sessionID).send(messageID: messageID, text: text, attachments: attachments, to: sessionID)
  }

  func messageExists(id: String, in sessionID: String) async throws -> Bool {
    try await client(for: sessionID).messageExists(id: id, in: sessionID)
  }

  func stop(sessionID: String) async throws { try await client(for: sessionID).stop(sessionID: sessionID) }

  func answerQuestion(requestID: String, sessionID: String, answers: [[String]]) async throws {
    try await client(for: sessionID).answerQuestion(requestID: requestID, sessionID: sessionID, answers: answers)
  }

  func rejectQuestion(requestID: String, sessionID: String) async throws {
    try await client(for: sessionID).rejectQuestion(requestID: requestID, sessionID: sessionID)
  }

  func answerPermission(
    requestID: String, sessionID: String, decision: PermissionDecision, message: String?
  ) async throws {
    try await client(for: sessionID).answerPermission(
      requestID: requestID, sessionID: sessionID, decision: decision, message: message)
  }

  func answerPlan(requestID: String, sessionID: String, decision: PlanDecision, feedback: String?) async throws {
    try await client(for: sessionID).answerPlan(
      requestID: requestID, sessionID: sessionID, decision: decision, feedback: feedback)
  }

  func events() -> AsyncStream<AgentEventEnvelope> {
    let streams = [main.events(), second.events()]
    return AsyncStream { continuation in
      let tasks = streams.map { stream in
        Task {
          for await event in stream { continuation.yield(event) }
        }
      }
      continuation.onTermination = { _ in tasks.forEach { $0.cancel() } }
    }
  }

  func setPermissionMode(_ mode: String?, sessionID: String) async throws {
    try await client(for: sessionID).setPermissionMode(mode, sessionID: sessionID)
  }

  func missedAnything(sessionID: String) async -> Bool? { await client(for: sessionID).missedAnything(sessionID: sessionID) }
  func usageLimits() async -> AgentUsage? { await main.usageLimits() }
  func contextUsage(sessionID: String) async -> AgentContextUsage? {
    await client(for: sessionID).contextUsage(sessionID: sessionID)
  }
  func compact(sessionID: String) async throws { try await client(for: sessionID).compact(sessionID: sessionID) }
  func commands(folder: String) async -> [AgentCommand] { await main.commands(folder: folder) }

  func previewUndo(sessionID: String, question: Int, directory: String) async throws -> FileUndo {
    try await client(for: sessionID).previewUndo(sessionID: sessionID, question: question, directory: directory)
  }

  func undo(sessionID: String, question: Int, directory: String) async throws -> FileUndo {
    try await client(for: sessionID).undo(sessionID: sessionID, question: question, directory: directory)
  }

  func steer(messageID: String, text: String, to sessionID: String) async throws {
    try await client(for: sessionID).steer(messageID: messageID, text: text, to: sessionID)
  }

  func activityHistory() async -> AgentActivityHistory? { await main.activityHistory() }

  func shutdown() async {
    await main.shutdown()
    await second.shutdown()
  }

  func release(sessionID: String) async {
    await client(for: sessionID).release(sessionID: sessionID)
    lock.withLock { _ = placedInSecond.remove(sessionID) }
  }

  func restartIdleProcess() async {
    await main.restartIdleProcess()
    await second.restartIdleProcess()
  }

  func chatTitle(sessionID: String, material: ChatNaming.Material) async -> String? {
    await client(for: sessionID).chatTitle(sessionID: sessionID, material: material)
  }

  func setConversationResolver(_ resolve: @escaping @Sendable (String) -> UUID?) {
    main.setConversationResolver(resolve)
    second.setConversationResolver(resolve)
  }
}

extension Set {
  mutating func toggle(_ member: Element, on: Bool) {
    if on { insert(member) } else { remove(member) }
  }
}
