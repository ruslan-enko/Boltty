import XCTest
@testable import Boltty

final class AgentSkillsTests: XCTestCase {
  func testTheCommandARequestOpensWith() {
    XCTAssertEqual(AgentCommand.leading(in: "/ping hello there")?.name, "ping")
    XCTAssertEqual(AgentCommand.leading(in: "/ping hello there")?.rest, "hello there")
    XCTAssertEqual(AgentCommand.leading(in: "/plan\n\nwords")?.rest, "words")
    XCTAssertNil(AgentCommand.leading(in: "/usr/bin/env"))
    XCTAssertNil(AgentCommand.leading(in: "no command"))
    XCTAssertNil(AgentCommand.leading(in: "/ "))
  }

  func testRankingPutsANamePrefixBeforeAMention() {
    let commands = [
      AgentCommand(name: "simplify", summary: "Review for reuse", argumentHint: nil),
      AgentCommand(name: "design:ux-copy", summary: "", argumentHint: nil),
      AgentCommand(name: "review", summary: "", argumentHint: nil),
    ]
    XCTAssertEqual(AgentCommand.rank(commands, query: "rev", limit: 8).map(\.name), ["review", "simplify"])
    XCTAssertEqual(AgentCommand.rank(commands, query: "ux", limit: 8).map(\.name), ["design:ux-copy"])
    XCTAssertEqual(AgentCommand.rank(commands, query: "", limit: 2).map(\.name), ["simplify", "design:ux-copy"])
  }

  func testClaudeCodeOffersSkillsButNotItsOwnCommands() {
    let handshake = JSONObject([
      "commands": [
        ["name": "code-review", "description": "Review changes (user)", "argumentHint": ""],
        ["name": "design:ux-copy", "description": "(design) Write copy", "argumentHint": "<copy>"],
        ["name": "clear", "description": "Start a new session", "builtin": true],
        ["name": "__remote-workflow", "description": "x"],
      ],
    ])
    let commands = ClaudeCodeClient.commands(in: handshake)
    XCTAssertEqual(commands.map(\.name), ["code-review", "design:ux-copy"])
    XCTAssertEqual(commands.map(\.summary), ["Review changes", "Write copy"])
    XCTAssertEqual(commands.map(\.argumentHint), [nil, "<copy>"])
  }

  func testCodexKeepsTheFirstSkillOfAName() {
    let response = JSONObject([
      "data": [[
        "skills": [
          ["name": "ping", "path": "/a/SKILL.md", "description": "long", "shortDescription": "short"],
          ["name": "ping", "path": "/b/SKILL.md"],
          ["name": "off", "path": "/c/SKILL.md", "enabled": false],
        ],
      ]],
    ])
    XCTAssertEqual(CodexClient.skills(in: response), [CodexClient.Skill(name: "ping", path: "/a/SKILL.md", summary: "short")])
  }

  func testOpenCodeSkillsAreItsIDs() throws {
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
      {"data": [{"id": "ping", "name": "Ping", "description": "Answers"}, {"id": "two words"}]}
      """#.utf8))
    XCTAssertEqual(OpenCodeClient.skills(in: payload), [AgentCommand(name: "ping", summary: "Answers", argumentHint: nil)])
  }

  func testGrokOffersOnlyWhatHasAPathAndNeverAlwaysApprove() {
    let listed = [
      JSONObject(["name": "always-approve", "description": "Toggle", "input": ["hint": "on|off"]]),
      JSONObject(["name": "animate", "description": "Build", "_meta": ["path": "/u/SKILL.md", "scope": "user"]]),
      JSONObject(["name": "ping", "description": "Here", "_meta": ["path": "/p/SKILL.md", "scope": "project"]]),
    ]
    let found = ACPClient.commands(in: listed)
    XCTAssertEqual(found.all.map(\.name), ["animate", "ping"])
    XCTAssertEqual(found.personal.map(\.name), ["animate"])
  }

  func testAntigravityReadsItsSkillsCommand() {
    let result = JSONObject([
      "command": ["name": "skills", "data": ["skills": [
        ["name": "ping", "description": "Answers", "builtin": false],
        ["name": "automation", "description": "Schedules", "builtin": true],
      ]]],
    ])
    XCTAssertEqual(AntigravityClient.skills(in: result).map(\.name), ["ping", "automation"])
    XCTAssertEqual(AntigravityClient.skills(in: JSONObject(["command": ["name": "usage"]])), [])
  }
}

final class SentSkillTranscriptTests: XCTestCase {
  func testClaudeCodeFilesASentSkillAsTheWordsThatSentIt() {
    let filed = "<command-message>ping</command-message>\n<command-name>/ping</command-name>\n<command-args>hello there</command-args>"
    XCTAssertEqual(InjectedText.claudeCommand(in: filed), "/ping hello there")
    XCTAssertNil(InjectedText.claudeCommand(in: "<command-name>/clear</command-name>"), "the CLI's own stay hidden")
    XCTAssertNil(InjectedText.claudeCommand(
      in: "<command-message>compact</command-message><command-name>/compact</command-name>"))
  }

  func testCodexSkillGoesBackInFrontOfTheWords() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let lines = [
      #"{"type":"response_item","payload":{"type":"message","role":"user","id":"u1","content":[{"type":"input_text","text":"hello there"}]}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"user","id":"u2","content":[{"type":"input_text","text":"<skill>\n<name>ping</name>\n<path>/p</path>\nbody</skill>"}]}}"#,
      ##"{"type":"response_item","payload":{"type":"message","role":"assistant","id":"a1","content":[{"type":"output_text","text":"<proposed_plan>\n# Plan\n</proposed_plan>"}]}}"##,
    ]
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    let messages = CodexRolloutTranscript.read(at: url)
    XCTAssertEqual(messages.map(\.plainText), ["/ping hello there", "# Plan"])
  }

  func testOpenCodeSkillGoesBackInFrontOfTheWords() throws {
    let dto = try JSONDecoder().decode(OpenCodeDTO.Message.self, from: Data(#"""
      {"id": "m1", "type": "user", "text": "hello there", "skills": [{"id": "ping"}]}
      """#.utf8))
    XCTAssertEqual(OpenCodeMapper.message(from: dto)?.plainText, "/ping hello there")
  }
}
