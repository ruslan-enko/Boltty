import AVFoundation
import Foundation
import os

/// Dictation by Parakeet on this Mac. One model hears all 25 of its
/// languages and tells them apart itself, so there is no language to pick
/// and no second recognizer. It needs the microphone and not Speech
/// Recognition.
///
/// Parakeet reads a whole take, not a stream: while the person speaks, the
/// take so far is read again every `livePass` (~0.1 s for 15 s of sound on an
/// M1 Pro), and once they stop, one last time for the final text.
@MainActor
final class ParakeetDictationEngine: DictationEngine {
  /// Its languages (FluidInference's Parakeet TDT 0.6B v3 card).
  static let languages: Set<String> = [
    "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt",
    "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
  ]

  static let livePass: TimeInterval = 0.7
  /// The model stays loaded this long after the last take (~600 MB).
  static let idleUnload: TimeInterval = 600
  /// After loading it ahead of use, it goes sooner if nobody dictates.
  static let warmUnload: TimeInterval = 60

  var folder: URL? {
    didSet {
      guard folder != oldValue else { return }
      unload()
    }
  }

  private let queue = DispatchQueue(label: "com.boltty.parakeet", qos: .userInitiated)
  private let loaded = LoadedTranscriber()
  private var idleTimer: Timer?

  /// Loads the model now, so the first take does not wait. After a download
  /// or an update Core ML compiles it first (24 s on an M1 Pro).
  func warm() {
    guard let folder else { return }
    queue.async { [loaded] in _ = try? loaded.transcriber(in: folder) }
    scheduleUnload(after: Self.warmUnload)
  }

  func start(
    locale: Locale,
    inputFormat: AVAudioFormat,
    onTranscript: @escaping @MainActor (String, Bool) -> Void,
    onFailure: @escaping @MainActor (DictationEngineError) -> Void
  ) async throws -> DictationSession {
    guard let folder else { throw DictationEngineError.engineUnavailable }
    guard let session = ParakeetSession(inputFormat: inputFormat) else {
      throw DictationEngineError.startFailed
    }
    idleTimer?.invalidate()
    let take = ParakeetTake(
      session: session, folder: folder, queue: queue, loaded: loaded,
      onTranscript: onTranscript, onFailure: onFailure,
      onDone: { [weak self] in self?.scheduleUnload(after: Self.idleUnload) })
    take.begin()
    return session
  }

  private func scheduleUnload(after delay: TimeInterval) {
    idleTimer?.invalidate()
    idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
      MainActor.assumeIsolated { self.unload() }
    }
  }

  private func unload() {
    idleTimer?.invalidate()
    idleTimer = nil
    queue.async { [loaded] in loaded.drop() }
  }
}

/// Reads one take while it is spoken and once more when it ends.
@MainActor
private final class ParakeetTake {
  private let session: ParakeetSession
  private let folder: URL
  private let queue: DispatchQueue
  private let loaded: LoadedTranscriber
  private let onTranscript: @MainActor (String, Bool) -> Void
  private let onFailure: @MainActor (DictationEngineError) -> Void
  private let onDone: @MainActor () -> Void
  private var timer: Timer?
  private var passing = false
  private var heard = 0
  private var finished = false

  init(
    session: ParakeetSession, folder: URL, queue: DispatchQueue, loaded: LoadedTranscriber,
    onTranscript: @escaping @MainActor (String, Bool) -> Void,
    onFailure: @escaping @MainActor (DictationEngineError) -> Void,
    onDone: @escaping @MainActor () -> Void
  ) {
    self.session = session
    self.folder = folder
    self.queue = queue
    self.loaded = loaded
    self.onTranscript = onTranscript
    self.onFailure = onFailure
    self.onDone = onDone
  }

  /// The take keeps itself alive through its timer and the session's end.
  func begin() {
    timer = Timer.scheduledTimer(
      withTimeInterval: ParakeetDictationEngine.livePass, repeats: true
    ) { _ in
      MainActor.assumeIsolated { self.tick() }
    }
    session.onEnd = {
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.end() }
      }
    }
  }

  private func tick() {
    guard !session.isCancelled, !finished else {
      session.onEnd = nil
      return stopTimer()
    }
    let count = session.count
    // Under a third of a second there is nothing worth showing yet.
    guard !passing, count > heard, count >= ParakeetTranscriber.frameSamples * 4 else { return }
    heard = count
    read(final: false)
  }

  private func end() {
    stopTimer()
    guard !finished, !session.isCancelled else { return }
    finished = true
    read(final: true)
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func read(final: Bool) {
    passing = true
    let samples = session.samples
    queue.async { [loaded, folder] in
      let result = Result { try loaded.transcriber(in: folder).transcribe(samples) }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.read(result, final: final) }
      }
    }
  }

  private func read(_ result: Result<String, Error>, final: Bool) {
    passing = false
    guard !session.isCancelled else { return }
    switch result {
    case let .success(text):
      // A live pass that lands after the end is old news.
      if final || !finished { onTranscript(text, final) }
    case let .failure(error):
      onFailure(.localModelFailed(error.localizedDescription))
    }
    if final {
      session.onEnd = nil
      onDone()
    }
  }
}

/// One take: the microphone's buffers, turned into 16 kHz mono as they come
/// (on the audio thread) and kept whole.
private final class ParakeetSession: DictationSession, @unchecked Sendable {
  var onEnd: (@Sendable () -> Void)?

  private let converter: AVAudioConverter
  private let target: AVAudioFormat
  private let state = OSAllocatedUnfairLock(initialState: (samples: [Float](), cancelled: false))

  init?(inputFormat: AVAudioFormat) {
    guard
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(ParakeetTranscriber.sampleRate),
        channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: inputFormat, to: target)
    else { return nil }
    self.target = target
    self.converter = converter
  }

  var samples: [Float] { state.withLock { $0.samples } }
  var count: Int { state.withLock { $0.samples.count } }
  var isCancelled: Bool { state.withLock { $0.cancelled } }

  func append(_ buffer: AVAudioPCMBuffer) {
    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
    var fed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if fed {
        status.pointee = .noDataNow
        return nil
      }
      fed = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
    let converted = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    state.withLock { $0.samples.append(contentsOf: converted) }
  }

  func endAudio() {
    onEnd?()
  }

  func cancel() {
    state.withLock { $0.cancelled = true }
  }
}

/// The transcriber, touched only on the engine's queue.
private final class LoadedTranscriber: @unchecked Sendable {
  private var transcriber: ParakeetTranscriber?
  private var folder: URL?

  func transcriber(in folder: URL) throws -> ParakeetTranscriber {
    if let transcriber, self.folder == folder { return transcriber }
    let made = try ParakeetTranscriber(folder: folder)
    transcriber = made
    self.folder = folder
    return made
  }

  func drop() {
    transcriber = nil
    folder = nil
  }
}
