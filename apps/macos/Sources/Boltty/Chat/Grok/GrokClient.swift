import Foundation
import os

struct ACPAgent: Sendable {
  let provider: AgentId
  let displayName: String
  let arguments: [String]
  let capabilities: AgentCapabilities
  var history: (@Sendable (String) throws -> DiskTranscript?)?
  var usage: (method: String, read: @Sendable (JSONObject) -> AgentUsage?)?
  var planMethod: String? = nil
  var askMethods: Set<String> = []

  static let grok = ACPAgent(
    provider: .grok,
    displayName: "Grok",
    // The person's ~/.grok/config.toml can say `always-approve`, and then
    // nothing asks: Boltty's Ask would not be Ask. The flag is global, so it
    // stands before `agent` (after it, `grok agent` refuses its arguments).
    arguments: ["--permission-mode", "default", "agent", "stdio"],
    capabilities: [
      .modelSelection, .permissions, .attachments, .images, .interrupt, .resumeSession,
      .workingDirectory, .reasoningEffort, .autoApproval, .usageReporting,
      .rereadableTranscript, .usageLimits, .questions,
    ],
    history: { try GrokChatHistoryTranscript.transcript(sessionID: $0) },
    usage: ("_x.ai/billing", { AgentUsage.grok($0) }),
    planMethod: "x.ai/exit_plan_mode",
    askMethods: ["x.ai/ask_user_question", "_x.ai/ask_user_question"]
  )
}

final class ACPClient: AgentClient, @unchecked Sendable {
  let agent: ACPAgent
  var provider: AgentId { agent.provider }

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
  private var permissions: [String: PendingPermission] = [:]
  private var plans: [String: PendingPlan] = [:]
  private var asks: [String: PendingAsk] = [:]
  private var conversationResolver: (@Sendable (String) -> UUID?)?
  private let executableOverride: String?

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
    var pendingMessageID: String?
    var messages: [ConversationMessage] = []
    var textSegment = 0
    var planToolCalls: Set<String> = []
    /// Auto Mode: an edit's permission is answered "allow once" as it comes.
    var autoApprove = false

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

  // MARK: - Availability

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

  // MARK: - Sessions

  func createSession(id: String, options: AgentSessionOptions) async throws -> RemoteSessionInfo {
    _ = try await connect()
    let result = try await request("session/new", params: [
      "cwd": options.directory,
      "mcpServers": []
    ])
    guard let sessionID = result.string("sessionId") else {
      throw AgentClientError.transport("\(agent.displayName) did not return a session id.")
    }

    let session = LiveSession(id: sessionID, directory: options.directory, model: options.model)
    session.autoApprove = options.autoApprove
    lock.withLock { sessions[sessionID] = session }
    try await apply(model: options.model, effort: options.effort, to: sessionID)

    return RemoteSessionInfo(
      id: sessionID,
      title: provider.shortDisplayName,
      directory: options.directory,
      model: options.model
    )
  }

  private func apply(model: ModelSelection?, effort: String?, to sessionID: String) async throws {
    if let model {
      _ = try? await request("session/set_model", params: [
        "sessionId": sessionID, "modelId": model.modelID
      ])
    }
    if let effort {
      _ = try? await request("session/set_config_option", params: [
        "sessionId": sessionID, "configId": "reasoning_effort", "value": effort
      ])
    }
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
    do {
      _ = try await request("session/load", params: ["sessionId": id, "mcpServers": []])
    } catch {
      log.debug("session/load refused \(id, privacy: .public): \(String(describing: error), privacy: .public)")
      throw AgentClientError.sessionNotFound
    }
    lock.withLock {
      if sessions[id] == nil {
        sessions[id] = LiveSession(
          id: id, directory: FileManager.default.currentDirectoryPath, model: nil
        )
      }
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
        ])
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

