import AppKit
import XCTest
@testable import Boltty

@MainActor
final class VoiceGlowPipelineTests: XCTestCase {
  private let surface = CGSize(width: 520, height: 74.5)

  // MARK: - The envelope

  func testTheGateDropsRoomToneAndKeepsSpeech() {
    let envelope = VoiceLevelEnvelope()
    XCTAssertEqual(envelope.gated(0), 0)
    XCTAssertEqual(envelope.gated(0.03), 0, "a fan sits here and must not light the shell")
    XCTAssertGreaterThan(envelope.gated(0.6), 0.5, "speech passes essentially untouched")
  }

  func testTheGateHasAKneeRatherThanACliff() {
    let envelope = VoiceLevelEnvelope()
    let justInside = envelope.gated(AgentPaletteMetrics.voiceGlowGate + 0.001)
    let midKnee = envelope.gated(
      AgentPaletteMetrics.voiceGlowGate + AgentPaletteMetrics.voiceGlowGateKnee / 2
    )
    let past = envelope.gated(
      AgentPaletteMetrics.voiceGlowGate + AgentPaletteMetrics.voiceGlowGateKnee + 0.01
    )
    XCTAssertLessThan(justInside, midKnee)
    XCTAssertLessThan(midKnee, past)
    XCTAssertGreaterThan(justInside, 0, "the knee opens gradually, it does not snap")
  }

  func testTheEnvelopeRisesFastAndFallsSlowly() {
    var rising = VoiceLevelEnvelope()
    rising.accept(1, dt: 0.1)
    let afterALoudTenth = rising.level

    var falling = VoiceLevelEnvelope()
    falling.settle(at: 1)
    falling.accept(0, dt: 0.1)
    let keptAfterASilentTenth = falling.level

    XCTAssertGreaterThan(afterALoudTenth, 0.2, "a consonant lights it at once")
    XCTAssertGreaterThan(keptAfterASilentTenth, 0.85, "the gap between words is not silence")
  }

  func testTheEnvelopeIsFrameRateIndependent() {
    var coarse = VoiceLevelEnvelope()
    coarse.accept(1, dt: 0.2)

    var fine = VoiceLevelEnvelope()
    for _ in 0..<20 { fine.accept(1, dt: 0.01) }

    XCTAssertEqual(coarse.level, fine.level, accuracy: 0.01)
  }

  // MARK: - The phases

  func testOnlyListeningAndProcessingHoldAClock() {
    XCTAssertTrue(VoiceGlowPhase.listening.isAnimating)
    XCTAssertTrue(VoiceGlowPhase.processing.isAnimating)
    for phase in [VoiceGlowPhase.idle, .completed, .cancelled, .failed] {
      XCTAssertFalse(phase.isAnimating, "\(phase) must not keep a display link")
      XCTAssertTrue(phase.releasesFrames)
    }
  }

  func testACompletedTakeLeavesSlowerThanACancelledOne() {
    XCTAssertGreaterThan(
      VoiceGlowPhase.completed.fadeDuration,
      VoiceGlowPhase.cancelled.fadeDuration
    )
    XCTAssertEqual(
      VoiceGlowPhase.failed.fadeDuration,
      VoiceGlowPhase.cancelled.fadeDuration
    )
    XCTAssertGreaterThan(VoiceGlowPhase.cancelled.fadeDuration, 0, "a blink reads as a glitch")
  }

  func testOnlyProcessingAsksForTheBeam() {
    XCTAssertEqual(VoiceGlowPhase.processing.beamMorph, 1)
    for phase in [VoiceGlowPhase.idle, .listening, .completed, .cancelled, .failed] {
      XCTAssertEqual(phase.beamMorph, 0)
    }
  }

  // MARK: - Knowing when someone stopped talking

  func testSilenceBeforeAnySpeechNeverSends() {
    var watcher = VoiceSilenceWatcher()
    var now: TimeInterval = 0
    for _ in 0..<200 {
      XCTAssertFalse(watcher.accept(level: 0, now: now))
      now += 0.1
    }
    XCTAssertFalse(watcher.hasHeardSpeech)
  }

