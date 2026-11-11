import AVFoundation
import Foundation
import os

@MainActor
final class ParakeetDictationEngine: DictationEngine {
  static let languages: Set<String> = [
    "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt",
    "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
  ]

  static let livePass: TimeInterval = 0.7
  static let idleUnload: TimeInterval = 600
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
