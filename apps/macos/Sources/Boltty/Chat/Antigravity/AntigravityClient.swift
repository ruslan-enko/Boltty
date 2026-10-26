import Foundation

/// Google Antigravity's `agy`, one process per conversation.
///
/// `--input-format stream-json` keeps `agy` alive and runs a turn per line on
/// stdin, `{"event": "user", "message": {"content": …}}`; it answers in
/// NDJSON keyed on `event`: `init`, `step_update`*, `result` (agy 1.3.4 and
/// 1.4.0). Inbound there is the user message and
/// nothing else (`StreamInputUserMessage` is the binary's only input type),
/// which decides most of `capabilities`.
final class AntigravityClient: AgentClient, @unchecked Sendable {
  let provider = AgentId.antigravity

  /// - **`.permissions` through Boltty's own gate** (`AntigravityPermissionGate`):
  ///   print mode cannot ask, so the process runs with
  ///   `--dangerously-skip-permissions` and a `PreToolUse` hook asks Boltty
  ///   before each call. A refusal's words reach the model as the hook's
  ///   `reason` (`.permissionMessage`). Where the gate cannot be installed the
  ///   process runs as print mode does — refusing — and the reply says so.
  /// - **No `.questions`**: `ask_question` has no way back in print mode.
  /// - **`.interrupt`**: SIGINT ends the turn with a `result` ("interrupted")
  ///   and the process exits; the next send resumes with `--conversation`,
  ///   the conversation intact.
  /// - **`.workingDirectory`**: since 1.3 the process's directory is where it
  ///   writes. Until then it wrote under its own `scratch/`.
  /// - **`.attachments`, not `.images`**: a content block other than text
  ///   ends the run (1.4.0: `stream input content block type "image" is not
  ///   supported`), so a file goes as its path in the words and `agy` opens
  ///   it with `view_file` — which sees a picture. The gate lets that read
  ///   through without a card (`AntigravityToolPolicy.readGrants`); print
  ///   mode alone refuses a read outside the folder.
  /// - **`.autoApproval`** lets edits inside the chat's folder through the
  ///   gate without a card; commands still ask. Without the gate it is
  ///   `--mode accept-edits`, a launch flag for the next process.
  let capabilities: AgentCapabilities = [
    .modelSelection, .reasoningEffort, .resumeSession, .workingDirectory, .attachments,
    .autoApproval, .interrupt, .rereadableTranscript, .permissions, .permissionMessage,
    .usageLimits,
  ]

  /// `init` is the handshake: it costs no model call and carries the id
  /// Antigravity minted. A process that has said nothing by then is stuck.
  static let initDeadline: TimeInterval = 25

  private let lock = NSLock()
  private var sessions: [String: LiveSession] = [:]
  private var eventContinuation: AsyncStream<AgentEventEnvelope>.Continuation?
  private let executableOverride: String?
  private let transcriptRoot: URL
  private let hooksFile: URL
  private let scriptFile: URL
  private let gateDirectory: URL
  private var gate: AntigravityPermissionGate?
  private var gateTried = false
  private var asks: [String: PendingAsk] = [:]
  private var conversationResolver: (@Sendable (String) -> UUID?)?

  init(
    executable: String? = nil,
    transcriptRoot: URL = AntigravityTranscript.defaultRoot,
    hooksFile: URL = AntigravityPermissionGate.defaultHooksFile,
    scriptFile: URL = AntigravityPermissionGate.defaultScriptFile,
    gateDirectory: URL = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-agy-gate-\(getpid())")
  ) {
    executableOverride = executable
    self.transcriptRoot = transcriptRoot
    self.hooksFile = hooksFile
    self.scriptFile = scriptFile
    self.gateDirectory = gateDirectory
  }

  func setConversationResolver(_ resolve: @escaping @Sendable (String) -> UUID?) {
    lock.withLock { conversationResolver = resolve }
  }

  private struct PendingAsk {
    let sessionID: String
    let always: String
  }

  /// Guarded by the client's lock.
  private final class LiveSession: @unchecked Sendable {
    /// Antigravity's own id: `--conversation` takes nothing else, and a new
    /// one exists only once `init` has named it.
    var id: String?
    var directory: String
    var model: ModelSelection?
    var effort: String?
    var autoApprove: Bool
    var process: JSONLineProcess?
    var pendingMessageID: String?
    var sentMessageIDs: Set<String> = []
    var stopping = false
    var initWaiter: CheckedContinuation<String, Error>?
    /// Whether the current process has said `init` — it can before anyone waits.
    var initialized = false
    /// What "Always allow" granted in this chat, while Boltty runs.
    var granted: Set<String> = []

