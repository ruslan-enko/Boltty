import Foundation

enum CodexRolloutTranscript {
  static let readLimit = 24 << 20

  /// The skill's record follows the words it was sent with: `/name` goes back
  /// in front of them, or stands alone when the request was the skill alone.
  static func prependSkill(
    _ name: String, to messages: inout [ConversationMessage], at stamp: Date, id: String?
  ) {
    let command = "/" + name
    if let index = messages.indices.last, messages[index].role == .user,
       let part = messages[index].parts.firstIndex(where: {
         if case .text = $0 { return true }
         return false
       }),
       case var .text(words) = messages[index].parts[part] {
      guard !words.text.hasPrefix(command) else { return }
      words.text = command + " " + words.text
      messages[index].parts[part] = .text(words)
      return
    }
    let messageID = id ?? UUID().uuidString
    messages.append(ConversationMessage(
      id: messageID, role: .user, createdAt: stamp, completedAt: stamp,
      parts: [.text(TextPart(id: "\(messageID)-text", kind: .text, text: command))]))
  }

  static func read(at url: URL) -> [ConversationMessage] {
    var messages: [ConversationMessage] = []
    var openCalls: [String: (messageIndex: Int, activityID: String)] = [:]

    let consume: (Data) -> Bool = { line in
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
        if role == "user", let skill = InjectedText.codexSkill(in: text) {
          Self.prependSkill(skill, to: &messages, at: stamp, id: payload["id"] as? String)
          return true
        }
        if role == "user",
           InjectedText.isScaffolding(
             text, tags: InjectedText.codexTags, prefixes: InjectedText.codexPrefixes
           ) {
          return true
        }
        if role == "user" { text = Self.request(in: text) }
        if role == "assistant", let plan = InjectedText.inside(text, tag: "proposed_plan") {
          text = plan
        }
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
    for prefix in forkPrefixes(of: url) {
      try? FileHead.forEachLine(of: prefix.url, maxLines: prefix.lines, maxBytes: readLimit, consume)
    }
    _ = try? FileTail.forEachLine(of: url, maxBytes: readLimit, consume)
    return AgentPlan.fold(messages)
  }

  /// The turn that holds `messageID`: a turn's own id (what a live chat names
  /// its answers by) or a message's id in the rollout (what a re-read one does).
  static func turnID(threadID: String, codexHome: URL, holding messageID: String) -> String? {
    guard let url = locate(threadID: threadID, in: codexHome.appendingPathComponent("sessions")) else {
      return nil
    }
    var turn: String?
    var found: String?
    let consume: (Data) -> Bool = { line in
      guard let record = JSONObject(line: line), let payload = record.object("payload") else { return true }
      if let id = payload.string("turn_id") {
        turn = id
        if messageID == id || messageID.hasPrefix(id + "-") { found = id }
      } else if record.string("type") == "response_item", payload.string("id") == messageID {
        found = turn
      }
      return found == nil
    }
    for prefix in forkPrefixes(of: url) {
      try? FileHead.forEachLine(of: prefix.url, maxLines: prefix.lines, maxBytes: readLimit, consume)
      if found != nil { return found }
    }
    _ = try? FileTail.forEachLine(of: url, maxBytes: readLimit, consume)
    return found
  }

  /// A forked thread's rollout holds only what came after the fork; its
  /// `session_meta` names the thread it came from and how many of that
  /// rollout's lines it carries (`forked_from_id`, `forked_from_ordinal_exclusive`,
  /// 0.169). Oldest first, a fork of a fork included.
  static func forkPrefixes(of url: URL) -> [(url: URL, lines: Int)] {
    let sessions = url.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    var chain: [(url: URL, lines: Int)] = []
    var current = url
    for _ in 0..<8 {
      var origin: (id: String, lines: Int)?
      try? FileHead.forEachLine(of: current, maxLines: 1) { line in
        let meta = JSONObject(line: line)?.object("payload")
        if let id = meta?.string("forked_from_id"), let lines = meta?.int("forked_from_ordinal_exclusive") {
          origin = (id, lines)
        }
        return false
      }
      guard let origin, let parent = locate(threadID: origin.id, in: sessions) else { break }
      chain.insert((parent, origin.lines), at: 0)
      current = parent
    }
    return chain
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
