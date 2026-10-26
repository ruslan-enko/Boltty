import Foundation

extension ClaudeCodeClient {
  final class LiveSession: @unchecked Sendable {
    struct PendingPermission {
      let controlRequestID: String
      let toolName: String
      let input: [String: Any]
      let askedAt = Date()
    }

    let id: String
    let directory: String
    var model: ModelSelection?
    let process: JSONLineProcess
    var readerTask: Task<Void, Never>?

    private let lock = NSLock()
    private var storedMessageID: String?
    private var storedState: ConversationExecutionState = .idle
    private var storedRateLimit: RateLimitHit?
    private var sent: Set<String> = []
    private var permissions: [String: PendingPermission] = [:]
    private var control: [String: CheckedContinuation<JSONObject, Error>] = [:]
    private var controlCounter = 0

    init(id: String, directory: String, model: ModelSelection?, process: JSONLineProcess) {
      self.id = id
      self.directory = directory
      self.model = model
      self.process = process
    }

    var currentMessageID: String? {
      get { lock.withLock { storedMessageID } }
      set { lock.withLock { storedMessageID = newValue } }
    }

    var executionState: ConversationExecutionState {
      get { lock.withLock { storedState } }
      set { lock.withLock { storedState = newValue } }
    }

    var rateLimitHit: RateLimitHit? {
      get { lock.withLock { storedRateLimit } }
      set { lock.withLock { storedRateLimit = newValue } }
    }

    var sentMessageIDs: Set<String> { lock.withLock { sent } }

    func rememberOutgoing(messageID: String, text: String) {
      lock.withLock { _ = sent.insert(messageID) }
    }

    // MARK: - Permissions

    func rememberPermission(_ pending: PendingPermission) {
      lock.withLock { permissions[pending.controlRequestID] = pending }
    }

    func takePermission(_ requestID: String) -> PendingPermission? {
      lock.withLock { permissions.removeValue(forKey: requestID) }
    }

    var openInteractions: [PendingInteraction] {
      lock.withLock { permissions.values }.map { pending in
        PendingInteraction(
          id: pending.controlRequestID,
          conversationID: UUID(),
          remoteSessionID: id,
          kind: .permission(PermissionPrompt(
            action: pending.toolName,
            resources: ClaudeCodeClient.resources(
              forTool: pending.toolName, input: JSONObject(pending.input)
            ),
            savePatterns: [],
            toolCallID: nil
          )),
          askedAt: pending.askedAt
        )
      }
    }

    // MARK: - The control channel

    func sendControl(_ request: [String: Any], timeout: TimeInterval) async throws -> JSONObject {
      let requestID: String = lock.withLock {
        controlCounter += 1
        return "boltty_\(controlCounter)"
      }
      guard let line = JSONObject.encode([
        "type": "control_request",
        "request_id": requestID,
        "request": request
      ]) else { throw AgentClientError.transport("That request could not be encoded.") }

      let timeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        guard !Task.isCancelled else { return }
        self?.resume(requestID, with: .failure(AgentClientError.startupTimedOut))
      }
      defer { timeoutTask.cancel() }

      return try await withCheckedThrowingContinuation { continuation in
        lock.withLock { control[requestID] = continuation }
        do {
          try process.writeLine(line)
        } catch {
          resume(requestID, with: .failure(error))
        }
      }
    }

    func resolveControl(_ frame: JSONObject) {
      guard let response = frame.object("response"),
            let requestID = response.string("request_id")
      else { return }
      if response.string("subtype") == "error" {
        resume(requestID, with: .failure(
          AgentClientError.transport(response.string("error") ?? "The agent refused that request.")
        ))
        return
      }
      resume(requestID, with: .success(response.object("response") ?? JSONObject([:])))
    }

    func failPending(_ error: Error) {
      let waiting: [CheckedContinuation<JSONObject, Error>] = lock.withLock {
        let values = Array(control.values)
        control.removeAll()
        return values
      }
      for continuation in waiting { continuation.resume(throwing: error) }
    }

    private func resume(_ requestID: String, with result: Result<JSONObject, Error>) {
      let continuation: CheckedContinuation<JSONObject, Error>? = lock.withLock {
        control.removeValue(forKey: requestID)
      }
      continuation?.resume(with: result)
    }
  }
}

enum ClaudeCodeTranscript {
  struct Located {
    let url: URL
    let directory: String
  }

