import AVFoundation
import XCTest
@testable import Boltty

final class AskBolttyBlipsTests: XCTestCase {
  /// Core Audio calls the render block on its own thread. Rendered here off
  /// the main thread, a block that had kept the main actor's isolation stops
  /// the process, as it stopped the app at its first blip.
  func testTheBlipRendersOffTheMainThread() async throws {
    let peak = try await Task.detached { () -> Float in
      let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
      let state = BlipState()
      let engine = AVAudioEngine()
      let node = AskBolttyBlips.makeSource(format: format, state: state)
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: format)
      try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
      try engine.start()
      state.trigger(pitch: 520)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
      _ = try engine.renderOffline(4096, to: buffer)
      engine.stop()
      let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
      return samples.map(abs).max() ?? 0
    }.value
    XCTAssertGreaterThan(peak, 0.1, "a blip makes a sound")
  }
}
