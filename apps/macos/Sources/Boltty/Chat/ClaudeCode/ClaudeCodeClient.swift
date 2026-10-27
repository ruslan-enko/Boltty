import Foundation
import os

final class ClaudeCodeClient: AgentClient, @unchecked Sendable {
  let provider = AgentId.claude

  let capabilities: AgentCapabilities = [
    .modelSelection, .permissions, .attachments, .images, .interrupt,
    .resumeSession, .workingDirectory, .reasoningEffort, .autoApproval,
    .usageReporting, .rereadableTranscript, .usageLimits, .contextUsage, .compaction,
    .permissionMessage, .steering
  ]

  private let log = Logger(subsystem: "com.boltty", category: "claude-code-client")
  private let lock = NSLock()
  private var sessions: [String: LiveSession] = [:]
  private var eventContinuation: AsyncStream<AgentEventEnvelope>.Continuation?
  private var conversationResolver: (@Sendable (String) -> UUID?)?
  private var cachedHandshake: JSONObject?

  private let executableOverride: String?
  private let throwawayDeadline: TimeInterval

  init(executable: String? = nil, throwawayDeadline: TimeInterval = 25) {
    self.executableOverride = executable
    self.throwawayDeadline = throwawayDeadline
  }

  func setConversationResolver(_ resolve: @escaping @Sendable (String) -> UUID?) {
    lock.withLock { conversationResolver = resolve }
  }

  // MARK: - Availability

  func probe() async -> AgentAvailability {
    guard locate() != nil else { return .notInstalled }
    // A probe is a re-read: a sign-in made in the terminal since the last one
    // must show up without restarting Boltty.
    lock.withLock { cachedHandshake = nil }
    guard let handshake = await handshake() else {
      return .unavailable("Claude Code did not answer. Try running `claude` once in a terminal.")
    }
    guard Self.isSignedIn(handshake.object("account")) else {
      return .needsLogin("Signed out — run `claude auth login` in a terminal.")
    }
    return .available(version: await version())
  }

  /// An expired login still answers `initialize` with an `account`, as
  /// `{"tokenSource": "none", "apiProvider": "firstParty"}` and no email
  /// (2.1.296, `claude auth status`: "Login: Expired").
  static func isSignedIn(_ account: JSONObject?) -> Bool {
    guard let account else { return false }
    if account.string("email") != nil { return true }
    if let source = account.string("tokenSource"), source != "none" { return true }
    if let provider = account.string("apiProvider"), provider != "firstParty" { return true }
    return false
  }

  func availableModels() async throws -> [AgentModelOption] {
    guard let handshake = await handshake() else { return [] }
    let models = handshake.array("models")
    return models.compactMap { model in
      guard let value = model.string("value") else { return nil }
      let selection = ModelSelection(
        providerID: provider.rawValue,
        modelID: value,
        displayName: model.string("displayName") ?? value
      )
      let levels = (model.bool("supportsEffort") ?? false)
        ? model.strings("supportedEffortLevels")
        : []
      return AgentModelOption(
        selection: selection,
        isDefault: value == "default",
        effortOptions: levels.map { AgentEffortOption(value: $0) }
      )
    }
  }

  static func effortArguments(_ effort: String?) -> [String] {
    guard let effort, !effort.isEmpty else { return [] }
    return ["--effort", effort]
  }

  // MARK: - Sessions

  func makeSessionID() -> String { AgentSessionID.uuid() }

  func createSession(
    id: String,
    options: AgentSessionOptions
  ) async throws -> RemoteSessionInfo {
    let session = try await startSession(id: id, options: options, resuming: false)
    return RemoteSessionInfo(
      id: session.id,
      title: "Claude Code",
      directory: options.directory,
      model: options.model
    )
  }

  func setAutoApproval(_ enabled: Bool, sessionID: String) async throws {
    guard let session = lock.withLock({ sessions[sessionID] }) else { return }
    _ = try await session.sendControl(
      ["subtype": "set_permission_mode", "mode": Self.permissionMode(autoApprove: enabled)],
      timeout: 5
    )
  }

  /// A read-only chat's tools: measured on 2.1.296, asked to write
  /// a file and run `touch`, it had neither tool and did neither.
  static let readOnlyTools = "Read,Glob,Grep"

