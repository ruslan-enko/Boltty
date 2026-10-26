import Foundation

enum CodexRolloutTranscript {
  static let readLimit = 24 << 20

  static func read(at url: URL) -> [ConversationMessage] {
    var messages: [ConversationMessage] = []
    var openCalls: [String: (messageIndex: Int, activityID: String)] = [:]

    _ = try? FileTail.forEachLine(of: url, maxBytes: readLimit) { line in
      guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            record["type"] as? String == "response_item",
            let payload = record["payload"] as? [String: Any]
      else { return true }

      let stamp = (record["timestamp"] as? String).flatMap(ISO8601Stamp.date(from:)) ?? Date()

      switch payload["type"] as? String {
      case "message":
        guard let role = payload["role"] as? String, role == "user" || role == "assistant"
        else { return true }
        var text = Self.text(in: payload["content"])
        if role == "user" {
          text = InjectedText.without(text, tag: "image")
        }
        guard !text.isEmpty else { return true }
        if role == "user",
           InjectedText.isScaffolding(
             text, tags: InjectedText.codexTags, prefixes: InjectedText.codexPrefixes
           ) {
          return true
        }
        if role == "user" { text = Self.request(in: text) }
        let id = payload["id"] as? String ?? UUID().uuidString
        messages.append(
          ConversationMessage(
            id: id,
            role: role == "user" ? .user : .agent,
            createdAt: stamp,
            completedAt: stamp,
            parts: [.text(TextPart(id: "\(id)-text", kind: .text, text: text))]
          )
        )

      case "custom_tool_call", "function_call":
        guard let callID = payload["call_id"] as? String else { return true }
        let id = payload["id"] as? String ?? callID
        let name = payload["name"] as? String ?? "tool"
        let steps = name == AgentPlan.codexToolName
          ? AgentPlan.codexArguments(payload["arguments"] as? String) : []
        let activity = steps.isEmpty
          ? AgentActivity(id: id, name: name, state: .completed, startedAt: stamp, endedAt: stamp)
          : AgentPlan.activity(id: id, steps: steps, at: stamp)
        if let index = messages.indices.last, messages[index].role == .agent {
          messages[index].parts.append(.activity(activity))
          openCalls[callID] = (index, id)
        } else {
          messages.append(
            ConversationMessage(
              id: id, role: .agent, createdAt: stamp, completedAt: stamp,
              parts: [.activity(activity)]
            )
          )
          openCalls[callID] = (messages.count - 1, id)
        }

      case "custom_tool_call_output", "function_call_output":
        guard let callID = payload["call_id"] as? String,
              let open = openCalls.removeValue(forKey: callID)
        else { return true }
        let detail = Self.text(in: payload["output"])
        guard !detail.isEmpty else { return true }
        let index = open.messageIndex
        guard messages.indices.contains(index) else { return true }
        messages[index].parts = messages[index].parts.map { part in
          guard case var .activity(activity) = part, activity.id == open.activityID
          else { return part }
          activity.detail = String(detail.prefix(4000))
          activity.endedAt = stamp
          return .activity(activity)
        }

      default:
        break
      }
      return true
    }
    return AgentPlan.fold(messages)
  }

  static func contextUsage(threadID: String, codexHome: URL) -> AgentContextUsage? {
    guard let rollout = locate(threadID: threadID, in: codexHome.appendingPathComponent("sessions"))
    else { return nil }
    var latest: AgentContextUsage?
    let marker = Data(#""type":"token_count""#.utf8)
    _ = try? FileTail.forEachLine(of: rollout, maxBytes: 1 << 20) { line in
      guard line.range(of: marker) != nil,
            let record = JSONObject(line: line),
            let info = record.object("payload")?.object("info"),
            let usage = AgentContextUsage.codexRollout(info)
      else { return true }
      latest = usage
      return true
    }
    return latest
  }

  static func locate(threadID: String, in sessions: URL) -> URL? {
    let suffix = "-\(threadID).jsonl"
    guard let walker = FileManager.default.enumerator(
      at: sessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) else { return nil }
    for case let url as URL in walker where url.lastPathComponent.hasSuffix(suffix) {
      return url
    }
    return nil
  }

  static func transcript(threadID: String, codexHome: URL) throws -> DiskTranscript? {
    guard let rollout = locate(threadID: threadID, in: codexHome.appendingPathComponent("sessions"))
    else { return nil }
    guard FileManager.default.isReadableFile(atPath: rollout.path) else {
      throw NativeSessionStoreError.unreadable(path: rollout.path, reason: "permission denied")
    }
    let row = try? CodexSessionStore(root: codexHome)
      .session(for: .chat(id: threadID, at: rollout))
    return DiskTranscript(
      messages: read(at: rollout),
      directory: row?.workingDirectory,
      title: row?.title
    )
  }

  static func request(in text: String) -> String {
    let heading = "## My request for Codex:"
    guard let range = text.range(of: heading) else { return text }
    let asked = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !asked.isEmpty, !asked.hasPrefix("The next image is untrusted") else {
      guard let comment = text.range(of: "\nComment:") else { return "" }
      return String(text[comment.upperBound...])
        .split(separator: "\n")
        .prefix { !$0.hasPrefix("#") }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return asked
  }

  private static func text(in value: Any?) -> String {
    guard let parts = value as? [[String: Any]] else { return value as? String ?? "" }
    return parts
      .compactMap { $0["text"] as? String }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
