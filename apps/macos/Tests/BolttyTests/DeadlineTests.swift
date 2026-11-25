import XCTest
@testable import Boltty

final class DeadlineTests: XCTestCase {
  func testWhatComesInTimeIsTaken() async {
    let value = await Deadline.value(of: Task { 7 }, within: 5)
    XCTAssertEqual(value, 7)
  }

  func testWhatDoesNotComeIsGoneOnWithout() async {
    let slow = Task { () -> Int in
      try? await Task.sleep(for: .seconds(30))
      return 7
    }
    let start = Date()
    let value = await Deadline.value(of: slow, within: 0.05)
    XCTAssertNil(value)
    XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    slow.cancel()
  }
}
