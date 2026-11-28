import Foundation

/// Antigravity over `agy acp`: it asks for permission itself, takes pictures, and switches
/// its modes per session. Its model list, plan limits, skills and chat names stay one-shot
/// reads of the CLI.
final class AntigravityClient: AgentClient, @unchecked Sendable {
  let provider = AgentId.antigravity

  let capabilities: AgentCapabilities = [
    .modelSelection, .modelSwitching, .reasoningEffort, .resumeSession, .workingDirectory, .attachments,
    .images, .interrupt, .rereadableTranscript, .permissions,
    .usageLimits, .folderMoving, .commands, .planMode, .computerUse,
  ]

  static let skipMode = "skip"

  private let lock = NSLock()
  private var skillsByFolder: [String: (read: Date, skills: [AgentCommand])] = [:]
  private let executableOverride: String?
  private let acp: ModeSplitClient

  init(executable: String? = nil, transcriptRoot: URL = AntigravityTranscript.defaultRoot) {
    executableOverride = executable
    acp = ModeSplitClient(
      main: ACPClient(agent: .antigravity(transcriptRoot: transcriptRoot, skipsPermissions: false), executable: executable),
      second: ACPClient(agent: .antigravity(transcriptRoot: transcriptRoot, skipsPermissions: true), executable: executable),
      runsInSecond: { $0 == AntigravityClient.skipMode }
    )
  }

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

  static let skillListLifetime: TimeInterval = 300

  func commands(folder: String) async -> [AgentCommand] {
    if let cached = lock.withLock({ skillsByFolder[folder] }),
       Date().timeIntervalSince(cached.read) < Self.skillListLifetime {
      return cached.skills
    }
    guard let executable = locate(),
          let answer = await OneShotCommand.run(
            executable, ["-p=/skills", "--output-format", "json"], deadline: Self.usageDeadline,
            directory: URL(fileURLWithPath: folder, isDirectory: true)
          ), answer.exitCode == 0
    else { return [] }
    let found = answer.output.split(whereSeparator: \.isNewline).lazy
      .compactMap { JSONObject(line: String($0)) }.first.map(Self.skills(in:)) ?? []
    lock.withLock { skillsByFolder[folder] = (Date(), found) }
    return found
  }

  static func skills(in result: JSONObject) -> [AgentCommand] {
    guard result.object("command")?.string("name") == "skills" else { return [] }
    var seen = Set<String>()
    return (result.object("command")?.object("data")?.array("skills") ?? []).compactMap { skill in
      guard let name = skill.string("name"), !name.isEmpty, !name.contains(where: \.isWhitespace),
            seen.insert(name).inserted
      else { return nil }
      return AgentCommand(name: name, summary: skill.string("description") ?? "", argumentHint: nil)
    }
  }