  static func sessionArguments(id: String, options: AgentSessionOptions, resuming: Bool) -> [String] {
    var arguments = [
      "--print",
      "--output-format", "stream-json",
      "--input-format", "stream-json",
      "--verbose",
      "--include-partial-messages",
      // Without this the CLI never asks for permission.
      "--permission-prompt-tool", "stdio",
      "--permission-mode", permissionMode(autoApprove: options.autoApprove)
    ]
    // `--tools` takes several values: a flag must follow it, never the prompt.
    if options.readOnly { arguments += ["--tools", readOnlyTools] }
    arguments += resuming ? ["--resume", id] : ["--session-id", id]
    if let model = options.model { arguments += ["--model", model.modelID] }
    arguments += effortArguments(options.effort)
    return arguments
  }

  static func permissionMode(autoApprove: Bool) -> String {
    autoApprove ? "acceptEdits" : "default"
  }

  func loadSession(id: String) async throws -> RemoteSessionSnapshot {
    guard let transcript = ClaudeCodeTranscript.locate(sessionID: id) else {
      throw AgentClientError.sessionNotFound
    }
    let parsed = ClaudeCodeTranscript.read(at: transcript.url)
    let live = lock.withLock { sessions[id] }
    let state: ConversationExecutionState = {
      guard let live else { return .idle }
      return live.executionState
    }()
    return RemoteSessionSnapshot(
      info: RemoteSessionInfo(
        id: id,
        title: parsed.title ?? "Claude Code",
        directory: live?.directory ?? transcript.directory,
        model: live?.model
      ),
      messages: parsed.messages,
      state: state,
      openInteractions: live?.openInteractions ?? []
    )
  }

  // MARK: - Sending

  func send(
    messageID: String,
    text: String,
    attachments: [OutgoingAttachment],
    to sessionID: String
  ) async throws {
    let session = try await requireSession(sessionID)
    var content: [[String: Any]] = []
    var prompt = text

    for attachment in attachments {
      if let image = Self.imageBlock(for: attachment) {
        content.append(image)
        continue
      }
      prompt += prompt.isEmpty ? "" : "\n"
      prompt += "Attached file: \(attachment.url.path)"
    }
    if !prompt.isEmpty {
      content.insert(["type": "text", "text": prompt], at: 0)
    }
    guard !content.isEmpty else { return }

    let frame: [String: Any] = [
      "type": "user",
      "message": ["role": "user", "content": content],
      "parent_tool_use_id": NSNull(),
      "session_id": sessionID
    ]
    guard let line = JSONObject.encode(frame) else {
      throw AgentClientError.transport("That message could not be encoded.")
    }
    session.rememberOutgoing(messageID: messageID, text: text)
    try session.process.writeLine(line)
    session.executionState = .working
    emit(.executionStateChanged(sessionID: sessionID, state: .working))
  }

  func steer(messageID: String, text: String, to sessionID: String) async throws {
    let session = try await requireSession(sessionID)
    guard session.executionState == .working else {
      throw AgentClientError.transport("No turn is running to add to.")
    }
    let frame: [String: Any] = [
      "type": "user",
      "message": ["role": "user", "content": [["type": "text", "text": text]]],
      "parent_tool_use_id": NSNull(),
      "session_id": sessionID
    ]
    guard let line = JSONObject.encode(frame) else {
      throw AgentClientError.transport("That message could not be encoded.")
    }
    session.rememberOutgoing(messageID: messageID, text: text)
    try session.process.writeLine(line)
  }

  func compact(sessionID: String) async throws {
    let session = try await requireSession(sessionID)
    guard let line = JSONObject.encode([
      "type": "user",
      "message": ["role": "user", "content": [["type": "text", "text": "/compact"]]],
      "parent_tool_use_id": NSNull(),
      "session_id": sessionID
    ]) else { throw AgentClientError.transport("That request could not be encoded.") }
    try session.process.writeLine(line)
    session.executionState = .working
    emit(.executionStateChanged(sessionID: sessionID, state: .working))
  }

