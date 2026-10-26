import Foundation

struct AgentStatistics: Codable, Equatable, Sendable {
  var sessions: [Session]

  struct Session: Codable, Equatable, Sendable {
    var agent: String
    var id: String
    var samples: [Sample]
  }

  struct Sample: Codable, Equatable, Sendable {
    var hour: Int
    var model: String
    var tokens: Int
    var messages: Int
  }

  static let empty = AgentStatistics(sessions: [])
}

enum AgentStatisticsRange: String, CaseIterable, Identifiable, Sendable {
  case all, month, week
  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "All"
    case .month: "30d"
    case .week: "7d"
    }
  }

  var days: Int? {
    switch self {
    case .all: nil
    case .month: 30
    case .week: 7
    }
  }

  func start(now: Date, calendar: Calendar) -> Date? {
    guard let days else { return nil }
    let today = calendar.startOfDay(for: now)
    return calendar.date(byAdding: .day, value: -(days - 1), to: today)
  }
}

struct AgentStatisticsSummary: Equatable, Sendable {
  var sessions = 0
  var messages = 0
  var tokens = 0
  var activeDays = 0
  var peakHour: Int?
  var favoriteModel: String?
  var days: [Date: Day] = [:]
  var models: [Model] = []

  struct Day: Equatable, Sendable {
    var messages = 0
    var tokens = 0
  }

  struct Model: Equatable, Identifiable, Sendable {
    var id: String
    var agent: AgentId?
    var tokens = 0
    var messages = 0
    var sessions = 0
  }

  var isEmpty: Bool { messages == 0 && tokens == 0 }

  init() {}

  init(
    _ statistics: AgentStatistics,
    range: AgentStatisticsRange,
    agent: AgentId? = nil,
    now: Date = Date(),
    calendar: Calendar = .current
  ) {
    let firstHour = range.start(now: now, calendar: calendar)
      .map { Int(($0.timeIntervalSince1970 / 3600).rounded(.down)) } ?? .min
    var hours = [Int](repeating: 0, count: 24)
    var models: [String: Model] = [:]
    var dayCache: [Int: Date] = [:]

    for session in statistics.sessions {
      guard agent == nil || session.agent == agent?.rawValue else { continue }
      var counted = false
      var modelsHere: Set<String> = []
      for sample in session.samples where sample.hour >= firstHour {
        guard sample.messages > 0 || sample.tokens > 0 else { continue }
        counted = true
        messages += sample.messages
        tokens += sample.tokens

        let day: Date
        if let cached = dayCache[sample.hour] {
          day = cached
        } else {
          day = calendar.startOfDay(for: Self.date(ofHour: sample.hour))
          dayCache[sample.hour] = day
        }
        days[day, default: Day()].messages += sample.messages
        days[day, default: Day()].tokens += sample.tokens

        let hourOfDay = calendar.component(.hour, from: Self.date(ofHour: sample.hour))
        hours[hourOfDay] += sample.messages

        let name = AgentStatisticsSummary.displayName(ofModel: sample.model)
        guard !name.isEmpty else { continue }
        var model = models[name] ?? Model(id: name, agent: AgentId(rawValue: session.agent))
        model.tokens += sample.tokens
        model.messages += sample.messages
        if modelsHere.insert(name).inserted { model.sessions += 1 }
        models[name] = model
      }
      if counted { sessions += 1 }
    }

    activeDays = days.count
    if let most = hours.max(), most > 0 { peakHour = hours.firstIndex(of: most) }
    self.models = models.values.sorted {
      ($0.tokens, $0.messages, $1.id) > ($1.tokens, $1.messages, $0.id)
    }
    favoriteModel = self.models.first?.id
  }

  static func date(ofHour hour: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(hour) * 3600)
  }

  static func displayName(ofModel id: String) -> String {
    let trimmed = id.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != "<synthetic>" else { return "" }
    guard trimmed.hasPrefix("claude-") else { return trimmed }
    var parts = trimmed.dropFirst("claude-".count).split(separator: "-").map(String.init)
    if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
    parts = parts.map { $0.replacingOccurrences(of: #"\[.*\]"#, with: "", options: .regularExpression) }
    let words = parts.prefix { !$0.allSatisfy(\.isNumber) }
    let numbers = parts.dropFirst(words.count).filter { $0.allSatisfy(\.isNumber) }
    guard !words.isEmpty else { return trimmed }
    let family = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    return numbers.isEmpty ? family : "\(family) \(numbers.joined(separator: "."))"
  }

  static func bookComparison(tokens: Int) -> String? {
    guard tokens > 0 else { return nil }
    let books: [(title: String, tokens: Double)] = [
      ("Animal Farm", 39_000),
      ("The Great Gatsby", 61_000),
      ("Nineteen Eighty-Four", 116_000),
      ("Moby-Dick", 273_000),
      ("War and Peace", 763_000),
      ("every Harry Potter book", 1_409_000),
    ]
    let count = Double(tokens)
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    if let book = books.last(where: { count >= $0.tokens * 2 }) {
      let times = formatter.string(from: NSNumber(value: (count / book.tokens).rounded())) ?? ""
      return "You’ve used ~\(times)× more tokens than \(book.title)."
    }
    let shortest = books[0]
    let share = max(1, Int((count / shortest.tokens * 100).rounded()))
    return "You’ve used ~\(share)% of the tokens in \(shortest.title)."
  }
}

extension AgentStatistics {
  struct Accumulator {
    private var buckets: [Key: (tokens: Int, messages: Int)] = [:]
    private struct Key: Hashable {
      var hour: Int
      var model: String
    }

    mutating func add(at date: Date, model: String, tokens: Int = 0, messages: Int = 0) {
      guard tokens > 0 || messages > 0 else { return }
      let key = Key(hour: Int((date.timeIntervalSince1970 / 3600).rounded(.down)), model: model)
      var bucket = buckets[key] ?? (0, 0)
      bucket.tokens += max(tokens, 0)
      bucket.messages += max(messages, 0)
      buckets[key] = bucket
    }

    var isEmpty: Bool { buckets.isEmpty }

    var samples: [Sample] {
      buckets
        .map { Sample(hour: $0.key.hour, model: $0.key.model, tokens: $0.value.tokens, messages: $0.value.messages) }
        .sorted { ($0.hour, $0.model) < ($1.hour, $1.model) }
    }
  }
}
