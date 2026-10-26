import XCTest
@testable import Boltty

final class OpenCodeServerReaperTests: XCTestCase {
  private var ledger: URL!

  override func setUp() {
    super.setUp()
    ledger = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-ledger-\(UUID().uuidString).pid")
    OpenCodeServer.useLedgerForTesting(ledger)
  }

  override func tearDown() {
    OpenCodeServer.clearRecordedPIDForTesting()
    OpenCodeServer.useLedgerForTesting(nil)
    try? FileManager.default.removeItem(at: ledger)
    super.tearDown()
  }

  func testTheTestsNeverTouchTheAppsLedger() throws {
    let real = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
      .appendingPathComponent("Boltty/opencode-server.pid")
    let before = try? Data(contentsOf: real)
    OpenCodeServer.recordPIDForTesting(pid_t(99_999_995))
    OpenCodeServer.clearRecordedPIDForTesting()
    XCTAssertEqual(try? Data(contentsOf: real), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.path), "cleared the test's own")
  }

  func testARecordedPIDThatNowBelongsToSomebodyElseIsLeftAlone() async {
    let me = getpid()
    OpenCodeServer.recordPIDForTesting(me)

    let server = OpenCodeServer()
    await server.reapForTesting()

    XCTAssertEqual(kill(me, 0), 0, "the test host must still be running")
    XCTAssertNil(
      OpenCodeServer.recordedPIDForTesting(),
      "a pid that could not be claimed is dropped rather than retried forever"
    )
  }

  func testARecordedPIDThatNoLongerExistsIsDropped() async {
    let gone = pid_t(99_999_990)
    OpenCodeServer.recordPIDForTesting(gone)
    let server = OpenCodeServer()
    await server.reapForTesting()
    XCTAssertFalse(
      OpenCodeServer.recordedPIDsForTesting().contains(gone),
      "a pid that no longer exists is dropped from the ledger"
    )
  }

  func testEveryRecordedServerIsConsidered() async {
    for pid in [pid_t(99_999_990), pid_t(99_999_992), pid_t(99_999_993)] {
      OpenCodeServer.recordPIDForTesting(pid)
    }
    XCTAssertEqual(
      OpenCodeServer.recordedPIDsForTesting().count, 3,
      "recording appends; it does not overwrite the previous server"
    )

    let server = OpenCodeServer()
    await server.reapForTesting()

    XCTAssertTrue(
      OpenCodeServer.recordedPIDsForTesting().isEmpty,
      "every entry is handled in one pass, not just the last one written"
    )
  }

  func testAServerWhoseOwnerIsStillRunningIsLeftAlone() async throws {
    let owner = Process()
    owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
    owner.arguments = ["30"]
    try owner.run()
    defer { owner.terminate() }
    XCTAssertEqual(kill(owner.processIdentifier, 0), 0, "the stand-in owner is running")

    OpenCodeServer.recordPIDForTesting(pid_t(99_999_994), owner: owner.processIdentifier)

    let server = OpenCodeServer()
    await server.reapForTesting()

    XCTAssertEqual(
      OpenCodeServer.recordedPIDsForTesting(), [99_999_994],
      "an entry stays until the app that owns it is gone"
    )
  }

  func testNoRecordedPIDIsANoOp() async {
    OpenCodeServer.clearRecordedPIDForTesting()
    let server = OpenCodeServer()
    await server.reapForTesting()
    XCTAssertNil(OpenCodeServer.recordedPIDForTesting())
  }

  func testAServerThisProcessStartedIsNeverReapedAsAnOrphan() async {
    OpenCodeServer.recordOwnedPIDForTesting(getpid())
    let neighbour = OpenCodeServer()
    await neighbour.reapForTesting()
    XCTAssertEqual(
      OpenCodeServer.recordedPIDForTesting(),
      getpid(),
      "a server recorded by this process survives another instance's reap pass"
    )
  }
}

final class OpenCodeServiceTests: XCTestCase {
  private var state: URL!

  override func setUp() {
    super.setUp()
    state = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-service-\(UUID().uuidString).json")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: state)
    super.tearDown()
  }

  private func write(_ json: String) throws {
    try Data(json.utf8).write(to: state)
  }

