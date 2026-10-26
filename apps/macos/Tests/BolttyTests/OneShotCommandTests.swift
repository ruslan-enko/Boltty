import XCTest
@testable import Boltty

final class OneShotCommandTests: XCTestCase {
  func testItAnswersWithTheOutputAndTheExitCode() async {
    let answer = await OneShotCommand.run("/bin/sh", ["-c", "echo 1.2.3; exit 3"], deadline: 5)
    XCTAssertEqual(answer, OneShotCommand.Result(exitCode: 3, output: "1.2.3\n"))
  }

  func testStandardErrorIsLeftOutUnlessAsked() async {
    let script = ["-c", "echo out; echo err >&2"]
    let quiet = await OneShotCommand.run("/bin/sh", script, deadline: 5)
    let both = await OneShotCommand.run("/bin/sh", script, deadline: 5, includeStandardError: true)
    XCTAssertEqual(quiet?.output, "out\n")
    XCTAssertEqual(both?.output.contains("err"), true)
  }

  func testACommandThatNeverExitsEndsAtItsDeadline() async {
    let started = Date()
    let answer = await OneShotCommand.run("/bin/sleep", ["30"], deadline: 0.5)
    XCTAssertNil(answer)
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)
  }

  func testAChildHoldingThePipeDoesNotHoldTheAnswer() async {
    let started = Date()
    let answer = await OneShotCommand.run(
      "/bin/sh", ["-c", "/bin/sleep 30 & echo hi"], deadline: 10
    )
    XCTAssertEqual(answer?.output, "hi\n")
    XCTAssertEqual(answer?.exitCode, 0)
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)
  }

  func testTheBlockingFormIsBoundedToo() {
    XCTAssertEqual(
      OneShotCommand.runBlocking("/bin/echo", ["ok"], deadline: 5)?.output, "ok\n"
    )
    let started = Date()
    XCTAssertNil(OneShotCommand.runBlocking("/bin/sleep", ["30"], deadline: 0.5))
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)
  }

  func testAMissingExecutableIsNoAnswer() async {
    let answer = await OneShotCommand.run("/nonexistent/cli", ["--version"], deadline: 5)
    XCTAssertNil(answer)
  }
}
