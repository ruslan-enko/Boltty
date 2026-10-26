import AppKit
import XCTest
@testable import Boltty

@MainActor
final class VoiceEdgeGlowTests: XCTestCase {
  func testSilenceStillHasAnIdleFloor() {
    let level = VoiceEdgeGlowLayout.intensity(level: 0, idle: 0.18, breathe: 1)
    XCTAssertEqual(level, 0.18, accuracy: 0.0001)
    XCTAssertGreaterThan(level, 0)
  }

  func testBreathFillsInOnlyTheGapToIdle() {
    let still = VoiceEdgeGlowLayout.intensity(level: 0, idle: 0.18, breathe: 0.5)
    let peak = VoiceEdgeGlowLayout.intensity(level: 0, idle: 0.18, breathe: 1)
    XCTAssertGreaterThan(peak, still)
    XCTAssertEqual(peak, 0.18, accuracy: 0.0001)
    XCTAssertEqual(still, 0.09, accuracy: 0.0001)

    let loud = VoiceEdgeGlowLayout.intensity(level: 1, idle: 0.18, breathe: 0.5)
    XCTAssertEqual(loud, 1, accuracy: 0.0001)
  }

  func testTheRaysTakeTheMascotsWholePalette() {
    let colors = VoiceEdgeGlowLayout.rayColors(from: .standard)
    XCTAssertEqual(colors.count, MascotPalette.standard.colors.count)
    XCTAssertEqual(colors.count, VoiceGlowRenderer.colorCount, "one stop for each the shader walks")
  }

