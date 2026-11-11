import Combine
import CoreML
import Foundation

protocol LocalModelFetching: Sendable {
  func fetch(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL
}

@MainActor
final class LocalModelStore: ObservableObject {
  enum State: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case preparing
    case ready
    case failed(String)
  }

  enum Failure: LocalizedError, Equatable {
    case secondCopy(String)
    case space(String, needs: Int64)
    case download(String, reason: String)
    case checksum(String)
    case doesNotLoad(String, reason: String)

    var errorDescription: String? {
      switch self {
      case let .secondCopy(name):
        "Another Boltty is already running. Download \(name) in that one."
      case let .space(name, needs):
        "Not enough free space: \(name) needs \(Self.size(needs)) free to download."
      case let .download(name, reason):
        "\(name) could not be downloaded: \(reason)"
      case let .checksum(name):
        "A file of \(name) does not match its checksum, so it was not kept."
      case let .doesNotLoad(name, reason):
        "\(name) does not run on this Mac: \(reason)"
      }
    }

    static func size(_ bytes: Int64) -> String {
      ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
  }

  @Published private(set) var states: [LocalVoiceModel.ID: State] = [:]

  let root: URL
  let models: [LocalVoiceModel]
  private let fetcher: any LocalModelFetching
  private let prepare: @Sendable (URL) throws -> Void
  private let freeSpace: @Sendable (URL) -> Int64?
  private let canWrite: () -> Bool
  private var installs: [LocalVoiceModel.ID: Task<Void, Never>] = [:]

  static let attempts = 3

  init(
    root: URL = LocalModelStore.defaultRoot(),
    models: [LocalVoiceModel] = LocalVoiceCatalog.all,
    fetcher: any LocalModelFetching = URLSessionModelFetcher(),
    prepare: @escaping @Sendable (URL) throws -> Void = LocalModelStore.compileModels(in:),
    freeSpace: @escaping @Sendable (URL) -> Int64? = LocalModelStore.availableSpace(at:),
    canWrite: @escaping () -> Bool = { true }
  ) {
    self.root = root
    self.models = models.filter(\.isWellFormed)
    self.fetcher = fetcher
    self.prepare = prepare
    self.freeSpace = freeSpace
    self.canWrite = canWrite
    refresh()
  }

  nonisolated static func defaultRoot() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("Boltty/Models", isDirectory: true)
  }

  func state(of id: LocalVoiceModel.ID) -> State { states[id] ?? .notInstalled }

  func folder(of id: LocalVoiceModel.ID) -> URL? {
    guard state(of: id) == .ready, let model = model(id) else { return nil }
    return folder(for: model)
  }

  func refresh() {
    let manager = FileManager.default
    let entries = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
    if canWrite() {
      for entry in entries where isStale(entry) {
        try? manager.removeItem(at: root.appendingPathComponent(entry))
      }
    }
    var next: [LocalVoiceModel.ID: State] = [:]
    for model in models where installs[model.id] == nil {
      next[model.id] = Self.isComplete(model, in: folder(for: model)) ? .ready : .notInstalled
    }
    for (id, state) in states where installs[id] != nil { next[id] = state }
    states = next
  }

  func install(_ id: LocalVoiceModel.ID) async {
    if let running = installs[id] { return await running.value }
    guard let model = model(id), state(of: id) != .ready else { return }
    let task = Task { await run(model) }
    installs[id] = task
    await task.value
    installs[id] = nil
  }

  func cancel(_ id: LocalVoiceModel.ID) {
    installs[id]?.cancel()
  }

  func remove(_ id: LocalVoiceModel.ID) {
    guard let model = model(id), canWrite() else { return }
    installs[id]?.cancel()
    try? FileManager.default.removeItem(at: folder(for: model))
    try? FileManager.default.removeItem(at: partialFolder(for: model))
    states[id] = .notInstalled
  }

  // MARK: - Installing

