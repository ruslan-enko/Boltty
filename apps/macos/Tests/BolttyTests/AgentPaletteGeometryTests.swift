import XCTest
@testable import Boltty

final class AgentPaletteGeometryTests: XCTestCase {
  func testIdleCapsuleUsesTheWideReferenceProportion() {
    XCTAssertEqual(AgentPaletteMetrics.promptSize, CGSize(width: 540, height: 85))
    XCTAssertEqual(
      AgentPaletteMetrics.promptSize.width - 20,
      AgentPaletteMetrics.fromMock(388.449),
      accuracy: 2.5
    )
    XCTAssertEqual(AgentPaletteMetrics.promptMockHeight, 74.5)
    XCTAssertEqual(
      AgentPaletteMetrics.promptMockHeight,
      AgentPaletteMetrics.fromMock(56),
      accuracy: 0.25
    )
  }

  func testPanelSizeWrapsThePromptAndItsShadowBleed() {
    let size = AgentPaletteMetrics.panelSize(extraHeight: 18)

    XCTAssertEqual(size.width, AgentPaletteMetrics.promptSize.width + AgentPaletteMetrics.safeAreaX * 2)
    XCTAssertEqual(
      size.height,
      AgentPaletteMetrics.promptSize.height + 18 + AgentPaletteMetrics.safeAreaY * 2
    )
  }
}