  func testTheStateFileNamesTheServiceAndHowToSignIn() throws {
    try write(#"{"id":"x","version":"2.0.18","url":"http://127.0.0.1:49374","pid":\#(getpid()),"password":"secret"}"#)
    let service = try XCTUnwrap(OpenCodeServer.service(describedAt: state))
    XCTAssertEqual(service.baseURL.absoluteString, "http://127.0.0.1:49374")
    XCTAssertTrue(service.isService)
    XCTAssertEqual(service.authorizationHeader, "Basic " + Data("opencode:secret".utf8).base64EncodedString())
  }

  func testADeadServiceIsNotOne() throws {
    try write(#"{"url":"http://127.0.0.1:49374","pid":99999993,"password":"secret"}"#)
    XCTAssertNil(OpenCodeServer.service(describedAt: state), "its pid is gone")
  }

  func testOnlyLoopbackIsTrusted() throws {
    try write(#"{"url":"http://10.0.0.5:49374","password":"secret"}"#)
    XCTAssertNil(OpenCodeServer.service(describedAt: state))
  }

  func testNoFileIsNoService() {
    XCTAssertNil(OpenCodeServer.service(describedAt: state))
  }

  func testAServiceThatDoesNotAnswerFallsBackToBolttysOwn() async throws {
    try write(#"{"url":"http://127.0.0.1:9","pid":\#(getpid()),"password":"secret"}"#)
    let server = OpenCodeServer(serviceState: state)
    guard (await server.locateExecutable()) != nil else { throw XCTSkip("opencode is not installed") }
    let endpoint = try await server.start()
    let usingService = await server.isUsingServiceForTesting
    await server.stop()
    XCTAssertFalse(endpoint.isService)
    XCTAssertFalse(usingService)
    XCTAssertNotEqual(endpoint.baseURL.port, 9, "not the address the dead service named")
  }

  private func fakeCLI(_ script: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-catalogue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let cli = directory.appendingPathComponent("opencode")
    try Data("#!/bin/sh\n\(script)\n".utf8).write(to: cli)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    return cli
  }

  private static let leaveAChild = "sleep 30 &\necho $! > \"$(dirname \"$0\")/child.pid\""

  private func endChild(of cli: URL) {
    let file = cli.deletingLastPathComponent().appendingPathComponent("child.pid")
    addTeardownBlock {
      guard let text = try? String(contentsOf: file, encoding: .utf8),
            let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
      else { return }
      kill(pid, SIGKILL)
    }
  }

  private func catalogueServer(running cli: URL, deadline: TimeInterval) -> OpenCodeServer {
    OpenCodeServer(executableCandidates: [cli.path], catalogueDeadline: deadline, serviceState: nil)
  }

  func testAModelListThatNeverExitsIsEndedAtItsDeadline() async throws {
    let server = catalogueServer(running: try fakeCLI("exec sleep 30"), deadline: 0.3)

    let started = Date()
    let lines = await server.modelLines()

    XCTAssertEqual(lines, [])
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the CLI was waited for past its deadline")
  }

  func testTheDeadlineHoldsWhenSomethingTheCLIStartedKeepsItsPipe() async throws {
    let cli = try fakeCLI("\(Self.leaveAChild)\nwait")
    endChild(of: cli)
    let server = catalogueServer(running: cli, deadline: 0.3)

    let started = Date()
    let lines = await server.modelLines()

    XCTAssertEqual(lines, [])
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the read waited for the CLI's child")
  }

  func testACLIThatExitedIsAnsweredThoughItsChildHoldsThePipe() async throws {
    let cli = try fakeCLI("echo opencode/big-pickle\n\(Self.leaveAChild)")
    endChild(of: cli)
    let server = catalogueServer(running: cli, deadline: 20)

    let started = Date()
    let lines = await server.modelLines()

    XCTAssertEqual(lines, ["opencode/big-pickle"])
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the read waited for the CLI's child")
  }

  func testTheCatalogueIsWhatTheCLIPrintedAndNothingWhenItFails() async throws {
    let printing = catalogueServer(
      running: try fakeCLI("printf 'opencode/big-pickle\\nopenai/gpt-5\\n'"), deadline: 20
    )
    let lines = await printing.modelLines()
    XCTAssertEqual(lines, ["opencode/big-pickle", "openai/gpt-5"])

    let failing = catalogueServer(running: try fakeCLI("echo opencode/big-pickle\nexit 1"), deadline: 20)
    let nothing = await failing.modelLines()
    XCTAssertEqual(nothing, [])
  }

  func testTheVersionIsReadAndEndedAtTheDeadline() async throws {
    let answering = catalogueServer(running: try fakeCLI("echo 2.0.24"), deadline: 20)
    let version = await answering.version()
    XCTAssertEqual(version, "2.0.24")

    let silent = catalogueServer(running: try fakeCLI("exec sleep 30"), deadline: 0.3)
    let started = Date()
    let none = await silent.version()
    XCTAssertNil(none)
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the CLI was waited for past its deadline")
  }

  func testTheRunningServiceIsUsedAndLeftRunning() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["BOLTTY_LIVE_AGENTS"] == "1")
    guard let described = OpenCodeServer.service(describedAt: OpenCodeServer.defaultServiceState),
          let pid = try? JSONObject(line: Data(contentsOf: OpenCodeServer.defaultServiceState))?.int("pid")
    else { throw XCTSkip("no OpenCode background service is running") }
    let server = OpenCodeServer()
    let endpoint = try await server.start()
    XCTAssertTrue(endpoint.isService)
    XCTAssertEqual(endpoint.baseURL, described.baseURL)
    await server.stop()
    XCTAssertEqual(kill(pid_t(pid), 0), 0, "the user's service is still running")
  }
}
