import Foundation
import os

final class OpenCodeClient: AgentClient, @unchecked Sendable {
  let provider = AgentId.opencode

  let capabilities: AgentCapabilities = [
    .modelSelection, .permissions, .questions, .attachments, .images,
    .interrupt, .resumeSession, .workingDirectory, .rereadableTranscript,
    .activityHistory, .permissionMessage, .steering
  ]

  private let server: OpenCodeServer
  /// Boltty's own server for sessions in folders macOS keeps from the background service.
  private let ownServer: OpenCodeServer
  /// The server's cap: limit=201 answers 400.
  static let messagePageLimit = 200

  static let transcriptMessageCap = 1_000

  static func messagesPath(sessionID: String) -> String {
    "/api/session/\(sessionID)/message?order=desc&limit=\(messagePageLimit)"
  }

  static func messagesPath(sessionID: String, cursor: String) -> String {
    let escaped = cursor.addingPercentEncoding(
      withAllowedCharacters: .alphanumerics
    ) ?? cursor
    return "/api/session/\(sessionID)/message?limit=\(messagePageLimit)&cursor=\(escaped)"
  }

  private var lastSequence: [String: Int] = [:]
  private var allowances = OpenCodeAllowances()
  private var historyIsAbsent = false
  private var freeModels: Set<String> = []

  private var formFields: [String: [OpenCodeDTO.FormRequest.Field]] = [:]
  /// true: the session runs on `ownServer`. Absent: not yet asked.
  private var runsOnOwnServer: [String: Bool] = [:]

  private let urlSession: URLSession
  private let log = Logger(subsystem: "com.boltty", category: "opencode-client")

  var conversationResolver: (@Sendable (String) -> UUID?)?

  func setConversationResolver(_ resolve: @escaping @Sendable (String) -> UUID?) {
    conversationResolver = resolve
  }

  private let lock = NSLock()
  private var eventContinuation: AsyncStream<AgentEventEnvelope>.Continuation?
  private var streamTask: Task<Void, Never>?
  private var ownStreamTask: Task<Void, Never>?

  init(
    server: OpenCodeServer = OpenCodeServer(),
    ownServer: OpenCodeServer = OpenCodeServer(serviceState: nil),
    urlSession: URLSession? = nil
  ) {
    self.server = server
    self.ownServer = ownServer
    if let urlSession {
      self.urlSession = urlSession
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 30
      configuration.timeoutIntervalForResource = .infinity
      configuration.waitsForConnectivity = false
      self.urlSession = URLSession(configuration: configuration)
    }
  }

  // MARK: - Availability

  func probe() async -> AgentAvailability {
    guard await server.locateExecutable() != nil else { return .notInstalled }
    guard let version = await server.version() else {
      return .unavailable("OpenCode did not report a version.")
    }
    return .available(version: version)
  }

  func availableModels() async throws -> [AgentModelOption] {
    do {
      let fromServer = try await modelsFromServer()
      if !fromServer.isEmpty { return fromServer }
      log.debug("opencode served an empty model catalog; asking the CLI")
    } catch {
      try Task.checkCancellation()
      log.debug("opencode catalogue failed (\(error.localizedDescription, privacy: .public)); asking the CLI")
      let fromCLI = OpenCodeMapper.models(fromCLILines: await server.modelLines())
      guard fromCLI.isEmpty else { return fromCLI }
      throw error
    }
    try Task.checkCancellation()
    return OpenCodeMapper.models(fromCLILines: await server.modelLines())
  }

  func activityHistory() async -> AgentActivityHistory? {
    guard let stats: OpenCodeStatsDTO = try? await get("/api/experimental/session/stats"),
          let data = stats.data
    else { return nil }
    var object: [String: Any] = [
      "activity": (data.activity ?? []).map { ["date": $0.date ?? "", "steps": $0.steps ?? 0] }
    ]
    if let streak = data.streak { object["streak"] = streak }
    if let sessions = data.sessions { object["sessions"] = sessions }
    if let prompts = data.prompts { object["prompts"] = prompts }
    return AgentActivityHistory.openCode(JSONObject(object))
  }

  func modelsFromServer() async throws -> [AgentModelOption] {
    if let modern = try? await modelsFromModelRoute(), !modern.isEmpty { return modern }
    return try await modelsFromProviderRoute()
  }

  private func modelsFromModelRoute() async throws -> [AgentModelOption] {
    let payload: JSONValue = try await get("/api/model")
    guard let rows = payload["data"]?.arrayValue else { return [] }
    var free: Set<String> = []
    var options: [AgentModelOption] = []
    for row in rows {
      guard let id = row["modelID"]?.stringValue ?? row["id"]?.stringValue,
            let providerID = row["providerID"]?.stringValue
      else { continue }
      if row["enabled"]?.boolValue == false { continue }
      if row["settings"]?["apiKey"]?.stringValue == "public" {
        free.insert("\(providerID)/\(id)")
      }
      options.append(
        OpenCodeMapper.model(
          from: OpenCodeDTO.ModelInfo(
            id: id, providerID: providerID, name: row["name"]?.stringValue
          ),
          isDefault: false
        )
      )
    }
    lock.withLock { freeModels = free }
    return options
  }

