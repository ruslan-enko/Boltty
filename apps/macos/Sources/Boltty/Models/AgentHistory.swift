import Foundation

enum AgentHistory {
  static let tabOrder: [AgentId] = [.claude, .codex, .opencode, .grok, .antigravity]

  /// The agents Boltty shows: the ones switched on that are on this Mac. `installed`
  /// is nil until the first scan has said. With none to show, every one: there is
  /// nothing to narrow to, and the way to one is on the list.
  static func listed(enabled: Set<String>, installed: Set<String>?) -> [AgentId] {
    let shown = tabOrder.filter {
      enabled.contains($0.rawValue) && (installed?.contains($0.rawValue) ?? true)
    }
    return shown.isEmpty ? tabOrder : shown
  }

  /// One agent has no need of All: it would be the same list twice.
  static func stops(for agents: [AgentId]) -> [AgentId?] {
    agents.count == 1 ? [agents[0]] : [nil] + agents.map { Optional($0) }
  }

  static func adjacentTab(to current: AgentId?, by delta: Int, among agents: [AgentId] = tabOrder) -> AgentId? {
    let stops = stops(for: agents)
    let index = stops.firstIndex(of: current) ?? 0
    return stops[min(max(index + delta, 0), stops.count - 1)]
  }

  struct Tab: Equatable, Identifiable, Sendable {
    let agent: AgentId
    let count: Int
    var id: AgentId { agent }
    var title: String { agent.shortDisplayName }
    var isEmpty: Bool { count == 0 }
  }

  struct Section: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let items: [BolttyAISessionItem]
  }

  static func tabs(_ items: [BolttyAISessionItem], agents: [AgentId] = tabOrder) -> [Tab] {
    var counts: [AgentId: Int] = [:]
    for item in items { counts[item.agent, default: 0] += 1 }
    return agents.map { Tab(agent: $0, count: counts[$0] ?? 0) }
  }

  static func sections(
    _ items: [BolttyAISessionItem],
    agent: AgentId? = nil,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> [Section] {
    let kept = agent.map { wanted in items.filter { $0.agent == wanted } } ?? items

    var sections: [Section] = []
    var indexByDay: [String: Int] = [:]
    for item in kept {
      let day = calendar.startOfDay(for: item.updatedAt)
      let id = dayID(day, calendar: calendar)
      if let index = indexByDay[id] {
        let existing = sections[index]
        sections[index] = Section(
          id: id, title: existing.title, items: existing.items + [item]
        )
      } else {
        indexByDay[id] = sections.count
        sections.append(
          Section(id: id, title: title(for: day, now: now, calendar: calendar), items: [item])
        )
      }
    }
    return sections
  }

  static func dayID(_ day: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: day)
    return String(
      format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
    )
  }

  static func title(for day: Date, now: Date, calendar: Calendar = .current) -> String {
    let today = calendar.startOfDay(for: now)
    let start = calendar.startOfDay(for: day)
    let distance = calendar.dateComponents([.day], from: start, to: today).day ?? 0

    if distance == 0 { return "Today" }
    if distance == 1 { return "Yesterday" }

    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    if distance > 1 && distance < 7 {
      formatter.setLocalizedDateFormatFromTemplate("EEEE")
      return formatter.string(from: start)
    }
    let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: today)
    formatter.setLocalizedDateFormatFromTemplate(sameYear ? "d MMMM" : "d MMMM y")
    return formatter.string(from: start)
  }
}
