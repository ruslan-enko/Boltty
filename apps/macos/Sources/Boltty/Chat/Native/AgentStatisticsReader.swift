import Foundation
import SQLite3

struct AgentStatisticsReader: Sendable {
  var claudeProjects: URL
  var codexSessions: URL
  var grokSessions: URL
  var openCodeDatabase: URL
  var antigravityConversations: URL
  var cacheURL: URL?

  init(
    home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    cacheURL: URL? = AgentStatisticsReader.defaultCacheURL()
  ) {
    claudeProjects = home.appendingPathComponent(".claude/projects")
    codexSessions = home.appendingPathComponent(".codex/sessions")
    grokSessions = home.appendingPathComponent(".grok/sessions")
    openCodeDatabase = home.appendingPathComponent(".local/share/opencode/opencode.db")
    antigravityConversations = home.appendingPathComponent(".gemini/antigravity-cli/conversations")
    self.cacheURL = cacheURL
  }

  static func defaultCacheURL() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Boltty/Usage/statistics.json")
  }

  // MARK: - Units

  private struct Unit: Sendable {
    enum Kind: Sendable { case claude, codex, grok, opencode, antigravity }
    var kind: Kind
    var url: URL
    var fingerprint: String
  }

  private struct Cache: Codable {
    static let version = 1
    var version = Cache.version
    var entries: [String: Entry] = [:]

    struct Entry: Codable {
      var fingerprint: String
      var sessions: [AgentStatistics.Session]
    }
  }

  private final class Found: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Cache.Entry] = [:]
    func set(_ path: String, _ entry: Cache.Entry) {
      lock.withLock { values[path] = entry }
    }
    var entries: [String: Cache.Entry] { lock.withLock { values } }
  }

  func read() -> AgentStatistics {
    let units = claudeUnits() + codexUnits() + grokUnits() + openCodeUnits() + antigravityUnits()
    var cache = loadCache()

    let stale = units.filter { cache.entries[$0.url.path]?.fingerprint != $0.fingerprint }
    let found = Found()
    DispatchQueue.concurrentPerform(iterations: stale.count) { index in
      let unit = stale[index]
      found.set(unit.url.path, Cache.Entry(fingerprint: unit.fingerprint, sessions: read(unit)))
    }
    let fresh = found.entries

    let present = Set(units.map(\.url.path))
    cache.entries = cache.entries.filter { present.contains($0.key) }
    cache.entries.merge(fresh) { $1 }
    if !stale.isEmpty { saveCache(cache) }

    var merged: [String: AgentStatistics.Session] = [:]
    var order: [String] = []
    for unit in units {
      for session in cache.entries[unit.url.path]?.sessions ?? [] {
        let key = "\(session.agent)/\(session.id)"
        if merged[key] == nil { order.append(key) }
        merged[key, default: .init(agent: session.agent, id: session.id, samples: [])]
          .samples += session.samples
      }
    }
    return AgentStatistics(sessions: order.compactMap { merged[$0] })
  }

  private func read(_ unit: Unit) -> [AgentStatistics.Session] {
    switch unit.kind {
    case .claude: Self.claudeSessions(at: unit.url, root: claudeProjects)
    case .codex: Self.codexSessions(at: unit.url)
    case .grok: Self.grokSessions(in: unit.url)
    case .opencode: Self.openCodeSessions(in: unit.url)
    case .antigravity: Self.antigravitySessions(at: unit.url)
    }
  }

  private static func fingerprint(of urls: [URL]) -> String? {
    var parts: [String] = []
    var any = false
    for url in urls {
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      else { parts.append("-"); continue }
      any = true
      parts.append("\(values.fileSize ?? 0)@\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
    }
    return any ? parts.joined(separator: "|") : nil
  }

  private func jsonlFiles(under root: URL, matching accept: (URL) -> Bool) -> [URL] {
    guard let walk = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey]
    ) else { return [] }
    var found: [URL] = []
    for case let url as URL in walk where url.pathExtension == "jsonl" && accept(url) {
      found.append(url)
    }
    return found
  }

  private func claudeUnits() -> [Unit] {
    jsonlFiles(under: claudeProjects) { _ in true }.compactMap { url in
      Self.fingerprint(of: [url]).map { Unit(kind: .claude, url: url, fingerprint: $0) }
    }
  }

  private func codexUnits() -> [Unit] {
    jsonlFiles(under: codexSessions) {
      CodexSessionStore.sessionID(fromRolloutName: $0.lastPathComponent) != nil
    }.compactMap { url in
      Self.fingerprint(of: [url]).map { Unit(kind: .codex, url: url, fingerprint: $0) }
    }
  }

  private func grokUnits() -> [Unit] {
    let manager = FileManager.default
    let places = (try? manager.contentsOfDirectory(at: grokSessions, includingPropertiesForKeys: nil)) ?? []
    return places.flatMap { place in
      ((try? manager.contentsOfDirectory(at: place, includingPropertiesForKeys: nil)) ?? []).compactMap { directory in
        let files = ["summary.json", "events.jsonl", "usage.json"].map { directory.appendingPathComponent($0) }
        guard FileManager.default.fileExists(atPath: files[0].path),
              let print = Self.fingerprint(of: files)
        else { return nil }
        return Unit(kind: .grok, url: directory, fingerprint: print)
      }
    }
  }

  private func openCodeUnits() -> [Unit] {
    guard FileManager.default.fileExists(atPath: openCodeDatabase.path),
          let print = Self.fingerprint(of: [
            openCodeDatabase, URL(fileURLWithPath: openCodeDatabase.path + "-wal"),
          ])
    else { return [] }
    return [Unit(kind: .opencode, url: openCodeDatabase, fingerprint: print)]
  }

  /// One conversation a file; its `-wal` is in the fingerprint, since a
  /// running `agy` writes there first.
  private func antigravityUnits() -> [Unit] {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: antigravityConversations, includingPropertiesForKeys: nil
    )) ?? []
    return files.filter { $0.pathExtension == "db" }.compactMap { url in
      Self.fingerprint(of: [url, URL(fileURLWithPath: url.path + "-wal")])
        .map { Unit(kind: .antigravity, url: url, fingerprint: $0) }
    }
  }

  // MARK: - Cache

  private func loadCache() -> Cache {
    guard let cacheURL,
          let data = try? Data(contentsOf: cacheURL),
          let cache = try? JSONDecoder().decode(Cache.self, from: data),
          cache.version == Cache.version
    else { return Cache() }
    return cache
  }

  private func saveCache(_ cache: Cache) {
    guard let cacheURL else { return }
    try? FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    if let data = try? JSONEncoder().encode(cache) {
      try? data.write(to: cacheURL, options: .atomic)
    }
  }

  // MARK: - Lines

  private static func forEachLine(of url: URL, _ body: (Data) -> Void) {
    try? FileHead.forEachLine(of: url, maxLines: .max, maxBytes: .max) { line in
      body(line)
      return true
    }
  }

  private static func object(_ line: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: line) as? [String: Any]
  }

  static func timestamp(in line: Data) -> Date? {
    guard let key = line.range(of: timestampNeedle) else { return nil }
    let rest = line[key.upperBound...]
    guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
    return ISO8601Stamp.date(from: String(decoding: rest[..<end], as: UTF8.self))
  }

  private static let timestampNeedle = Data("\"timestamp\":\"".utf8)

  private static func contains(_ line: Data, _ needle: Data) -> Bool {
    line.range(of: needle) != nil
  }

  private static func int(_ value: Any?) -> Int {
    (value as? NSNumber)?.intValue ?? 0
  }

  private static func text(of content: Any?) -> String {
    if let text = content as? String { return text }
    guard let parts = content as? [[String: Any]] else { return "" }
    return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
  }

  // MARK: - Claude Code

  private static let claudeAssistant = Data("\"type\":\"assistant\"".utf8)
  private static let claudeUser = Data("\"type\":\"user\"".utf8)
  private static let claudeToolResult = Data("\"type\":\"tool_result\"".utf8)
  private static let claudeMeta = Data("\"isMeta\":true".utf8)

  static func claudeSessions(at url: URL, root: URL) -> [AgentStatistics.Session] {
    let components = url.pathComponents
    let id: String
    if let subagents = components.lastIndex(of: "subagents"), subagents > 0 {
      id = components[subagents - 1]
    } else {
      id = url.deletingPathExtension().lastPathComponent
    }

    var accumulator = AgentStatistics.Accumulator()
    var replies: [String: (date: Date, model: String, tokens: Int)] = [:]
    var replyOrder: [String] = []
    forEachLine(of: url) { line in
      if contains(line, claudeAssistant) {
        guard let record = object(line), record["type"] as? String == "assistant",
              let message = record["message"] as? [String: Any],
              let date = (record["timestamp"] as? String).flatMap(ISO8601Stamp.date(from:))
        else { return }
        let model = message["model"] as? String ?? ""
        guard model != "<synthetic>" else { return }
        let usage = message["usage"] as? [String: Any] ?? [:]
        let tokens = int(usage["input_tokens"]) + int(usage["output_tokens"])
          + int(usage["cache_creation_input_tokens"]) + int(usage["cache_read_input_tokens"])
        let key = message["id"] as? String ?? record["uuid"] as? String ?? UUID().uuidString
        if replies[key] == nil { replyOrder.append(key) }
        replies[key] = (date, model, max(tokens, replies[key]?.tokens ?? 0))
      } else if contains(line, claudeUser), !contains(line, claudeToolResult), !contains(line, claudeMeta) {
        guard let record = object(line), record["type"] as? String == "user",
              let date = (record["timestamp"] as? String).flatMap(ISO8601Stamp.date(from:)),
              let message = record["message"] as? [String: Any]
        else { return }
        let text = Self.text(of: message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !InjectedText.isScaffolding(text, tags: InjectedText.claudeTags, prefixes: InjectedText.claudePrefixes)
        else { return }
        accumulator.add(at: date, model: "", messages: 1)
      }
    }
    for key in replyOrder {
      guard let reply = replies[key] else { continue }
      accumulator.add(at: reply.date, model: reply.model, tokens: reply.tokens, messages: 1)
    }
    return accumulator.isEmpty ? [] : [.init(agent: AgentId.claude.rawValue, id: id, samples: accumulator.samples)]
  }

  // MARK: - Codex

  private static let codexTurnContext = Data("\"type\":\"turn_context\"".utf8)
  private static let codexTokenCount = Data("\"type\":\"token_count\"".utf8)
  private static let codexResponseItem = Data("\"type\":\"response_item\"".utf8)
  private static let codexMessage = Data("\"type\":\"message\"".utf8)
  private static let codexAssistantRole = Data("\"role\":\"assistant\"".utf8)
  private static let codexUserRole = Data("\"role\":\"user\"".utf8)

  static func codexSessions(at url: URL) -> [AgentStatistics.Session] {
    guard let id = CodexSessionStore.sessionID(fromRolloutName: url.lastPathComponent) else { return [] }
    var accumulator = AgentStatistics.Accumulator()
    var model = ""
    var total = 0
    forEachLine(of: url) { line in
      if contains(line, codexTokenCount) {
        guard let date = timestamp(in: line),
              let record = object(line),
              let payload = record["payload"] as? [String: Any],
              let info = payload["info"] as? [String: Any]
        else { return }
        let running = int((info["total_token_usage"] as? [String: Any])?["total_tokens"])
        let last = int((info["last_token_usage"] as? [String: Any])?["total_tokens"])
        let added = running > total ? running - total : (running < total ? last : 0)
        total = running
        accumulator.add(at: date, model: model, tokens: added)
      } else if contains(line, codexTurnContext) {
        guard let record = object(line),
              let payload = record["payload"] as? [String: Any],
              let named = payload["model"] as? String
        else { return }
        model = named
      } else if contains(line, codexResponseItem), contains(line, codexMessage) {
        guard let date = timestamp(in: line) else { return }
        if contains(line, codexAssistantRole) {
          accumulator.add(at: date, model: model, messages: 1)
        } else if contains(line, codexUserRole) {
          guard let record = object(line),
                let payload = record["payload"] as? [String: Any],
                payload["role"] as? String == "user"
          else { return }
          let text = Self.text(of: payload["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty,
                !InjectedText.isScaffolding(text, tags: InjectedText.codexTags, prefixes: InjectedText.codexPrefixes)
          else { return }
          accumulator.add(at: date, model: "", messages: 1)
        }
      }
    }
    return accumulator.isEmpty ? [] : [.init(agent: AgentId.codex.rawValue, id: id, samples: accumulator.samples)]
  }

  // MARK: - Grok

  private static let grokTurnStarted = Data("\"type\":\"turn_started\"".utf8)
  private static let grokFirstToken = Data("\"type\":\"first_token\"".utf8)

  static func grokSessions(in directory: URL) -> [AgentStatistics.Session] {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("summary.json")),
          let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = (summary["info"] as? [String: Any])?["id"] as? String
    else { return [] }
    let named = (summary["session_summary"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard int(summary["num_messages"]) > 1 || !named.isEmpty else { return [] }

    var accumulator = AgentStatistics.Accumulator()
    var model = summary["current_model_id"] as? String ?? ""
    forEachLine(of: directory.appendingPathComponent("events.jsonl")) { line in
      if contains(line, grokTurnStarted) {
        guard let record = object(line),
              let date = (record["ts"] as? String).flatMap(ISO8601Stamp.date(from:))
        else { return }
        if let named = record["model_id"] as? String { model = named }
        accumulator.add(at: date, model: "", messages: 1)
      } else if contains(line, grokFirstToken) {
        guard let record = object(line),
              let date = (record["ts"] as? String).flatMap(ISO8601Stamp.date(from:))
        else { return }
        accumulator.add(at: date, model: model, messages: 1)
      }
    }

    if let data = try? Data(contentsOf: directory.appendingPathComponent("usage.json")),
       let usage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      let turns = usage["turns"] as? [[String: Any]] ?? []
      for turn in turns {
        guard let date = (turn["endedAt"] as? String).flatMap(ISO8601Stamp.date(from:)) else { continue }
        if let models = turn["modelUsage"] as? [String: [String: Any]], !models.isEmpty {
          for (name, counts) in models {
            accumulator.add(at: date, model: name, tokens: int(counts["totalTokens"]))
          }
        } else {
          accumulator.add(at: date, model: turn["primaryModelId"] as? String ?? model, tokens: int(turn["totalTokens"]))
        }
      }
    }
    return accumulator.isEmpty ? [] : [.init(agent: AgentId.grok.rawValue, id: id, samples: accumulator.samples)]
  }

  // MARK: - OpenCode

  /// This database holds credentials: named columns, read-only connection.
  static func openCodeSessions(in database: URL) -> [AgentStatistics.Session] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2("file:\(database.path)?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
          let handle
    else {
      sqlite3_close(handle)
      return []
    }
    defer { sqlite3_close(handle) }

    var tables: Set<String> = []
    query(handle, "SELECT name FROM sqlite_master WHERE type = 'table'") { row in
      if let name = text(row, 0) { tables.insert(name) }
    }

    let tokens = { (column: String) in
      ["input", "output", "reasoning", "cache.read", "cache.write"]
        .map { "COALESCE(json_extract(\(column), '$.tokens.\($0)'), 0)" }
        .joined(separator: " + ")
    }

    var accumulators: [String: AgentStatistics.Accumulator] = [:]
    var order: [String] = []
    func add(_ row: OpaquePointer) {
      guard let session = text(row, 0) else { return }
      let role = text(row, 1) ?? ""
      guard role == "user" || role == "assistant" else { return }
      let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 2)) / 1000)
      let model = role == "assistant" ? (text(row, 3) ?? "") : ""
      if accumulators[session] == nil { order.append(session) }
      accumulators[session, default: .init()]
        .add(at: date, model: model, tokens: Int(sqlite3_column_int64(row, 4)), messages: 1)
    }

    if tables.contains("session_message") {
      let parent = tables.contains("session_v2")
        ? "LEFT JOIN session_v2 s ON s.id = m.session_id" : ""
      let owner = tables.contains("session_v2") ? "COALESCE(s.parent_id, m.session_id)" : "m.session_id"
      query(handle, """
        SELECT \(owner), m.type, m.time_created, json_extract(m.data, '$.model.id'), \(tokens("m.data"))
          FROM session_message m \(parent)
         WHERE m.type IN ('user', 'assistant')
        """, add)
    }
    if tables.contains("message") {
      let parent = tables.contains("session") ? "LEFT JOIN session s ON s.id = m.session_id" : ""
      let owner = tables.contains("session") ? "COALESCE(s.parent_id, m.session_id)" : "m.session_id"
      let unseen = tables.contains("session_message")
        ? "WHERE m.session_id NOT IN (SELECT DISTINCT session_id FROM session_message)" : ""
      query(handle, """
        SELECT \(owner), json_extract(m.data, '$.role'), m.time_created, json_extract(m.data, '$.modelID'), \(tokens("m.data"))
          FROM message m \(parent)
          \(unseen)
        """, add)
    }

    return order.compactMap { id in
      guard let accumulator = accumulators[id], !accumulator.isEmpty else { return nil }
      return .init(agent: AgentId.opencode.rawValue, id: id, samples: accumulator.samples)
    }
  }

  // MARK: - Antigravity

  static func antigravitySessions(at url: URL) -> [AgentStatistics.Session] {
    guard let steps = try? AntigravityTranscript.steps(at: url) else { return [] }
    let models = (try? AntigravityTranscript.modelNames(at: url)) ?? [:]
    var accumulator = AgentStatistics.Accumulator()
    for use in AntigravityTranscript.usage(of: steps, models: models) {
      accumulator.add(at: use.date, model: use.model, tokens: use.tokens, messages: use.messages)
    }
    let id = url.deletingPathExtension().lastPathComponent
    return accumulator.isEmpty ? [] : [.init(agent: AgentId.antigravity.rawValue, id: id, samples: accumulator.samples)]
  }

  private static func query(_ handle: OpaquePointer, _ sql: String, _ row: (OpaquePointer) -> Void) {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
  }

  private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
  }
}