  private func modelsFromProviderRoute() async throws -> [AgentModelOption] {
    let payload: JSONValue = try await get("/provider")
    let connected = Set((payload["connected"]?.arrayValue ?? []).compactMap(\.stringValue))
    let defaults = payload["default"]?.objectValue ?? [:]
    return (payload["all"]?.arrayValue ?? []).flatMap { provider -> [AgentModelOption] in
      guard let providerID = provider["id"]?.stringValue, connected.contains(providerID) else {
        return []
      }
      let fallback = defaults[providerID]?.stringValue
      return (provider["models"]?.objectValue ?? [:])
        .sorted { $0.key < $1.key }
        .compactMap { _, model in
          guard let id = model["id"]?.stringValue else { return nil }
          return OpenCodeMapper.model(
            from: OpenCodeDTO.ModelInfo(
              id: id,
              providerID: providerID,
              name: model["name"]?.stringValue
            ),
            isDefault: id == fallback
          )
        }
    }
  }

  // MARK: - Sessions

  func createSession(
    id: String,
    options: AgentSessionOptions
  ) async throws -> RemoteSessionInfo {
    let directory = options.directory
    let model = options.model
    // The free tier refuses a session id in Boltty's spelling; let the server name free sessions.
    let free = await isFree(model)
    let body = OpenCodeDTO.CreateSessionRequest(
      id: free ? nil : id,
      location: OpenCodeDTO.LocationRef(directory: directory, workspaceID: nil),
      model: model.map {
        OpenCodeDTO.ModelRef(id: $0.modelID, providerID: $0.providerID, variant: nil)
      }
    )
    let own = await needsOwnServer(directory: directory)
    do {
      let response: OpenCodeDTO.DataEnvelope<OpenCodeDTO.SessionInfo> = try await perform(
        path: "/api/session", method: "POST", body: body, on: own ? ownServer : server
      )
      lock.withLock { runsOnOwnServer[response.data.id] = own }
      if own { startOwnStreamIfNeeded() }
      return info(from: response.data, fallbackDirectory: directory)
    } catch AgentClientError.indeterminate {
      guard !free else { throw AgentClientError.indeterminate("session creation") }
      if let existing = try? await loadSession(id: id) { return existing.info }
      throw AgentClientError.indeterminate("session creation")
    }
  }

  // MARK: - Which server runs a session

  /// launchd starts the background service, so no app answers for it to macOS's privacy
  /// checks: it is refused these folders (an empty HTTP 500 on the first prompt). Boltty's own
  /// server is Boltty's child and reaches whatever Boltty was allowed.
  static func isPrivacyProtected(_ directory: String, home: String = NSHomeDirectory()) -> Bool {
    let path = (directory as NSString).standardizingPath
    if path.hasPrefix("/Volumes/") { return true }
    let guarded = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
    return guarded.contains { folder in
      let root = (home as NSString).appendingPathComponent(folder)
      return path == root || path.hasPrefix(root + "/")
    }
  }

  private func needsOwnServer(directory: String) async -> Bool {
    guard Self.isPrivacyProtected(directory) else { return false }
    return (try? await server.start())?.isService == true
  }

  /// A session made in an earlier launch is placed by its folder, read off the record; reading
  /// it needs no access to the folder.
  private func server(forSession sessionID: String) async -> OpenCodeServer {
    if let own = lock.withLock({ runsOnOwnServer[sessionID] }) { return own ? ownServer : server }
    guard let session: OpenCodeDTO.DataEnvelope<OpenCodeDTO.SessionInfo> = try? await perform(
      path: "/api/session/\(sessionID)", method: "GET", body: Optional<EmptyBody>.none, on: server
    ) else { return server }
    let own = await needsOwnServer(directory: session.data.location?.directory ?? NSHomeDirectory())
    lock.withLock { runsOnOwnServer[sessionID] = own }
    if own { startOwnStreamIfNeeded() }
    return own ? ownServer : server
  }

  static func sessionID(inPath path: String) -> String? {
    let prefix = "/api/session/"
    guard path.hasPrefix(prefix) else { return nil }
    let id = path.dropFirst(prefix.count).prefix { $0 != "/" && $0 != "?" }
    return id.isEmpty ? nil : String(id)
  }

  private func allMessages(sessionID: String) async throws -> [OpenCodeDTO.Message] {
    try await Self.walkTranscript(sessionID: sessionID) { try await self.get($0) }
  }

  static func walkTranscript(
    sessionID: String,
    fetch: (String) async throws -> OpenCodeDTO.ListEnvelope<OpenCodeDTO.Message>
  ) async rethrows -> [OpenCodeDTO.Message] {
    var collected: [OpenCodeDTO.Message] = []
    var path = messagesPath(sessionID: sessionID)

    while collected.count < transcriptMessageCap {
      let page = try await fetch(path)
      guard !page.data.isEmpty else { break }
      collected += page.data
      guard let next = page.cursor?.next, !next.isEmpty else { break }
      path = messagesPath(sessionID: sessionID, cursor: next)
    }

    return collected.reversed()
  }

