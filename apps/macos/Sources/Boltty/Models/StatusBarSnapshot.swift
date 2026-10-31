import Foundation

enum StatusBarIconState: Equatable, Sendable {
  case idle
  case attention
}

struct AgentStatusRow: Equatable, Identifiable, Sendable {
  let id: UUID
  let agent: AgentId
  let prompt: String
}

struct StatusBarSnapshot: Equatable, Sendable {
  let iconState: StatusBarIconState
  let agentRows: [AgentStatusRow]
  let latestUnreadSessionID: UUID?
  let latestUnreadTitle: String?
  let accessibilityLabel: String

  static let idle = StatusBarSnapshot(
    iconState: .idle,
    agentRows: [],
    latestUnreadSessionID: nil,
    latestUnreadTitle: nil,
    accessibilityLabel: "Boltty"
  )
}

// MARK: - Boltty AI session switcher

struct BolttyAISessionItem: Equatable, Identifiable, Sendable {
  let id: UUID
  let title: String
  let subtitle: String
  let agent: AgentId
  let isCurrent: Bool
  var updatedAt: Date
  var state: AgentReportedState? = nil
  /// A reply arrived while this chat was not open (`Conversation.hasUnread`,
  /// cleared when the chat is opened).
  var hasUnread: Bool = false
}

enum BolttyAISessionList {
  static func items(
    conversations: [Conversation],
    transcripts: [UUID: ConversationTranscript] = [:],
    damagedIDs: Set<UUID> = [],
    selectedID: UUID?,
    query: String = ""
  ) -> [BolttyAISessionItem] {
    // Ask Boltty keeps no history: its chats are never rows.
    let rows = conversations.filter { !$0.isAskBoltty }.map { conversation in
      let agent = AgentId(rawValue: conversation.providerID) ?? .custom
      let transcript = transcripts[conversation.id] ?? ConversationTranscript()
      return BolttyAISessionItem(
        id: conversation.id,
        title: ChatTitle.forRow(conversation, transcript: transcript),
        subtitle: subtitle(
          for: conversation,
          transcript: transcript,
          damaged: damagedIDs.contains(conversation.id),
          previewLimit: rowPreviewLimit
        ),
        agent: agent,
        isCurrent: conversation.id == selectedID,
        updatedAt: conversation.updatedAt,
        state: conversation.lastKnownState.reportedState,
        hasUnread: conversation.hasUnread
      )
    }
    return filter(rows, transcripts: transcripts, query: query)
  }

  static func subtitle(
    for conversation: Conversation,
    transcript: ConversationTranscript,
    damaged: Bool,
    previewLimit: Int = .max
  ) -> String {
    if damaged {
      return "History could not be read"
    }
    switch conversation.lastKnownState {
    case .working: return liveStep(in: transcript) ?? "Working…"
    case .waiting: return "Waiting for you"
    case .failed: return "Stopped with an error"
    case .interrupted: return "Interrupted when Boltty quit"
    case .rateLimited: return "Rate limited"
    case .idle: break
    }
    guard let message = transcript.messages.last(where: { !$0.plainText.isEmpty }) else {
      return conversation.draft.isEmpty ? "No messages yet" : conversation.draft
    }
    return plainPreview(message.plainText, limit: previewLimit)
  }

  /// What a working chat is doing now, for its row: the step running
  /// (`AgentActivityGroup.progress`), "Thinking…" while it reasons, or `nil`
  /// between steps, when the row says "Working…". Read off the turn's own
  /// reply only: a step the last turn finished is not what it is doing.
  static func liveStep(in transcript: ConversationTranscript) -> String? {
    guard let reply = transcript.messages.last, reply.role == .agent,
          reply.completedAt == nil, let part = reply.parts.last
    else { return nil }
    switch part {
    case .reasoning:
      return "Thinking…"
    case let .activity(activity) where activity.state == .running || activity.state == .pending:
      return AgentActivityGroup.progress(for: activity)
    default:
      return nil
    }
  }

  static let rowPreviewLimit = 400

