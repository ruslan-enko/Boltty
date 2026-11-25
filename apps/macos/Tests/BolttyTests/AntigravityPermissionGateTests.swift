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
      verdict("run_command", ["CommandLine": "npm test", "Cwd": "/work/app"], auto: true),
      .allow,
      "Auto Mode lets a test run in the folder through"
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

final class AutoModeCommandsTests: XCTestCase {
  private var folder: String!
  private var home: String!

  override func setUpWithError() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("automode-\(UUID().uuidString)", isDirectory: true)
    home = root.path
    folder = root.appendingPathComponent("project").path
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(atPath: home)
  }

  private func allows(_ line: String) -> Bool {
    AutoModeCommands.allows(line, in: folder, autoMode: true, home: home)
  }

  func testBuildingAndTestingStillGoThrough() {
    XCTAssertTrue(allows("ls -la"))
    XCTAssertTrue(allows("npm test"))
    XCTAssertTrue(allows("npm run test:unit"))
    XCTAssertTrue(allows("python3 -m pytest"))
    XCTAssertTrue(allows("echo hi > notes.txt"))
    XCTAssertTrue(allows("git status && git diff"))
  }

  func testAScriptRunByItselfAsks() {
    XCTAssertFalse(allows("./run.sh"))
    XCTAssertFalse(allows("sh run.sh"))
    XCTAssertFalse(allows("python3 tool.py"))
    XCTAssertFalse(allows("node tool.js"))
    XCTAssertFalse(allows("bun tool.ts"))
    XCTAssertFalse(allows("npm run fetch-data"))
  }

  func testGitThatRunsAProgramAsks() {
    XCTAssertFalse(allows("git grep -O'touch x' needle"))
    XCTAssertFalse(allows("git grep --open-files-in-pager=sh needle"))
    XCTAssertFalse(allows("git fetch --upload-pack='touch x' ../repo"))
    XCTAssertFalse(allows("git diff --ext-diff"))
  }

  func testALinkOutOfTheFolderIsNotTheFolder() throws {
    let outside = (home as NSString).appendingPathComponent(".zshrc")
    FileManager.default.createFile(atPath: outside, contents: Data())
    try FileManager.default.createSymbolicLink(
      atPath: (folder as NSString).appendingPathComponent("rc"), withDestinationPath: outside)
    XCTAssertFalse(allows("echo x >> rc"))
    XCTAssertFalse(allows("ln -s ~/.zshrc other"))
    XCTAssertFalse(AutoModeCommands.isEditable("rc", in: folder, home: home))
    XCTAssertTrue(AutoModeCommands.isEditable("main.swift", in: folder, home: home))
  }

  func testALinkToNowhereIsRefused() throws {
    try FileManager.default.createSymbolicLink(
      atPath: (folder as NSString).appendingPathComponent("dangling"),
      withDestinationPath: (home as NSString).appendingPathComponent("not-yet"))
    XCTAssertFalse(allows("echo x > dangling"))
  }

  func testASecretLinkedIntoDotfilesIsStillASecret() throws {
    let dotfiles = (home as NSString).appendingPathComponent("dotfiles/ssh")
    try FileManager.default.createDirectory(atPath: dotfiles, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: (dotfiles as NSString).appendingPathComponent("id_ed25519"), contents: Data())
    try FileManager.default.createSymbolicLink(
      atPath: (home as NSString).appendingPathComponent(".ssh"), withDestinationPath: dotfiles)
    XCTAssertFalse(allows("cat ~/.ssh/id_ed25519"))
  }

  func testInHomeALinkedDotfileIsStillADotfile() throws {
    let target = (home as NSString).appendingPathComponent("dotfiles/zshrc")
    try FileManager.default.createDirectory(
      atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: target, contents: Data())
    try FileManager.default.createSymbolicLink(
      atPath: (home as NSString).appendingPathComponent(".zshrc"), withDestinationPath: target)
    XCTAssertFalse(AutoModeCommands.allows("echo x >> ~/.zshrc", in: home, autoMode: true, home: home))
  }

  func testGitsOwnFolderIsNotEdited() {
    XCTAssertFalse(AutoModeCommands.isEditable(".git/hooks/pre-commit", in: folder, home: home))
  }

  func testCredentialsAreNotRead() {
    XCTAssertFalse(allows("cat ~/.git-credentials"))
    XCTAssertFalse(allows("printenv"))
    XCTAssertFalse(allows("env"))
  }
}