  // MARK: - Control

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
    guard let waiting = lock.withLock({ permissions.removeValue(forKey: requestID) }) else {
      throw AgentClientError.requestGone
    }
    guard let optionID = waiting.optionsByDecision[decision] ?? waiting.rejectOptionID else {
      throw AgentClientError.transport("\(agent.displayName) offered no option for that answer.")
    }
    respond(to: waiting.rpcID, result: [
      "outcome": ["outcome": "selected", "optionId": optionID]
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
    emit(.interactionResolved(
      sessionID: sessionID,
      requestID: requestID,
      resolution: .plan(decision)
    ))
  }

  static func planResult(_ decision: PlanDecision, feedback: String?) -> [String: Any] {
    var result: [String: Any] = ["outcome": decision.rawValue]
    let words = feedback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if decision == .cancelled, !words.isEmpty { result["feedback"] = words }
    return result
  }

  func setAutoApproval(_ enabled: Bool, sessionID: String) async throws {}

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

  // MARK: - Transport

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

    return try await request("initialize", params: [
      "protocolVersion": 1,
      "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]]
    ])
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
    lock.withLock { plans.removeAll() }
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
    if let planMethod = agent.planMethod, method == planMethod {
      return handlePlan(id: id, params: params)
    }
    if agent.askMethods.contains(method) {
      return handleAsk(id: id, params: params)
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
    var names: [String] = []
    for option in options {
      guard let optionID = option.string("optionId") else { continue }
      let name = option.string("name") ?? optionID
      names.append(name)
      switch option.string("kind") {
      case "allow_once": byDecision[.once] = optionID
      case "allow_always": byDecision[.always] = optionID
      case "reject_once", "reject_always":
        byDecision[.reject] = optionID
        reject = optionID
      default: continue
      }
    }

    // Auto Mode is edits only, as Claude Code's acceptEdits is: a command
    // still asks.
    if params.object("toolCall")?.string("kind") == "edit",
       lock.withLock({ sessions[sessionID]?.autoApprove == true }),
       let allow = byDecision[.once] {
      respond(to: id, result: ["outcome": ["outcome": "selected", "optionId": allow]])
      return
    }

    let requestID = params.object("toolCall")?.string("toolCallId") ?? UUID().uuidString
    lock.withLock {
      permissions[requestID] = PendingPermission(
        rpcID: id,
        sessionID: sessionID,
        optionsByDecision: byDecision,
        rejectOptionID: reject
      )
    }

    guard let conversationID = lock.withLock({ conversationResolver })?(sessionID) else {
      if let reject { respond(to: id, result: ["outcome": ["outcome": "selected", "optionId": reject]]) }
      lock.withLock { _ = permissions.removeValue(forKey: requestID) }
      return
    }
    let tool = params.object("toolCall")
    emit(.interactionAsked(PendingInteraction(
      id: requestID,
      conversationID: conversationID,
      remoteSessionID: sessionID,
      kind: .permission(PermissionPrompt(
        action: tool?.string("title") ?? tool?.string("kind") ?? "run a tool",
        resources: names,
        savePatterns: [],
        toolCallID: tool?.string("toolCallId")
      ))
    )))
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
      kind: .plan(PlanPrompt(markdown: markdown, toolCallID: toolCallID))
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

  private func handleNotification(_ method: String, params: JSONObject) {
    guard method == "session/update" else { return }
    guard let sessionID = params.string("sessionId"),
          let update = params.object("update") else { return }

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
      let activity = AgentActivity(
        id: "\(replyID)-\(toolID)",
        name: update.string("title") ?? update.string("kind") ?? "tool",
        summary: update.string("kind"),
        state: update.string("status") == "completed" ? .completed : .running
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

  // MARK: - JSON-RPC

  private func request(_ method: String, params: [String: Any]) async throws -> JSONObject {
    let id: Int = lock.withLock {
      rpcCounter += 1
      return rpcCounter
    }
    guard let line = JSONObject.encode([
      "jsonrpc": "2.0", "id": id, "method": method, "params": params
    ]) else {
      throw AgentClientError.transport("That call could not be encoded.")
    }
    return try await withCheckedThrowingContinuation { continuation in
      lock.withLock { pending[id] = continuation }
      do {
        try lock.withLock({ process })?.writeLine(line)
      } catch {
        lock.withLock { _ = pending.removeValue(forKey: id) }
        continuation.resume(throwing: error)
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
      throw AgentClientError.transport("That answer could not be encoded.")
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

  // MARK: - Plumbing

  private func emit(_ event: AgentEvent) {
    let continuation = lock.withLock { eventContinuation }
    continuation?.yield(
      AgentEventEnvelope(providerID: provider.rawValue, id: nil, sequence: nil, event: event)
    )
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
