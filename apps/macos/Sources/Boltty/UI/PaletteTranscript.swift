import Foundation

enum AgentActivityGroup {
  enum Kind: CaseIterable, Equatable {
    case edit, browse, read, search, command, other

    func counted(_ count: Int) -> String {
      switch self {
      case .edit: String(localized: "Edited \(count) files")
      case .browse: String(localized: "Visited \(count) pages")
      case .read: String(localized: "Read \(count) files")
      case .search: String(localized: "Ran \(count) searches")
      case .command: String(localized: "Ran \(count) commands")
      case .other: String(localized: "Used \(count) tools")
      }
    }

    var progressive: String {
      switch self {
      case .edit: String(localized: "Editing…")
      case .browse: String(localized: "Browsing…")
      case .read: String(localized: "Reading…")
      case .search: String(localized: "Searching…")
      case .command: String(localized: "Running a command…")
      case .other: String(localized: "Using a tool…")
      }
    }

    func progressive(on name: String) -> String {
      switch self {
      case .edit: String(localized: "Editing \(name)")
      case .browse: String(localized: "Browsing \(name)")
      case .read: String(localized: "Reading \(name)")
      case .search: String(localized: "Searching \(name)")
      case .command: String(localized: "Running a command \(name)")
      case .other: String(localized: "Using a tool \(name)")
      }
    }
  }

  static let thoughtName = "boltty.thought"

  static func thought(id: String) -> AgentActivity {
    AgentActivity(id: id, name: thoughtName, summary: String(localized: "Thought"), state: .completed)
  }

  static func isGroupable(_ activity: AgentActivity) -> Bool {
    activity.plan == nil && activity.name != AgentCompaction.toolName
  }

  static func kind(of activity: AgentActivity) -> Kind {
    let named = kind(ofName: activity.name)
    if named != .other { return named }
    return activity.summary.map(kind(ofName:)) ?? .other
  }

  private static func kind(ofName raw: String) -> Kind {
    let name = raw.lowercased()
    func has(_ words: [String]) -> Bool { words.contains { name.contains($0) } }
    if has(["todo", "task"]) { return .other }
    if has(["web", "browser", "fetch", "navigate", "playwright", "chrome", "url"]) { return .browse }
    if has(["edit", "write", "patch", "delete", "move", "notebook", "replace", "create"]) { return .edit }
    if has(["grep", "glob", "search", "find"]) { return .search }
    if has(["read", "view", "image", "list", "open", "cat"]) { return .read }
    if has(["bash", "shell", "exec", "command", "terminal", "run"]) { return .command }
    return .other
  }

  static func summary(of activities: [AgentActivity]) -> String {
    var phrases: [String] = activities.contains(where: \.isThought) ? [String(localized: "Thought")] : []
    var stretch: [AgentActivity] = []
    func close() {
      defer { stretch = [] }
      guard let first = stretch.first else { return }
      phrases.append(stretch.count == 1 ? sentence(for: first) : kind(of: first).counted(stretch.count))
    }
    for activity in activities where !activity.isThought {
      if let first = stretch.first, kind(of: first) != kind(of: activity) { close() }
      stretch.append(activity)
    }
    close()
    return phrases.joined(separator: " • ")
  }

  static func sentence(for activity: AgentActivity) -> String {
    let kind = kind(of: activity)
    if activity.saysOnlyItsName, kind != .other { return kind.counted(1) }
    let headline = activity.headline
    guard let first = headline.first, first.isLowercase else { return headline }
    guard kind == .command else { return first.uppercased() + headline.dropFirst() }
    return headline.contains(where: { $0 == " " || $0 == "/" }) ? String(localized: "Ran \(headline)") : headline
  }

  static func progress(for activity: AgentActivity) -> String {
    let kind = kind(of: activity)
    if kind == .command {
      let line = activity.headline.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
      if let first = line.first, first.isUppercase { return line }
      if line.contains(where: { $0 == " " || $0 == "/" }) { return String(localized: "Running \(line)") }
    }
    if let file = activity.files.first {
      return kind.progressive(on: (file as NSString).lastPathComponent)
    }
    return kind.progressive
  }

