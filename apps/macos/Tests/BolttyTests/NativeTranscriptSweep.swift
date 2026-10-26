import Foundation
import XCTest
@testable import Boltty

@MainActor
final class NativeTranscriptSweep: XCTestCase {
  private struct Truth {
    var assistantTexts: [String] = []
    var userTexts: [String] = []
  }

  private struct Finding {
    var agent: String
    var session: String
    var kind: String
    var detail: String
  }

  func testEveryChatShowsWhatTheCLIWrote() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_SWEEP"] else {
      throw XCTSkip("set BOLTTY_SWEEP to sweep every chat on this machine")
    }
    let out = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    var report: [String] = []
    var findings: [Finding] = []
    var dropped: [String: Int] = [:]
    var spoken: [String: Int] = [:]

    for (name, store, truth) in stores() {
      guard let sessions = try? store.sessions(limit: 5_000), !sessions.isEmpty else {
        report.append("\(name): no chats on this machine")
        continue
      }
      var read = 0, unreadable = 0, invented = 0, lostReplies = 0
      var shown = 0

      for session in sessions {
        guard let url = session.sourceURL else { unreadable += 1; continue }
        let file = store.agent == .grok
          ? url.appendingPathComponent("chat_history.jsonl")
          : url
        guard let raw = Self.tail(of: file) else { unreadable += 1; continue }
        guard let transcript = try? store.transcript(for: session) else {
          unreadable += 1; continue
        }
        read += 1
        shown += transcript.count
        let facts = truth(raw)

        for message in transcript {
          let text = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty else { continue }
          let needle = Self.flat(text)
          let pool = (facts.userTexts + facts.assistantTexts).map(Self.flat)
          guard pool.contains(where: { $0.contains(needle) || needle.contains($0) }) else {
            invented += 1
            findings.append(Finding(agent: name, session: session.id, kind: "invented",
                                    detail: String(text.prefix(120))))
            continue
          }
        }

        let shownAgent = transcript.filter { $0.role == .agent }
          .map { Self.flat($0.plainText) }
          .filter { !$0.isEmpty }
        for raw in facts.assistantTexts where !raw.isEmpty {
          let reply = Self.flat(raw)
          guard !shownAgent.contains(where: { $0.contains(reply) || reply.contains($0) }) else {
            continue
          }
          lostReplies += 1
          findings.append(Finding(agent: name, session: session.id, kind: "lost reply",
                                  detail: String(raw.prefix(120))))
        }

        for message in transcript where message.role == .user {
          let text = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty else { continue }
          spoken["\(name)  \(Self.shape(of: text))", default: 0] += 1
        }
        let shownUser = transcript.filter { $0.role == .user }.map { Self.flat($0.plainText) }
        for typed in facts.userTexts where !typed.isEmpty {
          let needle = Self.flat(typed)
          guard !shownUser.contains(where: { $0.contains(needle) || needle.contains($0) })
          else { continue }
          dropped["\(name)  \(Self.shape(of: typed))", default: 0] += 1
        }
      }

      report.append("""
        \(name): \(sessions.count) chats, \(read) read, \(unreadable) unreadable, \
        \(shown) messages shown — invented \(invented), lost replies \(lostReplies)
        """)
    }

    report.append("")
    report.append("user turns the transcript SHOWS, by shape — read this for things")
    report.append("nobody typed; anything but prose here wants explaining:")
    for (shape, count) in spoken.sorted(by: { $0.value > $1.value }).prefix(25) {
      report.append("  \(count)× \(shape)")
    }
    report.append("  … \(max(0, spoken.count - 25)) more shapes, all of them one-offs")

    report.append("")
    report.append("user turns the readers dropped, by shape:")
    for (shape, count) in dropped.sorted(by: { $0.value > $1.value }) {
      report.append("  \(count)× \(shape)")
    }
    if !findings.isEmpty {
      report.append("")
      report.append("findings:")
      for finding in findings.prefix(200) {
        report.append("  [\(finding.agent)] \(finding.kind) in \(finding.session): \(finding.detail)")
      }
      if findings.count > 200 { report.append("  … and \(findings.count - 200) more") }
    }

    let text = report.joined(separator: "\n") + "\n"
    try text.write(to: out.appendingPathComponent("sweep.txt"), atomically: true, encoding: .utf8)
    print(text)

    XCTAssertTrue(
      findings.allSatisfy { $0.kind != "invented" },
      "a transcript showed text that is not in the CLI's own file"
    )
  }

  private static func flat(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func shape(of text: String) -> String {
    if text.hasPrefix("<"), let end = text.firstIndex(where: { $0 == ">" || $0 == " " || $0 == "\n" }) {
      return String(text[..<end]) + ">"
    }
    return "plain: " + String(text.prefix(40)).replacingOccurrences(of: "\n", with: "⏎")
  }

  // MARK: - The second reader

  private func stores() -> [(String, NativeSessionStore, (String) -> Truth)] {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    return [
      ("codex", CodexSessionStore(root: home.appendingPathComponent(".codex")), Self.codexTruth),
      ("claude", ClaudeCodeSessionStore(root: home.appendingPathComponent(".claude/projects")),
       Self.claudeTruth),
      ("grok", GrokSessionStore(root: home.appendingPathComponent(".grok/sessions")),
       Self.grokTruth),
    ]
  }

  private static func tail(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let cap = UInt64(CodexRolloutTranscript.readLimit)
    let complete = size <= cap
    if !complete { try? handle.seek(toOffset: size - cap) } else { try? handle.seek(toOffset: 0) }
    guard let data = try? handle.readToEnd(),
          let text = String(data: data, encoding: .utf8)
    else { return nil }
    guard !complete else { return text }
    guard let newline = text.firstIndex(of: "\n") else { return "" }
    return String(text[text.index(after: newline)...])
  }

  private static func records(_ raw: String) -> [[String: Any]] {
    raw.split(separator: "\n").compactMap { line in
      guard let data = line.data(using: .utf8) else { return nil }
      return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
  }

  private static func codexTruth(_ raw: String) -> Truth {
    var truth = Truth()
    for record in records(raw) {
      guard let payload = record["payload"] as? [String: Any],
            payload["type"] as? String == "message",
            let role = payload["role"] as? String
      else { continue }
      let text = joined(payload["content"])
      guard !text.isEmpty else { continue }
      if role == "user" { truth.userTexts.append(text) }
      if role == "assistant" { truth.assistantTexts.append(text) }
    }
    return truth
  }

  private static func claudeTruth(_ raw: String) -> Truth {
    var truth = Truth()
    for record in records(raw) {
      guard let kind = record["type"] as? String,
            let message = record["message"] as? [String: Any]
      else { continue }
      let text: String
      if let plain = message["content"] as? String {
        text = plain.trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        text = joined(message["content"])
      }
      guard !text.isEmpty else { continue }
      if kind == "user" { truth.userTexts.append(text) }
      if kind == "assistant" { truth.assistantTexts.append(text) }
    }
    return truth
  }

  private static func grokTruth(_ raw: String) -> Truth {
    var truth = Truth()
    for record in records(raw) {
      guard let kind = record["type"] as? String else { continue }
      let text: String
      if let plain = record["content"] as? String {
        text = plain.trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        text = joined(record["content"])
      }
      guard !text.isEmpty else { continue }
      if kind == "user", record["synthetic_reason"] == nil { truth.userTexts.append(text) }
      if kind == "assistant" { truth.assistantTexts.append(text) }
    }
    return truth
  }

  private static func joined(_ content: Any?) -> String {
    guard let parts = content as? [[String: Any]] else {
      return (content as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    return parts.compactMap { $0["text"] as? String }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