  func testSilenceAfterSpeechSendsOnceTheThresholdPasses() {
    var watcher = VoiceSilenceWatcher(threshold: 2)
    XCTAssertFalse(watcher.accept(level: 0.8, now: 0), "still talking")
    XCTAssertFalse(watcher.accept(level: 0, now: 1.0), "a pause for breath")
    XCTAssertFalse(watcher.accept(level: 0, now: 2.5), "not yet")
    XCTAssertTrue(watcher.accept(level: 0, now: 3.1), "two seconds after the last word")
  }

  func testSpeakingAgainRestartsTheCountdown() {
    var watcher = VoiceSilenceWatcher(threshold: 2)
    _ = watcher.accept(level: 0.8, now: 0)
    _ = watcher.accept(level: 0, now: 1.0)
    XCTAssertFalse(watcher.accept(level: 0.9, now: 1.5), "…and then they carry on")
    XCTAssertFalse(watcher.accept(level: 0, now: 3.0), "silence restarts here, not at 1.0")
    XCTAssertFalse(
      watcher.accept(level: 0, now: 4.5),
      "1.5s after the new last word — the first pause must not count toward this"
    )
    XCTAssertTrue(watcher.accept(level: 0, now: 5.1), "two full seconds after it")
  }

  func testRoomToneDoesNotCountAsTalking() {
    var watcher = VoiceSilenceWatcher(threshold: 1)
    _ = watcher.accept(level: 0.8, now: 0)
    XCTAssertFalse(watcher.accept(level: 0.03, now: 0.2), "a fan")
    XCTAssertTrue(watcher.accept(level: 0.03, now: 1.4), "which never re-armed it")
  }

  func testTheCountdownReportsItsOwnProgress() {
    var watcher = VoiceSilenceWatcher(threshold: 2)
    _ = watcher.accept(level: 0.8, now: 0)
    XCTAssertEqual(watcher.progress(now: 0), 0, "talking is not a countdown")
    _ = watcher.accept(level: 0, now: 1.0)
    XCTAssertEqual(watcher.progress(now: 1.0), 0, accuracy: 0.01)
    XCTAssertEqual(watcher.progress(now: 2.0), 0.5, accuracy: 0.01)
    XCTAssertEqual(watcher.progress(now: 4.0), 1, accuracy: 0.01)
  }

  func testResettingForgetsThatAnythingWasEverSaid() {
    var watcher = VoiceSilenceWatcher(threshold: 1)
    _ = watcher.accept(level: 0.8, now: 0)
    watcher.reset()
    XCTAssertFalse(watcher.hasHeardSpeech)
    XCTAssertFalse(watcher.accept(level: 0, now: 10), "a spent countdown is not inherited")
  }

  // MARK: - The frame handed to the shader

  func testEveryStopOfThePaletteReachesTheShader() {
    let input = frame(intensity: 0.7)
    let u = VoiceGlowRenderer.uniforms(for: input)
    for index in 0..<VoiceGlowRenderer.colorCount {
      let sent = VoiceGlowRenderer.color(u, at: index)
      let expected = input.colors[index].usingColorSpace(.sRGB)!
      XCTAssertEqual(CGFloat(sent.x), expected.redComponent, accuracy: 0.01, "stop \(index)")
      XCTAssertEqual(CGFloat(sent.y), expected.greenComponent, accuracy: 0.01, "stop \(index)")
      XCTAssertEqual(CGFloat(sent.z), expected.blueComponent, accuracy: 0.01, "stop \(index)")
    }
  }

  func testAPaletteWithFewerStopsIsStretchedOverWhatTheShaderWalks() {
    var input = frame(intensity: 0.7)
    input.colors = [NSColor.red, NSColor.blue]
    let u = VoiceGlowRenderer.uniforms(for: input)
    let first = VoiceGlowRenderer.color(u, at: 0)
    let last = VoiceGlowRenderer.color(u, at: VoiceGlowRenderer.colorCount - 1)
    XCTAssertEqual(first.x, 1, accuracy: 0.01)
    XCTAssertEqual(last.z, 1, accuracy: 0.01)

    input.colors = []
    let none = VoiceGlowRenderer.uniforms(for: input)
    XCTAssertEqual(VoiceGlowRenderer.color(none, at: 3).x, 1, accuracy: 0.01, "nothing is white")
  }

