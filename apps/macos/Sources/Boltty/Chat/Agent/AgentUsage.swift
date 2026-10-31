import Foundation

struct AgentUsage: Equatable, Sendable {
  var windows: [AgentUsageWindow]

  var pressing: AgentUsageWindow? {
    windows.max { lhs, rhs in
      lhs.usedPercent == rhs.usedPercent
        ? lhs.kind.order < rhs.kind.order
        : lhs.usedPercent < rhs.usedPercent
    }
  }
}

struct AgentUsageWindow: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case session
    case weekly
    case other(minutes: Int)

    init(minutes: Int) {
      switch minutes {
      case 300: self = .session
      case 10_080: self = .weekly
      default: self = .other(minutes: minutes)
      }
    }

    var order: Int {
      switch self {
      case .session: 0
      case let .other(minutes): minutes < 10_080 ? 1 : 3
      case .weekly: 2
      }
    }

    var title: String {
      switch self {
      case .session: "5-hour"
      case .weekly: "Weekly"
      case let .other(minutes):
        minutes % 1_440 == 0 ? "\(minutes / 1_440)-day" : "\(max(minutes / 60, 1))-hour"
      }
    }
  }

  enum Severity: Equatable, Sendable {
    case normal, high, exhausted
  }

  var kind: Kind
  var usedPercent: Int
  var resetsAt: Date?
  /// What the window is for, where an agent has several of one length —
  /// Antigravity keeps a weekly limit per group of models.
  var label: String?

  var title: String { label.map { "\($0) · \(kind.title)" } ?? kind.title }

  var severity: Severity {
    if usedPercent >= 100 { return .exhausted }
    if usedPercent >= Self.highThreshold { return .high }
    return .normal
  }

  static let highThreshold = 80
}

extension AgentUsage {
  static func claudeCode(_ response: JSONObject) -> AgentUsage? {
    guard response.bool("rate_limits_available") != false,
          let limits = response.object("rate_limits")
    else { return nil }
    let windows: [AgentUsageWindow] = [
      ("five_hour", AgentUsageWindow.Kind.session),
      ("seven_day", .weekly),
    ].compactMap { key, kind in
      guard let window = limits.object(key),
            let used = window.double("utilization")
      else { return nil }
      return AgentUsageWindow(
        kind: kind,
        usedPercent: Int(used.rounded()),
        resetsAt: window.string("resets_at").flatMap(ISO8601Stamp.date(from:))
      )
    }
    return windows.isEmpty ? nil : AgentUsage(windows: windows)
  }

  static func codex(_ result: JSONObject) -> AgentUsage? {
    guard let limits = result.object("rateLimits") ?? (result.object("primary") != nil ? result : nil)
    else { return nil }
    let windows: [AgentUsageWindow] = ["primary", "secondary"].compactMap { key in
      guard let window = limits.object(key),
            let used = window.double("usedPercent")
      else { return nil }
      return AgentUsageWindow(
        kind: .init(minutes: window.int("windowDurationMins") ?? 0),
        usedPercent: Int(used.rounded()),
        resetsAt: window.double("resetsAt").map { Date(timeIntervalSince1970: $0) }
      )
    }
    return windows.isEmpty ? nil : AgentUsage(windows: windows)
  }

  /// `agy -p=/usage --output-format json` (1.3.4): a
  /// `result` whose `command.data.groups` each hold `buckets` with a
  /// `window` (`weekly`), a `remaining_fraction` and a `reset_time`.
  static func antigravity(_ result: JSONObject) -> AgentUsage? {
    let groups = result.object("command")?.object("data")?.array("groups") ?? []
    let windows: [AgentUsageWindow] = groups.flatMap { group in
      group.array("buckets").compactMap { bucket -> AgentUsageWindow? in
        guard let remaining = bucket.double("remaining_fraction") else { return nil }
        let minutes: Int? = switch bucket.string("window") {
        case "weekly": 10_080
        case "daily": 1_440
        default: nil
        }
        guard let minutes else { return nil }
        return AgentUsageWindow(
          kind: .init(minutes: minutes),
          usedPercent: Int(((1 - remaining) * 100).rounded()),
          resetsAt: bucket.string("reset_time").flatMap(ISO8601Stamp.date(from:)),
          label: Self.shortGroupName(group.string("name"))
        )
      }
    }
    return windows.isEmpty ? nil : AgentUsage(windows: windows)
  }

