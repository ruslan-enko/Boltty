import Foundation
import SQLite3

/// OpenCode's free models have a daily allowance the server keeps to itself:
/// no route reports it, and the steps taken before it ran out were 55, 198 and
/// 141 on three days (2.2.6). What is known is read off the database: the steps
/// taken since the day began, and, from the last `provider.free-limit` error's
/// `retryAfterMs`, when it comes back (00:00–00:33 UTC, measured).
struct OpenCodeFreeUsage: Equatable, Sendable {
  var steps: Int
  var since: Date
  var backAt: Date?

  static func read(
    database: URL = OpenCodeSessionStore().database,
    isFree: (_ providerID: String, _ modelID: String) -> Bool,
    now: Date = Date()
  ) -> OpenCodeFreeUsage? {
    guard FileManager.default.fileExists(atPath: database.path) else { return nil }
    var handle: OpaquePointer?
    guard sqlite3_open_v2(
      "file:\(database.path)?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
    ) == SQLITE_OK, let handle else {
      sqlite3_close(handle)
      return nil
    }
    defer { sqlite3_close(handle) }

    let sql = """
      SELECT time_created,
             json_extract(data, '$.model.providerID'),
             json_extract(data, '$.model.id'),
             json_extract(data, '$.error.type'),
             json_extract(data, '$.error.retryAfterMs')
        FROM session_message
       WHERE type = 'assistant' AND time_created >= ?
       ORDER BY time_created
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    let dayStart = Self.dayStart(of: now)
    sqlite3_bind_int64(statement, 1, Int64((dayStart.timeIntervalSince1970 - 86_400) * 1_000))

    var records: [Record] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let provider = text(statement, 1), let model = text(statement, 2),
            isFree(provider, model)
      else { continue }
      let at = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)) / 1_000)
      let retry = sqlite3_column_type(statement, 4) == SQLITE_NULL
        ? nil : Double(sqlite3_column_int64(statement, 4)) / 1_000
      records.append(Record(at: at, isLimit: text(statement, 3) == "provider.free-limit", retryAfter: retry))
    }
    return summary(of: records, now: now)
  }

  struct Record: Equatable {
    var at: Date
    var isLimit: Bool
    var retryAfter: TimeInterval?
  }

  /// The day starts at midnight UTC, or later where a limit said it came back later.
  static func summary(of records: [Record], now: Date) -> OpenCodeFreeUsage? {
    let backs = records.compactMap { record -> Date? in
      guard record.isLimit, let retry = record.retryAfter else { return nil }
      return record.at.addingTimeInterval(retry)
    }
    var since = dayStart(of: now)
    if let reopened = backs.filter({ $0 <= now && $0 > since }).max() { since = reopened }
    let backAt = backs.filter { $0 > now }.max()
    let steps = records.filter { !$0.isLimit && $0.at >= since }.count
    guard steps > 0 || backAt != nil else { return nil }
    return OpenCodeFreeUsage(steps: steps, since: since, backAt: backAt)
  }

  static func dayStart(of date: Date) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar.startOfDay(for: date)
  }

  private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
  }
}