  static var projectsDirectory: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
  }

  static func locate(sessionID: String) -> Located? {
    let fileManager = FileManager.default
    guard let projects = try? fileManager.contentsOfDirectory(
      at: projectsDirectory, includingPropertiesForKeys: nil
    ) else { return nil }
    for project in projects {
      let candidate = project.appendingPathComponent("\(sessionID).jsonl")
      guard fileManager.isReadableFile(atPath: candidate.path) else { continue }
      return Located(url: candidate, directory: workingDirectory(in: candidate) ?? NSHomeDirectory())
    }
    return nil
  }

  private static func workingDirectory(in url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
    for line in String(decoding: head, as: UTF8.self).components(separatedBy: .newlines) {
      if let cwd = JSONObject(line: line)?.string("cwd") { return cwd }
    }
    return nil
  }

  struct Parsed {
    var messages: [ConversationMessage] = []
    var title: String?
  }

  static let readLimit = 24 << 20

  static func read(at url: URL) -> Parsed {
    var byID: [String: ConversationMessage] = [:]
    var order: [String] = []
    var toolHome: [String: String] = [:]
    var parsed = Parsed()

    let complete = (try? FileTail.forEachLine(of: url, maxBytes: readLimit) { rawLine in
      guard let record = JSONObject(line: rawLine) else { return true }
      let timestamp = record.string("timestamp").flatMap(ISO8601Stamp.date(from:)) ?? Date()
      switch record.string("type") {
      case "user":
        guard let message = record.object("message") else { return true }
        let blocks = message.array("content")
        if blocks.contains(where: { $0.string("type") == "tool_result" }) {
          for block in blocks where block.string("type") == "tool_result" {
            guard let toolID = block.string("tool_use_id"),
                  let home = toolHome[toolID],
                  var existing = byID[home]
            else { continue }
            existing.upsert(.activity(AgentActivity(
              id: toolID,
              name: "",
              state: (block.bool("is_error") ?? false) ? .failed : .completed,
              detail: block.rendered("content"),
              endedAt: timestamp
            )))
            byID[home] = existing
          }
          return true
        }
        let text = plainText(of: message)
        if Self.isImageBookkeeping(text) { return true }
        if InjectedText.isScaffolding(
          text, tags: InjectedText.claudeTags, prefixes: InjectedText.claudePrefixes
        ) { return true }
        let id = record.string("uuid") ?? UUID().uuidString
        var built = ConversationMessage(
          id: id, role: .user, createdAt: timestamp, completedAt: timestamp
        )
        if !text.isEmpty {
          built.parts.append(.text(TextPart(id: "\(id)-text", kind: .text, text: text)))
          if parsed.title == nil { parsed.title = String(text.prefix(60)) }
        }
        byID[id] = built
        order.append(id)

      case "attachment":
        // Words sent mid-turn are filed as a queued_command attachment, not a user record.
        guard let attachment = record.object("attachment"),
              attachment.string("type") == "queued_command"
        else { return true }
        let blocks = attachment.array("prompt")
        let text = blocks.isEmpty
          ? attachment.string("prompt") ?? ""
          : blocks.compactMap { $0.string("type") == "text" ? $0.string("text") : nil }
            .joined(separator: "\n")
        guard !text.isEmpty,
              !InjectedText.isScaffolding(
                text, tags: InjectedText.claudeTags, prefixes: InjectedText.claudePrefixes)
        else { return true }
        let id = record.string("uuid") ?? UUID().uuidString
        var built = ConversationMessage(id: id, role: .user, createdAt: timestamp, completedAt: timestamp)
        built.parts.append(.text(TextPart(id: "\(id)-text", kind: .text, text: text)))
        byID[id] = built
        order.append(id)

      case "assistant":
        guard let message = record.object("message"),
              let id = message.string("id")
        else { return true }
        var built = byID[id] ?? ConversationMessage(
          id: id, role: .agent, createdAt: timestamp, completedAt: timestamp
        )
        built.completedAt = timestamp
        for (index, block) in message.array("content").enumerated() {
          switch block.string("type") {
          case "text":
            built.upsert(.text(TextPart(
              id: "\(id)#\(index)", kind: .text, text: block.string("text") ?? ""
            )))
          case "thinking":
            built.upsert(.reasoning(TextPart(
              id: "\(id)#\(index)", kind: .reasoning, text: block.string("thinking") ?? ""
            )))
          case "tool_use":
            guard let toolID = block.string("id"), let name = block.string("name")
            else { continue }
            let input = block.object("input") ?? JSONObject([:])
            toolHome[toolID] = id
            built.upsert(.activity(AgentActivity(
              id: toolID,
              name: name,
              summary: ClaudeCodeClient.summary(forTool: name, input: input),
              state: .completed,
              files: ClaudeCodeClient.files(forTool: name, input: input),
              startedAt: timestamp
            )))
          default:
            break
          }
        }
        if byID[id] == nil { order.append(id) }
        byID[id] = built

      default:
        break
      }
      return true
    }) ?? false

    parsed.messages = order.compactMap { byID[$0] }.filter { !$0.parts.isEmpty }
    if !complete { parsed.title = firstUserText(at: url) }
    return parsed
  }

  private static func firstUserText(at url: URL) -> String? {
    var title: String?
    try? FileHead.forEachLine(of: url, maxLines: 400) { rawLine in
      guard let record = JSONObject(line: rawLine),
            record.string("type") == "user",
            let message = record.object("message")
      else { return true }
      let text = plainText(of: message)
      guard !text.isEmpty else { return true }
      title = String(text.prefix(60))
      return false
    }
    return title
  }

  static func isImageBookkeeping(_ text: String) -> Bool {
    let lines = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return false }
    return lines.allSatisfy {
      ($0.hasPrefix("[Image: source: ") || $0.hasPrefix("[Image: original "))
        && $0.hasSuffix("]")
    }
  }

  private static func plainText(of message: JSONObject) -> String {
    if let text = message.string("content") { return text }
    return message.array("content")
      .filter { $0.string("type") == "text" }
      .compactMap { $0.string("text") }
      .joined(separator: "\n\n")
  }
}
