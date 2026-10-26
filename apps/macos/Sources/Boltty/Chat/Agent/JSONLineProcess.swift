import Foundation
import os

final class JSONLineProcess: @unchecked Sendable {
  private let executable: String
  private let arguments: [String]
  private let directory: String?
  private let extraEnvironment: [String: String]
  private let log: Logger

  private let process = Process()
  private let inPipe = Pipe()
  private let outPipe = Pipe()
  private let errPipe = Pipe()

  private let lock = NSLock()
  private let writeLock = NSLock()
  private var outBuffer = Data()
  private var outScanned = 0
  private var errBuffer = Data()
  private var continuation: AsyncStream<String>.Continuation?
  private var hasExited = false

  var onExit: (@Sendable (Int32, String) -> Void)?

  init(
    executable: String,
    arguments: [String],
    directory: String? = nil,
    environment: [String: String] = [:],
    category: String = "agent-process"
  ) {
    self.executable = executable
    self.arguments = arguments
    self.directory = directory
    self.extraEnvironment = environment
    self.log = Logger(subsystem: "com.boltty", category: category)
  }

  private(set) lazy var lines: AsyncStream<String> = AsyncStream { continuation in
    lock.withLock { self.continuation = continuation }
  }

  var isRunning: Bool { process.isRunning }
  var processIdentifier: Int32 { process.processIdentifier }
  var terminationStatus: Int32 { process.terminationStatus }

  var exitDetail: String {
    Self.exitDetail(status: terminationStatus, stderr: standardErrorText)
  }

  static func exitDetail(status: Int32, stderr: String) -> String {
    let tail = stderr
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .last { !$0.isEmpty }
    return tail ?? "exited (status \(status))"
  }

  var standardErrorText: String {
    lock.withLock { String(decoding: errBuffer, as: UTF8.self) }
  }

  func start() throws {
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = Self.searchPath(adding: environment["PATH"])
    for (key, value) in extraEnvironment { environment[key] = value }
    process.environment = environment
    process.standardInput = inPipe
    process.standardOutput = outPipe
    process.standardError = errPipe

    outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.absorbStandardOutput(handle.availableData)
    }
    errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.absorbStandardError(handle.availableData)
    }
    process.terminationHandler = { [weak self] process in
      self?.finish(status: process.terminationStatus)
    }

    do {
      try process.run()
    } catch {
      throw AgentClientError.serverStartFailed(error.localizedDescription)
    }
  }

  /// One writer at a time: lines longer than the pipe's atomic size interleave.
  func writeLine(_ line: String) throws {
    guard process.isRunning else {
      throw AgentClientError.processExited(process.terminationStatus)
    }
    let data = Data((line + "\n").utf8)
    do {
      try writeLock.withLock {
        try inPipe.fileHandleForWriting.write(contentsOf: data)
      }
    } catch {
      throw AgentClientError.transport("The agent stopped accepting input.")
    }
  }

  func closeInput() {
    try? inPipe.fileHandleForWriting.close()
  }

  func terminate() {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(2)
    DispatchQueue.global(qos: .utility).async { [process] in
      while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }

  private func absorbStandardOutput(_ data: Data) {
    guard !data.isEmpty else { return }
    let (ready, continuation): ([String], AsyncStream<String>.Continuation?) = lock.withLock {
      outBuffer.append(data)
      var lines: [String] = []
      let base = outBuffer.startIndex
      var start = base
      var searchFrom = base + outScanned
      while let index = Self.newline(in: outBuffer, from: searchFrom) {
        let text = String(decoding: outBuffer[start..<index], as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { lines.append(text) }
        start = index + 1
        searchFrom = start
      }
      if start > base { outBuffer.removeSubrange(base..<start) }
      outScanned = outBuffer.count
      return (lines, self.continuation)
    }
    for line in ready { continuation?.yield(line) }
  }

  private static func newline(in buffer: Data, from: Data.Index) -> Data.Index? {
    guard from < buffer.endIndex else { return nil }
    return buffer.withUnsafeBytes { raw -> Data.Index? in
      guard let base = raw.baseAddress else { return nil }
      let offset = from - buffer.startIndex
      guard let hit = memchr(base + offset, 0x0A, raw.count - offset) else { return nil }
      return buffer.startIndex + (UnsafeRawPointer(hit) - base)
    }
  }

  private func absorbStandardError(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.withLock {
      errBuffer.append(data)
      if errBuffer.count > 8192 { errBuffer.removeFirst(errBuffer.count - 8192) }
    }
  }

  /// The exit can be reported before the handler has read the CLI's last
  /// words, which are the error a refused start must carry. Read what is
  /// left without blocking: a child that inherited the pipe may hold it open.
  private func drainStandardError() {
    let descriptor = errPipe.fileHandleForReading.fileDescriptor
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      guard count > 0 else { return }
      absorbStandardError(Data(buffer[0..<count]))
    }
  }

  private func finish(status: Int32) {
    let shouldReport: Bool = lock.withLock {
      guard !hasExited else { return false }
      hasExited = true
      return true
    }
    guard shouldReport else { return }
    outPipe.fileHandleForReading.readabilityHandler = nil
    errPipe.fileHandleForReading.readabilityHandler = nil
    drainStandardError()
    lock.withLock { continuation }?.finish()
    onExit?(status, standardErrorText)
  }

  static func searchPath(adding existing: String?) -> String {
    ExecutableLookup.searchDirectories(path: existing ?? "").joined(separator: ":")
  }

  static let loginShellDeadline: TimeInterval = 5

  static func locate(_ program: String, extraCandidates: [String] = []) -> String? {
    let fileManager = FileManager.default
    let candidates = extraCandidates + ExecutableLookup.searchDirectories()
      .map { "\($0)/\(program)" }
    for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
      return candidate
    }
    guard let answer = OneShotCommand.runBlocking(
      "/usr/bin/env", ["sh", "-lc", "command -v \(program)"],
      deadline: loginShellDeadline,
      searchPath: false
    ) else { return nil }
    let path = answer.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return fileManager.isExecutableFile(atPath: path) ? path : nil
  }
}
