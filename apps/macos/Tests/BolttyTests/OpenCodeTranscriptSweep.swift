import Foundation
import XCTest
@testable import Boltty

@MainActor
final class OpenCodeTranscriptSweep: XCTestCase {
  func testEveryOpenCodeChatDecodesIntoWhatTheServerSent() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_OPENCODE_SWEEP"] else {
      throw XCTSkip("set BOLTTY_OPENCODE_SWEEP to the directory of captured responses")
    }
    let root = URL(fileURLWithPath: dir)
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
    try XCTSkipIf(files.isEmpty, "no captures in \(dir)")

    var chats = 0, undecodable = 0, empty = 0, shown = 0
    var lost: [String] = []
    var invented: [String] = []

    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let data = try Data(contentsOf: file)
      let name = file.deletingPathExtension().lastPathComponent
      chats += 1

      guard let envelope = try? JSONDecoder()
        .decode(OpenCodeDTO.ListEnvelope<OpenCodeDTO.Message>.self, from: data)
      else {
        undecodable += 1
        continue
      }
      let messages = envelope.data.compactMap(OpenCodeMapper.message(from:))
      shown += messages.count

      let truth = Self.truth(in: data)
      if messages.isEmpty, !truth.isEmpty { empty += 1 }

      let rendered = messages.map { Self.flat($0.plainText) }.filter { !$0.isEmpty }
      for said in truth {
        let needle = Self.flat(said)
        guard !needle.isEmpty else { continue }
        if !rendered.contains(where: { $0.contains(needle) || needle.contains($0) }) {
          lost.append("\(name): \(String(said.prefix(100)))")
        }
      }
      let pool = truth.map(Self.flat)
      for line in rendered where !pool.contains(where: { $0.contains(line) || line.contains($0) }) {
        invented.append("\(name): \(String(line.prefix(100)))")
      }
    }

    print("""
      [opencode sweep] \(chats) chats, \(shown) messages — undecodable \(undecodable), \
      empty-but-not \(empty), lost \(lost.count), invented \(invented.count)
      """)
    XCTAssertEqual(undecodable, 0, "a real response the decoder could not read")
    XCTAssertEqual(empty, 0, "a chat with messages in it came back empty")
    XCTAssertEqual(lost, [], "text the server sent and the transcript does not show")
    XCTAssertEqual(invented, [], "text the transcript shows and the server never sent")
  }

  private static func truth(in data: Data) -> [String] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = object["data"] as? [[String: Any]]
    else { return [] }
    var said: [String] = []
    for message in list {
      switch message["type"] as? String {
      case "user":
        if let text = message["text"] as? String { said.append(text) }
      case "assistant":
        for part in message["content"] as? [[String: Any]] ?? []
        where part["type"] as? String == "text" {
          if let text = part["text"] as? String { said.append(text) }
        }
      default:
        continue
      }
    }
    return said
  }

  private static func flat(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
