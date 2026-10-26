import AVFoundation

/// The mascot's voice while Ask Boltty's words type out: a soft blip a syllable,
/// as Animal Crossing and Zelda give their characters — no words, a pitch
/// that wanders a little round the agent's own, in place of reading the
/// answer aloud. Synthesized here, so the sound is
/// Boltty's: a short sine with a quick attack and a falling tail.
@MainActor
final class AskBolttyBlips {
  /// Quiet: under the interface sounds, which sit near −21 dBFS.
  static let volume: Float = 0.08
  nonisolated static let duration: Double = 0.055

  private let engine = AVAudioEngine()
  private var source: AVAudioSourceNode?
  private let state = BlipState()
  private var started = false

  /// One blip at `pitch` Hz.
  func blip(pitch: Double) {
    guard prepare() else { return }
    state.trigger(pitch: pitch)
  }

  func stop() {
    guard started else { return }
    engine.stop()
    started = false
  }

  private func prepare() -> Bool {
    if started { return true }
    if source == nil {
      let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
      let node = Self.makeSource(format: format, state: state)
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: format)
      engine.mainMixerNode.outputVolume = Self.volume
      source = node
    }
    do {
      try engine.start()
      started = true
    } catch {
      return false
    }
    return true
  }

  /// The render block, made outside the main actor. Written inside a
  /// main-actor method the closure is main-actor isolated, the runtime checks
  /// that where Core Audio calls it — its own I/O thread — and the app stops
  /// on `_dispatch_assert_queue_fail` at the first blip.
  nonisolated static func makeSource(format: AVAudioFormat, state: BlipState) -> AVAudioSourceNode {
    AVAudioSourceNode(format: format) { @Sendable _, _, frameCount, buffers in
      let list = UnsafeMutableAudioBufferListPointer(buffers)
      guard let samples = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
      state.render(into: samples, frames: Int(frameCount), rate: 44_100)
      return noErr
    }
  }
}

/// Shared with the render thread under a lock: what the next samples are.
final class BlipState: @unchecked Sendable {
  private let lock = NSLock()
  private var pitch = 0.0
  private var phase = 0.0
  private var remaining = 0
  private var length = 1

  func trigger(pitch: Double) {
    lock.withLock {
      self.pitch = pitch
      length = Int(AskBolttyBlips.duration * 44_100)
      remaining = length
    }
  }

  func render(into samples: UnsafeMutablePointer<Float>, frames: Int, rate: Double) {
    lock.withLock {
      for i in 0..<frames {
        guard remaining > 0 else {
          samples[i] = 0
          continue
        }
        let t = Double(length - remaining) / Double(length)
        let envelope = min(1, t * 12) * pow(1 - t, 2)
        // A touch of the octave makes it a voice, not a beep.
        let value = sin(phase) + 0.3 * sin(phase * 2)
        samples[i] = Float(value * envelope)
        phase += 2 * .pi * pitch / rate
        if phase > 2 * .pi { phase -= 2 * .pi }
        remaining -= 1
      }
    }
  }
}
