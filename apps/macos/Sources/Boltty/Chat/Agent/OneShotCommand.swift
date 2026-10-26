import Foundation

enum OneShotCommand {
  struct Result: Sendable, Equatable {
    var exitCode: Int32
    var output: String
  }

  static let versionDeadline: TimeInterval = 8

  static let afterExitGrace: TimeInterval = 0.3
  static let killGrace: TimeInterval = 1

  static func run(
    _ executable: String,
    _ arguments: [String],
    deadline: TimeInterval,
    includeStandardError: Bool = false,
    searchPath: Bool = true
  ) async -> Result? {
    await withCheckedContinuation { continuation in
      start(
        executable, arguments,
        deadline: deadline,
        includeStandardError: includeStandardError,
        searchPath: searchPath
      ) { continuation.resume(returning: $0) }
    }
  }

  static func runBlocking(
    _ executable: String,
    _ arguments: [String],
    deadline: TimeInterval,
    includeStandardError: Bool = false,
    searchPath: Bool = true
  ) -> Result? {
    let box = ResultBox()
    let done = DispatchSemaphore(value: 0)
    start(
      executable, arguments,
      deadline: deadline,
      includeStandardError: includeStandardError,
      searchPath: searchPath
    ) {
      box.value = $0
      done.signal()
    }
    done.wait()
    return box.value
  }

  // MARK: - Plumbing

  private final class ResultBox: @unchecked Sendable {
    var value: Result?
  }

  private final class Run: @unchecked Sendable {
    let lock = NSLock()
    var output = Data()
    var exited = false
    var outputClosed = false
    var finished = false
    var exitCode: Int32 = -1
    let completion: @Sendable (Result?) -> Void

    init(completion: @escaping @Sendable (Result?) -> Void) {
      self.completion = completion
    }

    func finish(timedOut: Bool = false) {
      let answer: Result?? = lock.withLock {
        guard !finished else { return nil }
        finished = true
        if timedOut { return .some(nil) }
        return .some(Result(exitCode: exitCode, output: String(decoding: output, as: UTF8.self)))
      }
      guard let answer else { return }
      completion(answer)
    }
  }

  private static func start(
    _ executable: String,
    _ arguments: [String],
    deadline: TimeInterval,
    includeStandardError: Bool,
    searchPath: Bool,
    completion: @escaping @Sendable (Result?) -> Void
  ) {
    let run = Run(completion: completion)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if searchPath {
      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] = JSONLineProcess.searchPath(adding: environment["PATH"])
      process.environment = environment
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = includeStandardError ? pipe : FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let reader = pipe.fileHandleForReading
    reader.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        let ready = run.lock.withLock {
          run.outputClosed = true
          return run.exited
        }
        if ready { run.finish() }
      } else {
        run.lock.withLock { run.output.append(chunk) }
      }
    }
    process.terminationHandler = { ended in
      let ready = run.lock.withLock {
        run.exited = true
        run.exitCode = ended.terminationStatus
        return run.outputClosed
      }
      if ready {
        run.finish()
      } else {
        DispatchQueue.global().asyncAfter(deadline: .now() + afterExitGrace) {
          reader.readabilityHandler = nil
          run.finish()
        }
      }
    }

    do {
      try process.run()
    } catch {
      reader.readabilityHandler = nil
      process.terminationHandler = nil
      run.finish(timedOut: true)
      return
    }

    let pid = process.processIdentifier
    DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
      withExtendedLifetime(process) {}
      let pending = run.lock.withLock { !run.finished && !run.exited }
      guard pending else { return }
      kill(pid, SIGTERM)
      reader.readabilityHandler = nil
      run.finish(timedOut: true)
      DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
        if run.lock.withLock({ !run.exited }) { kill(pid, SIGKILL) }
      }
    }
  }
}
