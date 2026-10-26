import AVFoundation
import CoreMedia
import Foundation
import Speech

@MainActor
final class SpeechAnalyzerDictationEngine: DictationEngine {
  static let displayName = "Apple (on-device)"

  private let tier: DictationTier
  /// Asks the model for the confidence of its final results — what
  /// `BilingualTranscript` chooses by. One language needs none.
  private let reportsConfidence: Bool

  init(tier: DictationTier, reportsConfidence: Bool = false) {
    self.tier = tier
    self.reportsConfidence = reportsConfidence
  }

  func start(
    locale: Locale,
    inputFormat: AVAudioFormat,
    onTranscript: @escaping @MainActor (String, Bool) -> Void,
    onFailure: @escaping @MainActor (DictationEngineError) -> Void
  ) async throws -> DictationSession {
    let accumulator = AccumulatorBox()
    return try await startReporting(
      locale: locale,
      inputFormat: inputFormat,
      onUpdate: { update in
        onTranscript(accumulator.value.consume(update.text, isFinal: update.isFinal), false)
      },
      onEnd: { onTranscript(accumulator.value.text, true) },
      onFailure: onFailure
    )
  }

  /// Every result as it comes, and `onEnd` once there will be no more. A
  /// failure ends it without `onEnd`.
  func startReporting(
    locale: Locale,
    inputFormat: AVAudioFormat,
    onUpdate: @escaping @MainActor (DictationUpdate) -> Void,
    onEnd: @escaping @MainActor () -> Void,
    onFailure: @escaping @MainActor (DictationEngineError) -> Void
  ) async throws -> DictationSession {
    let name = Self.name(of: locale)

    switch tier {
    case .speechTranscriber:
      guard let matched = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
        throw DictationEngineError.languageUnsupported(name)
      }
      guard Self.isInstalled(matched, in: await SpeechTranscriber.installedLocales) else {
        throw DictationEngineError.modelNotInstalled(name)
      }
      let module: SpeechTranscriber
      if reportsConfidence {
        // Not the progressive preset: its `fastResults` lowers what the model
        // says it is sure of — a short English phrase 0.53 where this gives
        // 0.80, and sureness is what two languages are
        // told apart by.
        module = SpeechTranscriber(
          locale: matched,
          transcriptionOptions: [],
          reportingOptions: [.volatileResults],
          attributeOptions: [.transcriptionConfidence]
        )
      } else {
        module = SpeechTranscriber(locale: matched, preset: .progressiveTranscription)
      }
      return try await run(module: module, inputFormat: inputFormat) { analyzer, session in
        Self.forward(
          module,
          text: { $0.text },
          analyzer: analyzer,
          session: session,
          onUpdate: onUpdate,
          onEnd: onEnd,
          onFailure: onFailure
        )
      }

    case .dictationTranscriber, .legacy:
      guard let matched = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
        throw DictationEngineError.languageUnsupported(name)
      }
      guard Self.isInstalled(matched, in: await DictationTranscriber.installedLocales) else {
        throw DictationEngineError.modelNotInstalled(name)
      }
      var preset = DictationTranscriber.Preset.progressiveLongDictation
      if reportsConfidence { preset.attributeOptions.insert(.transcriptionConfidence) }
      let module = DictationTranscriber(locale: matched, preset: preset)
      return try await run(module: module, inputFormat: inputFormat) { analyzer, session in
        Self.forward(
          module,
          text: { $0.text },
          analyzer: analyzer,
          session: session,
          onUpdate: onUpdate,
          onEnd: onEnd,
          onFailure: onFailure
        )
      }
    }
  }

  /// Both transcribers' results read alike but for where the words are, so one
  /// loop serves both.
  private static func forward<Module: SpeechModule>(
    _ module: Module,
    text: @escaping @Sendable (Module.Result) -> AttributedString,
    analyzer: SpeechAnalyzer,
    session: AnalyzerSession,
    onUpdate: @escaping @MainActor (DictationUpdate) -> Void,
    onEnd: @escaping @MainActor () -> Void,
    onFailure: @escaping @MainActor (DictationEngineError) -> Void
  ) {
    Task { @MainActor in
      do {
        for try await result in module.results {
          let words = text(result)
          onUpdate(
            DictationUpdate(
              text: String(words.characters),
              isFinal: result.isFinal,
              start: Self.seconds(result.range.start),
              end: Self.seconds(result.range.end),
              confidence: Self.confidence(of: words),
              finalizedThrough: Self.seconds(result.resultsFinalizationTime)
            )
          )
        }
      } catch {
        onFailure(.startFailed)
        return
      }
      onEnd()
      _ = analyzer
      _ = session
    }
  }

  private func run(
    module: any SpeechModule,
    inputFormat: AVAudioFormat,
    consumeResults: (SpeechAnalyzer, AnalyzerSession) -> Void
  ) async throws -> DictationSession {
    let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let analyzer = SpeechAnalyzer(modules: [module])

    let session = AnalyzerSession(
      continuation: continuation,
      analyzer: analyzer,
      converter: analyzerFormat.flatMap { AVAudioConverter(from: inputFormat, to: $0) }
    )
    consumeResults(analyzer, session)

    do {
      try await analyzer.start(inputSequence: stream)
    } catch {
      throw DictationEngineError.startFailed
    }
    return session
  }

  private static func isInstalled(_ locale: Locale, in installed: [Locale]) -> Bool {
    let key = DictationLanguageCatalog.normalize(locale.identifier)
    return installed.contains { DictationLanguageCatalog.normalize($0.identifier) == key }
  }

  private static func name(of locale: Locale) -> String {
    Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
  }

  private static func seconds(_ time: CMTime) -> Double {
    time.isNumeric ? time.seconds : 0
  }

  /// The mean of the confidences a result's words carry, by their length;
  /// `nil` when none carries one.
  private static func confidence(of words: AttributedString) -> Double? {
    var weighted = 0.0
    var weight = 0.0
    for run in words.runs {
      guard let confidence = run.transcriptionConfidence else { continue }
      let count = Double(max(1, words[run.range].characters.count))
      weighted += confidence * count
      weight += count
    }
    return weight > 0 ? weighted / weight : nil
  }
}