  private func run(_ model: LocalVoiceModel) async {
    guard canWrite() else {
      states[model.id] = .failed(Failure.secondCopy(model.name).localizedDescription)
      return
    }
    let manager = FileManager.default
    let partial = partialFolder(for: model)
    let final = folder(for: model)
    do {
      try manager.createDirectory(at: root, withIntermediateDirectories: true)
      if manager.fileExists(atPath: final.path) {
        try? manager.removeItem(at: partial)
        try manager.moveItem(at: final, to: partial)
      }
      try manager.createDirectory(at: partial, withIntermediateDirectories: true)

      let held = await Self.checked(model.files, in: partial)
      var done = model.files.filter { held.contains($0.path) }.reduce(Int64(0)) { $0 + $1.size }
      let needed = model.size - done
      if let free = freeSpace(root), free < needed * 2 {
        throw Failure.space(model.name, needs: needed * 2)
      }
      states[model.id] = .downloading(Self.fraction(done, of: model))

      for file in model.files where !held.contains(file.path) {
        try Task.checkCancellation()
        let base = done
        let fetched = try await fetch(file, of: model) { [weak self] received in
          Task { @MainActor in self?.report(model, base + received) }
        }
        let target = partial.appendingPathComponent(file.path)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: target)
        try manager.moveItem(at: fetched, to: target)
        done += file.size
        report(model, done)
      }

      try Task.checkCancellation()
      try manager.moveItem(at: partial, to: final)
      states[model.id] = .preparing
      let prepare = prepare
      do {
        try await Task.detached(priority: .utility) { try prepare(final) }.value
      } catch {
        try? manager.removeItem(at: final)
        throw Failure.doesNotLoad(model.name, reason: error.localizedDescription)
      }
      states[model.id] = .ready
    } catch let error where error is CancellationError || Task.isCancelled {
      states[model.id] = .notInstalled
    } catch {
      states[model.id] = .failed((error as? Failure)?.localizedDescription
        ?? Failure.download(model.name, reason: error.localizedDescription).localizedDescription)
    }
  }

  private func fetch(
    _ file: LocalVoiceModel.File,
    of model: LocalVoiceModel,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> URL {
    var lastError: Error?
    for _ in 0..<Self.attempts {
      try Task.checkCancellation()
      let fetched: URL
      do {
        fetched = try await fetcher.fetch(model.source(of: file), progress: progress)
      } catch {
        if Task.isCancelled { throw CancellationError() }
        lastError = error
        continue
      }
      guard await Self.matches(fetched, file) else {
        try? FileManager.default.removeItem(at: fetched)
        throw Failure.checksum(model.name)
      }
      return fetched
    }
    throw Failure.download(model.name, reason: lastError?.localizedDescription ?? "unknown error")
  }

  private func report(_ model: LocalVoiceModel, _ bytes: Int64) {
    guard case let .downloading(current) = state(of: model.id) else { return }
    let fraction = Self.fraction(bytes, of: model)
    guard fraction >= current + 0.005 || (fraction == 1 && current < 1) else { return }
    states[model.id] = .downloading(fraction)
  }

  private static func fraction(_ bytes: Int64, of model: LocalVoiceModel) -> Double {
    model.size > 0 ? min(1, Double(bytes) / Double(model.size)) : 1
  }

  // MARK: - Disk

  private func model(_ id: LocalVoiceModel.ID) -> LocalVoiceModel? {
    models.first { $0.id == id }
  }

  private func folder(for model: LocalVoiceModel) -> URL {
    root.appendingPathComponent(model.folderName, isDirectory: true)
  }

  private func partialFolder(for model: LocalVoiceModel) -> URL {
    root.appendingPathComponent(model.folderName + ".partial", isDirectory: true)
  }

  private func isStale(_ entry: String) -> Bool {
    let ours = LocalVoiceModel.ID.allCases.contains { entry.hasPrefix($0.rawValue + "-") }
    let current = models.contains { entry == $0.folderName || entry == $0.folderName + ".partial" }
    return ours && !current
  }

  private static func isComplete(_ model: LocalVoiceModel, in folder: URL) -> Bool {
    model.files.allSatisfy { file in
      let path = folder.appendingPathComponent(file.path).path
      let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
      return size == file.size
    }
  }

  private static func checked(_ files: [LocalVoiceModel.File], in folder: URL) async -> Set<String> {
    await Task.detached(priority: .utility) {
      var held: Set<String> = []
      for file in files {
        let url = folder.appendingPathComponent(file.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        if size == file.size, (try? FileDigest.sha256(of: url)) == file.sha256 { held.insert(file.path) }
      }
      return held
    }.value
  }

  private static func matches(_ fetched: URL, _ file: LocalVoiceModel.File) async -> Bool {
    await Task.detached(priority: .utility) {
      let size = (try? FileManager.default.attributesOfItem(atPath: fetched.path)[.size] as? NSNumber)?.int64Value
      return size == file.size && (try? FileDigest.sha256(of: fetched)) == file.sha256
    }.value
  }

  // MARK: - Defaults

  nonisolated static func compileModels(in folder: URL) throws {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    for bundle in modelBundles(in: folder) {
      _ = try MLModel(contentsOf: bundle, configuration: configuration)
    }
  }

  nonisolated static func modelBundles(in folder: URL) -> [URL] {
    guard let walker = FileManager.default.enumerator(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return [] }
    var bundles: [URL] = []
    for case let url as URL in walker where url.pathExtension == "mlmodelc" {
      bundles.append(url)
      walker.skipDescendants()
    }
    return bundles.sorted { $0.path < $1.path }
  }

  nonisolated static func availableSpace(at url: URL) -> Int64? {
    var probe = url
    while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
      probe = probe.deletingLastPathComponent()
    }
    return try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage
  }
}

struct URLSessionModelFetcher: LocalModelFetching {
  func fetch(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
    let watcher = DownloadProgressWatcher(report: progress)
    let (file, response) = try await URLSession.shared.download(from: url, delegate: watcher)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      try? FileManager.default.removeItem(at: file)
      throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Hugging Face answered \(status)."])
    }
    return file
  }
}

/// Watches one download's bytes. Reports at most once a megabyte: a 600 MB
/// file would otherwise wake the main actor tens of thousands of times.
private final class DownloadProgressWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let report: @Sendable (Int64) -> Void
  private var observation: NSKeyValueObservation?
  private var reported: Int64 = 0
  private let lock = NSLock()

  init(report: @escaping @Sendable (Int64) -> Void) {
    self.report = report
  }

  func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
    observation = task.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
      self?.received(progress.completedUnitCount)
    }
  }

  private func received(_ bytes: Int64) {
    let due: Bool = lock.withLock {
      guard bytes - reported >= 1 << 20 else { return false }
      reported = bytes
      return true
    }
    if due { report(bytes) }
  }
}
