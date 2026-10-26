import Foundation

enum CodexMapper {
  static func part(from item: JSONObject, completed: Bool) -> ConversationPart? {
    guard let id = item.string("id") else { return nil }
    switch item.string("type") {
    case "contextCompaction":
      return .activity(AgentCompaction.activity(id: id))

    case "agentMessage":
      return .text(TextPart(id: id, kind: .text, text: item.string("text") ?? ""))

    case "reasoning":
      let text = item.string("summary")
        ?? item.array("content").compactMap { $0.string("text") }.joined(separator: "\n")
      return .reasoning(TextPart(id: id, kind: .reasoning, text: text))

    case "commandExecution":
      let command = item.string("command") ?? ""
      var activity = AgentActivity(
        id: id,
        name: "shell",
        summary: command.isEmpty ? nil : command,
        state: state(item.string("status"), completed: completed),
        detail: item.string("aggregatedOutput"),
        startedAt: Date()
      )
      if let exit = item.int("exitCode"), exit != 0 { activity.state = .failed }
      if completed { activity.endedAt = Date() }
      return .activity(activity)

    case "fileChange":
      let files = (item["changes"] as? [String: Any]).map { Array($0.keys) }
        ?? item.array("changes").compactMap { $0.string("path") }
      return .activity(AgentActivity(
        id: id,
        name: "edit",
        summary: files.count == 1
          ? "Edited \((files[0] as NSString).lastPathComponent)"
          : "Edited \(files.count) files",
        state: state(item.string("status"), completed: completed),
        files: files,
        endedAt: completed ? Date() : nil
      ))

    case "mcpToolCall", "dynamicToolCall":
      return .activity(AgentActivity(
        id: id,
        name: item.string("tool") ?? "tool",
        summary: item.string("server").map { "\($0) · \(item.string("tool") ?? "")" },
        state: state(item.string("status"), completed: completed),
        detail: item.rendered("result") ?? item.rendered("error"),
        endedAt: completed ? Date() : nil
      ))

    case "webSearch":
      return .activity(AgentActivity(
        id: id,
        name: "search",
        summary: item.string("query").map { "Searched \($0)" },
        state: completed ? .completed : .running,
        endedAt: completed ? Date() : nil
      ))

    case "imageView":
      return .activity(AgentActivity(
        id: id,
        name: "image",
        summary: item.string("path").map { "Viewed \(($0 as NSString).lastPathComponent)" },
        state: .completed,
        files: [item.string("path")].compactMap { $0 }
      ))

    case "plan":
      return .text(TextPart(id: id, kind: .text, text: item.string("text") ?? ""))

    default:
      return nil
    }
  }

  private static func state(_ raw: String?, completed: Bool) -> AgentActivity.State {
    switch raw {
    case "completed", "success": return .completed
    case "failed", "error": return .failed
    case "inProgress", "running": return .running
    default: return completed ? .completed : .running
    }
  }
}
