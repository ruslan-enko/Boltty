import Darwin
import Foundation
import os

actor OpenCodeServer {
  struct Endpoint: Equatable, Sendable {
    let baseURL: URL
    let username: String
    let password: String
    var isService = false

    var authorizationHeader: String {
      let raw = "\(username):\(password)"
      return "Basic " + Data(raw.utf8).base64EncodedString()
    }
  }

  private let executableCandidates: [String]
  private let serviceState: URL?
  private let log = Logger(subsystem: "com.boltty", category: "opencode-server")

  private var process: Process?
  private var endpoint: Endpoint?
  private var startTask: Task<Endpoint, Error>?

  private let readinessTimeout: TimeInterval
  private let catalogueDeadline: TimeInterval

  init(
    executableCandidates: [String] = OpenCodeServer.defaultCandidates,
    readinessTimeout: TimeInterval = 20,
    catalogueDeadline: TimeInterval = 15,
    serviceState: URL? = OpenCodeServer.defaultServiceState
  ) {
    self.executableCandidates = executableCandidates
    self.serviceState = serviceState
    self.readinessTimeout = readinessTimeout
    self.catalogueDeadline = catalogueDeadline
  }

  static var defaultServiceState: URL {
    let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/state")
    return base.appendingPathComponent("opencode/service.json")
  }

  static func service(describedAt url: URL) -> Endpoint? {
    guard let data = try? Data(contentsOf: url),
          let state = JSONObject(line: data),
          let address = state.string("url"), let base = URL(string: address),
          base.host == "127.0.0.1" || base.host == "localhost",
          let password = state.string("password"), !password.isEmpty
    else { return nil }
    if let pid = state.int("pid"), pid > 1, kill(pid_t(pid), 0) != 0 { return nil }
    return Endpoint(baseURL: base, username: "opencode", password: password, isService: true)
  }

  private func answeringService() async -> Endpoint? {
    guard let serviceState, let candidate = Self.service(describedAt: serviceState) else { return nil }
    var request = URLRequest(url: candidate.baseURL.appendingPathComponent("api/info"))
    request.setValue(candidate.authorizationHeader, forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 2
    guard let (_, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200
    else {
      log.debug("opencode service described but not answering; starting Boltty's own")
      return nil
    }
    log.info("using the opencode background service at \(candidate.baseURL.absoluteString, privacy: .public)")
    return candidate
  }

  func invalidate(_ stale: Endpoint) {
    guard stale.isService, endpoint == stale else { return }
    endpoint = nil
  }

  var isUsingServiceForTesting: Bool { endpoint?.isService ?? false }

  static let defaultCandidates = [
    "/opt/homebrew/bin/opencode",
    "/usr/local/bin/opencode",
    "\(NSHomeDirectory())/.opencode/bin/opencode",
    "\(NSHomeDirectory())/.local/bin/opencode"
  ]

  func locateExecutable() -> String? {
    JSONLineProcess.locate("opencode", extraCandidates: executableCandidates)
  }

  func version() async -> String? {
    guard let executable = locateExecutable(),
          let answer = await OneShotCommand.run(
            executable, ["--version"], deadline: catalogueDeadline
          )
    else { return nil }
    let text = answer.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  func modelLines() async -> [String] {
    guard let executable = locateExecutable() else { return [] }
    return await Self.catalogueLines(running: executable, deadline: catalogueDeadline)
  }

  private static func catalogueLines(
    running executable: String,
    deadline: TimeInterval
  ) async -> [String] {
    guard let answer = await OneShotCommand.run(executable, ["models"], deadline: deadline),
          answer.exitCode == 0
    else { return [] }
    return answer.output
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
  }

  var isRunning: Bool { process?.isRunning == true }

  func start() async throws -> Endpoint {
    if let endpoint, endpoint.isService || process?.isRunning == true { return endpoint }
    if let startTask { return try await startTask.value }

    let task = Task<Endpoint, Error> {
      if self.process == nil, let service = await self.answeringService() { return service }
      return try await self.launch()
    }
    startTask = task
    defer { startTask = nil }
    do {
      let endpoint = try await task.value
      self.endpoint = endpoint
      return endpoint
    } catch {
      await stop()
      throw error
    }
  }

  private func launch() async throws -> Endpoint {
    guard let executable = locateExecutable() else {
      throw AgentClientError.notInstalled
    }

    let password = Self.makePassword()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "0"]

    var environment = ProcessInfo.processInfo.environment
    environment["OPENCODE_SERVER_PASSWORD"] = password
    environment["CI"] = environment["CI"] ?? "1"
    process.environment = environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice

    let ready = ReadinessBox()
    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      let text = String(decoding: data, as: UTF8.self)
      Task { await ready.append(text) }
    }
    stderr.fileHandleForReading.readabilityHandler = { [log] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      let text = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      let safe = Self.redact(text)
      log.debug("opencode: \(safe, privacy: .public)")
      Task { await ready.appendError(safe) }
    }

    reapOrphanFromPreviousLaunch()

    do {
      try process.run()
    } catch {
      throw AgentClientError.serverStartFailed(error.localizedDescription)
    }
    self.process = process
    Self.recordPID(process.processIdentifier)

    let deadline = Date().addingTimeInterval(readinessTimeout)
    while Date() < deadline {
      if let port = await ready.port() {
        guard let url = URL(string: "http://127.0.0.1:\(port)") else {
          throw AgentClientError.serverStartFailed("unusable port \(port)")
        }
        log.info("opencode server ready on 127.0.0.1:\(port, privacy: .public)")
        return Endpoint(baseURL: url, username: "opencode", password: password)
      }
      if !process.isRunning {
        guard let said = await ready.lastError() else {
          throw AgentClientError.processExited(process.terminationStatus)
        }
        throw AgentClientError.serverStartFailed(said)
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    throw AgentClientError.startupTimedOut
  }

  func stop() async {
    guard let process else {
      endpoint = nil
      return
    }
    (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    if process.isRunning {
      process.terminate()
      let deadline = Date().addingTimeInterval(3)
      while process.isRunning, Date() < deadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
    let stopped = process.processIdentifier
    self.process = nil
    endpoint = nil
    Self.forgetPID(stopped)
  }

  private static func makePassword() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
      bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func redact(_ text: String) -> String {
    var output = text
    for pattern in ["OPENCODE_SERVER_PASSWORD=[^\\s]+", "password=[^\\s]+", "Basic [A-Za-z0-9+/=]+"] {
      output = output.replacingOccurrences(
        of: pattern,
        with: "<redacted>",
        options: [.regularExpression, .caseInsensitive]
      )
    }
    return output
  }

  private actor ReadinessBox {
    private var text = ""
    private var announcedPort: Int?
    private var errors = ""

    func append(_ chunk: String) {
      guard announcedPort == nil else { return }
      text += chunk
      announcedPort = OpenCodeServer.parsePort(from: text)
      if announcedPort != nil { text = "" }
    }

    func appendError(_ chunk: String) {
      errors += chunk
      if errors.count > 8192 { errors.removeFirst(errors.count - 8192) }
    }

    func port() -> Int? { announcedPort }

    func lastError() -> String? {
      errors
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty }
    }
  }

  static func parsePort(from output: String) -> Int? {
    let pattern = "listening on https?://(?:127\\.0\\.0\\.1|localhost):(\\d+)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
      return nil
    }
    let range = NSRange(output.startIndex..., in: output)
    guard let match = regex.firstMatch(in: output, range: range),
          let portRange = Range(match.range(at: 1), in: output)
    else { return nil }
    return Int(output[portRange])
  }

  // MARK: - Reaping servers a crash left behind

  private static var pidFileURL: URL? {
    if let override = ledgerOverride.withLock({ $0 }) { return override }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    guard let base else { return nil }
    let directory = base.appendingPathComponent("Boltty", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("opencode-server.pid")
  }

  private static let ledgerOverride = OSAllocatedUnfairLock<URL?>(initialState: nil)

  static func useLedgerForTesting(_ url: URL?) {
    ledgerOverride.withLock { $0 = url }
  }

  private struct ServerRecord {
    let server: pid_t
    let owner: pid_t
  }

  private static func readLedger() -> [ServerRecord] {
    guard let url = pidFileURL,
          let text = try? String(contentsOf: url, encoding: .utf8)
    else { return [] }
    return text.split(separator: "\n").compactMap { line in
      let fields = line.split(separator: " ")
      guard let server = pid_t(fields.first ?? "") else { return nil }
      let owner = fields.count > 1 ? pid_t(fields[1]) ?? 0 : 0
      return ServerRecord(server: server, owner: owner)
    }
  }

  private static func writeLedger(_ records: [ServerRecord]) {
    guard let url = pidFileURL else { return }
    guard !records.isEmpty else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    let text = records.map { "\($0.server) \($0.owner)" }.joined(separator: "\n")
    try? Data(text.utf8).write(to: url, options: .atomic)
  }

  private static let ownedLock = NSLock()
  nonisolated(unsafe) private static var ownedServers: Set<pid_t> = []

  private static func recordPID(_ pid: pid_t) {
    ownedLock.withLock { _ = ownedServers.insert(pid) }
    var records = readLedger().filter { $0.server != pid }
    records.append(ServerRecord(server: pid, owner: getpid()))
    writeLedger(records)
  }

  private static func isOwnedByThisProcess(_ pid: pid_t) -> Bool {
    ownedLock.withLock { ownedServers.contains(pid) }
  }

  private static func forgetPID(_ pid: pid_t) {
    ownedLock.withLock { _ = ownedServers.remove(pid) }
    writeLedger(readLedger().filter { $0.server != pid })
  }

  private static func clearRecordedPID() {
    guard let url = pidFileURL else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private func reapOrphanFromPreviousLaunch() {
    let records = Self.readLedger()
    guard !records.isEmpty else { return }
    var survivors: [ServerRecord] = []

    for record in records {
      if Self.isOwnedByThisProcess(record.server) {
        survivors.append(record)
        continue
      }
      if record.owner > 1, record.owner != getpid(), kill(record.owner, 0) == 0 {
        survivors.append(record)
        continue
      }
      guard record.server > 1, kill(record.server, 0) == 0 else { continue }
      guard let path = Self.executablePath(ofPID: record.server),
            executableCandidates.contains(path) || path.hasSuffix("/opencode")
      else {
        log.debug("stale opencode pid \(record.server, privacy: .public) now belongs to something else")
        continue
      }
      log.info("reaping opencode server \(record.server, privacy: .public) left by a previous launch")
      kill(record.server, SIGTERM)
    }

    Self.writeLedger(survivors)
  }

  func reapForTesting() { reapOrphanFromPreviousLaunch() }
  static func recordPIDForTesting(_ pid: pid_t, owner: pid_t = 99_999_991) {
    var records = readLedger().filter { $0.server != pid }
    records.append(ServerRecord(server: pid, owner: owner))
    writeLedger(records)
  }
  static func clearRecordedPIDForTesting() {
    ownedLock.withLock { ownedServers.removeAll() }
    clearRecordedPID()
  }

  static func recordOwnedPIDForTesting(_ pid: pid_t) { recordPID(pid) }
  static func recordedPIDForTesting() -> pid_t? { readLedger().first?.server }
  static func recordedPIDsForTesting() -> [pid_t] { readLedger().map(\.server) }

  private static func executablePath(ofPID pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer[..<Int(length)], as: UTF8.self)
  }
}
