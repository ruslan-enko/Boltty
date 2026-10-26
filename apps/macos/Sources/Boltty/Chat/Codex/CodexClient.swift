import Foundation
import os

final class CodexClient: AgentClient, @unchecked Sendable {
  let provider = AgentId.codex

  let capabilities: AgentCapabilities = [
    .modelSelection, .permissions, .questions, .attachments, .images,
    .interrupt, .resumeSession, .workingDirectory, .reasoningEffort,
    .autoApproval, .usageReporting, .rereadableTranscript, .usageLimits,
    .contextUsage, .compaction, .steering, .activityHistory
  ]

  private let log = Logger(subsystem: "com.boltty", category: "codex-client")
  private let lock = NSLock()

  private var process: JSONLineProcess?
  private var startTask: Task<JSONLineProcess, Error>?
  private var nextRequestID = 0
  private struct PendingRequest {
    let server: JSONLineProcess
    let continuation: CheckedContinuation<JSONObject, Error>
  }
  private var pending: [Int: PendingRequest] = [:]
  private var threads: [String: ThreadState] = [:]
  private var contextByThread: [String: AgentContextUsage] = [:]
  private var limitHits: [String: RateLimitHit] = [:]
  private var replySegment: [String: String] = [:]
  private var partHome: [String: String] = [:]
  private var approvals: [String: PendingApproval] = [:]
  private var unloadTokens: [String: UUID] = [:]
  var idleUnloadDelay: TimeInterval = 600
  private var eventContinuation: AsyncStream<AgentEventEnvelope>.Continuation?
  private var conversationResolver: (@Sendable (String) -> UUID?)?

  private let executableOverride: String?
  private let codexHome: URL

  init(executable: String? = nil, codexHome: URL? = nil) {
    self.executableOverride = executable
    self.codexHome = codexHome
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
  }

  func setConversationResolver(_ resolve: @escaping @Sendable (String) -> UUID?) {
    lock.withLock { conversationResolver = resolve }
  }

  private final class ThreadState {
    let id: String
    var directory: String
    var model: ModelSelection?
    var effort: String?
    var autoApprove = false
    var currentTurnID: String?
    var executionState: ConversationExecutionState = .idle
    weak var loadedOn: JSONLineProcess?

    init(
      id: String,
      directory: String,
      model: ModelSelection?,
      effort: String? = nil,
      autoApprove: Bool = false
    ) {
      self.id = id
      self.directory = directory
      self.model = model
      self.effort = effort
      self.autoApprove = autoApprove
    }
  }

  private struct PendingApproval {
    let rpcID: Int
    let method: String
    let threadID: String
  }

  // MARK: - Availability

  func probe() async -> AgentAvailability {
    guard let executable = locate() else { return .notInstalled }
    let status = await Self.run(executable, ["login", "status"], timeout: 8)
    guard status.exitCode == 0 else {
      return .needsLogin("Signed out — run `codex login` in a terminal.")
    }
    let version = await Self.run(executable, ["--version"], timeout: 8).output
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return .available(version: version.isEmpty ? nil : version)
  }

  func availableModels() async throws -> [AgentModelOption] {
    let response = try await request("model/list", params: ["includeHidden": false])
    return response.array("data").compactMap { model in
      guard let id = model.string("id") else { return nil }
      let efforts = model.array("supportedReasoningEfforts").compactMap { option -> AgentEffortOption? in
        guard let value = option.string("reasoningEffort") else { return nil }
        return AgentEffortOption(value: value, detail: option.string("description"))
      }
      return AgentModelOption(
        selection: ModelSelection(
          providerID: provider.rawValue,
          modelID: id,
          displayName: model.string("displayName") ?? id
        ),
        isDefault: model.bool("isDefault") ?? false,
        effortOptions: efforts
      )
    }
  }

  func usageLimits() async -> AgentUsage? {
    guard let result = try? await request("account/rateLimits/read", params: [:]) else {
      return nil
    }
    return AgentUsage.codex(result)
  }

  // MARK: - Threads

