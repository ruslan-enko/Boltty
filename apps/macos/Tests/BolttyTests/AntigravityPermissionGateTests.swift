import XCTest
@testable import Boltty

final class AntigravityPermissionGateTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
  }

  private var hooksFile: URL { root.appendingPathComponent("config/hooks.json") }
  private var scriptFile: URL { root.appendingPathComponent("gate.sh") }

  // MARK: - Installing

  func testInstallingKeepsThePersonsOwnHooks() throws {
    try FileManager.default.createDirectory(
      at: hooksFile.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try #"{"lint": {"PostToolUse": []}}"#.write(to: hooksFile, atomically: true, encoding: .utf8)

    try AntigravityPermissionGate.install(hooksFile: hooksFile, scriptFile: scriptFile)
    let hooks = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: hooksFile)) as? [String: Any]
    )
    XCTAssertNotNil(hooks["lint"], "someone else's hook stays")
    let gate = try XCTUnwrap(hooks[AntigravityPermissionGate.hookName] as? [String: Any])
    let group = try XCTUnwrap((gate["PreToolUse"] as? [[String: Any]])?.first)
    let handler = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
    XCTAssertEqual(group["matcher"] as? String, "*")
    XCTAssertEqual(handler["timeout"] as? Int, AntigravityPermissionGate.hookTimeout)
    XCTAssertTrue((handler["command"] as? String)?.contains(scriptFile.path) == true)
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptFile.path))

    let before = try Data(contentsOf: hooksFile)
    try AntigravityPermissionGate.install(hooksFile: hooksFile, scriptFile: scriptFile)
    XCTAssertEqual(try Data(contentsOf: hooksFile), before, "installing twice changes nothing")
  }

  func testAHooksFileThatIsNotPlainJSONIsLeftAlone() throws {
    try FileManager.default.createDirectory(
      at: hooksFile.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let commented = "{ // the person's comment\n}"
    try commented.write(to: hooksFile, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(
      try AntigravityPermissionGate.install(hooksFile: hooksFile, scriptFile: scriptFile)
    )
    XCTAssertEqual(try String(contentsOf: hooksFile, encoding: .utf8), commented)
  }

  // MARK: - The script

  /// Outside Boltty the hook answers `ask`, which leaves agy to its rules.
  func testOutsideBolttyTheHookHasNoOpinion() throws {
    try AntigravityPermissionGate.install(hooksFile: hooksFile, scriptFile: scriptFile)
    let result = try runScript(environment: [:], input: #"{"toolCall":{"name":"view_file"}}"#)
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), #"{"decision":"ask"}"#)
  }

  func testTheScriptHandsTheCallToBolttyAndPrintsItsAnswer() async throws {
    try AntigravityPermissionGate.install(hooksFile: hooksFile, scriptFile: scriptFile)
    let gate = AntigravityPermissionGate(directory: root.appendingPathComponent("gate"))
    let asked = expectation(description: "Boltty is asked")
    let seen = Box<AntigravityPermissionGate.Request>()
    gate.onRequest = { request in
      seen.value = request
      gate.answer(request.id, decision: "deny", reason: "no")
      asked.fulfill()
    }
    try gate.start()
    defer { gate.stop() }

    let input = #"{"conversationId":"c1","workspacePaths":["/w"],"toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}"#
    let script = scriptFile
    let folder = gate.directory.path
    let run = Task.detached {
      try Self.run(script, environment: [AntigravityPermissionGate.environmentKey: folder], input: input)
    }
    await fulfillment(of: [asked], timeout: 10)
    let result = try await run.value
    XCTAssertEqual(result.status, 0)
    let answer = JSONObject(line: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    XCTAssertEqual(answer?.string("decision"), "deny", result.output)
    XCTAssertEqual(answer?.string("reason"), "no")
    XCTAssertEqual(seen.value?.conversationID, "c1")
    XCTAssertEqual(seen.value?.tool, "run_command")
    XCTAssertEqual(seen.value?.arguments.string("CommandLine"), "ls")
    XCTAssertEqual(seen.value?.workspace, "/w")
  }

  /// With Boltty gone the folder goes, and the hook fails — which blocks the
  /// call (measured: a failed hook is a refusal; only empty exit 0 lets through).
  func testTheScriptFailsWhenBolttyIsGone() async throws {
    try AntigravityPermissionGate.install(hooksFile: hooksFile, scriptFile: scriptFile)
    let folder = root.appendingPathComponent("gone")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let script = scriptFile
    let path = folder.path
    let run = Task.detached {
      try Self.run(script, environment: [AntigravityPermissionGate.environmentKey: path], input: "{}")
    }
    try await Task.sleep(for: .milliseconds(400))
    try FileManager.default.removeItem(at: folder)
    let result = try await run.value
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.output.isEmpty)
  }

  // MARK: - What asks

  func testReadsInsideTheFolderGoQuietlyAndTheRestAsks() {
    func verdict(
      _ tool: String, _ args: [String: Any], auto: Bool = false, granted: Set<String> = []
    ) -> AntigravityToolPolicy.Verdict {
      AntigravityToolPolicy.verdict(
        tool: tool, arguments: JSONObject(args), directory: "/work/app",
        autoApprove: auto, granted: granted
      )
    }
    XCTAssertEqual(verdict("view_file", ["AbsolutePath": "/work/app/README.md"]), .allow)
    XCTAssertEqual(
      verdict("view_file", ["AbsolutePath": "/Users/me/.ssh/id_rsa"]),
      .ask(action: "read", resources: ["/Users/me/.ssh/id_rsa"], always: "read:/Users/me/.ssh/id_rsa")
    )
    XCTAssertEqual(
      verdict("run_command", ["CommandLine": "npm test", "Cwd": "/work/app"]),
      .ask(action: "command", resources: ["npm test"], always: "command:npm test")
    )
    XCTAssertEqual(
      verdict("run_command", ["CommandLine": "npm test"], auto: true),
      .ask(action: "command", resources: ["npm test"], always: "command:npm test"),
      "Auto Mode is edits only"
    )
    XCTAssertEqual(
      verdict("run_command", ["CommandLine": "npm test"], granted: ["command:npm test"]), .allow
    )
    XCTAssertEqual(verdict("write_to_file", ["TargetFile": "/work/app/a.txt"], auto: true), .allow)
    XCTAssertEqual(
      verdict("write_to_file", ["TargetFile": "/etc/hosts"], auto: true),
      .ask(action: "edit", resources: ["/etc/hosts"], always: "edit"),
      "Auto Mode stops at the folder"
    )
    XCTAssertEqual(
      verdict("brand_new_tool", [:]),
      .ask(action: "brand_new_tool", resources: [], always: "brand_new_tool"),
      "what Boltty does not know asks"
    )
  }

  // MARK: - Helpers

  private final class Box<Value>: @unchecked Sendable { var value: Value? }

  private func runScript(
    environment: [String: String], input: String
  ) throws -> (status: Int32, output: String) {
    try Self.run(scriptFile, environment: environment, input: input)
  }

  private static func run(
    _ scriptFile: URL, environment: [String: String], input: String
  ) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [scriptFile.path]
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: AntigravityPermissionGate.environmentKey)
    env.merge(environment) { $1 }
    process.environment = env
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    try process.run()
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try stdin.fileHandleForWriting.close()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}
