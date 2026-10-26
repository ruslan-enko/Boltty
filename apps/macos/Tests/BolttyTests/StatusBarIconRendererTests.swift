import AppKit
import XCTest
@testable import Boltty

@MainActor
final class StatusBarIconRendererTests: XCTestCase {
  func testRendererUsesFixedSizeAndCorrectTemplateModes() {
    let idle = StatusBarIconRenderer.image(state: .idle)
    let attention = StatusBarIconRenderer.image(state: .attention)

    XCTAssertEqual(idle.size, NSSize(width: 20, height: 18))
    XCTAssertTrue(idle.isTemplate)
    XCTAssertTrue(attention.isTemplate)
    XCTAssertNotNil(attention.tiffRepresentation)
  }

  func testRobotFaceIconRendersNonEmptyImage() {
    let image = StatusBarIconRenderer.image(state: .idle)
    XCTAssertNotNil(image.tiffRepresentation)
    XCTAssertGreaterThan(image.size.width, 0)
    XCTAssertGreaterThan(image.size.height, 0)
  }
}