  func contextUsage(sessionID: String) async -> AgentContextUsage? {
    guard let session = lock.withLock({ sessions[sessionID] }), session.process.isRunning,
          let response = try? await session.sendControl(["subtype": "get_context_usage"], timeout: 5)
    else { return nil }
    return AgentContextUsage.claudeCode(response)
  }

  func messageExists(id: String, in sessionID: String) async throws -> Bool {
    lock.withLock { sessions[sessionID]?.sentMessageIDs.contains(id) ?? false }
  }

  func stop(sessionID: String) async throws {
    guard let session = lock.withLock({ sessions[sessionID] }) else { return }
    _ = try? await session.sendControl(["subtype": "interrupt"], timeout: 5)
    session.executionState = .idle
    emit(.executionStateChanged(sessionID: sessionID, state: .idle))
  }

  // MARK: - Interactions

  func answerQuestion(requestID: String, sessionID: String, answers: [[String]]) async throws {
    throw AgentClientError.transport("Claude Code does not ask multiple-choice questions.")
  }

  func rejectQuestion(requestID: String, sessionID: String) async throws {
    throw AgentClientError.transport("Claude Code does not ask multiple-choice questions.")
  }

  func answerPermission(
    requestID: String,
    sessionID: String,
    decision: PermissionDecision,
    message: String?
  ) async throws {
    guard let session = lock.withLock({ sessions[sessionID] }),
          let pending = session.takePermission(requestID)
    else { throw AgentClientError.requestGone }

    var response: [String: Any]
    switch decision {
    case .once:
      response = ["behavior": "allow", "updatedInput": pending.input]
    case .always:
      response = [
        "behavior": "allow",
        "updatedInput": pending.input,
        "updatedPermissions": [[
          "type": "addRules",
          "rules": [["toolName": pending.toolName]],
          "behavior": "allow",
          "destination": "session"
        ]]
      ]
    case .reject:
      response = ["behavior": "deny", "message": Self.denialMessage(saying: message)]
    }

    let frame: [String: Any] = [
      "type": "control_response",
      "response": [
        "subtype": "success",
        "request_id": pending.controlRequestID,
        "response": response
      ]
    ]
    guard let line = JSONObject.encode(frame) else {
      throw AgentClientError.transport("That reply could not be encoded.")
    }
    try session.process.writeLine(line)
  }

  static func denialMessage(saying words: String?) -> String {
    guard let words = words?.trimmingCharacters(in: .whitespacesAndNewlines),
          !words.isEmpty
    else { return "The user did not allow this." }
    return "The user did not allow this. To tell you how to proceed, the user said:\n\(words)"
  }

  // MARK: - Events

  func events() -> AsyncStream<AgentEventEnvelope> {
    AsyncStream { continuation in
      lock.withLock { self.eventContinuation = continuation }
    }
  }

  func shutdown() async {
    let live = lock.withLock { Array(sessions.values) }
    for session in live {
      session.readerTask?.cancel()
      session.process.closeInput()
      session.process.terminate()
    }
    lock.withLock { sessions.removeAll() }
  }

  func release(sessionID: String) async {
    guard let session = lock.withLock({ sessions.removeValue(forKey: sessionID) }) else { return }
    session.readerTask?.cancel()
    session.process.closeInput()
    session.process.terminate()
  }

  // MARK: - Process lifecycle

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

  private func requireSession(_ sessionID: String) async throws -> LiveSession {
    if let session = lock.withLock({ sessions[sessionID] }), session.process.isRunning {
      return session
    }
    guard let directory = ClaudeCodeTranscript.locate(sessionID: sessionID)?.directory else {
      throw AgentClientError.sessionNotFound
    }
    return try await startSession(
      id: sessionID,
      options: AgentSessionOptions(directory: directory),
      resuming: true
    )
  }