  /// "Gemini Models" → "Gemini"; "Claude and GPT models" → "Claude and GPT".
  private static func shortGroupName(_ name: String?) -> String? {
    guard var name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
    if name.lowercased().hasSuffix(" models") { name = String(name.dropLast(7)) }
    return name
  }

  static func grok(_ result: JSONObject) -> AgentUsage? {
    guard let config = result.object("config"),
          let period = config.object("currentPeriod"),
          let start = period.string("start").flatMap(ISO8601Stamp.date(from:)),
          let end = period.string("end").flatMap(ISO8601Stamp.date(from:)),
          end > start
    else { return nil }
    let used = config.double("creditUsagePercent") ?? 0
    return AgentUsage(windows: [
      AgentUsageWindow(
        kind: .init(minutes: Int((end.timeIntervalSince(start) / 60).rounded())),
        usedPercent: Int(used.rounded()),
        resetsAt: end)
    ])
  }
}

extension AgentUsageWindow {
  /// DateFormatter, not Date.FormatStyle: the latter returns "" on regional-override locales.
  /// "18d 7h", "3h 12m", "42m": how long until a window comes back.
  static func countdown(to date: Date, now: Date = Date()) -> String {
    let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
    let days = minutes / 1_440, hours = minutes % 1_440 / 60, rest = minutes % 60
    if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
    if hours > 0 { return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h" }
    return "\(rest)m"
  }

  static func resetPhrase(_ date: Date, now: Date = Date()) -> String {
    let formatter = DateFormatter()
    if Calendar.current.isDate(date, inSameDayAs: now) {
      formatter.setLocalizedDateFormatFromTemplate("jmm")
    } else if date.timeIntervalSince(now) < 6 * 86_400 {
      formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
    } else {
      formatter.setLocalizedDateFormatFromTemplate("d MMM")
    }
    return formatter.string(from: date)
  }
}

struct AgentContextUsage: Equatable, Sendable {
  var usedTokens: Int
  var limitTokens: Int

  var percent: Int {
    guard limitTokens > 0 else { return 0 }
    return min(100, Int((Double(usedTokens) / Double(limitTokens) * 100).rounded()))
  }

  static let compactOfferThreshold = 70

  static let coldCacheOfferThreshold = 40
  static let promptCacheLifetime: TimeInterval = 3600

  static func offersCompact(percent: Int, cacheIsCold: Bool) -> Bool {
    percent >= (cacheIsCold ? coldCacheOfferThreshold : compactOfferThreshold)
  }

  static func claudeCode(_ response: JSONObject) -> AgentContextUsage? {
    guard let used = response.int("totalTokens"), let limit = response.int("maxTokens"),
          limit > 0
    else { return nil }
    return AgentContextUsage(usedTokens: used, limitTokens: limit)
  }

  static func codex(_ tokenUsage: JSONObject) -> AgentContextUsage? {
    guard let used = tokenUsage.object("last")?.int("totalTokens"),
          let limit = tokenUsage.int("modelContextWindow"), limit > 0
    else { return nil }
    return AgentContextUsage(usedTokens: used, limitTokens: limit)
  }

  static func codexRollout(_ info: JSONObject) -> AgentContextUsage? {
    guard let used = info.object("last_token_usage")?.int("total_tokens"),
          let limit = info.int("model_context_window"), limit > 0
    else { return nil }
    return AgentContextUsage(usedTokens: used, limitTokens: limit)
  }
}

struct RateLimitHit: Codable, Equatable, Sendable {
  var resetsAt: Date?

