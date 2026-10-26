import Foundation

struct ClaudeCodeSessionStore: NativeSessionStore {
  var agent: AgentId { .claude }

  let root: URL

  init(root: URL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".claude/projects")) {
    self.root = root
  }

  func session(for change: NativeStoreChange) throws -> NativeSession? {
    guard case let .chat(id, url) = change else { return nil }
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate ?? Date()
    return try session(at: url, id: id, modified: modified)
  }

  func transcript(for session: NativeSession) throws -> [ConversationMessage]? {
    guard let url = session.sourceURL,
          FileManager.default.fileExists(atPath: url.path)
    else { return nil }
    return ClaudeCodeTranscript.read(at: url).messages
  }

  private static let cwdNeedle = Data("\"cwd\"".utf8)
  private static let userNeedle = Data("\"user\"".utf8)

  func sessions(limit: Int) throws -> [NativeSession] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: root.path, isDirectory: &isDirectory
    ), isDirectory.boolValue else {
      return []
    }

    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    guard let walk = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: keys
    ) else {
      throw NativeSessionStoreError.unreadable(
        path: root.path, reason: "the projects directory could not be enumerated"
      )
    }

    var found: [(url: URL, id: String, modified: Date)] = []
    for case let url as URL in walk {
      guard url.pathExtension == "jsonl" else { continue }
      let values = try? url.resourceValues(forKeys: Set(keys))
      guard values?.isRegularFile == true else { continue }
      found.append(
        (url, url.deletingPathExtension().lastPathComponent,
         values?.contentModificationDate ?? .distantPast)
      )
    }

    return found
      .sorted { $0.modified > $1.modified }
      .prefix(limit)
      .compactMap { file in try? session(at: file.url, id: file.id, modified: file.modified) }
  }

  private func session(at url: URL, id: String, modified: Date) throws -> NativeSession {
    var directory = ""
    var title: String?

    try FileHead.forEachLine(of: url, maxLines: 400) { line in
      let mightPlace = directory.isEmpty && line.range(of: Self.cwdNeedle) != nil
      let mightName = title == nil && line.range(of: Self.userNeedle) != nil
      guard mightPlace || mightName else { return true }

      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
      else { return true }

      if directory.isEmpty, let cwd = object["cwd"] as? String { directory = cwd }
      if title == nil, object["type"] as? String == "user" {
        let isMeta = object["isMeta"] as? Bool ?? false
        let isSidechain = object["isSidechain"] as? Bool ?? false
        if !isMeta, !isSidechain,
           let message = object["message"] as? [String: Any] {
          title = Self.firstTypedText(in: message["content"])
        }
      }
      return directory.isEmpty || title == nil
    }

    return NativeSession(
      id: id,
      agent: .claude,
      title: title ?? Self.fallbackTitle(for: directory),
      workingDirectory: directory,
      updatedAt: modified,
      sourceURL: url
    )
  }

  private static func firstTypedText(in content: Any?) -> String? {
    var candidates: [String] = []
    if let text = content as? String {
      candidates = [text]
    } else if let parts = content as? [[String: Any]] {
      candidates = parts.compactMap { $0["text"] as? String }
    }
    for candidate in candidates {
      let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty,
            !InjectedText.isScaffolding(
              text, tags: InjectedText.claudeTags, prefixes: InjectedText.claudePrefixes
            )
      else { continue }
      return InjectedText.title(from: text)
    }
    return nil
  }

  private static func fallbackTitle(for directory: String) -> String {
    let name = (directory as NSString).lastPathComponent
    return name.isEmpty ? "Claude Code session" : name
  }
}