  static func plainPreview(_ markdown: String, limit: Int = .max) -> String {
    var lines: [String] = []
    var length = 0
    var rest = markdown[...]
    while !rest.isEmpty, length <= limit {
      let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
      let raw = rest[..<end]
      rest = end == rest.endIndex ? rest[end...] : rest[rest.index(after: end)...]
      guard !raw.isEmpty else { continue }
      var line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
      // A rule and a table's dashes are drawing, not words; a table's row
      // is its cells.
      if PreviewMarkup.rule.hasMatch(in: line) { continue }
      if line.hasPrefix("|") {
        line = line.split(separator: "|")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
          .joined(separator: " · ")
      }
      line = PreviewMarkup.leadingMarker.replacing(in: line, with: "")
      line = PreviewMarkup.link.replacing(in: line, with: "$1")
      line = line.replacingOccurrences(of: "**", with: "")
      line = line.replacingOccurrences(of: "`", with: "")
      line = PreviewMarkup.emphasis.replacing(in: line, with: "$1")
      if !line.isEmpty {
        lines.append(line)
        length += line.count + 1
      }
    }
    return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private enum PreviewMarkup {
    static let leadingMarker = compile(#"^(#{1,6}\s+|>\s?|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)"#)
    static let link = compile(#"!?\[([^\]]*)\]\([^)]*\)"#)
    static let emphasis = compile(#"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#)
    /// `---`, `***`, `___`, and a table's `|---|:--:|` under its head.
    static let rule = compile(
      #"^\|?(?:\s*:?-{3,}:?\s*\|)*\s*:?-{3,}:?\s*\|?$|^(?:[*_]\s*){3,}$"#
    )

    private static func compile(_ pattern: String) -> NSRegularExpression {
      try! NSRegularExpression(pattern: pattern)
    }
  }

  static func holding(_ items: [BolttyAISessionItem], to held: [BolttyAISessionItem]) -> [BolttyAISessionItem] {
    let position = Dictionary(held.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    let heldDay = Dictionary(held.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
    let fresh = items.filter { position[$0.id] == nil }
    let kept = items.filter { position[$0.id] != nil }
      .sorted { position[$0.id]! < position[$1.id]! }
      .map { item -> BolttyAISessionItem in
        var item = item
        if let day = heldDay[item.id] { item.updatedAt = day }
        return item
      }
    return fresh + kept
  }

  static func filter(
    _ rows: [BolttyAISessionItem],
    transcripts: [UUID: ConversationTranscript] = [:],
    query: String
  ) -> [BolttyAISessionItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return rows }
    return rows.filter { row in
      if row.title.localizedCaseInsensitiveContains(trimmed) { return true }
      if let transcript = transcripts[row.id] {
        return transcript.messages.reversed().contains { $0.containsText(trimmed) }
      }
      return row.subtitle.localizedCaseInsensitiveContains(trimmed)
    }
  }

  static func displayPath(_ absolute: String) -> String {
    let trimmed = absolute.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "~" }
    let home = WorkingDirectoryResolver.homeDirectoryPath
    if trimmed == home { return "~" }
    if trimmed.hasPrefix(home + "/") {
      return String(trimmed.dropFirst(home.count + 1))
    }
    if trimmed == "/" { return "/" }
    return (trimmed as NSString).abbreviatingWithTildeInPath
  }
}

extension ConversationExecutionState {
  var reportedState: AgentReportedState {
    switch self {
    case .idle: .finished
    case .working: .running
    case .waiting: .blocked
    case .failed, .interrupted, .rateLimited: .failed
    }
  }
}

// MARK: - A chat's title, as a row shows it

/// **A row's title is the request, whole and in the person's words.** The
/// stored title is cut at 40 characters (`ConversationEngine.title(from:)`,
/// kept short for the notch, the banners and the tray), which in a row stops
/// half way across while the reply under it runs to the edge. And the
/// prompt as sent carries what the person never typed: a screen
/// selection's bracket, a path where a file chip stood.
///
/// So the row reads the first request off the transcript when the stored
/// title is only a cut of it, and the label truncates by its own width.
/// A stored title that is not a cut — a CLI's own name for an adopted
/// session — is kept. Either is cleaned the same way (`clean`).
enum ChatTitle {
  /// What the history row shows for this chat.
  static func forRow(_ conversation: Conversation, transcript: ConversationTranscript) -> String {
    let files = conversation.sentFiles
    let stored = clean(conversation.title, files: files)
    let untitled = conversation.title == ConversationEngine.untitled
    if let request = firstRequest(in: transcript) {
      let whole = clean(request, files: files)
      if !whole.isEmpty, untitled || stored.isEmpty || isCut(stored, of: whole) {
        return whole
      }
    }
    if !stored.isEmpty, !untitled { return stored }
    // A request that was only chips: the first file's name ("image1.png"),
    // rather than "New conversation" or nothing.
    return files.first?.name ?? conversation.title
  }

  /// The request the person typed, with each chip as only a file they chose
  /// keeps it: its own name. A picture pasted or a region of the screen —
  /// a chip Boltty named, "image1" — leaves nothing, nor does pasted text;
  /// any other path is its last part. Whitespace is one space; past
  /// `displayLimit` it is cut at a word. Empty when nothing typed is left.
  static func clean(_ text: String, files: [SentFile] = []) -> String {
    // The files first, on the whole request: a screen region's bracket
    // carries the text read off it and can run to kilobytes. Then enough
    // for any title a row can show; a construct cut there is caught by the
    // unterminated forms below.
    var text = String(liftingFiles(in: text, files: files).prefix(rawLimit))
    // Most requests are words alone; the expressions are for the rest. The
    // list builds every row's title on each change while it is open.
    if text.contains(where: { "[<\"/~".contains($0) }) {
      for removal in Pattern.removals {
        text = removal.replacing(in: text, with: "")
      }
      text = shorteningPaths(in: text)
    }
    let words = text.split(whereSeparator: \.isWhitespace)
    var title = ""
    for word in words {
      if title.count + word.count + 1 > displayLimit {
        return title.isEmpty ? String(word.prefix(displayLimit)) + "…" : title + "…"
      }
      title += title.isEmpty ? String(word) : " " + word
    }
    return title
  }

  static let rawLimit = 600
  static let displayLimit = 240

  private static func firstRequest(in transcript: ConversationTranscript) -> String? {
    guard let message = transcript.messages.first(where: { $0.role == .user }) else { return nil }
    let text = message.parts.compactMap { part -> String? in
      guard case let .text(text) = part, text.kind == .text else { return nil }
      return text.text
    }.joined(separator: " ")
    return text.isEmpty ? nil : text
  }

  /// The stored title is the request's opening words, cut — what
  /// `ConversationEngine.title(from:)` and the CLI stores' titles are.
  private static func isCut(_ stored: String, of whole: String) -> Bool {
    let opening = stored.hasSuffix("…") ? String(stored.dropLast()) : stored
    let trimmed = opening.trimmingCharacters(in: .whitespaces)
    return !trimmed.isEmpty && whole.hasPrefix(trimmed)
  }

  /// Every spelling a sent file took in the prompt, longest first: a screen
  /// region's whole bracket, then its paths, quoted and bare.
  private static func liftingFiles(in text: String, files: [SentFile]) -> String {
    guard !files.isEmpty else { return text }
    let byPath = files.sorted { $0.path.count > $1.path.count }
    let spellings: [(text: String, file: SentFile)] =
      files.compactMap { file in file.expansion.map { ($0, file) } }
        .sorted { $0.text.count > $1.text.count }
      + byPath.flatMap { file in [("\"\(file.path)\"", file), (file.path, file)] }
    var text = text
    for (spelling, file) in spellings where text.contains(spelling) {
      text = text.replacingOccurrences(of: spelling, with: name(of: file))
    }
    return text
  }

  /// A file the person chose is named by itself; one Boltty wrote out
  /// (a picture, a screen region, a long paste) is named by Boltty after
  /// its chip, and says nothing in a title.
  private static func name(of file: SentFile) -> String {
    let own = URL(fileURLWithPath: file.path).lastPathComponent
    return file.expansion == nil && own == file.name ? file.name : ""
  }

  /// What is left of a path: a quoted one in Boltty's own folder is a copy
  /// Boltty made and goes; any other keeps its last part.
  private static func shorteningPaths(in text: String) -> String {
    let text = NSMutableString(string: text)
    for (pattern, quoted) in [(Pattern.quotedPath, true), (Pattern.barePath, false)] {
      let matches = pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length))
      // From the end, so the ranges still ahead stay where they were.
      for match in matches.reversed() {
        let found = text.substring(with: match.range(at: 1))
        let ours = quoted && found.contains("/Application Support/Boltty/")
        let last = ours ? "" : (found as NSString).lastPathComponent
        text.replaceCharacters(in: match.range, with: last)
      }
    }
    return text as String
  }

  private enum Pattern {
    static let removals = [
      // A screen region's bracket, whole: it ends with the text read off
      // it, or with the whole screen's picture.
      compile(#"\[Selected on screen[\s\S]*?(?:</screen-text>\]|\.png"?\])"#),
      // …or cut short, as a stored title cut it.
      compile(#"\[Selected on[^\]]*$"#),
      compile(#"<pasted-text>[\s\S]*?</pasted-text>"#),
      compile(#"<pasted-text>[\s\S]*$"#),
      compile(#"<screen-text>[\s\S]*?</screen-text>"#),
      compile(#"<screen-text>[\s\S]*$"#),
      // A quoted path the cut left open.
      compile(#""(?:~|/)[^"\n]*$"#),
    ]
    static let quotedPath = compile(#""((?:~|/)[^"\n]+)""#)
    /// A path with a folder in it, starting a word — never the `//` of an
    /// address or the `/` of "and/or".
    static let barePath = compile(#"(?<![\w/:."])((?:~/|/)(?:[^\s/"]+/)+[^\s/"]+)"#)

    private static func compile(_ pattern: String) -> NSRegularExpression {
      try! NSRegularExpression(pattern: pattern)
    }
  }
}

private extension NSRegularExpression {
  func replacing(in string: String, with template: String) -> String {
    stringByReplacingMatches(
      in: string, range: NSRange(string.startIndex..., in: string), withTemplate: template
    )
  }

  func hasMatch(in string: String) -> Bool {
    firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
  }
}