  static func isCodexLimit(_ errorInfo: Any?) -> Bool {
    guard let code = errorInfo as? String else { return false }
    return code == "usageLimitExceeded" || code == "rateLimitExceeded"
  }

  static func claudeCode(_ info: JSONObject) -> RateLimitHit? {
    guard info.string("status") == "rejected" else { return nil }
    return RateLimitHit(resetsAt: info.double("resetsAt").map { Date(timeIntervalSince1970: $0) })
  }
}

enum AgentCompaction {
  static let toolName = "compact"

  static func activity(id: String, before: Int? = nil, after: Int? = nil) -> AgentActivity {
    var summary = "Compacted the conversation"
    if let before, let after, before > after {
      summary += " · \(tokens(before)) → \(tokens(after)) tokens"
    }
    return AgentActivity(
      id: id, name: toolName, summary: summary, state: .completed,
      startedAt: Date(), endedAt: Date())
  }

  static func tokens(_ count: Int) -> String {
    count < 1_000 ? "\(count)" : String(format: "%.1fk", Double(count) / 1_000)
  }
}

struct AgentActivityHistory: Equatable, Sendable {
  enum Unit: Equatable, Sendable {
    case tokens, steps

    var title: String {
      switch self {
      case .tokens: "tokens"
      case .steps: "steps"
      }
    }
  }

  struct Day: Equatable, Sendable, Identifiable {
    var date: Date
    var value: Double
    var id: Date { date }
  }

  var unit: Unit
  var days: [Day]
  var streakDays: Int?
  var summary: String?

  static let window = 14

  static func lastDays(
    _ values: [String: Double], today: Date = Date(), calendar: Calendar = .current
  ) -> [Day] {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let start = calendar.startOfDay(for: today)
    return (0..<window).reversed().compactMap { back in
      guard let day = calendar.date(byAdding: .day, value: -back, to: start) else { return nil }
      return Day(date: day, value: values[formatter.string(from: day)] ?? 0)
    }
  }

  static func codex(_ result: JSONObject, today: Date = Date()) -> AgentActivityHistory? {
    let buckets = result.array("dailyUsageBuckets")
    guard !buckets.isEmpty || result.object("summary") != nil else { return nil }
    var values: [String: Double] = [:]
    for bucket in buckets {
      guard let date = bucket.string("startDate"), let tokens = bucket.double("tokens") else { continue }
      values[String(date.prefix(10)), default: 0] += tokens
    }
    let summary = result.object("summary")
    return AgentActivityHistory(
      unit: .tokens,
      days: lastDays(values, today: today),
      streakDays: summary?.int("currentStreakDays"),
      summary: summary?.double("lifetimeTokens").map {
        "\(AgentActivityHistory.compact($0)) tokens all time"
      })
  }

  static func openCode(_ data: JSONObject, today: Date = Date()) -> AgentActivityHistory? {
    let activity = data.array("activity")
    guard !activity.isEmpty || data.int("sessions") != nil else { return nil }
    var values: [String: Double] = [:]
    for day in activity {
      guard let date = day.string("date"), let steps = day.double("steps") else { continue }
      values[String(date.prefix(10)), default: 0] += steps
    }
    let sessions = data.int("sessions")
    let prompts = data.int("prompts")
    return AgentActivityHistory(
      unit: .steps,
      days: lastDays(values, today: today),
      streakDays: data.int("streak"),
      summary: sessions.map { sessions in
        "\(sessions) sessions" + (prompts.map { ", \($0) prompts" } ?? "")
      })
  }

  static func compact(_ value: Double) -> String {
    switch value {
    case 1e9...: String(format: "%.1fB", value / 1e9)
    case 1e6...: String(format: "%.1fM", value / 1e6)
    case 1e3...: String(format: "%.1fk", value / 1e3)
    default: String(Int(value))
    }
  }
}
