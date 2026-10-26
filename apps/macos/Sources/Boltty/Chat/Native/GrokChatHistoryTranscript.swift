import Foundation

enum GrokChatHistoryTranscript {
  static let readLimit = 24 << 20

  static func read(at url: URL) -> [ConversationMessage] {
    var messages: [ConversationMessage] = []
    var openCalls: [String: (messageIndex: Int, activityID: String)] = [:]
    var index = 0

    _ = try? FileTail.forEachLine(of: url, maxBytes: readLimit) { line in
      index += 1
      guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
      else { return true }

      switch record["type"] as? String {
      case "user":
        guard record["synthetic_reason"] == nil else { return true }
        let spoken = Self.text(in: record["content"])
        let text = InjectedText.inside(spoken, tag: "user_query") ?? spoken
        guard !text.isEmpty,
              !InjectedText.isScaffolding(text, tags: InjectedText.grokTags)
        else { return true }
        messages.append(
          Self.message(id: "grok-\(index)", role: .user, text: text)
        )

      case "assistant":
        let text = Self.text(in: record["content"])
        var message = Self.message(id: "grok-\(index)", role: .agent, text: text)
        for call in record["tool_calls"] as? [[String: Any]] ?? [] {
          guard let id = call["id"] as? String else { continue }
          message.parts.append(
            .activity(
              AgentActivity(
                id: id,
                name: call["name"] as? String ?? "tool",
                state: .completed
              )
            )
          )
          openCalls[id] = (messages.count, id)
        }
        guard !message.parts.isEmpty else { return true }
        messages.append(message)

      case "reasoning":
        let summaries = (record["summary"] as? [[String: Any]] ?? [])
          .compactMap { $0["text"] as? String }
          .joined(separator: "\n")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summaries.isEmpty else { return true }
        let id = record["id"] as? String ?? "grok-reasoning-\(index)"
        messages.append(
          ConversationMessage(
            id: id, role: .agent, createdAt: Date(), completedAt: Date(),
            parts: [.reasoning(TextPart(id: "\(id)-reasoning", kind: .reasoning, text: summaries))]
          )
        )

      case "tool_result":
        guard let callID = record["tool_call_id"] as? String,
              let open = openCalls.removeValue(forKey: callID),
              messages.indices.contains(open.messageIndex)
        else { return true }
        let detail = Self.text(in: record["content"])
        guard !detail.isEmpty else { return true }
        messages[open.messageIndex].parts = messages[open.messageIndex].parts.map { part in
          guard case var .activity(activity) = part, activity.id == open.activityID
          else { return part }
          activity.detail = String(detail.prefix(4000))
          return .activity(activity)
        }

      default:
        break
      }
      return true
    }
    return messages
  }

  static var defaultRoot: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/sessions")
  }

  static func locate(sessionID: String, in root: URL) -> URL? {
    guard let places = try? FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    ) else { return nil }
    for place in places {
      let directory = place.appendingPathComponent(sessionID)
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
         isDirectory.boolValue {
        return directory
      }
    }
    return nil
  }

  static func transcript(sessionID: String, in root: URL = defaultRoot) throws -> DiskTranscript? {
    guard let directory = locate(sessionID: sessionID, in: root) else { return nil }
    let history = directory.appendingPathComponent("chat_history.jsonl")
    let exists = FileManager.default.fileExists(atPath: history.path)
    if exists, !FileManager.default.isReadableFile(atPath: history.path) {
      throw NativeSessionStoreError.unreadable(path: history.path, reason: "permission denied")
    }
    let messages = exists ? read(at: history) : []
    let row = try? GrokSessionStore(root: root).session(for: .chat(id: sessionID, at: directory))
    return DiskTranscript(messages: messages, directory: row?.workingDirectory, title: row?.title)
  }

  private static func message(
    id: String, role: ConversationMessage.Role, text: String
  ) -> ConversationMessage {
    var message = ConversationMessage(
      id: id, role: role, createdAt: Date(), completedAt: Date()
    )
    if !text.isEmpty {
      message.parts.append(.text(TextPart(id: "\(id)-text", kind: .text, text: text)))
    }
    return message
  }

  private static func text(in value: Any?) -> String {
    if let text = value as? String {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let parts = value as? [[String: Any]] else { return "" }
    return parts
      .compactMap { $0["text"] as? String }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