    init(id: String?, directory: String, model: ModelSelection?, effort: String?, autoApprove: Bool) {
      self.id = id
      self.directory = directory
      self.model = model
      self.effort = effort
      self.autoApprove = autoApprove
    }
  }

  // MARK: - Availability

  func probe() async -> AgentAvailability {
    guard let executable = locate() else { return .notInstalled }
    guard let answer = await OneShotCommand.run(
      executable, ["--version"], deadline: OneShotCommand.versionDeadline
    ), answer.exitCode == 0,
      let version = answer.output.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .newlines).first, !version.isEmpty
    else {
      return .unavailable("`agy` is installed but did not answer `--version`.")
    }
    return .available(version: version)
  }

  /// `agy models` prints `<id>\t<label>` per line and reaches no model.
  ///
  /// **Effort is spelled into the id** — `gemini-3.8-flash-high`, `-medium`,
  /// `-low` — while `--model` takes the base name with `--effort` beside it
  /// (1.3.4's changelog). So the suffix is folded into `effortOptions` and one
  /// model stays on the menu.
  func availableModels() async throws -> [AgentModelOption] {
    guard let executable = locate() else { throw AgentClientError.notInstalled }
    guard let answer = await OneShotCommand.run(
      executable, ["models"], deadline: OneShotCommand.versionDeadline * 2
    ), answer.exitCode == 0 else {
      throw AgentClientError.transport("`agy models` did not answer.")
    }
    let models = Self.models(fromListing: answer.output, provider: provider.rawValue)
    guard !models.isEmpty else { throw AgentClientError.transport("`agy models` listed nothing.") }
    return models
  }

  static func models(fromListing output: String, provider: String) -> [AgentModelOption] {
    var order: [String] = []
    var efforts: [String: [String]] = [:]
    for line in output.components(separatedBy: .newlines) {
      let columns = line.components(separatedBy: "\t")
      guard columns.count >= 2 else { continue }
      let id = columns[0].trimmingCharacters(in: .whitespaces)
      guard !id.isEmpty else { continue }
      let (base, effort) = splitEffort(id)
      if !order.contains(base) { order.append(base) }
      if let effort, !(efforts[base] ?? []).contains(effort) {
        efforts[base, default: []].append(effort)
      }
    }
    return order.enumerated().map { index, base in
      AgentModelOption(
        selection: ModelSelection(providerID: provider, modelID: base),
        isDefault: index == 0,
        effortOptions: (efforts[base] ?? []).map { AgentEffortOption(value: $0) }
      )
    }
  }

  static func splitEffort(_ id: String) -> (base: String, effort: String?) {
    for effort in ["xhigh", "high", "medium", "low", "max"] where id.hasSuffix("-\(effort)") {
      return (String(id.dropLast(effort.count + 1)), effort)
    }
    return (id, nil)
  }

  /// `/usage` in print mode: answered from the account, no model call and
  /// no conversation written (~4 s).
  func usageLimits() async -> AgentUsage? {
    guard let executable = locate(),
          let answer = await OneShotCommand.run(
            executable, ["-p=/usage", "--output-format", "json"], deadline: Self.usageDeadline
          ), answer.exitCode == 0
    else { return nil }
    let result = answer.output.split(whereSeparator: \.isNewline).lazy
      .compactMap { JSONObject(line: String($0)) }.first
    return result.flatMap(AgentUsage.antigravity)
  }

  static let usageDeadline: TimeInterval = 20

  // MARK: - Sessions

  /// Starts the conversation's process and waits for `init`, which names it.
  /// No turn runs, and the conversation's file is on disk from then on.
  func createSession(id: String, options: AgentSessionOptions) async throws -> RemoteSessionInfo {
    guard let executable = locate() else { throw AgentClientError.notInstalled }
    let session = LiveSession(
      id: nil,
      directory: options.directory,
      model: options.model,
      effort: options.effort,
      autoApprove: options.autoApprove
    )
    let remoteID = try await start(session, executable: executable)
    lock.withLock { sessions[remoteID] = session }
    return RemoteSessionInfo(
      id: remoteID,
      title: provider.shortDisplayName,
      directory: options.directory,
      model: options.model
    )
  }

  func loadSession(id: String) async throws -> RemoteSessionSnapshot {
    let live = lock.withLock { sessions[id] }
    let disk: DiskTranscript?
    do {
      disk = try AntigravityTranscript.transcript(sessionID: id, in: transcriptRoot)
    } catch {
      throw AgentClientError.transport(String(describing: error))
    }
    guard let disk else { throw AgentClientError.sessionNotFound }
    let working = lock.withLock { live?.pendingMessageID != nil }
    return RemoteSessionSnapshot(
      info: RemoteSessionInfo(
        id: id,
        title: provider.shortDisplayName,
        directory: live?.directory ?? NSHomeDirectory(),
        model: live?.model
      ),
      messages: disk.messages,
      state: working ? .working : .idle,
      openInteractions: []
    )
  }

  func messageExists(id: String, in sessionID: String) async throws -> Bool {
    lock.withLock { sessions[sessionID]?.sentMessageIDs.contains(id) ?? false }
  }

  func send(
    messageID: String,
    text: String,
    attachments: [OutgoingAttachment],
    to sessionID: String
  ) async throws {
    guard let executable = locate() else { throw AgentClientError.notInstalled }
    let session = try lock.withLock { () -> LiveSession in
      if let session = sessions[sessionID] { return session }
      guard FileManager.default.fileExists(
        atPath: AntigravityTranscript.url(sessionID: sessionID, in: transcriptRoot).path
      ) else { throw AgentClientError.sessionNotFound }
      // A conversation from before a relaunch: the next process resumes it.
      let session = LiveSession(
        id: sessionID, directory: NSHomeDirectory(), model: nil, effort: nil, autoApprove: false
      )
      sessions[sessionID] = session
      return session
    }

    if lock.withLock({ session.process?.isRunning != true }) {
      _ = try await start(session, executable: executable)
    }
    guard let line = JSONObject.encode([
      "event": "user",
      "message": ["role": "user", "content": text],
    ]) else {
      throw AgentClientError.transport("That prompt could not be encoded.")
    }

    let process = lock.withLock { () -> JSONLineProcess? in
      session.pendingMessageID = messageID
      session.sentMessageIDs.insert(messageID)
      session.granted.formUnion(AntigravityToolPolicy.readGrants(for: attachments))
      session.stopping = false
      return session.process
    }
    emit(.executionStateChanged(sessionID: sessionID, state: .working))
    do {
      guard let process else { throw AgentClientError.processExited(-1) }
      try process.writeLine(line)
    } catch {
      lock.withLock {
        session.pendingMessageID = nil
        session.sentMessageIDs.remove(messageID)
      }
      emit(.executionStateChanged(sessionID: sessionID, state: .failed))
      throw error
    }
  }

  /// Starts `agy` for a conversation — resuming it when it has an id — and
  /// answers once `init` has named it. A CLI that refuses its arguments says
  /// so on stderr and exits; that line is the error.
  private func start(_ session: LiveSession, executable: String) async throws -> String {
    let gate = preparedGate()
    let (arguments, directory) = lock.withLock {
      (Self.arguments(for: session, gated: gate != nil), session.directory)
    }
    let process = JSONLineProcess(
      executable: executable,
      arguments: arguments,
      directory: directory,
      environment: gate.map { [AntigravityPermissionGate.environmentKey: $0.directory.path] } ?? [:],
      category: "antigravity"
    )
    lock.withLock {
      session.process = process
      session.initialized = false
    }
    // The exit, not the end of stdout, carries what the CLI said on stderr.
    process.onExit = { [weak self] status, stderr in
      guard let self else { return }
      let waiter = self.lock.withLock { () -> CheckedContinuation<String, Error>? in
        defer { session.initWaiter = nil }
        return session.initWaiter
      }
      waiter?.resume(throwing: AgentClientError.serverStartFailed(
        JSONLineProcess.exitDetail(status: status, stderr: stderr)
      ))
    }
    try process.start()
    Task { [weak self] in await self?.read(process, session: session) }

    return try await withCheckedThrowingContinuation { continuation in
      let named = lock.withLock { () -> String? in
        if session.initialized, let id = session.id { return id }
        session.initWaiter = continuation
        return nil
      }
      if let named {
        continuation.resume(returning: named)
        return
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.initDeadline) {
        [weak self] in
        guard let self else { return }
        let waiter = self.lock.withLock { () -> CheckedContinuation<String, Error>? in
          defer { session.initWaiter = nil }
          return session.initWaiter
        }
        guard let waiter else { return }
        process.terminate()
        waiter.resume(throwing: AgentClientError.startupTimedOut)
      }
    }
  }

  /// `--print=`, attached and empty: `--print` takes an optional value, and a
  /// bare one swallows the next flag as the prompt.
  ///
  /// `--dangerously-skip-permissions` only with the gate in place: then the
  /// gate is what asks, and nothing runs that it did not allow.
  private static func arguments(for session: LiveSession, gated: Bool) -> [String] {
    var arguments = ["--input-format", "stream-json", "--output-format", "stream-json"]
    if let model = session.model { arguments += ["--model", model.modelID] }
    if let effort = session.effort { arguments += ["--effort", effort] }
    if gated {
      arguments.append("--dangerously-skip-permissions")
    } else if session.autoApprove {
      arguments += ["--mode", "accept-edits"]
    }
    if let id = session.id { arguments += ["--conversation", id] }
    arguments.append("--print=")
    return arguments
  }

  // MARK: - Reading

  /// **Text arrives twice**: `step_update.text_delta` streams it and
  /// `result.response` repeats it whole. Only the deltas are taken.
  private func read(_ process: JSONLineProcess, session: LiveSession) async {
    var reply: ConversationMessage?

    for await line in process.lines {
      guard let frame = JSONObject(line: line) else { continue }
      switch frame.string("event") {
      case "init":
        guard let id = frame.string("conversation_id") else { continue }
        let waiter = lock.withLock { () -> CheckedContinuation<String, Error>? in
          if session.id == nil { session.id = id }
          session.initialized = true
          defer { session.initWaiter = nil }
          return session.initWaiter
        }
        waiter?.resume(returning: id)

      case "step_update":
        guard let step = frame.object("step_update"),
              let (sessionID, messageID) = turn(of: session)
        else { continue }
        let replyID = "\(messageID)-reply"
        if reply == nil {
          reply = ConversationMessage(id: replyID, role: .agent, createdAt: Date())
          emit(.messageUpdated(sessionID: sessionID, message: reply!))
        }
        switch step.string("step_type") {
        case "agent_response":
          guard let delta = step.string("text_delta"), !delta.isEmpty else { continue }
          let partID = "\(replyID)-text-\(step.int("step_index") ?? 0)"
          reply?.appendDelta(delta, toPart: partID, kind: .text)
          emit(.partDelta(
            sessionID: sessionID, messageID: replyID, partID: partID, kind: .text, delta: delta
          ))

        case "tool":
          guard let name = step.string("tool_name") else { continue }
          let state: AgentActivity.State = switch step.string("state") {
          case "DONE": .completed
          case "ERROR": .failed
          default: .running
          }
          let info = step.object("tool_info")?.object("parameters")
          let activity = AgentActivity(
            id: "\(replyID)-tool-\(step.int("step_index") ?? 0)",
            name: name,
            summary: info?.string("toolAction") ?? info?.string("toolSummary"),
            state: state
          )
          reply?.upsert(.activity(activity))
          emit(.partUpdated(sessionID: sessionID, messageID: replyID, part: .activity(activity)))

        default:
          continue
        }

      case "result":
        guard let result = frame.object("result"),
              let (sessionID, messageID) = turn(of: session)
        else { continue }
        let stopped = lock.withLock { session.stopping }
        let failure = Self.failure(of: result, stopped: stopped)
        if reply != nil || failure != nil {
          var building = reply ?? ConversationMessage(
            id: "\(messageID)-reply", role: .agent, createdAt: Date()
          )
          building.completedAt = Date()
          building.failure = failure
          emit(.messageUpdated(sessionID: sessionID, message: building))
        }
        let isFailed = failure?.name == Self.turnErrorName
        if isFailed, let failure {
          emit(.sessionFailed(sessionID: sessionID, failure: failure))
        }
        emit(.executionStateChanged(sessionID: sessionID, state: isFailed ? .failed : .idle))
        reply = nil
        lock.withLock { session.pendingMessageID = nil }

      default:
        continue
      }
    }

    // The process ended. A turn it never finished must not stay "working".
    let (sessionID, interrupted) = lock.withLock { () -> (String?, Bool) in
      let interrupted = session.pendingMessageID != nil && !session.stopping
      session.pendingMessageID = nil
      if session.process === process { session.process = nil }
      return (session.id, interrupted)
    }
    if let sessionID { settleAsks(of: sessionID, reason: "Antigravity stopped.") }
    guard let sessionID, interrupted else { return }
    emit(.sessionFailed(sessionID: sessionID, failure: MessageFailure(
      name: "AntigravityExited", message: "`agy` stopped: \(process.exitDetail)"
    )))
    emit(.executionStateChanged(sessionID: sessionID, state: .failed))
  }

  private func turn(of session: LiveSession) -> (String, String)? {
    lock.withLock {
      guard let id = session.id, let message = session.pendingMessageID else { return nil }
      return (id, message)
    }
  }

  static let deniedName = "AntigravityDenied"
  static let turnErrorName = "AntigravityTurnError"

  /// What a `result` says went wrong, if anything. A refusal print mode made
  /// on the person's behalf is said in the agent's terms, with the two ways
  /// round it.
  static func failure(of result: JSONObject, stopped: Bool) -> MessageFailure? {
    if result.string("status") != "SUCCESS" {
      let error = result.string("error") ?? "Antigravity ended the turn without a result."
      if stopped || error == "interrupted" { return MessageFailure(name: "aborted", message: error) }
      return MessageFailure(name: turnErrorName, message: error)
    }
    let actions = result.array("denied_actions")
    let denied = actions.compactMap { $0.string("display_name") ?? $0.string("action") }
    guard !denied.isEmpty else { return nil }
    // Auto Mode is `--mode accept-edits`: it lets file writes through and
    // still refuses commands, so it is offered only where it would help.
    let onlyEdits = actions.allSatisfy { $0.string("action") == "write_file" }
    let remedy = onlyEdits
      ? "Turn on Auto Mode for this chat to allow edits, or allow them in Antigravity's settings (permissions.allow)."
      : "Auto Mode does not cover commands; allow them in Antigravity's settings (permissions.allow)."
    return MessageFailure(
      name: deniedName,
      message: "Antigravity cannot ask for permission when Boltty runs it, so it refused: "
        + denied.joined(separator: ", ") + ". " + remedy
    )
  }

  // MARK: - Control

  /// SIGINT: `agy` ends the turn with a `result` and exits. The next send
  /// resumes the conversation in a new process.
  func stop(sessionID: String) async throws {
    let process = lock.withLock { () -> JSONLineProcess? in
      guard let session = sessions[sessionID], session.pendingMessageID != nil else { return nil }
      session.stopping = true
      return session.process
    }
    settleAsks(of: sessionID, reason: "The user stopped the turn.")
    guard let process, process.isRunning else { return }
    kill(process.processIdentifier, SIGINT)
  }

  func answerQuestion(requestID: String, sessionID: String, answers: [[String]]) async throws {
    throw AgentClientError.requestGone
  }

  func rejectQuestion(requestID: String, sessionID: String) async throws {
    throw AgentClientError.requestGone
  }

  func answerPermission(
    requestID: String,
    sessionID: String,
    decision: PermissionDecision,
    message: String?
  ) async throws {
    let (ask, gate) = lock.withLock { (asks.removeValue(forKey: requestID), self.gate) }
    guard let ask, let gate else { throw AgentClientError.requestGone }
    switch decision {
    case .once:
      gate.answer(requestID, decision: "allow")
    case .always:
      lock.withLock { _ = sessions[ask.sessionID]?.granted.insert(ask.always) }
      gate.answer(requestID, decision: "allow")
    case .reject:
      gate.answer(requestID, decision: "deny", reason: Self.denialReason(message))
    }
    emit(.interactionResolved(
      sessionID: ask.sessionID, requestID: requestID, resolution: .permission(decision)
    ))
    emit(.executionStateChanged(sessionID: ask.sessionID, state: .working))
  }

  /// The hook's `reason` reaches the model as "tool call denied by pre-tool
  /// hook: <reason>" (measured), so the person's words go as theirs.
  static func denialReason(_ message: String?) -> String {
    guard let words = message?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty
    else { return "The user refused this." }
    return "The user refused this and said: \(words)"
  }

  // MARK: - The gate

  /// Installs the hook and starts the hand-over folder, once. `nil` when that
  /// failed — the process then runs without the bypass and print mode refuses.
  private func preparedGate() -> AntigravityPermissionGate? {
    lock.lock()
    if gateTried { defer { lock.unlock() }; return gate }
    gateTried = true
    lock.unlock()
    let gate = AntigravityPermissionGate(directory: gateDirectory)
    do {
      try AntigravityPermissionGate.install(hooksFile: hooksFile, scriptFile: scriptFile)
      gate.onRequest = { [weak self] request in self?.handle(request) }
      try gate.start()
    } catch {
      return nil
    }
    lock.withLock { self.gate = gate }
    return gate
  }

  private func handle(_ request: AntigravityPermissionGate.Request) {
    let found = lock.withLock { () -> (LiveSession, Set<String>, Bool, String)? in
      guard let session = sessions[request.conversationID] else { return nil }
      return (session, session.granted, session.autoApprove, session.directory)
    }
    guard let gate = lock.withLock({ self.gate }) else { return }
    guard let (_, granted, autoApprove, directory) = found else {
      gate.answer(request.id, decision: "deny", reason: "Boltty does not know this conversation.")
      return
    }
    let verdict = AntigravityToolPolicy.verdict(
      tool: request.tool,
      arguments: request.arguments,
      directory: request.workspace ?? directory,
      autoApprove: autoApprove,
      granted: granted
    )
    guard case let .ask(action, resources, always) = verdict else {
      gate.answer(request.id, decision: "allow")
      return
    }
    let sessionID = request.conversationID
    guard let conversationID = lock.withLock({ conversationResolver })?(sessionID) else {
      gate.answer(request.id, decision: "deny", reason: "Nobody in Boltty can answer this.")
      return
    }
    lock.withLock { asks[request.id] = PendingAsk(sessionID: sessionID, always: always) }
    emit(.interactionAsked(PendingInteraction(
      id: request.id,
      conversationID: conversationID,
      remoteSessionID: sessionID,
      kind: .permission(PermissionPrompt(
        action: action,
        resources: resources,
        savePatterns: [],
        toolCallID: nil
      ))
    )))
    emit(.executionStateChanged(sessionID: sessionID, state: .waiting))

    // The hook gives up before `agy` kills it; the card goes first.
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + AntigravityPermissionGate.cardLifetime
    ) { [weak self] in
      guard let self, self.lock.withLock({ self.asks.removeValue(forKey: request.id) }) != nil
      else { return }
      gate.answer(request.id, decision: "deny", reason: "Nobody answered in time.")
      self.emit(.interactionResolved(sessionID: sessionID, requestID: request.id, resolution: .expired))
    }
  }

  /// Refuses every open ask of a session — a stop, or its process gone.
  private func settleAsks(of sessionID: String, reason: String) {
    let (open, gate) = lock.withLock { () -> ([String], AntigravityPermissionGate?) in
      let open = asks.filter { $0.value.sessionID == sessionID }.map(\.key)
      open.forEach { asks.removeValue(forKey: $0) }
      return (open, self.gate)
    }
    for id in open {
      gate?.answer(id, decision: "deny", reason: reason)
      emit(.interactionResolved(sessionID: sessionID, requestID: id, resolution: .expired))
    }
  }

  /// The mode is a launch flag, so an idle process is let go and the next
  /// send starts one under the new mode. A running turn keeps the old one.
  func setAutoApproval(_ enabled: Bool, sessionID: String) async throws {
    let idle = lock.withLock { () -> JSONLineProcess? in
      guard let session = sessions[sessionID], session.autoApprove != enabled else { return nil }
      session.autoApprove = enabled
      // With the gate the mode is Boltty's and reaches the running turn.
      guard gate == nil, session.pendingMessageID == nil else { return nil }
      defer { session.process = nil }
      return session.process
    }
    idle?.closeInput()
    idle?.terminate()
  }

  func events() -> AsyncStream<AgentEventEnvelope> {
    AsyncStream { continuation in
      lock.withLock { self.eventContinuation = continuation }
    }
  }

  func release(sessionID: String) async {
    guard let process = lock.withLock({ sessions.removeValue(forKey: sessionID)?.process }) else { return }
    process.closeInput()
    process.terminate()
  }

  func shutdown() async {
    let (live, gate) = lock.withLock { () -> ([JSONLineProcess], AntigravityPermissionGate?) in
      let processes = sessions.values.compactMap(\.process)
      sessions.removeAll()
      asks.removeAll()
      return (processes, self.gate)
    }
    gate?.stop()
    for process in live {
      process.closeInput()
      process.terminate()
    }
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
}
