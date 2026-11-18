import Foundation

/// Files for `@`: a walk of the chat's folder, or Spotlight when the chat is in
/// the home folder (the default, where a walk would never end). No CLI offers
/// this to all five agents, so Boltty searches and the chosen file goes as a card.
@MainActor
final class FileMentionSearch {
  nonisolated static let resultLimit = 8

  private var spotlight: NSMetadataQuery?
  private var spotlightObserver: NSObjectProtocol?
  private var walkTask: Task<Void, Never>?
  private var generation = 0
  private var index: (root: String, made: Date, candidates: [FileMention.Candidate])?
  private var indexTask: (root: String, task: Task<[FileMention.Candidate], Never>)?

  nonisolated static let indexLifetime: TimeInterval = 20

  func search(
    _ query: String, in folder: String?,
    deliver: @escaping @MainActor ([FileMention.Candidate]) -> Void
  ) {
    cancel()
    generation += 1
    let current = generation
    let root = folder.map { ($0 as NSString).standardizingPath } ?? NSHomeDirectory()
    if Self.usesSpotlight(root) {
      searchSpotlight(query, under: root) { [weak self] found in
        guard self?.generation == current else { return }
        deliver(found)
      }
      return
    }
    walkTask = Task { [weak self] in
      guard let self else { return }
      let candidates = await self.candidates(under: root)
      guard !Task.isCancelled, self.generation == current else { return }
      let ranked = await Task.detached(priority: .userInitiated) {
        FileMention.rank(candidates, query: query, limit: Self.resultLimit)
      }.value
      guard !Task.isCancelled, self.generation == current else { return }
      deliver(ranked)
    }
  }

  func cancel() {
    generation += 1
    walkTask?.cancel()
    walkTask = nil
    stopSpotlight()
  }

  /// Home, or a folder that holds it: Spotlight's index, not a walk.
  nonisolated static func usesSpotlight(_ root: String) -> Bool {
    let home = NSHomeDirectory()
    return root == home || home.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }

  // MARK: - The chat's folder

  private func candidates(under root: String) async -> [FileMention.Candidate] {
    if let index, index.root == root, Date().timeIntervalSince(index.made) < Self.indexLifetime {
      return index.candidates
    }
    let task: Task<[FileMention.Candidate], Never>
    if let running = indexTask, running.root == root {
      task = running.task
    } else {
      task = Task.detached(priority: .userInitiated) { FolderWalk.candidates(under: root) }
      indexTask = (root, task)
    }
    let found = await task.value
    if indexTask?.root == root { indexTask = nil }
    index = (root, Date(), found)
    return found
  }

  // MARK: - Spotlight

  private func searchSpotlight(
    _ query: String, under root: String,
    deliver: @escaping @MainActor ([FileMention.Candidate]) -> Void
  ) {
    let metadata = NSMetadataQuery()
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      metadata.predicate = NSPredicate(
        format: "%K >= %@", "kMDItemLastUsedDate", Date().addingTimeInterval(-14 * 86_400) as NSDate)
    } else {
      metadata.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(trimmed)*")
    }
    metadata.searchScopes = [root == NSHomeDirectory() ? NSMetadataQueryUserHomeScope : URL(fileURLWithPath: root)]
    metadata.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
    spotlightObserver = NotificationCenter.default.addObserver(
      forName: .NSMetadataQueryDidFinishGathering, object: metadata, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let metadata = self.spotlight else { return }
        metadata.disableUpdates()
        let found = Self.spotlightCandidates(metadata, under: root, query: trimmed)
        self.stopSpotlight()
        deliver(found)
      }
    }
    spotlight = metadata
    metadata.start()
  }

  private static func spotlightCandidates(
    _ metadata: NSMetadataQuery, under root: String, query: String
  ) -> [FileMention.Candidate] {
    var found: [FileMention.Candidate] = []
    let count = min(metadata.resultCount, 400)
    for index in 0..<count {
      guard let item = metadata.result(at: index) as? NSMetadataItem,
            let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
            !FolderWalk.isOutOfSight(path, under: root)
      else { continue }
      let type = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
      let used = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
      let changed = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
      found.append(FileMention.Candidate(
        url: URL(fileURLWithPath: path),
        isDirectory: type == "public.folder",
        relativePath: FolderWalk.relative(path, to: root),
        modified: used ?? changed))
    }
    return FileMention.rank(found, query: query, limit: resultLimit)
  }

  private func stopSpotlight() {
    spotlight?.stop()
    spotlight = nil
    if let spotlightObserver { NotificationCenter.default.removeObserver(spotlightObserver) }
    spotlightObserver = nil
  }
}

