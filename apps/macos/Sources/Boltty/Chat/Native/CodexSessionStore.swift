import Foundation

struct CodexSessionStore: NativeSessionStore {
  var agent: AgentId { .codex }

  let root: URL

  init(root: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")) {
    self.root = root
  }

  static func sessionID(fromRolloutName name: String) -> String? {
    let pattern = /^rollout-.+-([0-9a-fA-F-]{36})\.jsonl$/
    guard let match = name.wholeMatch(of: pattern) else { return nil }
    return String(match.1).lowercased()
  }

  func session(for change: NativeStoreChange) throws -> NativeSession? {
    guard case let .chat(id, url) = change else { return nil }
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate ?? Date()
    return try session(
      from: Rollout(url: url, id: id, modified: modified), titles: indexedTitles()
    )
  }

  func transcript(for session: NativeSession) throws -> [ConversationMessage]? {
    guard let url = session.sourceURL,
          FileManager.default.fileExists(atPath: url.path)
    else { return nil }
    return CodexRolloutTranscript.read(at: url)
  }

  private static let metaNeedle = Data("session_meta".utf8)
  private static let userNeedle = Data("user".utf8)

  func sessions(limit: Int) throws -> [NativeSession] {
    let sessionsRoot = root.appendingPathComponent("sessions")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: sessionsRoot.path, isDirectory: &isDirectory
    ), isDirectory.boolValue else {
      return []
    }

    let files = try rollouts(under: sessionsRoot)
      .sorted { $0.modified > $1.modified }
      .prefix(limit)
    let titles = indexedTitles()

    return files.compactMap { file in
      try? session(from: file, titles: titles)
    }
  }

  // MARK: - Walking

  private struct Rollout {
    let url: URL
    let id: String
    let modified: Date
  }

  private func rollouts(under sessionsRoot: URL) throws -> [Rollout] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    guard let walk = FileManager.default.enumerator(
      at: sessionsRoot, includingPropertiesForKeys: keys
    ) else {
      throw NativeSessionStoreError.unreadable(
        path: sessionsRoot.path, reason: "the sessions directory could not be enumerated"
      )
    }

    var found: [Rollout] = []
    for case let url as URL in walk {
      guard let id = Self.sessionID(fromRolloutName: url.lastPathComponent) else { continue }
      let values = try? url.resourceValues(forKeys: Set(keys))
      guard values?.isRegularFile == true else { continue }
      found.append(
        Rollout(
          url: url,
          id: id,
          modified: values?.contentModificationDate ?? .distantPast
        )
      )
    }
    return found
  }

  // MARK: - One session

  private func session(from rollout: Rollout, titles: [String: String]) throws -> NativeSession {
    var directory = ""
    var typedTitle: String?

    try FileHead.forEachLine(of: rollout.url, maxLines: 600) { line in
      let mightBeMeta = directory.isEmpty && line.range(of: Self.metaNeedle) != nil
      let mightBeUser = typedTitle == nil && line.range(of: Self.userNeedle) != nil
      guard mightBeMeta || mightBeUser else { return true }

      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let payload = object["payload"] as? [String: Any]
      else { return true }

      if object["type"] as? String == "session_meta", directory.isEmpty {
        directory = payload["cwd"] as? String ?? ""
      }
      if typedTitle == nil,
         object["type"] as? String == "response_item",
         payload["type"] as? String == "message",
         payload["role"] as? String == "user" {
        typedTitle = Self.firstTypedText(in: payload["content"])
      }
      return directory.isEmpty || typedTitle == nil
    }

    let title = titles[rollout.id] ?? typedTitle ?? Self.fallbackTitle(for: directory)
    return NativeSession(
      id: rollout.id,
      agent: .codex,
      title: title,
      workingDirectory: directory,
      updatedAt: rollout.modified,
      sourceURL: rollout.url
    )
  }

  private static func firstTypedText(in content: Any?) -> String? {
    guard let parts = content as? [[String: Any]] else { return nil }
    for part in parts {
      let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !text.isEmpty,
            !InjectedText.isScaffolding(
              text, tags: InjectedText.codexTags, prefixes: InjectedText.codexPrefixes
            )
      else { continue }
      return InjectedText.title(from: text)
    }
    return nil
  }

  private static func fallbackTitle(for directory: String) -> String {
    let name = (directory as NSString).lastPathComponent
    return name.isEmpty ? "Codex session" : name
  }

  // MARK: - The index, used only for its titles

  private func indexedTitles() -> [String: String] {
    let index = root.appendingPathComponent("session_index.jsonl")
    guard let lines = try? FileHead.lines(of: index, maxLines: 5000) else { return [:] }
    var titles: [String: String] = [:]
    for line in lines {
      guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String,
            let name = (object["thread_name"] as? String)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
      else { continue }
      titles[id.lowercased()] = name
    }
    return titles
  }
}
