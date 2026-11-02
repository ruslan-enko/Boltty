import AVFoundation
import Foundation
import os

/// Says pieces of text in Supertonic's voice, in order: each is synthesized
/// on a serial queue while the one before it plays, and played through one
/// `AVAudioPlayerNode`.
///
/// `onStart` runs when a piece is really heard (Ask Boltty's caption and
/// pointing follow the sound), `onFinish` when it has played or failed.
/// `stop()` drops everything queued and nothing of it is reported after.
@MainActor
final class SupertonicSpeaker {
  /// What a piece is said with.
  struct Delivery: Equatable, Sendable {
    var voice: String
    /// Multiplies Supertonic's own pace.
    var rate: Double
  }

  /// The models' folder; a new one (or none) unloads the old.
  var folder: URL? {
    didSet {
      guard folder != oldValue else { return }
      stop()
      unload()
    }
  }

  /// The last thing that went wrong, until something is said again.
  private(set) var failure: String?

  /// The models stay loaded this long after the last piece (~100 MB).
  static let idleUnload: TimeInterval = 600

  private let queue = DispatchQueue(label: "com.boltty.supertonic", qos: .userInitiated)
  private let loaded = Loaded()
  private let current = OSAllocatedUnfairLock(initialState: 0)
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let format = AVAudioFormat(
    standardFormatWithSampleRate: Double(SupertonicSynthesizer.sampleRate), channels: 1)!
  private var generation = 0
  private var playing: [Scheduled] = []
  private var synthesizing = 0
  private var idleTimer: Timer?

  private struct Scheduled {
    let id: Int
    let onStart: (() -> Void)?
    let onFinish: (Bool) -> Void
  }

  private var nextID = 0
  /// Callbacks of pieces still being synthesized; the queue carries only ids.
  private var waiting: [Int: Scheduled] = [:]

  init() {
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
  }

  /// Loads the models now, off the main thread, so the first answer does not
  /// wait. After a download or an update Core ML compiles them first.
  func warm() {
    guard let folder else { return }
    queue.async { [loaded] in _ = try? loaded.synthesizer(in: folder) }
    scheduleUnload()
  }

  /// Queues `piece`. `onFinish(false)` when it could not be said.
  func say(
    _ piece: String, language: String, delivery: Delivery,
    onStart: (() -> Void)? = nil, onFinish: @escaping (Bool) -> Void
  ) {
    guard let folder else { return onFinish(false) }
    let generation = generation
    nextID += 1
    let id = nextID
    synthesizing += 1
    waiting[id] = Scheduled(id: id, onStart: onStart, onFinish: onFinish)
    idleTimer?.invalidate()
    let speed = SupertonicSynthesizer.baseSpeed * Float(delivery.rate)
    queue.async { [loaded, current] in
      guard current.withLock({ $0 }) == generation else { return }
      let result = Result {
        let synthesizer = try loaded.synthesizer(in: folder)
        return try synthesizer.say(
          piece, language: language, voice: synthesizer.voice(delivery.voice), speed: speed)
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.synthesized(result, id: id, generation: generation)
        }
      }
    }
  }

  func stop() {
    generation += 1
    let generation = generation
    current.withLock { $0 = generation }
    synthesizing = 0
    waiting.removeAll()
    playing.removeAll()
    if player.isPlaying { player.stop() }
    scheduleUnload()
  }

  // MARK: - Playing

  private func synthesized(_ result: Result<[Float], Error>, id: Int, generation: Int) {
    guard generation == self.generation, let piece = waiting.removeValue(forKey: id) else { return }
    synthesizing -= 1
    switch result {
    case let .failure(error):
      failure = error.localizedDescription
      piece.onFinish(false)
    case let .success(samples):
      failure = nil
      guard !samples.isEmpty, let buffer = buffer(samples), start() else {
        piece.onFinish(samples.isEmpty)
        break
      }
      let wasIdle = playing.isEmpty
      playing.append(piece)
      player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self.played(id, generation: generation) }
        }
      }
      if wasIdle { piece.onStart?() }
    }
    scheduleUnload()
  }

  private func played(_ id: Int, generation: Int) {
    guard generation == self.generation, let index = playing.firstIndex(where: { $0.id == id })
    else { return }
    let done = playing.remove(at: index)
    done.onFinish(true)
    if index == 0 { playing.first?.onStart?() }
    scheduleUnload()
  }

  /// Starts the engine where it stopped: first use, or after the output
  /// device changed (`AVAudioEngineConfigurationChange` stops it).
  private func start() -> Bool {
    if !engine.isRunning {
      do {
        try engine.start()
      } catch {
        failure = error.localizedDescription
        return false
      }
    }
    if !player.isPlaying { player.play() }
    return true
  }

  private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
    }
    return buffer
  }

  // MARK: - Idle

  /// With nothing to say the engine stops (it holds the audio device) and,
  /// after `idleUnload`, the models go.
  private func scheduleUnload() {
    idleTimer?.invalidate()
    guard playing.isEmpty, synthesizing == 0 else { return }
    if engine.isRunning {
      player.stop()
      engine.stop()
    }
    idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleUnload, repeats: false) { _ in
      MainActor.assumeIsolated { self.unload() }
    }
  }

  private func unload() {
    idleTimer?.invalidate()
    idleTimer = nil
    queue.async { [loaded] in loaded.drop() }
  }
}

/// The synthesizer, touched only on the speaker's queue.
private final class Loaded: @unchecked Sendable {
  private var synthesizer: SupertonicSynthesizer?
  private var folder: URL?

  func synthesizer(in folder: URL) throws -> SupertonicSynthesizer {
    if let synthesizer, self.folder == folder { return synthesizer }
    let made = try SupertonicSynthesizer(folder: folder)
    synthesizer = made
    self.folder = folder
    return made
  }

  func drop() {
    synthesizer = nil
    folder = nil
  }
}