enum FolderWalk {
  static let entryLimit = 40_000
  static let timeLimit: TimeInterval = 2

  /// Never worth offering, and often most of a project's files.
  static let skippedNames: Set<String> = [
    "node_modules", "DerivedData", "Pods", "Carthage", "build", "dist", "target",
    "__pycache__", "venv", "vendor",
  ]

  static func candidates(under root: String) -> [FileMention.Candidate] {
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let ignored = GitIgnoreNames.read(at: rootURL)
    let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .isPackageKey]
    guard let walk = FileManager.default.enumerator(
      at: rootURL, includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants],
      errorHandler: { _, _ in true })
    else { return [] }
    let deadline = Date().addingTimeInterval(timeLimit)
    var found: [FileMention.Candidate] = []
    for case let url as URL in walk {
      let name = url.lastPathComponent
      let values = try? url.resourceValues(forKeys: Set(keys))
      let isDirectory = values?.isDirectory == true && values?.isPackage != true
      if skippedNames.contains(name) || ignored.matches(name, isDirectory: isDirectory) {
        if isDirectory { walk.skipDescendants() }
        continue
      }
      found.append(FileMention.Candidate(
        url: url, isDirectory: isDirectory,
        relativePath: relative(url.path, to: root),
        modified: values?.contentModificationDate))
      if found.count >= entryLimit || (found.count % 512 == 0 && Date() > deadline) { break }
    }
    return found
  }

  static func relative(_ path: String, to root: String) -> String {
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
  }

  /// Spotlight's home holds Library and dot-folders, which nobody means by `@`.
  static func isOutOfSight(_ path: String, under root: String) -> Bool {
    let inside = relative(path, to: root)
    if inside == path, !path.hasPrefix(root) { return true }
    let parts = inside.split(separator: "/")
    if parts.contains(where: { $0.hasPrefix(".") || skippedNames.contains(String($0)) }) { return true }
    return parts.first == "Library"
  }
}

/// The plain lines of a folder's `.gitignore`: names and `*.ext`. Anything
/// with a slash inside or another glob is passed over, never guessed at.
struct GitIgnoreNames {
  var names: Set<String> = []
  var directoryNames: Set<String> = []
  var extensions: Set<String> = []

  static func read(at root: URL) -> GitIgnoreNames {
    var result = GitIgnoreNames()
    guard let text = try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
    else { return result }
    for raw in text.split(whereSeparator: \.isNewline) {
      var line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
      if line.hasPrefix("/") { line.removeFirst() }
      let directoryOnly = line.hasSuffix("/")
      if directoryOnly { line.removeLast() }
      guard !line.isEmpty, !line.contains("/") else { continue }
      if line.hasPrefix("*."), !line.dropFirst(2).contains(where: { "*?[".contains($0) }) {
        result.extensions.insert(String(line.dropFirst(2)).lowercased())
      } else if !line.contains(where: { "*?[".contains($0) }) {
        if directoryOnly { result.directoryNames.insert(line) } else { result.names.insert(line) }
      }
    }
    return result
  }

  func matches(_ name: String, isDirectory: Bool) -> Bool {
    if names.contains(name) { return true }
    if isDirectory { return directoryNames.contains(name) }
    let ext = (name as NSString).pathExtension.lowercased()
    return !ext.isEmpty && extensions.contains(ext)
  }
}