  static var brain: String {
    (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/antigravity-cli/brain")
  }

  static func isPlanFile(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "md"
      && (path as NSString).standardizingPath.hasPrefix(brain + "/")
  }

  func makeSessionID() -> String { acp.makeSessionID() }

  func createSession(id: String, options: AgentSessionOptions) async throws -> RemoteSessionInfo {
    try await acp.createSession(id: id, options: options)
  }

  func prepareSession(_ id: String, options: AgentSessionOptions) async throws {
    try await acp.prepareSession(id, options: options)
  }

  func loadSession(id: String) async throws -> RemoteSessionSnapshot { try await acp.loadSession(id: id) }

  func send(messageID: String, text: String, attachments: [OutgoingAttachment], to sessionID: String) async throws {
    try await acp.send(messageID: messageID, text: text, attachments: attachments, to: sessionID)
  }

  func messageExists(id: String, in sessionID: String) async throws -> Bool {
    try await acp.messageExists(id: id, in: sessionID)
  }

  func stop(sessionID: String) async throws { try await acp.stop(sessionID: sessionID) }

  func answerQuestion(requestID: String, sessionID: String, answers: [[String]]) async throws {
    try await acp.answerQuestion(requestID: requestID, sessionID: sessionID, answers: answers)
  }

  func rejectQuestion(requestID: String, sessionID: String) async throws {
    try await acp.rejectQuestion(requestID: requestID, sessionID: sessionID)
  }

  func answerPermission(
    requestID: String, sessionID: String, decision: PermissionDecision, message: String?
  ) async throws {
    try await acp.answerPermission(requestID: requestID, sessionID: sessionID, decision: decision, message: message)
  }

  func answerPlan(requestID: String, sessionID: String, decision: PlanDecision, feedback: String?) async throws {
    try await acp.answerPlan(requestID: requestID, sessionID: sessionID, decision: decision, feedback: feedback)
  }

  func events() -> AsyncStream<AgentEventEnvelope> { acp.events() }

  func setPermissionMode(_ mode: String?, sessionID: String) async throws {
    try await acp.setPermissionMode(mode, sessionID: sessionID)
  }

  func missedAnything(sessionID: String) async -> Bool? { await acp.missedAnything(sessionID: sessionID) }

  func release(sessionID: String) async { await acp.release(sessionID: sessionID) }

  func restartIdleProcess() async { await acp.restartIdleProcess() }

  func setConversationResolver(_ resolve: @escaping @Sendable (String) -> UUID?) {
    acp.setConversationResolver(resolve)
  }

  func chatTitle(sessionID: String, material: ChatNaming.Material) async -> String? {
    guard let executable = locate(),
          let models = try? await availableModels(),
          let model = models.first(where: { $0.selection.modelID.contains("flash") })
            ?? models.first(where: \.isDefault)
    else { return nil }
    var arguments = [
      "--input-format", "stream-json", "--output-format", "stream-json",
      "--disable-slash-commands", "--model", model.selection.modelID,
    ]
    if let effort = AskBolttyConfiguration.fastestEffort(model.effortOptions) {
      arguments += ["--effort", effort]
    }
    arguments.append("--print=")
    let words = ChatNaming.instruction + "\n\n" + ChatNaming.conversation(material)
    let frame: [String: Any] = ["event": "user", "message": ["content": words]]
    guard let line = try? JSONSerialization.data(withJSONObject: frame) else { return nil }
    let answer = await OneShotCommand.run(
      executable, arguments,
      deadline: ChatNaming.askDeadline,
      input: String(decoding: line, as: UTF8.self) + "\n",
      directory: ChatNaming.workingDirectory()
    )
    guard let answer, answer.exitCode == 0 else { return nil }
    return Self.response(inStream: answer.output)
  }

  static func response(inStream output: String) -> String? {
    for line in output.split(whereSeparator: \.isNewline).reversed() {
      guard let frame = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
            frame["event"] as? String == "result",
            let result = frame["result"] as? [String: Any]
      else { continue }
      return result["response"] as? String
    }
    return nil
  }

  func shutdown() async { await acp.shutdown() }

  /// Before `agy acp`, Boltty asked through a hook of its own and lent Computer Use through a
  /// plugin; both are taken out of the person's Antigravity config.
  static func removeOldGate() {
    let manager = FileManager.default
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let hooks = home.appendingPathComponent(".gemini/config/hooks.json")
    if let data = try? Data(contentsOf: hooks),
       var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       object.removeValue(forKey: "boltty-permission-gate") != nil,
       let written = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
      try? written.write(to: hooks, options: .atomic)
    }
    try? manager.removeItem(at: home.appendingPathComponent(".gemini/config/plugins/boltty"))
    let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Boltty")
    try? manager.removeItem(at: support.appendingPathComponent("antigravity-permission-gate.sh"))
    try? manager.removeItem(at: support.appendingPathComponent("computer-use-bridge.sh"))
  }

  private func locate() -> String? {
    executableOverride ?? JSONLineProcess.locate(provider.program)
  }
}

extension ACPAgent {
  /// `--dangerously-skip-permissions` is a launch flag for the whole process: Skip
  /// Permissions chats run in a second one.
  static func antigravity(transcriptRoot: URL, skipsPermissions: Bool) -> ACPAgent {
    var agent = ACPAgent(
      provider: .antigravity,
      displayName: "Antigravity",
      arguments: skipsPermissions ? ["acp", "--dangerously-skip-permissions"] : ["acp"],
      capabilities: [],
      history: { try AntigravityTranscript.transcript(sessionID: $0, in: transcriptRoot) }
    )
    agent.effortConfigID = "thought_level"
    agent.modelConfigID = "model"
    agent.modeID = { options in
      if options.planMode, !options.readOnly { return "plan" }
      guard !options.readOnly, let mode = options.permissionMode, mode != AntigravityClient.skipMode else { return "default" }
      return mode
    }
    agent.planFile = { input in
      guard let path = input.string("Path"), AntigravityClient.isPlanFile(path) else { return nil }
      return path
    }
    return agent
  }
}
