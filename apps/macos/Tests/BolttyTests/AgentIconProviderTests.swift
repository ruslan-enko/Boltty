import AppKit
import XCTest
@testable import Boltty

@MainActor
final class AgentIconProviderTests: XCTestCase {
  func testImageIsTemplateForEveryAgent() {
    for agent in AgentId.allCases {
      let image = AgentIconProvider.image(for: agent)
      XCTAssertTrue(image.isTemplate, "isTemplate should be true for \(agent.rawValue)")
    }
  }

  func testSameAgentReturnsCachedInstance() {
    let first = AgentIconProvider.image(for: .claude)
    let second = AgentIconProvider.image(for: .claude)
    XCTAssertTrue(first === second)
  }

  func testDifferentAgentsReturnDistinctInstances() {
    let claude = AgentIconProvider.image(for: .claude)
    let codex = AgentIconProvider.image(for: .codex)
    XCTAssertFalse(claude === codex)
  }

  func testCustomAgentReturnsTemplateImage() {
    let image = AgentIconProvider.image(for: .custom)
    XCTAssertTrue(image.isTemplate)
  }

  func testBundledAgentArtworkReturnsTemplateImage() {
    let image = AgentIconProvider.image(for: .opencode, bundle: .main)
    XCTAssertTrue(image.isTemplate)
  }

  func testEveryDiscoverableAgentShipsItsOwnArtwork() {
    for agent in AgentId.discoverableCases {
      XCTAssertNotNil(
        Bundle.main.url(
          forResource: agent.iconAssetName,
          withExtension: "svg",
          subdirectory: "AgentIcons"
        ),
        "missing AgentIcons/\(agent.iconAssetName).svg for \(agent.displayName)"
      )
    }
  }

  func testShippedArtworkDoesNotFillItsCanvas() {
    let raw = AgentIconProvider.image(for: .claude)
    guard let bounds = AgentIconProvider.inkBounds(of: raw) else {
      return XCTFail("no ink in the Claude mark")
    }
    XCTAssertLessThan(bounds.width, 0.9, "canvas is not the mark")
    XCTAssertLessThan(bounds.height, 0.9)
  }

  func testTrimmedArtworkReachesItsOwnEdges() {
    for agent in AgentId.discoverableCases {
      let trimmed = AgentIconProvider.trimmedImage(for: agent)
      guard let bounds = AgentIconProvider.inkBounds(of: trimmed) else {
        return XCTFail("no ink in \(agent.rawValue) after trimming")
      }
      XCTAssertGreaterThan(bounds.width, 0.97, "\(agent.rawValue) width \(bounds.width)")
      XCTAssertGreaterThan(bounds.height, 0.97, "\(agent.rawValue) height \(bounds.height)")
    }
  }

  func testTrimmingKeepsTheImageATemplate() {
    XCTAssertTrue(AgentIconProvider.trimmedImage(for: .opencode).isTemplate)
  }

  func testUnavailableNewSymbolUsesAnOlderSystemFallback() {
    let image = BolttySFSymbolImage.make(
      name: "boltty.symbol.that.does.not.exist",
      fallbackName: "sparkles"
    )

    XCTAssertTrue(image.isTemplate)
    XCTAssertNotNil(image.symbolConfiguration)
  }
}