  func missedAnything(sessionID: String) async -> Bool? {
    guard lock.withLock({ !historyIsAbsent }) else { return nil }
    guard let seen = lock.withLock({ lastSequence[sessionID] }) else {
      return Self.missedAnything(seen: nil, events: nil)
    }
    let path = "/api/session/\(sessionID)/history?limit=1&after=\(seen)"
    do {
      let page: OpenCodeDTO.HistoryEnvelope = try await get(path)
      return Self.missedAnything(seen: seen, events: page.data)
    } catch AgentClientError.sessionNotFound {
      lock.withLock { historyIsAbsent = true }
      return nil
    } catch {
      return Self.missedAnything(seen: seen, events: nil)
    }
  }

  static func missedAnything(seen: Int?, events: [OpenCodeDTO.EventFrame]?) -> Bool? {
    guard seen != nil, let events else { return nil }
    return !events.isEmpty
  }

  func loadSession(id: String) async throws -> RemoteSessionSnapshot {
    async let sessionCall: OpenCodeDTO.DataEnvelope<OpenCodeDTO.SessionInfo> =
      get("/api/session/\(id)")
    async let messagesCall: [OpenCodeDTO.Message] = allMessages(sessionID: id)
    async let questionsCall: OpenCodeDTO.ListEnvelope<OpenCodeDTO.QuestionRequest> =
      get("/api/session/\(id)/question")
    async let formsCall: OpenCodeDTO.ListEnvelope<OpenCodeDTO.FormRequest> =
      get("/api/session/\(id)/form")
    async let permissionsCall: OpenCodeDTO.ListEnvelope<OpenCodeDTO.PermissionRequest> =
      get("/api/session/\(id)/permission")

    let session = try await sessionCall
    let messages = (try? await messagesCall) ?? []
    let questions = (try? await questionsCall)?.data ?? []
    let forms = (try? await formsCall)?.data ?? []
    let permissions = (try? await permissionsCall)?.data ?? []
    for form in forms {
      lock.withLock { formFields[form.id] = form.fields }
    }

    let conversationID = conversationResolver?(id) ?? UUID()
    var interactions = questions.map {
      OpenCodeMapper.interaction(from: $0, conversationID: conversationID)
    }
    interactions += forms.map {
      OpenCodeMapper.interaction(from: $0, conversationID: conversationID)
    }
    interactions += permissions.map {
      OpenCodeMapper.interaction(from: $0, conversationID: conversationID)
    }

    let mapped = messages.compactMap(OpenCodeMapper.message(from:))
    let state: ConversationExecutionState = {
      if !interactions.isEmpty { return .waiting }
      if let last = mapped.last, last.role == .agent, last.completedAt == nil { return .working }
      return .idle
    }()

    return RemoteSessionSnapshot(
      info: info(from: session.data, fallbackDirectory: nil),
      messages: mapped,
      state: state,
      openInteractions: interactions
    )
  }

  private func info(
    from dto: OpenCodeDTO.SessionInfo,
    fallbackDirectory: String?
  ) -> RemoteSessionInfo {
    RemoteSessionInfo(
      id: dto.id,
      title: dto.title ?? "Untitled",
      directory: dto.location?.directory ?? fallbackDirectory ?? NSHomeDirectory(),
      model: dto.model.map {
        ModelSelection(providerID: $0.providerID, modelID: $0.id)
      }
    )
  }

  func isFree(_ selection: ModelSelection?) async -> Bool {
    guard let selection else { return false }
    let key = "\(selection.providerID)/\(selection.modelID)"
    if lock.withLock({ freeModels.contains(key) }) { return true }
    guard lock.withLock({ freeModels.isEmpty }) else { return false }
    _ = try? await modelsFromModelRoute()
    return lock.withLock { freeModels.contains(key) }
  }

  // MARK: - Sending

  func send(
    messageID: String,
    text: String,
    attachments: [OutgoingAttachment],
    to sessionID: String
  ) async throws {
    let body = OpenCodeDTO.PromptRequest(
      id: messageID,
      text: text,
      files: attachments.isEmpty
        ? nil
        : attachments.map {
          OpenCodeDTO.PromptRequest.FileAttachment(
            uri: $0.url.absoluteString,
            name: $0.displayName
          )
        }
    )
    try await postIgnoringResponse("/api/session/\(sessionID)/prompt", body: body)
  }

  func steer(messageID: String, text: String, to sessionID: String) async throws {
    let body = OpenCodeDTO.PromptRequest(id: messageID, text: text, files: nil, delivery: "steer")
    try await postIgnoringResponse("/api/session/\(sessionID)/prompt", body: body)
  }