  static func id(of activities: [AgentActivity]) -> String {
    "group:" + ((activities.first { !$0.isThought } ?? activities.first)?.id ?? "")
  }
}

extension AgentActivity {
  var isThought: Bool { name == AgentActivityGroup.thoughtName }

  var saysOnlyItsName: Bool { (summary ?? "").isEmpty && files.isEmpty }
}

struct PaletteTurnHeader: Equatable {
  let id: String
  let startedAt: Date
  let endedAt: Date?
  let isRunning: Bool
  let isCollapsed: Bool

  func text(now: Date = Date()) -> String {
    let seconds = max(1, Int(((endedAt ?? now).timeIntervalSince(startedAt)).rounded()))
    let duration = Self.duration(seconds)
    return isRunning ? String(localized: "Working for \(duration)") : String(localized: "Worked for \(duration)")
  }

  static func duration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = seconds % 3600 / 60
    let rest = seconds % 60
    if hours > 0 { return String(localized: "\(hours)h \(minutes)m") }
    if minutes > 0 { return String(localized: "\(minutes)m \(rest)s") }
    return String(localized: "\(rest)s")
  }
}

enum PaletteTranscriptItem: Equatable {
  case message(ConversationMessage, folded: Bool)
  case turnHeader(PaletteTurnHeader)
}

enum PaletteTranscript {
  static func items(
    for messages: [ConversationMessage],
    isBusy: Bool,
    expandedTurns: Set<String>
  ) -> [PaletteTranscriptItem] {
    var items: [PaletteTranscriptItem] = []
    var request: ConversationMessage?
    var work: [ConversationMessage] = []

    func flush(isLast: Bool) {
      defer { work = [] }
      let ended = work.compactMap { $0.completedAt ?? $0.createdAt }.max()
      work = joined(work)
      guard let request else {
        items += work.map { .message($0, folded: false) }
        return
      }
      let running = isLast && isBusy
      if running {
        items += work.map { .message($0, folded: false) }
        return
      }
      let answer = work.last { segments(of: $0).contains(where: \.isText) }
      let pieces = work.reduce(0) { $0 + segments(of: $1).count }
      let hasWork = pieces > (answer == nil ? 0 : 1)
      guard hasWork else {
        items += work.map { .message($0, folded: false) }
        return
      }
      let collapsed = !expandedTurns.contains(request.id)
      items.append(.turnHeader(PaletteTurnHeader(
        id: request.id,
        startedAt: request.createdAt,
        endedAt: ended ?? request.createdAt,
        isRunning: false,
        isCollapsed: collapsed
      )))
      if collapsed {
        if let answer { items.append(.message(answer, folded: true)) }
      } else {
        items += work.map { .message($0, folded: false) }
      }
    }

    for message in messages {
      if message.role == .user {
        flush(isLast: false)
        items.append(.message(message, folded: false))
        request = message
      } else {
        work.append(message)
      }
    }
    flush(isLast: true)
    return items
  }

  private static func segments(of message: ConversationMessage) -> [PaletteSegment] {
    message.paletteSegments
  }

  static func joined(_ messages: [ConversationMessage]) -> [ConversationMessage] {
    var joined: [ConversationMessage] = []
    var carried: ConversationMessage?
    for message in messages {
      var next = message
      if var stretch = carried, stretch.role == message.role {
        stretch.parts += message.parts
        stretch.completedAt = message.completedAt
        stretch.failure = message.failure
        next = stretch
      } else if let stretch = carried {
        joined.append(stretch)
      }
      carried = nil
      if next.role == .agent, !hasWords(next) { carried = next } else { joined.append(next) }
    }
    if let carried { joined.append(carried) }
    return joined
  }

  static func rowID(of id: String, in messages: [ConversationMessage]) -> String {
    var start: String?
    for message in messages {
      guard message.role == .agent else {
        start = nil
        if message.id == id { return id }
        continue
      }
      let row = start ?? message.id
      if message.id == id { return row }
      start = hasWords(message) ? nil : row
    }
    return id
  }

  private static func hasWords(_ message: ConversationMessage) -> Bool {
    message.paletteSegments.contains(where: \.isText)
  }
}

extension PaletteSegment {
  var isText: Bool {
    if case .text = self { return true }
    return false
  }
}