  @discardableResult
  private func startSession(
    id: String,
    options: AgentSessionOptions,
    resuming: Bool
  ) async throws -> LiveSession {
    guard let executable = locate() else { throw AgentClientError.notInstalled }
    let directory = options.directory
    let model = options.model

    let arguments = Self.sessionArguments(id: id, options: options, resuming: resuming)

    let process = JSONLineProcess(
      executable: executable,
      arguments: arguments,
      directory: directory,
      category: "claude-code"
    )
    let session = LiveSession(id: id, directory: directory, model: model, process: process)
    process.onExit = { [weak self, weak session] status, stderr in
      guard let self, let session else { return }
      session.failPending(AgentClientError.processExited(status))
      if session.executionState.blocksSending {
        emit(.sessionFailed(
          sessionID: id,
          failure: MessageFailure(
            name: "ProcessExited",
            message: stderr.isEmpty ? "Claude Code stopped (status \(status))." : stderr
          )
        ))
      }
      session.executionState = .idle
      self.forget(session)
    }

    try process.start()
    lock.withLock { sessions[id] = session }
    session.readerTask = Task { [weak self] in
      for await line in process.lines {
        guard let self else { return }
        handle(line: line, in: session)
      }
    }
    do {
      _ = try await session.sendControl(["subtype": "initialize", "hooks": NSNull()], timeout: 30)
    } catch {
      guard process.isRunning else {
        forget(session)
        throw AgentClientError.serverStartFailed(process.exitDetail)
      }
      log.debug("claude handshake unanswered: \(String(describing: error), privacy: .public)")
    }
    return session
  }

  private func forget(_ session: LiveSession) {
    lock.withLock {
      if sessions[session.id] === session { sessions.removeValue(forKey: session.id) }
    }
  }

  func usageLimits() async -> AgentUsage? {
    guard let response = await throwawayControl(subtype: "get_usage") else { return nil }
    return AgentUsage.claudeCode(response)
  }

  /// A probe must not start the person's MCP servers or hooks.
  static let throwawayArguments = [
    "--print", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose",
    "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#,
  ]

  private func handshake() async -> JSONObject? {
    if let cached = lock.withLock({ cachedHandshake }) { return cached }
    guard let response = await throwawayControl(subtype: nil) else { return nil }
    lock.withLock { cachedHandshake = response }
    return response
  }

  private func throwawayControl(subtype: String?) async -> JSONObject? {
    guard let executable = locate() else { return nil }
    let process = JSONLineProcess(
      executable: executable,
      arguments: Self.throwawayArguments,
      directory: NSHomeDirectory(),
      category: "claude-code-probe"
    )
    guard (try? process.start()) != nil else { return nil }
    let deadline = throwawayDeadline
    let watchdog = Task {
      try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
      guard !Task.isCancelled else { return }
      process.terminate()
    }
    defer {
      watchdog.cancel()
      process.closeInput()
      process.terminate()
    }
    guard let line = JSONObject.encode([
      "type": "control_request",
      "request_id": "boltty_probe",
      "request": ["subtype": "initialize", "hooks": NSNull()]
    ]), (try? process.writeLine(line)) != nil else { return nil }
    let wanted = subtype.map { _ in "boltty_follow_up" } ?? "boltty_probe"
    if let subtype {
      guard let follow = JSONObject.encode([
        "type": "control_request",
        "request_id": wanted,
        "request": ["subtype": subtype]
      ]), (try? process.writeLine(follow)) != nil else { return nil }
    }

    for await raw in process.lines {
      guard let frame = JSONObject(line: raw), frame.string("type") == "control_response",
            let envelope = frame.object("response"),
            envelope.string("request_id") == wanted,
            let response = envelope.object("response")
      else { continue }
      return response
    }
    return nil
  }

  // MARK: - Reading the stream

  private func handle(line: String, in session: LiveSession) {
    guard let frame = JSONObject(line: line) else { return }
    switch frame.string("type") {
    case "control_response":
      session.resolveControl(frame)

    case "control_request":
      handleControlRequest(frame, in: session)

    case "stream_event":
      handleStreamEvent(frame, in: session)

    case "assistant":
      handleAssistant(frame, in: session)

    case "user":
      handleToolResult(frame, in: session)

    case "result":
      handleResult(frame, in: session)

    case "rate_limit_event":
      if let info = frame.object("rate_limit_info"), let hit = RateLimitHit.claudeCode(info) {
        session.rateLimitHit = hit
      }

    case "system":
      switch frame.string("subtype") {
      case "compact_boundary":
        emitCompaction(frame.object("compact_metadata"), in: session)
      case "init" where session.executionState != .working:
        session.executionState = .working
        emit(.executionStateChanged(sessionID: session.id, state: .working))
      default:
        break
      }

    default:
      break
    }
  }