  func messageExists(id: String, in sessionID: String) async throws -> Bool {
    do {
      let _: JSONValue = try await get("/api/session/\(sessionID)/message/\(id)")
      return true
    } catch AgentClientError.sessionNotFound {
      return false
    }
  }

  func stop(sessionID: String) async throws {
    try await postIgnoringResponse("/api/session/\(sessionID)/interrupt", body: EmptyBody())
  }

  // MARK: - Interactions

  static func answering(_ reply: () async throws -> Void) async throws {
    do {
      try await reply()
    } catch AgentClientError.sessionNotFound {
      throw AgentClientError.requestGone
    } catch let AgentClientError.transport(detail) where detail.hasPrefix("HTTP 409") {
      throw AgentClientError.requestGone
    }
  }

  func answerQuestion(requestID: String, sessionID: String, answers: [[String]]) async throws {
    try await Self.answering { try await sendAnswer(requestID: requestID, sessionID: sessionID, answers: answers) }
  }

  private func sendAnswer(requestID: String, sessionID: String, answers: [[String]]) async throws {
    guard Self.isForm(requestID) else {
      try await postIgnoringResponse(
        "/api/session/\(sessionID)/question/\(requestID)/reply",
        body: OpenCodeDTO.QuestionReplyRequest(answers: answers)
      )
      return
    }
    let fields = try await formFields(formID: requestID, sessionID: sessionID)
    guard !fields.isEmpty else { throw AgentClientError.requestGone }
    try await postIgnoringResponse(
      "/api/session/\(sessionID)/form/\(requestID)/reply",
      body: OpenCodeDTO.FormReplyRequest(answer: Self.answer(fields: fields, answers: answers))
    )
  }

  func rejectQuestion(requestID: String, sessionID: String) async throws {
    try await Self.answering { try await sendRejection(requestID: requestID, sessionID: sessionID) }
  }

  private func sendRejection(requestID: String, sessionID: String) async throws {
    guard Self.isForm(requestID) else {
      try await postIgnoringResponse(
        "/api/session/\(sessionID)/question/\(requestID)/reject",
        body: EmptyBody()
      )
      return
    }
    try await deleteIgnoringResponse("/api/session/\(sessionID)/form/\(requestID)")
  }

  static func isForm(_ requestID: String) -> Bool { requestID.hasPrefix("frm_") }

  static func answer(
    fields: [OpenCodeDTO.FormRequest.Field],
    answers: [[String]]
  ) -> [String: OpenCodeDTO.FormValue] {
    var out: [String: OpenCodeDTO.FormValue] = [:]
    for (field, values) in zip(fields, answers) where !values.isEmpty {
      out[field.key] = value(for: field, values)
    }
    return out
  }

  static func value(
    for field: OpenCodeDTO.FormRequest.Field,
    _ values: [String]
  ) -> OpenCodeDTO.FormValue {
    let first = values[0].trimmingCharacters(in: .whitespacesAndNewlines)
    switch field.type {
    case "multiselect":
      return .selections(values)
    case "boolean":
      switch first.lowercased() {
      case "true", "yes": return .flag(true)
      case "false", "no": return .flag(false)
      default: return .text(first)
      }
    case "number", "integer":
      return Double(first.replacingOccurrences(of: ",", with: ".")).map(OpenCodeDTO.FormValue.number)
        ?? .text(first)
    case "external":
      return .flag(true)
    default:
      return .text(values[0])
    }
  }

  private func formFields(
    formID: String,
    sessionID: String
  ) async throws -> [OpenCodeDTO.FormRequest.Field] {
    if let known = lock.withLock({ formFields[formID] }), !known.isEmpty { return known }
    let listed: OpenCodeDTO.ListEnvelope<OpenCodeDTO.FormRequest> =
      try await get("/api/session/\(sessionID)/form")
    for form in listed.data {
      lock.withLock { formFields[form.id] = form.fields }
    }
    return lock.withLock { formFields[formID] } ?? []
  }

  /// 2.0 takes `decision`, 1.18 `reply`; the old body is retried on a 400 only.
  func answerPermission(
    requestID: String,
    sessionID: String,
    decision: PermissionDecision,
    message: String?
  ) async throws {
    let decision = lock.withLock { allowances.decide(decision, requestID: requestID, sessionID: sessionID) }
    let path = "/api/session/\(sessionID)/permission/\(requestID)/reply"
    let words = decision == .reject ? message : nil
    try await Self.answering {
      do {
        try await postIgnoringResponse(
          path, body: OpenCodeDTO.PermissionReplyRequest(decision: decision.rawValue, message: words)
        )
      } catch let AgentClientError.transport(detail) where detail.hasPrefix("HTTP 400") {
        try await postIgnoringResponse(
          path, body: OpenCodeDTO.LegacyPermissionReplyRequest(reply: decision.rawValue, message: words)
        )
      }
    }
  }

  // MARK: - Events

