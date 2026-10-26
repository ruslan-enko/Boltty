import Foundation

struct GrokSessionStore: NativeSessionStore {
  var agent: AgentId { .grok }

  let root: URL

  init(root: URL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".grok/sessions")) {
    self.root = root
  }

  func session(for change: NativeStoreChange) throws -> NativeSession? {
    guard case let .chat(_, url) = change else { return nil }
    return chat(in: url)
  }

  private static let userNeedle = Data("\"user\"".utf8)

  func sessions(limit: Int) throws -> [NativeSession] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: root.path, isDirectory: &isDirectory
    ), isDirectory.boolValue else {
      return []
    }

    let manager = FileManager.default
    guard let places = try? manager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    ) else {
      throw NativeSessionStoreError.unreadable(
        path: root.path, reason: "the sessions directory could not be listed"
      )
    }

    var chats: [NativeSession] = []
    for place in places {
      let directories = (try? manager.contentsOfDirectory(
        at: place, includingPropertiesForKeys: nil
      )) ?? []
      for session in directories {
        if let chat = chat(in: session) { chats.append(chat) }
      }
    }
    return chats.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit).map { $0 }
  }

  private func chat(in directory: URL) -> NativeSession? {
    let summaryURL = directory.appendingPathComponent("summary.json")
    guard let data = try? Data(contentsOf: summaryURL),
          let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let info = summary["info"] as? [String: Any],
          let id = info["id"] as? String
    else { return nil }

    let messages = summary["num_messages"] as? Int ?? 0
    let named = (summary["session_summary"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard messages > 1 || !named.isEmpty else { return nil }

    let workingDirectory = info["cwd"] as? String ?? ""
    let updated = Self.date(
      summary["last_active_at"] as? String ?? summary["updated_at"] as? String
    )

    return NativeSession(
      id: id,
      agent: .grok,
      title: named.isEmpty
        ? (typedTitle(in: directory) ?? Self.fallbackTitle(for: workingDirectory))
        : named,
      workingDirectory: workingDirectory,
      updatedAt: updated ?? .distantPast,
      sourceURL: directory
    )
  }

  func transcript(for session: NativeSession) throws -> [ConversationMessage]? {
    guard let directory = session.sourceURL else { return nil }
    let history = directory.appendingPathComponent("chat_history.jsonl")
    guard FileManager.default.fileExists(atPath: history.path) else { return nil }
    return GrokChatHistoryTranscript.read(at: history)
  }

  private func typedTitle(in directory: URL) -> String? {
    let history = directory.appendingPathComponent("chat_history.jsonl")
    var found: String?
    try? FileHead.forEachLine(of: history, maxLines: 200) { line in
      guard line.range(of: Self.userNeedle) != nil,
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["type"] as? String == "user",
            object["synthetic_reason"] == nil
      else { return true }

      var candidates: [String] = []
      if let text = object["content"] as? String {
        candidates = [text]
      } else if let parts = object["content"] as? [[String: Any]] {
        candidates = parts.compactMap { $0["text"] as? String }
      }
      for candidate in candidates {
        let spoken = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = InjectedText.inside(spoken, tag: "user_query") ?? spoken
        guard !text.isEmpty,
              !InjectedText.isScaffolding(text, tags: InjectedText.grokTags)
        else { continue }
        found = InjectedText.title(from: text)
        return false
      }
      return true
    }
    return found
  }

  static func date(_ value: String?) -> Date? {
    value.flatMap(ISO8601Stamp.date(from:))
  }

  private static func fallbackTitle(for directory: String) -> String {
    let name = (directory as NSString).lastPathComponent
    return name.isEmpty ? "Grok session" : name
  }
}