/// A transcript being built by an escaping closure.
@MainActor
private final class AccumulatorBox {
  var value = TranscriptAccumulator()
}

struct TranscriptAccumulator {
  private var finalized = ""
  private var volatileTail = ""

  var text: String { finalized + volatileTail }

  mutating func consume(_ plain: String, isFinal: Bool) -> String {
    if isFinal {
      finalized += plain
      volatileTail = ""
    } else {
      volatileTail = plain
    }
    return self.text
  }
}

final class AnalyzerSession: DictationSession, @unchecked Sendable {
  private let continuation: AsyncStream<AnalyzerInput>.Continuation
  private let analyzer: SpeechAnalyzer
  private let converter: AVAudioConverter?
  private let lock = NSLock()
  private var isFinished = false

  init(
    continuation: AsyncStream<AnalyzerInput>.Continuation,
    analyzer: SpeechAnalyzer,
    converter: AVAudioConverter?
  ) {
    self.continuation = continuation
    self.analyzer = analyzer
    self.converter = converter
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    let finished = isFinished
    lock.unlock()
    guard !finished, let converted = convert(buffer) else { return }
    continuation.yield(AnalyzerInput(buffer: converted))
  }

  func endAudio() {
    lock.lock()
    guard !isFinished else { return lock.unlock() }
    isFinished = true
    lock.unlock()

    continuation.finish()
    let analyzer = analyzer
    Task {
      try? await analyzer.finalizeAndFinishThroughEndOfInput()
    }
  }

  func cancel() {
    lock.lock()
    guard !isFinished else { return lock.unlock() }
    isFinished = true
    lock.unlock()

    continuation.finish()
    let analyzer = analyzer
    Task { await analyzer.cancelAndFinishNow() }
  }

  private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let converter else { return buffer }
    let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
    guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
    else { return nil }

    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, output.frameLength > 0 else { return nil }
    return output
  }
}