  func createSession(
    id: String,
    options: AgentSessionOptions
  ) async throws -> RemoteSessionInfo {
    let directory = options.directory
    let model = options.model
    var params: [String: Any] = [
      "cwd": directory,
      "approvalPolicy": Self.approvalPolicy(autoApprove: options.autoApprove),
      "sandbox": options.readOnly ? "read-only" : "workspace-write"
    ]
    if let model { params["model"] = model.modelID }

    let server = try await server()
    let response = try await request("thread/start", params: params, on: server)
    guard let threadID = response.object("thread")?.string("id") ?? response.string("threadId")
    else { throw AgentClientError.transport("Codex did not return a thread id.") }

    lock.withLock {
      threads[threadID] = ThreadState(
        id: threadID,
        directory: directory,
        model: model,
        effort: options.effort,
        autoApprove: options.autoApprove
      )
      threads[threadID]?.loadedOn = server
    }
    return RemoteSessionInfo(
      id: threadID,
      title: "Codex",
      directory: response.string("cwd") ?? directory,
      model: response.string("model").map {
        ModelSelection(providerID: provider.rawValue, modelID: $0)
      } ?? model
    )
  }

  /// Read off the rollout: thread/resume writes to it.
  func loadSession(id: String) async throws -> RemoteSessionSnapshot {
    let live = lock.withLock { () -> (directory: String, model: ModelSelection?, state: ConversationExecutionState)? in
      threads[id].map { ($0.directory, $0.model, $0.executionState) }
    }
    let found: DiskTranscript?
    do {
      found = try CodexRolloutTranscript.transcript(threadID: id, codexHome: codexHome)
    } catch {
      throw AgentClientError.transport(String(describing: error))
    }
    guard let disk = found else {
      guard let live else { throw AgentClientError.sessionNotFound }
      return RemoteSessionSnapshot(
        info: RemoteSessionInfo(id: id, title: "Codex", directory: live.directory, model: live.model),
        messages: [],
        state: live.state,
        openInteractions: []
      )
    }
    return RemoteSessionSnapshot(
      info: RemoteSessionInfo(
        id: id,
        title: disk.title ?? "Codex",
        directory: live?.directory ?? disk.directory ?? NSHomeDirectory(),
        model: live?.model
      ),
      messages: disk.messages,
      state: live?.state ?? .idle,
      openInteractions: []
    )
  }

  func activityHistory() async -> AgentActivityHistory? {
    guard let result = try? await request("account/usage/read", params: [:]) else { return nil }
    return AgentActivityHistory.codex(result)
  }

  // MARK: - Context

  func contextUsage(sessionID: String) async -> AgentContextUsage? {
    if let live = lock.withLock({ contextByThread[sessionID] }) { return live }
    return CodexRolloutTranscript.contextUsage(threadID: sessionID, codexHome: codexHome)
  }

  func compact(sessionID: String) async throws {
    let server = try await server()
    try await ensureThread(id: sessionID, on: server)
    _ = try await request("thread/compact/start", params: ["threadId": sessionID], on: server)
  }

  // MARK: - Steering

  func steer(messageID: String, text: String, to sessionID: String) async throws {
    guard let turnID = lock.withLock({ threads[sessionID]?.currentTurnID }) else {
      throw AgentClientError.transport("No turn is running to add to.")
    }
    let server = try await server()
    _ = try await request("turn/steer", params: [
      "threadId": sessionID,
      "expectedTurnId": turnID,
      "input": [["type": "text", "text": text]],
      "clientUserMessageId": messageID,
    ], on: server)
    let segment = "\(turnID)-after-\(messageID)"
    lock.withLock { replySegment[turnID] = segment }
  }

  private func home(forPart partID: String, threadID: String, turnID: String) -> String {
    let (home, isNew): (String, Bool) = lock.withLock {
      if let known = partHome[partID] { return (known, false) }
      let segment = replySegment[turnID] ?? turnID
      let announced = partHome.values.contains(segment) || segment == turnID
      partHome[partID] = segment
      return (segment, !announced)
    }
    if isNew {
      emit(.messageUpdated(
        sessionID: threadID,
        message: ConversationMessage(id: home, role: .agent, createdAt: Date())))
    }
    return home
  }

  // MARK: - Letting a thread go