  private func handleControlRequest(_ frame: JSONObject, in session: LiveSession) {
    guard let requestID = frame.string("request_id"),
          let request = frame.object("request")
    else { return }

    guard request.string("subtype") == "can_use_tool",
          let toolName = request.string("tool_name")
    else {
      let refusal: [String: Any] = [
        "type": "control_response",
        "response": [
          "subtype": "error",
          "request_id": requestID,
          "error": "Boltty does not implement this request."
        ]
      ]
      if let line = JSONObject.encode(refusal) { try? session.process.writeLine(line) }
      return
    }

    let input = (request["input"] as? [String: Any]) ?? [:]
    session.rememberPermission(
      LiveSession.PendingPermission(
        controlRequestID: requestID,
        toolName: toolName,
        input: input
      )
    )
    let conversationID = lock.withLock { conversationResolver }?(session.id) ?? UUID()
    let prompt = PermissionPrompt(
      action: toolName,
      resources: Self.resources(forTool: toolName, input: JSONObject(input)),
      savePatterns: [],
      toolCallID: request.string("tool_use_id")
    )
    session.executionState = .waiting
    emit(.interactionAsked(PendingInteraction(
      id: requestID,
      conversationID: conversationID,
      remoteSessionID: session.id,
      kind: .permission(prompt)
    )))
  }

  private func handleStreamEvent(_ frame: JSONObject, in session: LiveSession) {
    guard let event = frame.object("event") else { return }
    switch event.string("type") {
    case "message_start":
      guard let message = event.object("message"), let id = message.string("id") else { return }
      session.currentMessageID = id
      emit(.messageUpdated(
        sessionID: session.id,
        message: ConversationMessage(id: id, role: .agent, createdAt: Date())
      ))

    case "content_block_start":
      guard let messageID = session.currentMessageID,
            let index = event.int("index"),
            let block = event.object("content_block")
      else { return }
      let partID = "\(messageID)#\(index)"
      switch block.string("type") {
      case "text":
        emit(.partUpdated(
          sessionID: session.id,
          messageID: messageID,
          part: .text(TextPart(id: partID, kind: .text, text: block.string("text") ?? ""))
        ))
      case "thinking":
        emit(.partUpdated(
          sessionID: session.id,
          messageID: messageID,
          part: .reasoning(
            TextPart(id: partID, kind: .reasoning, text: block.string("thinking") ?? "")
          )
        ))
      default:
        break
      }

    case "content_block_delta":
      guard let messageID = session.currentMessageID,
            let index = event.int("index"),
            let delta = event.object("delta")
      else { return }
      let partID = "\(messageID)#\(index)"
      if let text = delta.string("text") {
        emit(.partDelta(
          sessionID: session.id, messageID: messageID, partID: partID, kind: .text, delta: text
        ))
      } else if let thinking = delta.string("thinking") {
        emit(.partDelta(
          sessionID: session.id, messageID: messageID, partID: partID,
          kind: .reasoning, delta: thinking
        ))
      }

    default:
      break
    }
  }

  private func handleAssistant(_ frame: JSONObject, in session: LiveSession) {
    guard let message = frame.object("message"), let messageID = message.string("id") else { return }
    session.currentMessageID = messageID
    for block in message.array("content") where block.string("type") == "tool_use" {
      guard let toolID = block.string("id"), let name = block.string("name") else { continue }
      let input = block.object("input") ?? JSONObject([:])
      emit(.partUpdated(
        sessionID: session.id,
        messageID: messageID,
        part: .activity(AgentActivity(
          id: toolID,
          name: name,
          summary: Self.summary(forTool: name, input: input),
          state: .running,
          files: Self.files(forTool: name, input: input),
          startedAt: Date()
        ))
      ))
    }
  }

  private func handleToolResult(_ frame: JSONObject, in session: LiveSession) {
    guard let messageID = session.currentMessageID,
          let message = frame.object("message")
    else { return }
    for block in message.array("content") where block.string("type") == "tool_result" {
      guard let toolID = block.string("tool_use_id") else { continue }
      let failed = block.bool("is_error") ?? false
      emit(.partUpdated(
        sessionID: session.id,
        messageID: messageID,
        part: .activity(AgentActivity(
          id: toolID,
          name: "",
          state: failed ? .failed : .completed,
          detail: block.rendered("content"),
          endedAt: Date()
        ))
      ))
    }
  }

