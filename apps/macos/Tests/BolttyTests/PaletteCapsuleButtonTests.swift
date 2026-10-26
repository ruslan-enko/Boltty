import XCTest

@testable import Boltty

@MainActor
final class GlassPillButtonTests: XCTestCase {
  private func button(_ title: String = "Retry") -> GlassPillButton {
    let button = GlassPillButton.titled(title)
    button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
    button.layoutSubtreeIfNeeded()
    return button
  }

  func testItWearsTheFolderChipsLanguage() {
    let capsule = button()

    XCTAssertEqual(
      capsule.intrinsicContentSize.height,
      AgentPaletteMetrics.directoryChipHeight,
      accuracy: 0.01,
      "as tall as a chip, whatever the type would have made it"
    )
    XCTAssertEqual(capsule.button.restingTint, AgentPaletteMetrics.directoryChipTextColor)
  }

  func testItIsTheSystemsGlassCapsule() {
    let capsule = button("Restore unsent message")
    XCTAssertTrue(capsule.usesSystemGlassForTesting)
    XCTAssertTrue(capsule.isCapsuleForTesting)
    XCTAssertEqual(capsule.button.restingBackground, .clear)
    XCTAssertEqual(capsule.button.hoverBackground, .clear)
  }

  func testChangingTheWordKeepsTheFace() {
    let capsule = button("Show command")
    capsule.title = "Hide command"
    XCTAssertEqual(capsule.button.attributedTitle.string, "Hide command")
    XCTAssertEqual(
      capsule.button.attributedTitle.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont,
      roundedAppFont(size: AgentPaletteMetrics.directoryChipFontSize)
    )
  }
}