  private func scheduleUnload(_ threadID: String) {
    let token = UUID()
    lock.withLock { unloadTokens[threadID] = token }
    let delay = idleUnloadDelay
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      await self?.unloadIfIdle(threadID, token: token)
    }
  }

  private func unloadIfIdle(_ threadID: String, token: UUID) async {
    let server: JSONLineProcess? = lock.withLock {
      guard unloadTokens[threadID] == token,
            let thread = threads[threadID], thread.currentTurnID == nil,
            !approvals.values.contains(where: { $0.threadID == threadID })
      else { return nil }
      return thread.loadedOn
    }
    guard let server else { return }
    _ = try? await requestUnchecked("thread/unsubscribe", params: ["threadId": threadID], on: server)
    lock.withLock {
      if unloadTokens[threadID] == token { threads[threadID]?.loadedOn = nil }
    }
  }

  // MARK: - Sending

  private func ensureThread(id: String, on server: JSONLineProcess) async throws {
    guard !lock.withLock({ threads[id]?.loadedOn === server }) else { return }
    _ = try await resumeThread(id: id, on: server)
  }

  @discardableResult
  private func resumeThread(id: String, on server: JSONLineProcess) async throws -> JSONObject {
    let resumed: JSONObject
    do {
      resumed = try await requestUnchecked(
        "thread/resume", params: ["threadId": id, "excludeTurns": true], on: server)
    } catch let error as RPCFailure {
      if error.code == -32600, error.message == "no rollout found for thread id \(id)" {
        throw AgentClientError.sessionNotFound
      }
      throw AgentClientError.transport(error.message)
    }
    lock.withLock {
      if threads[id] == nil {
        threads[id] = ThreadState(
          id: id,
          directory: resumed.string("cwd") ?? NSHomeDirectory(),
          model: resumed.string("model").map { ModelSelection(providerID: provider.rawValue, modelID: $0) },
          effort: resumed.string("reasoningEffort"),
          autoApprove: resumed.string("approvalPolicy") == "never"
        )
      }
      threads[id]?.loadedOn = server
    }
    return resumed
  }

  static func turnInput(text: String, attachments: [OutgoingAttachment]) -> [[String: Any]] {
    var input: [[String: Any]] = []
    if !text.isEmpty { input.append(["type": "text", "text": text]) }
    for attachment in attachments {
      let mime = attachment.mimeType ?? MIMEType.guess(for: attachment.url) ?? ""
      if mime.hasPrefix("image/") {
        input.append(["type": "localImage", "path": attachment.url.path])
      } else {
        input.append(["type": "text", "text": "Attached file: \(attachment.url.path)"])
      }
    }
    return input
  }

  func send(
    messageID: String,
    text: String,
    attachments: [OutgoingAttachment],
    to sessionID: String
  ) async throws {
    let input = Self.turnInput(text: text, attachments: attachments)
    guard !input.isEmpty else { return }

    let server = try await server()
    try await ensureThread(id: sessionID, on: server)

    var params: [String: Any] = [
      "threadId": sessionID,
      "input": input,
      "clientUserMessageId": messageID
    ]
    lock.withLock {
      let thread = threads[sessionID]
      if let model = thread?.model { params["model"] = model.modelID }
      if let effort = thread?.effort, !effort.isEmpty { params["effort"] = effort }
      params["approvalPolicy"] = Self.approvalPolicy(autoApprove: thread?.autoApprove ?? false)
    }
    let response: JSONObject
    do {
      response = try await requestUnchecked("turn/start", params: params, on: server)
    } catch let error as RPCFailure {
      guard error.code == -32600, error.message == "thread not found: \(sessionID)" else {
        throw AgentClientError.transport(error.message)
      }
      lock.withLock { threads[sessionID]?.loadedOn = nil }
      try await ensureThread(id: sessionID, on: server)
      response = try await request("turn/start", params: params, on: server)
    }
    let turnID = response.object("turn")?.string("id")
    lock.withLock {
      threads[sessionID]?.currentTurnID = turnID
      threads[sessionID]?.executionState = .working
    }
    emit(.executionStateChanged(sessionID: sessionID, state: .working))
  }

  func messageExists(id: String, in sessionID: String) async throws -> Bool { false }

  func stop(sessionID: String) async throws {
    guard let turnID = lock.withLock({ threads[sessionID]?.currentTurnID }) else { return }
    _ = try await request("turn/interrupt", params: ["threadId": sessionID, "turnId": turnID])
  }

  // MARK: - Interactions

  func answerQuestion(requestID: String, sessionID: String, answers: [[String]]) async throws {
    guard let pending = takeApproval(requestID) else {
      throw AgentClientError.requestGone
    }
    let ids = requestID.split(separator: "\u{1F}").dropFirst().map(String.init)
    var payload: [String: Any] = [:]
    for (index, id) in ids.enumerated() where index < answers.count {
      payload[id] = ["answers": answers[index]]
    }
    respond(to: pending.rpcID, result: ["answers": payload])
  }

  func rejectQuestion(requestID: String, sessionID: String) async throws {
    guard let pending = takeApproval(requestID) else {
      throw AgentClientError.requestGone
    }
    respond(to: pending.rpcID, result: ["answers": [:]])
  }

  func answerPermission(
    requestID: String,
    sessionID: String,
    decision: PermissionDecision,
    message: String?
  ) async throws {
    guard let pending = takeApproval(requestID) else {
      throw AgentClientError.requestGone
    }
    switch pending.method {
    case "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
         "applyPatchApproval", "execCommandApproval":
      respond(to: pending.rpcID, result: ["decision": Self.decision(for: decision)])
    default:
      respond(to: pending.rpcID, result: ["permissions": [:], "scope": "turn"])
    }
  }

  func setAutoApproval(_ enabled: Bool, sessionID: String) async throws {
    let server = try await server()
    try await ensureThread(id: sessionID, on: server)
    lock.withLock { threads[sessionID]?.autoApprove = enabled }
  }

  static func approvalPolicy(autoApprove: Bool) -> String {
    autoApprove ? "never" : "on-request"
  }

  static func decision(for decision: PermissionDecision) -> String {
    switch decision {
    case .once: return "accept"
    case .always: return "acceptForSession"
    case .reject: return "decline"
    }
  }

  // MARK: - Events

  func events() -> AsyncStream<AgentEventEnvelope> {
    AsyncStream { continuation in
      lock.withLock { self.eventContinuation = continuation }
    }
  }

  func shutdown() async {
    let running = lock.withLock { () -> JSONLineProcess? in
      let value = process
      process = nil
      startTask = nil
      return value
    }
    if let running { serverExited(running, status: 0, stderr: "Codex was shut down.") }
    running?.closeInput()
    running?.terminate()
  }

  // MARK: - The server

  private func locate() -> String? {
    executableOverride ?? JSONLineProcess.locate(provider.program)
  }

  private func server() async throws -> JSONLineProcess {
    let task = lock.withLock { () -> Task<JSONLineProcess, Error> in
      if let existing = startTask { return existing }
      let task = Task { [self] () throws -> JSONLineProcess in
        guard let executable = locate() else { throw AgentClientError.notInstalled }
        let started = JSONLineProcess(
          executable: executable,
          arguments: ["app-server"],
          directory: NSHomeDirectory(),
          category: "codex-app-server"
        )
        started.onExit = { [weak self, weak started] status, stderr in
          guard let started else { return }
          self?.serverExited(started, status: status, stderr: stderr)
        }
        lock.withLock { process = started }
        let lines = started.lines
        try started.start()
        Task { [weak self] in
          for await line in lines {
            self?.handle(line: line)
          }
        }
        _ = try await requestUnchecked(
          "initialize",
          params: [
            "clientInfo": ["name": "Boltty", "title": "Boltty", "version": Self.bolttyVersion],
            "capabilities": ["optOutNotificationMethods": Self.unreadNotifications],
          ],
          on: started
        )
        notify("initialized", params: [:], on: started)
        return started
      }
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

  static let unreadNotifications = [
    "turn/diff/updated",
    "item/commandExecution/outputDelta",
    "item/commandExecution/terminalInteraction",
    "item/fileChange/outputDelta",
    "item/fileChange/patchUpdated",
    "item/plan/delta",
    "item/mcpToolCall/progress",
    "command/exec/outputDelta",
    "process/outputDelta",
    "thread/realtime/outputAudio/delta",
    "thread/realtime/transcript/delta",
  ]

  private static var bolttyVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
  }

  private func serverExited(_ server: JSONLineProcess, status: Int32, stderr: String) {
    let waiting: [CheckedContinuation<JSONObject, Error>] = lock.withLock {
      let ids = pending.keys.filter { pending[$0]?.server === server }
      let values = ids.compactMap { pending.removeValue(forKey: $0)?.continuation }
      if process === server {
        process = nil
        startTask = nil
      }
      return values
    }
    let error = AgentClientError.serverStartFailed(
      stderr.isEmpty ? "Codex exited (status \(status))." : stderr
    )
    for continuation in waiting { continuation.resume(throwing: error) }
  }

  // MARK: - JSON-RPC

  private struct RPCFailure: Error {
    let code: Int?
    let message: String
  }

  @discardableResult
  private func request(_ method: String, params: [String: Any]) async throws -> JSONObject {
    let server = try await server()
    return try await request(method, params: params, on: server)
  }

  private func request(_ method: String, params: [String: Any], on server: JSONLineProcess) async throws -> JSONObject {
    do {
      return try await requestUnchecked(method, params: params, on: server)
    } catch let error as RPCFailure {
      throw AgentClientError.transport(error.message)
    }
  }

  private func requestUnchecked(
    _ method: String,
    params: [String: Any],
    on server: JSONLineProcess
  ) async throws -> JSONObject {
    let id: Int = lock.withLock {
      nextRequestID += 1
      return nextRequestID
    }
    guard let line = JSONObject.encode([
      "jsonrpc": "2.0", "id": id, "method": method, "params": params
    ]) else { throw AgentClientError.transport("That request could not be encoded.") }

    return try await withCheckedThrowingContinuation { continuation in
      lock.withLock { pending[id] = PendingRequest(server: server, continuation: continuation) }
      do {
        try server.writeLine(line)
      } catch {
        let stored: CheckedContinuation<JSONObject, Error>? = lock.withLock {
          pending.removeValue(forKey: id)?.continuation
        }
        stored?.resume(throwing: error)
      }
    }
  }

  private func notify(_ method: String, params: [String: Any], on server: JSONLineProcess) {
    guard let line = JSONObject.encode(["jsonrpc": "2.0", "method": method, "params": params])
    else { return }
    try? server.writeLine(line)
  }

  private func respond(to rpcID: Int, result: [String: Any]) {
    guard let server = lock.withLock({ process }),
          let line = JSONObject.encode(["jsonrpc": "2.0", "id": rpcID, "result": result])
    else { return }
    try? server.writeLine(line)
  }

  private func handle(line: String) {
    guard let frame = JSONObject(line: line) else { return }

    if let id = frame.int("id"), frame["method"] == nil {
      let continuation: CheckedContinuation<JSONObject, Error>? = lock.withLock {
        pending.removeValue(forKey: id)?.continuation
      }
      if let error = frame.object("error") {
        continuation?.resume(throwing: RPCFailure(
          code: error.int("code"), message: error.string("message") ?? "Codex refused that request."
        ))
      } else {
        continuation?.resume(returning: frame.object("result") ?? JSONObject([:]))
      }
      return
    }

    guard let method = frame.string("method") else { return }
    let params = frame.object("params") ?? JSONObject([:])

    if let id = frame.int("id") {
      handleServerRequest(method: method, rpcID: id, params: params)
      return
    }
    handleNotification(method: method, params: params)
  }

  private func handleServerRequest(method: String, rpcID: Int, params: JSONObject) {
    guard let threadID = params.string("threadId") else {
      respond(to: rpcID, result: [:])
      return
    }
    let conversationID = lock.withLock { conversationResolver }?(threadID) ?? UUID()

    switch method {
    case "item/tool/requestUserInput":
      let questions = params.array("questions")
      let interactionID = ([params.string("itemId") ?? "ask"]
        + questions.compactMap { $0.string("id") }).joined(separator: "\u{1F}")
      rememberApproval(interactionID, PendingApproval(
        rpcID: rpcID, method: method, threadID: threadID
      ))
      emit(.interactionAsked(PendingInteraction(
        id: interactionID,
        conversationID: conversationID,
        remoteSessionID: threadID,
        kind: .question(QuestionPrompt(
          items: questions.map { question in
            QuestionItem(
              header: question.string("header") ?? "",
              question: question.string("question") ?? "",
              choices: (question["options"] as? [[String: Any]] ?? []).map {
                let option = JSONObject($0)
                return AgentChoice(
                  value: option.string("label") ?? "",
                  label: option.string("label") ?? "",
                  detail: option.string("description")
                )
              },
              allowsMultiple: false,
              allowsCustom: question.bool("isOther") ?? false
            )
          },
          toolCallID: params.string("itemId")
        ))
      )))

    case "item/commandExecution/requestApproval", "execCommandApproval":
      let interactionID = params.string("approvalId")
        ?? params.string("itemId")
        ?? "approval_\(rpcID)"
      rememberApproval(interactionID, PendingApproval(
        rpcID: rpcID, method: method, threadID: threadID
      ))
      emit(.interactionAsked(PendingInteraction(
        id: interactionID,
        conversationID: conversationID,
        remoteSessionID: threadID,
        kind: .permission(PermissionPrompt(
          action: "shell",
          resources: [params.string("command") ?? ""].filter { !$0.isEmpty },
          savePatterns: [],
          toolCallID: params.string("itemId")
        ))
      )))

    case "item/fileChange/requestApproval", "applyPatchApproval":
      let interactionID = params.string("itemId") ?? "approval_\(rpcID)"
      rememberApproval(interactionID, PendingApproval(
        rpcID: rpcID, method: method, threadID: threadID
      ))
      emit(.interactionAsked(PendingInteraction(
        id: interactionID,
        conversationID: conversationID,
        remoteSessionID: threadID,
        kind: .permission(PermissionPrompt(
          action: "edit",
          resources: [params.string("reason") ?? "Write files"],
          savePatterns: [],
          toolCallID: params.string("itemId")
        ))
      )))

    case "item/permissions/requestApproval":
      let interactionID = params.string("itemId") ?? "approval_\(rpcID)"
      rememberApproval(interactionID, PendingApproval(
        rpcID: rpcID, method: method, threadID: threadID
      ))
      emit(.interactionAsked(PendingInteraction(
        id: interactionID,
        conversationID: conversationID,
        remoteSessionID: threadID,
        kind: .permission(PermissionPrompt(
          action: "permissions",
          resources: [params.string("reason") ?? "Extra access"],
          savePatterns: [],
          toolCallID: params.string("itemId")
        ))
      )))

    default:
      respond(to: rpcID, result: [:])
    }
  }

  private func handleNotification(method: String, params: JSONObject) {
    switch method {
    case "turn/started":
      if let threadID = params.string("threadId") { lock.withLock { unloadTokens[threadID] = UUID() } }
      guard let threadID = params.string("threadId"),
            let turn = params.object("turn"), let turnID = turn.string("id")
      else { return }
      lock.withLock {
        threads[threadID]?.currentTurnID = turnID
        threads[threadID]?.executionState = .working
      }
      emit(.messageUpdated(
        sessionID: threadID,
        message: ConversationMessage(id: turnID, role: .agent, createdAt: Date())
      ))
      emit(.executionStateChanged(sessionID: threadID, state: .working))

    case "turn/completed":
      guard let threadID = params.string("threadId"), let turn = params.object("turn") else {
        return
      }
      let turnID = turn.string("id") ?? ""
      let heldHit = lock.withLock { limitHits.removeValue(forKey: threadID) }
      var hit = heldHit
      if let error = turn.object("error") {
        if RateLimitHit.isCodexLimit(error.raw["codexErrorInfo"]) {
          hit = hit ?? RateLimitHit(resetsAt: nil)
        }
        emit(.sessionFailed(
          sessionID: threadID,
          failure: MessageFailure(
            name: turn.string("status") ?? "failed",
            message: error.string("message") ?? "That turn ended with an error.",
            rateLimit: hit
          )
        ))
      } else if let hit {
        emit(.sessionFailed(
          sessionID: threadID,
          failure: MessageFailure(
            name: "usageLimitExceeded",
            message: "The plan's limit refused this turn.",
            rateLimit: hit
          )
        ))
      }
      let segments: Set<String> = lock.withLock {
        let mine = Set(partHome.values.filter { $0 == turnID || $0.hasPrefix("\(turnID)-after-") })
        partHome = partHome.filter { !mine.contains($0.value) }
        replySegment[turnID] = nil
        return mine.union([turnID])
      }
      for id in segments.sorted() {
        emit(.messageUpdated(
          sessionID: threadID,
          message: ConversationMessage(id: id, role: .agent, createdAt: Date(), completedAt: Date())
        ))
      }
      let ended: ConversationExecutionState = hit == nil ? .idle : .rateLimited
      lock.withLock {
        threads[threadID]?.currentTurnID = nil
        threads[threadID]?.executionState = ended
      }
      emit(.executionStateChanged(sessionID: threadID, state: ended))
      scheduleUnload(threadID)

    case "turn/plan/updated":
      guard let threadID = params.string("threadId"), let turnID = params.string("turnId")
      else { return }
      let steps = AgentPlan.codexLive(params)
      guard !steps.isEmpty else { return }
      let planID = "\(turnID)-plan"
      emit(.partUpdated(
        sessionID: threadID, messageID: home(forPart: planID, threadID: threadID, turnID: turnID),
        part: .activity(AgentPlan.activity(id: planID, steps: steps))))

    case "thread/tokenUsage/updated":
      guard let threadID = params.string("threadId"),
            let usage = params.object("tokenUsage").flatMap(AgentContextUsage.codex)
      else { return }
      lock.withLock { contextByThread[threadID] = usage }

    case "item/agentMessage/delta":
      guard let threadID = params.string("threadId"),
            let turnID = params.string("turnId"),
            let itemID = params.string("itemId"),
            let delta = params.string("delta")
      else { return }
      emit(.partDelta(
        sessionID: threadID, messageID: home(forPart: itemID, threadID: threadID, turnID: turnID),
        partID: itemID, kind: .text, delta: delta
      ))

    case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
      guard let threadID = params.string("threadId"),
            let turnID = params.string("turnId"),
            let itemID = params.string("itemId"),
            let delta = params.string("delta")
      else { return }
      emit(.partDelta(
        sessionID: threadID, messageID: home(forPart: itemID, threadID: threadID, turnID: turnID),
        partID: itemID, kind: .reasoning, delta: delta
      ))

    case "item/started", "item/completed":
      guard let threadID = params.string("threadId"),
            let turnID = params.string("turnId"),
            let item = params.object("item"),
            let part = CodexMapper.part(from: item, completed: method == "item/completed")
      else { return }
      emit(.partUpdated(
        sessionID: threadID, messageID: home(forPart: part.id, threadID: threadID, turnID: turnID),
        part: part))

    case "thread/status/changed":
      guard let threadID = params.string("threadId"),
            let status = params.object("status")?.string("type")
      else { return }
      if status == "idle" {
        lock.withLock { threads[threadID]?.executionState = .idle }
        emit(.executionStateChanged(sessionID: threadID, state: .idle))
      }

    case "error":
      log.debug("codex error: \(params.rendered("message") ?? "", privacy: .public)")
      if params.bool("willRetry") != true, let threadID = params.string("threadId"),
         RateLimitHit.isCodexLimit(params.object("error")?.raw["codexErrorInfo"]) {
        lock.withLock { limitHits[threadID] = RateLimitHit(resetsAt: nil) }
      }

    default:
      break
    }
  }

  private func rememberApproval(_ id: String, _ approval: PendingApproval) {
    lock.withLock {
      approvals[id] = approval
      threads[approval.threadID]?.executionState = .waiting
    }
  }

  private func takeApproval(_ id: String) -> PendingApproval? {
    lock.withLock {
      guard let taken = approvals.removeValue(forKey: id) else { return nil }
      let stillAsking = approvals.values.contains { $0.threadID == taken.threadID }
      if !stillAsking, threads[taken.threadID]?.executionState == .waiting {
        threads[taken.threadID]?.executionState = .working
      }
      return taken
    }
  }

  private func emit(_ event: AgentEvent) {
    let continuation = lock.withLock { eventContinuation }
    continuation?.yield(AgentEventEnvelope(providerID: provider.rawValue, event: event))
  }

  static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval)
    async -> (exitCode: Int32, output: String) {
    guard let answer = await OneShotCommand.run(
      executable, arguments, deadline: timeout, includeStandardError: true
    ) else { return (-1, "") }
    return (answer.exitCode, answer.output)
  }
}