  func testADarkStopIsLiftedSoTheGlassDoesNotTurnItToMud() {
    let lilac = MascotPalette.palette(withID: "slate")!
    let raw = lilac.colors.last!.usingColorSpace(.sRGB)!
    let lifted = VoiceEdgeGlowLayout.rayColors(from: lilac).last!.usingColorSpace(.sRGB)!
    func luma(_ c: NSColor) -> CGFloat {
      0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
    XCTAssertGreaterThan(luma(lifted), luma(raw))
  }

  func testTheRaysQuickenWithTheVoiceAndSilenceStillDrifts() {
    let silent = VoiceEdgeGlowLayout.flowSpeed(level: 0, processing: 0)
    let loud = VoiceEdgeGlowLayout.flowSpeed(level: 1, processing: 0)
    XCTAssertGreaterThan(silent, 0, "a quiet room still moves")
    XCTAssertGreaterThan(loud, silent * 3, "and a word sets it running")
    XCTAssertEqual(
      VoiceEdgeGlowLayout.flowSpeed(level: 0.3, processing: 1),
      AgentPaletteMetrics.voiceGlowFlowProcessing,
      accuracy: 0.0001,
      "processing holds its own pace, whatever the microphone says"
    )
  }

  func testTheRaysStartUnderTheShellInSilenceAndClimbIntoItWithTheVoice() {
    let size = CGSize(width: 200, height: 74.5)
    func origin(_ level: CGFloat) -> CGPoint {
      VoiceEdgeGlowLayout.rayOrigin(
        size: size, intensity: level, beam: 0, clock: 0, reduceMotion: true
      )
    }
    XCTAssertLessThan(origin(0).y, 0, "lit from under, as it always was")
    XCTAssertGreaterThan(origin(1).y, origin(0).y)
    XCTAssertGreaterThan(origin(1).y, 0, "a loud word puts the hot centre in the capsule")
    XCTAssertEqual(origin(0.5).x, size.width / 2, accuracy: 0.001, "and holds still without motion")
  }

  func testTheOriginSwaysFurtherTheLouderItIs() {
    let size = CGSize(width: 200, height: 74.5)
    func shift(_ level: CGFloat) -> CGFloat {
      abs(
        VoiceEdgeGlowLayout.rayOrigin(
          size: size, intensity: level, beam: 0, clock: 1, reduceMotion: false
        ).x - size.width / 2
      )
    }
    XCTAssertGreaterThan(shift(0), 0)
    XCTAssertGreaterThan(shift(1), shift(0))
  }

  func testProcessingGathersTheOriginToTheMiddleOfTheShell() {
    let size = CGSize(width: 200, height: 74.5)
    let origin = VoiceEdgeGlowLayout.rayOrigin(
      size: size, intensity: 0.74, beam: 1, clock: 1.3, reduceMotion: false
    )
    XCTAssertEqual(origin.x, size.width / 2, accuracy: 0.001)
    XCTAssertEqual(origin.y, size.height / 2, accuracy: 0.001)
  }

  func testATallShellIsLitFromItsFootOnly() {
    let capsule = CGSize(width: 200, height: VoiceEdgeGlowLayout.authoredHeight)
    XCTAssertEqual(VoiceEdgeGlowLayout.reach(size: capsule, intensity: 1), capsule.height)

    let chat = CGSize(width: 584, height: 680)
    let quiet = VoiceEdgeGlowLayout.reach(size: chat, intensity: 0.2)
    let loud = VoiceEdgeGlowLayout.reach(size: chat, intensity: 1)
    XCTAssertGreaterThan(loud, quiet)
    XCTAssertLessThan(loud, chat.height * 0.3, "a foot, not the transcript")
  }

  func testTheOrbFillsTheShellOnlyWhenTheTakeCollapsesIt() {
    let glow = VoiceEdgeGlowView(frame: CGRect(x: 0, y: 0, width: 540, height: 84))
    glow.setListening(true)
    glow.layoutSubtreeIfNeeded()
    XCTAssertEqual(glow.uniformsForTesting.orb, 0, "a composer beside its chat is lit from its foot")
    glow.fillsShell = true
    XCTAssertEqual(
      glow.uniformsForTesting.orb, 1,
      "a capsule as long as the prompt is still the orb's, grown round its words"
    )

    let origin = VoiceEdgeGlowLayout.rayOrigin(
      size: CGSize(width: 84, height: 84), intensity: 0.2, beam: 0, clock: 1, orb: 1, reduceMotion: false
    )
    XCTAssertEqual(origin.x, 42, accuracy: 0.001, "the orb's rays come from its centre")
    XCTAssertEqual(origin.y, 42, accuracy: 0.001)
  }

  func testTheOrbsSurfaceIsDrawnOnlyForTheOrbAndTakesNoClicks() {
    let glow = VoiceEdgeGlowView(frame: CGRect(x: 0, y: 0, width: 84, height: 84))
    glow.surfaceCornerRadius = 42
    glow.fillsShell = true
    glow.setListening(true)
    glow.layoutSubtreeIfNeeded()
    XCTAssertEqual(glow.uniformsForTesting.orb, 1, accuracy: 0.001)
    XCTAssertEqual(glow.uniformsForTesting.layer, 0, "the glow is the layer under the glass")
    XCTAssertNil(glow.sheen.hitTest(NSPoint(x: 42, y: 42)))

    glow.sheen.show(VoiceGlowRenderer.uniforms(for: .init(
      size: CGSize(width: 520, height: 74.5), pixelSize: 0.5, cornerRadius: 37.25,
      cornerIsContinuous: true, intensity: 0.5, beam: 0, clock: 0, opacity: 1,
      isLightAppearance: false, reduceMotion: false, colors: [.white]
    )))
    XCTAssertFalse(glow.sheen.isShowingForTesting, "the rays have no surface of their own")
    glow.sheen.show(nil)
    XCTAssertFalse(glow.sheen.isShowingForTesting)
  }

  func testTheViewIsDecorative() {
    let glow = VoiceEdgeGlowView(frame: CGRect(x: 0, y: 0, width: 520, height: 74.5))
    glow.layoutSubtreeIfNeeded()

    XCTAssertNil(glow.hitTest(NSPoint(x: 260, y: 8)))
    XCTAssertTrue(glow.avoidsOffscreenPassForTesting)
    XCTAssertFalse(glow.isListeningForTesting)
    XCTAssertTrue(glow.isHidden)
  }

  func testListeningLightsTheMascotsColours() {
    let glow = VoiceEdgeGlowView(frame: CGRect(x: 0, y: 0, width: 520, height: 74.5))
    glow.surfaceCornerRadius = 37.25
    glow.apply(palette: .standard)
    glow.setListening(true)
    glow.layoutSubtreeIfNeeded()

    XCTAssertTrue(glow.isListeningForTesting)
    XCTAssertFalse(glow.isHidden)
    XCTAssertEqual(glow.rayColorsForTesting.count, VoiceGlowRenderer.colorCount)
    XCTAssertEqual(glow.paletteIDForTesting, MascotPalette.standard.id)
    XCTAssertTrue(glow.avoidsOffscreenPassForTesting)
    let lifted = VoiceEdgeGlowLayout.rayColors(from: .standard)
    assertColor(glow.rayColorsForTesting[0], matches: lifted[0])
    assertColor(glow.rayColorsForTesting[5], matches: lifted[5])
  }

  func testADifferentMascotRecoloursTheGlow() {
    let glow = VoiceEdgeGlowView(frame: CGRect(x: 0, y: 0, width: 520, height: 74.5))
    glow.setListening(true)
    glow.apply(palette: MascotPalette.palette(withID: "ember")!)
    glow.layoutSubtreeIfNeeded()

    XCTAssertEqual(glow.paletteIDForTesting, "ember")
    let ember = VoiceEdgeGlowLayout.rayColors(from: MascotPalette.palette(withID: "ember")!)
    assertColor(glow.rayColorsForTesting[0], matches: ember[0])
  }

  func testTheLevelFallsSlowerThanItRises() {
    let glow = VoiceEdgeGlowView(frame: CGRect(x: 0, y: 0, width: 520, height: 74.5))
    glow.setListening(true)
    glow.setAudioLevel(1)
    let afterOneLoudReading = glow.smoothedLevelForTesting
    glow.setAudioLevel(0)
    let afterOneSilentReading = glow.smoothedLevelForTesting

    XCTAssertGreaterThan(afterOneLoudReading, 0.15, "a consonant should lift it")
    XCTAssertGreaterThan(
      afterOneSilentReading,
      afterOneLoudReading * 0.5,
      "one quiet buffer must not extinguish it"
    )
  }

  func testStoppingPutsTheGlowOut() {
    let glow = VoiceEdgeGlowView(frame: CGRect(x: 0, y: 0, width: 520, height: 74.5))
    glow.setListening(true)
    glow.setAudioLevel(1)
    glow.setListening(false)

    XCTAssertFalse(glow.isListeningForTesting)
    XCTAssertEqual(glow.smoothedLevelForTesting, 0)
    XCTAssertEqual(glow.displayedLevelForTesting, 0)
  }

  private func assertColor(
    _ actual: NSColor,
    matches expected: NSColor,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let a = actual.usingColorSpace(.sRGB) ?? actual
    let e = expected.usingColorSpace(.sRGB) ?? expected
    XCTAssertEqual(a.redComponent, e.redComponent, accuracy: 0.02, file: file, line: line)
    XCTAssertEqual(a.greenComponent, e.greenComponent, accuracy: 0.02, file: file, line: line)
    XCTAssertEqual(a.blueComponent, e.blueComponent, accuracy: 0.02, file: file, line: line)
  }
}