  func testTheVoiceAndTheFlowReachTheShader() {
    var input = frame(intensity: 0.6, clock: 2)
    input.flow = 5
    input.voice = 0.8
    let u = VoiceGlowRenderer.uniforms(for: input)
    XCTAssertEqual(u.intensity, 0.6, accuracy: 0.0001)
    XCTAssertEqual(u.voice, 0.8, accuracy: 0.0001, "the quick envelope the orb answers to")
    XCTAssertEqual(u.flow, 5, accuracy: 0.0001)
    XCTAssertEqual(u.clock, 2, accuracy: 0.0001)
  }

  func testTheRaysStartBelowTheShellWhileListeningAndInItWhileProcessing() {
    let listening = VoiceGlowRenderer.uniforms(for: frame(intensity: 0.2))
    let processing = VoiceGlowRenderer.uniforms(for: frame(intensity: 0.74, beam: 1))
    XCTAssertLessThan(listening.origin.y, 0)
    XCTAssertEqual(CGFloat(processing.origin.y), surface.height / 2, accuracy: 0.001)
    XCTAssertEqual(processing.beam, 1)
  }

  func testTheShellIsLitThroughoutWhenItIsTheCapsuleAndFromTheFootWhenItIsTaller() {
    let capsule = VoiceGlowRenderer.uniforms(for: frame(intensity: 1))
    XCTAssertEqual(CGFloat(capsule.reach), surface.height, accuracy: 0.001)

    var card = frame(intensity: 1)
    card.size = CGSize(width: 520, height: 420)
    let tall = VoiceGlowRenderer.uniforms(for: card)
    XCTAssertLessThan(
      CGFloat(tall.reach), card.size.height * 0.5,
      "it stays a light along the bottom rather than filling the card"
    )
  }

  // MARK: - Accessibility and appearance

  func testReduceMotionStopsTheRaysButNotTheVoice() {
    var still = frame(intensity: 0.7, clock: 3, reduceMotion: true)
    still.flow = 9
    let u = VoiceGlowRenderer.uniforms(for: still)
    XCTAssertEqual(u.clock, 0)
    XCTAssertEqual(u.flow, 0)
    XCTAssertEqual(CGFloat(u.origin.x), surface.width / 2, accuracy: 0.001)
    XCTAssertEqual(u.intensity, 0.7, accuracy: 0.0001, "the voice still lights it")
  }

  func testTheShellCornerReachesTheShaderSoTheGlowCannotSpillPastTheGlass() {
    var input = frame(intensity: 1)
    input.cornerRadius = 37.25
    input.cornerIsContinuous = true
    let continuous = VoiceGlowRenderer.uniforms(for: input)
    XCTAssertEqual(continuous.cornerRadius, 37.25, accuracy: 0.001)
    XCTAssertEqual(continuous.cornerIsContinuous, 1)

    input.cornerIsContinuous = false
    XCTAssertEqual(VoiceGlowRenderer.uniforms(for: input).cornerIsContinuous, 0)
  }

  func testTheAppearanceReachesTheShader() {
    XCTAssertEqual(VoiceGlowRenderer.uniforms(for: frame(intensity: 1)).appearance, 0)
    var light = frame(intensity: 1)
    light.isLightAppearance = true
    XCTAssertEqual(VoiceGlowRenderer.uniforms(for: light).appearance, 1)
  }

  // MARK: -

  private func frame(
    intensity: CGFloat,
    beam: CGFloat = 0,
    clock: CGFloat = 0,
    reduceMotion: Bool = false
  ) -> VoiceGlowRenderer.Frame {
    let colors = VoiceEdgeGlowLayout.rayColors(from: .standard)
    return VoiceGlowRenderer.Frame(
      size: surface,
      pixelSize: 0.5,
      cornerRadius: 37.25,
      cornerIsContinuous: true,
      intensity: intensity,
      beam: beam,
      clock: clock,
      opacity: 1,
      isLightAppearance: false,
      reduceMotion: reduceMotion,
      colors: colors
    )
  }
}