  private func handleResult(_ frame: JSONObject, in session: LiveSession) {
    if let messageID = session.currentMessageID {
      emit(.messageUpdated(
        sessionID: session.id,
        message: ConversationMessage(
          id: messageID, role: .agent, createdAt: Date(), completedAt: Date()
        )
      ))
    }
    session.currentMessageID = nil
    if let hit = session.rateLimitHit {
      session.rateLimitHit = nil
      failForRateLimit(hit, detail: frame.string("result"), in: session)
      return
    }
    if frame.bool("is_error") == true {
      emit(.sessionFailed(
        sessionID: session.id,
        failure: MessageFailure(
          name: frame.string("subtype") ?? "Error",
          message: frame.string("result") ?? "That turn ended with an error."
        )
      ))
    }
    session.executionState = .idle
    emit(.executionStateChanged(sessionID: session.id, state: .idle))
  }

  private func failForRateLimit(_ hit: RateLimitHit, detail: String?, in session: LiveSession) {
    let messageID = "rate-limit-\(UUID().uuidString)"
    emit(.messageUpdated(
      sessionID: session.id,
      message: ConversationMessage(
        id: messageID, role: .agent, createdAt: Date(), completedAt: Date())
    ))
    emit(.sessionFailed(
      sessionID: session.id,
      failure: MessageFailure(
        name: "rate_limit_event",
        message: detail ?? "The plan's limit refused this turn.",
        rateLimit: hit
      )
    ))
    session.executionState = .rateLimited
    emit(.executionStateChanged(sessionID: session.id, state: .rateLimited))
  }

  private func emitCompaction(_ metadata: JSONObject?, in session: LiveSession) {
    let messageID = "compact-\(UUID().uuidString)"
    emit(.messageUpdated(
      sessionID: session.id,
      message: ConversationMessage(
        id: messageID, role: .agent, createdAt: Date(), completedAt: Date())
    ))
    emit(.partUpdated(
      sessionID: session.id, messageID: messageID,
      part: .activity(AgentCompaction.activity(
        id: "\(messageID)-row",
        before: metadata?.int("pre_tokens"),
        after: metadata?.int("post_tokens")))
    ))
  }

  private func emit(_ event: AgentEvent) {
    let continuation = lock.withLock { eventContinuation }
    continuation?.yield(AgentEventEnvelope(providerID: provider.rawValue, event: event))
  }

  // MARK: - Rendering a tool for a card

  static func resources(forTool tool: String, input: JSONObject) -> [String] {
    switch tool {
    case "Bash", "BashOutput":
      return [input.string("command") ?? ""].filter { !$0.isEmpty }
    case "Read", "Write", "Edit", "NotebookEdit":
      return [input.string("file_path") ?? input.string("path") ?? ""].filter { !$0.isEmpty }
    case "WebFetch":
      return [input.string("url") ?? ""].filter { !$0.isEmpty }
    default:
      return [input.rendered("command") ?? input.rendered("file_path") ?? ""]
        .filter { !$0.isEmpty }
    }
  }

  static func summary(forTool tool: String, input: JSONObject) -> String? {
    if let description = input.string("description") { return description }
    let resources = resources(forTool: tool, input: input)
    guard let first = resources.first, !first.isEmpty else { return nil }
    return "\(tool) \((first as NSString).lastPathComponent)"
  }

  static func files(forTool tool: String, input: JSONObject) -> [String] {
    guard let path = input.string("file_path") ?? input.string("path") else { return [] }
    return [path]
  }

  static func imageBlock(for attachment: OutgoingAttachment) -> [String: Any]? {
    let mime = attachment.mimeType ?? MIMEType.guess(for: attachment.url) ?? ""
    guard mime.hasPrefix("image/"), let data = try? Data(contentsOf: attachment.url) else {
      return nil
    }
    return [
      "type": "image",
      "source": [
        "type": "base64",
        "media_type": mime,
        "data": data.base64EncodedString()
      ]
    ]
  }
}
