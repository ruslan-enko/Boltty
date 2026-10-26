import Foundation
import XCTest
@testable import Boltty

final class ISO8601StampTests: XCTestCase {
  private func reference(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return fractional.date(from: value) ?? plain.date(from: value)
  }

  private func assertMatchesFoundation(
    _ value: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let expected = reference(value) else {
      return XCTFail("fixture \(value) is not a date Foundation reads", file: file, line: line)
    }
    guard let parsed = ISO8601Stamp.date(from: value) else {
      return XCTFail("\(value) was not read at all", file: file, line: line)
    }
    XCTAssertEqual(
      parsed.timeIntervalSince1970, expected.timeIntervalSince1970,
      accuracy: 0.0005, file: file, line: line
    )
  }

  func testTheShapeTheCLIsWriteMatchesFoundation() {
    for value in [
      "2026-09-21T09:15:42.123Z",
      "2026-09-21T09:15:42Z",
      "2026-01-01T00:00:00Z",
      "2026-12-31T23:59:59.999Z",
      "1970-01-01T00:00:00Z",
      "2000-02-29T12:00:00.500Z",
      "2024-02-29T23:59:59.001Z",
      "2026-03-01T00:00:00Z",
      "2026-06-30T12:34:56.7Z"
    ] {
      assertMatchesFoundation(value)
    }
  }

  func testEveryMonthBoundaryMatchesFoundation() {
    for year in [1999, 2000, 2023, 2024, 2100] {
      for month in 1...12 {
        assertMatchesFoundation(String(format: "%04d-%02d-01T00:00:00Z", year, month))
        assertMatchesFoundation(String(format: "%04d-%02d-28T23:59:59.999Z", year, month))
      }
    }
  }

  func testMicrosecondsAreKeptWhereFoundationTruncatesThem() throws {
    let stamp = "2026-09-11T08:25:32.646947Z"
    let whole = try XCTUnwrap(ISO8601Stamp.date(from: "2026-09-11T08:25:32Z"))
    let parsed = try XCTUnwrap(ISO8601Stamp.date(from: stamp))
    XCTAssertEqual(parsed.timeIntervalSince1970 - whole.timeIntervalSince1970,
                   0.646947, accuracy: 1e-6)
    let truncated = try XCTUnwrap(reference(stamp))
    XCTAssertEqual(truncated.timeIntervalSince1970 - whole.timeIntervalSince1970,
                   0.646, accuracy: 1e-6)
  }

  func testShapesTheScanDeclinesAreStillReadByFoundation() throws {
    for value in [
      "2026-09-21T09:15:42+03:00",   // an offset
      "2026-09-21T09:15:42-07:00",
      "2026-09-21T24:00:00Z",        // legal ISO 8601 end-of-day
      "2026-9-21T09:15:42Z",         // one-digit month
      "26-09-21T09:15:42Z",          // two-digit year — year 26, not 2026
      "2026-09-21T09:15:42ZZ"        // trailing junk Foundation shrugs at
    ] {
      let expected = try XCTUnwrap(reference(value), "fixture \(value) changed meaning")
      let parsed = try XCTUnwrap(ISO8601Stamp.date(from: value), value)
      XCTAssertEqual(parsed.timeIntervalSince1970, expected.timeIntervalSince1970,
                     accuracy: 0.0005, value)
    }
  }

  func testNonsenseIsRefusedByBothPaths() {
    for value in [
      "", "not a date", "2026-09-21", "2026-13-01T00:00:00Z", "2026-00-01T00:00:00Z",
      "2026-09-32T00:00:00Z", "2026-09-21T09:60:00Z", "2026-09-21T09:15:99Z",
      "2026-09-21 09:15:42Z", "2026-09-21T09:15:42", "ZZZZ"
    ] {
      XCTAssertNil(ISO8601Stamp.date(from: value), "\(value) was read as a date")
    }
  }

  func testAnEmptyFractionFallsThroughToTheWholeSecond() throws {
    XCTAssertEqual(
      try XCTUnwrap(ISO8601Stamp.date(from: "2026-09-21T09:15:42.Z")),
      try XCTUnwrap(ISO8601Stamp.date(from: "2026-09-21T09:15:42Z"))
    )
  }

  func testTheScanIsSubstantiallyFasterThanFoundationsReader() {
    let stamps = (0..<2_000).map { String(format: "2026-09-21T09:15:%02dZ", $0 % 60) }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    var sink = 0.0

    let scanStarted = Date()
    for stamp in stamps { sink += ISO8601Stamp.date(from: stamp)?.timeIntervalSince1970 ?? 0 }
    let scanned = Date().timeIntervalSince(scanStarted)

    let referenceStarted = Date()
    for stamp in stamps { sink += formatter.date(from: stamp)?.timeIntervalSince1970 ?? 0 }
    let reference = Date().timeIntervalSince(referenceStarted)

    XCTAssertGreaterThan(sink, 0)
    XCTAssertLessThan(
      scanned * 20, reference,
      "the scan took \(scanned)s against \(reference)s for Foundation's reader"
    )
  }
}