  func events() -> AsyncStream<AgentEventEnvelope> {
    AsyncStream { continuation in
      let server = self.server
      lock.withLock {
        eventContinuation = continuation
        streamTask?.cancel()
        streamTask = Task { [weak self] in await self?.runEventLoop(on: server, reportsConnection: true) }
        ownStreamTask?.cancel()
        ownStreamTask = nil
      }
      if lock.withLock({ runsOnOwnServer.values.contains(true) }) { startOwnStreamIfNeeded() }
      continuation.onTermination = { [weak self] _ in
        self?.lock.withLock {
          self?.streamTask?.cancel()
          self?.ownStreamTask?.cancel()
          self?.ownStreamTask = nil
        }
      }
    }
  }

  private func startOwnStreamIfNeeded() {
    let ownServer = self.ownServer
    lock.withLock {
      guard eventContinuation != nil, ownStreamTask == nil else { return }
      ownStreamTask = Task { [weak self] in
        await self?.runEventLoop(on: ownServer, reportsConnection: false)
      }
    }
  }

  /// The second stream says only "connected", which re-reads every chat; its drops are not the
  /// provider's connection state.
  private func runEventLoop(on server: OpenCodeServer, reportsConnection: Bool) async {
    var backoff: UInt64 = 250_000_000
    while !Task.isCancelled {
      do {
        let endpoint = try await server.start()
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("api/event"))
        request.setValue(endpoint.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = .infinity

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
          (bytes, response) = try await urlSession.bytes(for: request)
        } catch {
          await server.invalidate(endpoint)
          throw error
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
          guard endpoint.isService else {
            emit(AgentEventEnvelope(event: .connection(.failed("Authentication failed"))))
            return
          }
          await server.invalidate(endpoint)
          throw AgentClientError.unauthorized
        }
        emit(AgentEventEnvelope(event: .connection(.connected)))
        backoff = 250_000_000

        var parser = ServerSentEventParser()
        var line: [UInt8] = []
        line.reserveCapacity(4096)
        for try await byte in bytes {
          line.append(byte)
          guard byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") else { continue }
          if Task.isCancelled { return }
          for frame in parser.consume(line) {
            handle(frame: frame)
          }
          line.removeAll(keepingCapacity: true)
        }
        if reportsConnection { emit(AgentEventEnvelope(event: .connection(.reconnecting))) }
      } catch is CancellationError {
        return
      } catch {
        if Task.isCancelled { return }
        log.debug("event stream dropped: \(OpenCodeServer.redact(error.localizedDescription), privacy: .public)")
        if reportsConnection { emit(AgentEventEnvelope(event: .connection(.reconnecting))) }
      }
      if Task.isCancelled { return }
      try? await Task.sleep(nanoseconds: backoff)
      backoff = min(backoff * 2, 5_000_000_000)
    }
  }

  private func emit(_ envelope: AgentEventEnvelope) {
    lock.withLock { eventContinuation }?.yield(envelope)
  }

  func handle(frame: ServerSentEventParser.Event) {
    guard let data = frame.data.data(using: .utf8),
          let event = try? JSONDecoder().decode(OpenCodeDTO.EventFrame.self, from: data)
    else { return }
    if let aggregate = event.durable?.aggregateID, let seq = event.durable?.seq {
      lock.withLock { lastSequence[aggregate] = max(lastSequence[aggregate] ?? 0, seq) }
    }
    for domain in Self.domainEvents(from: event, resolver: conversationResolver) {
      if case let .interactionAsked(ask) = domain, case let .permission(prompt) = ask.kind {
        let sessionID = ask.remoteSessionID
        let covered = lock.withLock {
          allowances.ask(ask.id, saving: prompt.savePatterns, in: sessionID)
        }
        if covered {
          Task { [weak self] in
            try? await self?.answerPermission(
              requestID: ask.id, sessionID: sessionID, decision: .once, message: nil)
          }
          continue
        }
      }
      emit(
        AgentEventEnvelope(
          id: event.id ?? frame.id,
          sequence: event.durable?.seq,
          event: domain
        )
      )
    }
  }

  static func domainEvents(
    from event: OpenCodeDTO.EventFrame,
    resolver: (@Sendable (String) -> UUID?)?
  ) -> [AgentEvent] {
    switch event.type {
    case "message.updated":
      guard let dto = event.data?["info"]?.decode(as: OpenCodeDTO.EventMessage.self) else {
        return []
      }
      return [
        .messageUpdated(
          sessionID: dto.sessionID,
          message: OpenCodeMapper.message(fromEvent: dto)
        )
      ]

    case "message.removed":
      guard let sessionID = event.data?["sessionID"]?.stringValue,
            let messageID = event.data?["messageID"]?.stringValue
      else { return [] }
      return [.messageRemoved(sessionID: sessionID, messageID: messageID)]

    case "message.part.updated":
      guard let dto = event.data?["part"]?.decode(as: OpenCodeDTO.EventPart.self),
            let part = OpenCodeMapper.part(fromEvent: dto)
      else { return [] }
      return [
        .partUpdated(sessionID: dto.sessionID, messageID: dto.messageID, part: part)
      ]

    case "message.part.delta":
      guard let sessionID = event.data?["sessionID"]?.stringValue,
            let messageID = event.data?["messageID"]?.stringValue,
            let partID = event.data?["partID"]?.stringValue,
            let delta = event.data?["delta"]?.stringValue
      else { return [] }
      let field = event.data?["field"]?.stringValue ?? "text"
      guard field == "text" || field == "reasoning" else { return [] }
      return [
        .partDelta(
          sessionID: sessionID,
          messageID: messageID,
          partID: partID,
          kind: field == "reasoning" ? .reasoning : .text,
          delta: delta
        )
      ]

    case "message.part.removed":
      guard let sessionID = event.data?["sessionID"]?.stringValue,
            let messageID = event.data?["messageID"]?.stringValue,
            let partID = event.data?["partID"]?.stringValue
      else { return [] }
      return [.partRemoved(sessionID: sessionID, messageID: messageID, partID: partID)]

    case "session.idle":
      guard let sessionID = event.data?["sessionID"]?.stringValue else { return [] }
      return [.executionStateChanged(sessionID: sessionID, state: .idle)]

    case "session.status":
      guard let sessionID = event.data?["sessionID"]?.stringValue,
            let state = OpenCodeMapper.executionState(fromStatus: event.data?["status"])
      else { return [] }
      return [.executionStateChanged(sessionID: sessionID, state: state)]

    case "session.error":
      guard let sessionID = event.data?["sessionID"]?.stringValue else { return [] }
      return [
        .sessionFailed(
          sessionID: sessionID,
          failure: OpenCodeMapper.failure(fromError: event.data?["error"])
        )
      ]

    case "session.deleted":
      guard let sessionID = event.data?["info"]?["id"]?.stringValue
        ?? event.data?["sessionID"]?.stringValue
      else { return [] }
      return [.sessionDeleted(sessionID: sessionID)]

    case "question.v2.asked":
      guard let dto = event.data?.decode(as: OpenCodeDTO.QuestionRequest.self) else { return [] }
      let conversationID = resolver?(dto.sessionID) ?? UUID()
      return [
        .interactionAsked(
          OpenCodeMapper.interaction(from: dto, conversationID: conversationID)
        )
      ]

    case "question.v2.replied":
      guard let sessionID = event.data?["sessionID"]?.stringValue,
            let requestID = event.data?["requestID"]?.stringValue
      else { return [] }
      let answers = event.data?["answers"]?.arrayValue?.map { answer in
        answer.arrayValue?.compactMap(\.stringValue) ?? []
      }
      return [
        .interactionResolved(
          sessionID: sessionID,
          requestID: requestID,
          resolution: answers.map { PendingInteraction.Resolution.answered($0) }
            ?? .resolvedElsewhere
        )
      ]

    case "question.v2.rejected":
      guard let sessionID = event.data?["sessionID"]?.stringValue,
            let requestID = event.data?["requestID"]?.stringValue
      else { return [] }
      return [
        .interactionResolved(sessionID: sessionID, requestID: requestID, resolution: .rejected)
      ]

    case "form.created":
      guard let dto = event.data?["form"]?.decode(as: OpenCodeDTO.FormRequest.self)
      else { return [] }
      return [
        .interactionAsked(
          OpenCodeMapper.interaction(
            from: dto, conversationID: resolver?(dto.sessionID) ?? UUID()
          )
        )
      ]

    case "form.replied":
      guard let sessionID = event.data?["sessionID"]?.stringValue,
            let requestID = event.data?["id"]?.stringValue
      else { return [] }
      let answered = event.data?["answer"]?.objectValue?.values
        .map { $0.arrayValue?.compactMap(\.stringValue) ?? [$0.stringValue].compactMap { $0 } }
      return [
        .interactionResolved(
          sessionID: sessionID,
          requestID: requestID,
          resolution: answered.map { PendingInteraction.Resolution.answered($0) }
            ?? .resolvedElsewhere
        )
      ]

    case "form.cancelled":
      guard let sessionID = event.data?["sessionID"]?.stringValue,
            let requestID = event.data?["id"]?.stringValue
      else { return [] }
      return [
        .interactionResolved(sessionID: sessionID, requestID: requestID, resolution: .rejected)
      ]

    case "permission.asked", "permission.v2.asked":
      guard let dto = event.data?.decode(as: OpenCodeDTO.PermissionRequest.self) else { return [] }
      let conversationID = resolver?(dto.sessionID) ?? UUID()
      return [
        .interactionAsked(
          OpenCodeMapper.interaction(from: dto, conversationID: conversationID)
        )
      ]

    case "permission.replied", "permission.v2.replied":
      guard let sessionID = event.data?["sessionID"]?.stringValue,
            let requestID = event.data?["requestID"]?.stringValue
      else { return [] }
      let reply = event.data?["reply"]?.stringValue
      let decision = reply.flatMap(PermissionDecision.init(rawValue:))
      return [
        .interactionResolved(
          sessionID: sessionID,
          requestID: requestID,
          resolution: decision.map { PendingInteraction.Resolution.permission($0) }
            ?? .resolvedElsewhere
        )
      ]

    case "file.edited":
      guard let path = event.data?["file"]?.stringValue,
            let sessionID = event.data?["sessionID"]?.stringValue
      else { return [] }
      return [.fileChanged(sessionID: sessionID, path: path)]

    default:
      return sessionStreamEvents(from: event)
    }
  }

  static func sessionStreamEvents(from event: OpenCodeDTO.EventFrame) -> [AgentEvent] {
    guard let data = event.data,
          let sessionID = data["sessionID"]?.stringValue
    else { return [] }
    let messageID = data["assistantMessageID"]?.stringValue
    let timestamp = data["timestamp"]?.doubleValue

    func date() -> Date {
      timestamp.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
    }

    func partID(reasoning: Bool) -> String? {
      if let named = data[reasoning ? "reasoningID" : "textID"]?.stringValue { return named }
      guard let messageID, let ordinal = data["ordinal"]?.intValue else { return nil }
      return "\(messageID)#\(reasoning ? "reasoning" : "text")-\(ordinal)"
    }

    func callID() -> String? {
      data["callID"]?.stringValue ?? data["id"]?.stringValue
    }

    switch event.type {
    case "session.inbox.enqueued", "session.inbox.delivered",
         "session.next.prompt.admitted", "session.next.prompted":
      guard let id = data["inboxID"]?.stringValue ?? data["messageID"]?.stringValue
      else { return [] }
      var message = ConversationMessage(
        id: id,
        role: .user,
        createdAt: date(),
        completedAt: date()
      )
      let echoed = data["item"]?["payload"]?["text"]?.stringValue
        ?? data["prompt"]?["text"]?.stringValue
      if let text = echoed, !text.isEmpty {
        message.parts = [.text(TextPart(id: "\(id)-text", kind: .text, text: text))]
      }
      return [
        .messageUpdated(sessionID: sessionID, message: message),
        .executionStateChanged(sessionID: sessionID, state: .working)
      ]

    case "session.step.started", "session.next.step.started":
      guard let messageID else { return [] }
      return [
        .messageUpdated(
          sessionID: sessionID,
          message: ConversationMessage(id: messageID, role: .agent, createdAt: date())
        ),
        .executionStateChanged(sessionID: sessionID, state: .working)
      ]

    case "session.text.delta", "session.reasoning.delta",
         "session.next.text.delta", "session.next.reasoning.delta":
      let isReasoning = event.type.contains("reasoning")
      guard let messageID,
            let partID = partID(reasoning: isReasoning),
            let delta = data["delta"]?.stringValue
      else { return [] }
      return [
        .partDelta(
          sessionID: sessionID,
          messageID: messageID,
          partID: partID,
          kind: isReasoning ? .reasoning : .text,
          delta: delta
        )
      ]

    case "session.text.ended", "session.reasoning.ended",
         "session.next.text.ended", "session.next.reasoning.ended":
      let isReasoning = event.type.contains("reasoning")
      guard let messageID,
            let partID = partID(reasoning: isReasoning),
            let text = data["text"]?.stringValue
      else { return [] }
      let part = TextPart(
        id: partID,
        kind: isReasoning ? .reasoning : .text,
        text: text
      )
      return [
        .partUpdated(
          sessionID: sessionID,
          messageID: messageID,
          part: isReasoning ? .reasoning(part) : .text(part)
        )
      ]

    case "session.tool.input.started":
      guard let messageID, let callID = callID() else { return [] }
      return [
        .partUpdated(
          sessionID: sessionID,
          messageID: messageID,
          part: .activity(
            AgentActivity(
              id: callID,
              name: data["name"]?.stringValue ?? data["tool"]?.stringValue ?? "tool",
              state: .running,
              startedAt: date()
            )
          )
        )
      ]

    case "session.tool.called", "session.next.tool.called":
      guard let messageID, let callID = callID() else { return [] }
      return [
        .partUpdated(
          sessionID: sessionID,
          messageID: messageID,
          part: .activity(
            AgentActivity(
              id: callID,
              name: data["tool"]?.stringValue ?? data["name"]?.stringValue ?? "",
              state: .running,
              files: filePaths(fromToolInput: data["input"]),
              startedAt: date()
            )
          )
        )
      ]

    case "session.tool.success", "session.tool.failed",
         "session.next.tool.success", "session.next.tool.failed":
      guard let messageID, let callID = callID() else { return [] }
      let failed = event.type.hasSuffix("failed")
      let output = data["content"]?.arrayValue?
        .compactMap { $0["text"]?.stringValue }
        .joined(separator: "\n")
      var files = data["outputPaths"]?.arrayValue?.compactMap(\.stringValue) ?? []
      if let target = data["structured"]?["target"]?.stringValue { files.append(target) }
      return [
        .partUpdated(
          sessionID: sessionID,
          messageID: messageID,
          part: .activity(
            AgentActivity(
              id: callID,
              name: "",
              summary: data["structured"]?["operation"]?.stringValue.map {
                summary(operation: $0, resource: data["structured"]?["resource"]?.stringValue)
              },
              state: failed ? .failed : .completed,
              detail: failed
                ? (data["error"]?.stringValue ?? output)
                : (output?.isEmpty == false ? output : nil),
              files: Array(Set(files)).sorted(),
              endedAt: date()
            )
          )
        )
      ]

    case "session.step.ended", "session.next.step.ended":
      let finish = data["finish"]?.stringValue
      guard finish != "tool-calls" else { return [] }
      return [.executionStateChanged(sessionID: sessionID, state: .idle)]

    case "session.step.failed", "session.next.step.failed":
      return [
        .sessionFailed(
          sessionID: sessionID,
          failure: OpenCodeMapper.failure(fromError: data["error"])
        )
      ]

    case "session.retried", "session.execution.started":
      return [.executionStateChanged(sessionID: sessionID, state: .working)]

    default:
      return []
    }
  }

  private static func filePaths(fromToolInput input: JSONValue?) -> [String] {
    guard let input else { return [] }
    return ["path", "filePath", "file"].compactMap { input[$0]?.stringValue }
  }

  private static func summary(operation: String, resource: String?) -> String {
    guard let resource, !resource.isEmpty else { return operation.capitalized }
    return "\(operation.capitalized) \(resource)"
  }

  func shutdown() async {
    lock.withLock {
      streamTask?.cancel()
      streamTask = nil
      ownStreamTask?.cancel()
      ownStreamTask = nil
      eventContinuation?.finish()
      eventContinuation = nil
    }
    await server.stop()
    await ownServer.stop()
  }

  // MARK: - HTTP

  private struct EmptyBody: Encodable {}

  private func get<T: Decodable>(_ path: String) async throws -> T {
    try await perform(path: path, method: "GET", body: Optional<EmptyBody>.none)
  }

  private func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
    try await perform(path: path, method: "POST", body: body)
  }

  private func deleteIgnoringResponse(_ path: String) async throws {
    let _: JSONValue = try await perform(
      path: path, method: "DELETE", body: Optional<EmptyBody>.none
    )
  }

  private func postIgnoringResponse(_ path: String, body: some Encodable) async throws {
    let _: JSONValue = try await perform(path: path, method: "POST", body: body)
  }

  private func perform<T: Decodable>(
    path: String,
    method: String,
    body: (some Encodable)?,
    on chosen: OpenCodeServer? = nil
  ) async throws -> T {
    let server: OpenCodeServer
    if let chosen {
      server = chosen
    } else if let sessionID = Self.sessionID(inPath: path) {
      server = await self.server(forSession: sessionID)
    } else {
      server = self.server
    }
    let endpoint = try await server.start()
    guard let url = URL(string: endpoint.baseURL.absoluteString + path) else {
      throw AgentClientError.transport("bad path \(path)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue(endpoint.authorizationHeader, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await urlSession.data(for: request)
    } catch let error as URLError where error.code == .cannotConnectToHost {
      await server.invalidate(endpoint)
      throw AgentClientError.transport(error.localizedDescription)
    } catch let error as URLError where Self.isIndeterminate(error) {
      // Possibly accepted before the connection died: never retry.
      throw AgentClientError.indeterminate(error.localizedDescription)
    } catch {
      throw AgentClientError.transport(error.localizedDescription)
    }

    guard let http = response as? HTTPURLResponse else {
      throw AgentClientError.transport("no HTTP response")
    }
    switch http.statusCode {
    case 200..<300:
      if T.self == JSONValue.self, data.isEmpty { return JSONValue.null as! T }
      do {
        return try JSONDecoder().decode(T.self, from: data)
      } catch {
        throw AgentClientError.transport("could not read the response: \(error)")
      }
    case 401:
      await server.invalidate(endpoint)
      throw AgentClientError.unauthorized
    case 404:
      throw AgentClientError.sessionNotFound
    default:
      let message = String(decoding: data.prefix(400), as: UTF8.self)
      throw AgentClientError.transport("HTTP \(http.statusCode): \(OpenCodeServer.redact(message))")
    }
  }

  static func isIndeterminate(_ error: URLError) -> Bool {
    switch error.code {
    case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet:
      return true
    default:
      return false
    }
  }
}

struct OpenCodeAllowances {
  private var asked: [String: Set<String>] = [:]
  private var allowed: [String: Set<String>] = [:]

  mutating func ask(_ requestID: String, saving patterns: [String], in sessionID: String) -> Bool {
    let patterns = Set(patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    asked[requestID] = patterns
    return !patterns.isEmpty && patterns.isSubset(of: allowed[sessionID] ?? [])
  }

  mutating func decide(_ decision: PermissionDecision, requestID: String, sessionID: String) -> PermissionDecision {
    let patterns = asked.removeValue(forKey: requestID) ?? []
    guard decision == .always else { return decision }
    allowed[sessionID, default: []].formUnion(patterns)
    return .once
  }
}
