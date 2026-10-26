import Foundation
import SQLite3

struct OpenCodeSessionStore: NativeSessionStore {
  var agent: AgentId { .opencode }

  let database: URL

  init(database: URL? = nil) {
    self.database = database ?? URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".local/share/opencode/opencode.db")
  }

  /// The table is not a constant: 2.0 uses session_v2, 1.18's `session` stays behind, frozen.
  private static func query(tables: Set<String>) -> String? {
    let chats = { (table: String) in
      """
      SELECT id, title, directory, time_updated
        FROM \(table)
       WHERE parent_id IS NULL AND time_archived IS NULL
      """
    }
    switch (tables.contains("session_v2"), tables.contains("session")) {
    case (true, true):
      return """
        \(chats("session"))
           AND id NOT IN (SELECT id FROM session_v2)\(tables.contains("message")
             ? "\n   AND EXISTS (SELECT 1 FROM message WHERE message.session_id = session.id)"
             : "")
        UNION ALL
        \(chats("session_v2"))
        ORDER BY time_updated DESC
        LIMIT ?
        """
    case (true, false):
      return "\(chats("session_v2"))\nORDER BY time_updated DESC\nLIMIT ?"
    case (false, true):
      return "\(chats("session"))\nORDER BY time_updated DESC\nLIMIT ?"
    case (false, false):
      return nil
    }
  }

  private static let tablesQuery = """
    SELECT name FROM sqlite_master
     WHERE type = 'table' AND name IN ('session', 'session_v2', 'message')
    """

  func sessions(limit: Int) throws -> [NativeSession] {
    guard FileManager.default.fileExists(atPath: database.path) else {
      return []
    }

    var handle: OpaquePointer?
    let uri = "file:\(database.path)?mode=ro"
    guard sqlite3_open_v2(
      uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
    ) == SQLITE_OK, let handle else {
      let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
      sqlite3_close(handle)
      throw NativeSessionStoreError.unreadable(path: database.path, reason: reason)
    }
    defer { sqlite3_close(handle) }

    let tables = try self.tables(in: handle)
    guard let sql = Self.query(tables: tables) else {
      throw NativeSessionStoreError.unreadable(
        path: database.path, reason: "no session table: this is not OpenCode's database"
      )
    }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
    else {
      throw NativeSessionStoreError.unreadable(
        path: database.path, reason: String(cString: sqlite3_errmsg(handle))
      )
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int(statement, 1, Int32(limit))

    var sessions: [NativeSession] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let id = text(statement, 0) else { continue }
      let directory = text(statement, 2) ?? ""
      sessions.append(
        NativeSession(
          id: id,
          agent: .opencode,
          title: text(statement, 1).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.fallbackTitle(for: directory),
          workingDirectory: directory,
          updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)
        )
      )
    }
    return sessions
  }

  private func tables(in handle: OpaquePointer) throws -> Set<String> {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, Self.tablesQuery, -1, &statement, nil) == SQLITE_OK,
          let statement
    else {
      throw NativeSessionStoreError.unreadable(
        path: database.path, reason: String(cString: sqlite3_errmsg(handle))
      )
    }
    defer { sqlite3_finalize(statement) }

    var names: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let name = text(statement, 0) { names.insert(name) }
    }
    return names
  }

  private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
  }

  private static func fallbackTitle(for directory: String) -> String {
    let name = (directory as NSString).lastPathComponent
    return name.isEmpty ? "OpenCode session" : name
  }
}
