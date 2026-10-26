import AVFoundation
import Foundation
import OSLog

/// Dictation in two languages: the same audio goes to a recognizer for each,
/// and `BilingualTranscript` decides whose words every phrase gets.
///
/// `start`'s locale is the primary language's; the second one is this
/// engine's. If the second recognizer cannot start — its model was removed, the
/// Mac stopped offering it — dictation goes on in the first alone rather than
/// not at all.
@MainActor
final class BilingualDictationEngine: DictationEngine {
  private let log = Logger(subsystem: "com.boltty", category: "bilingual-dictation")
  private let primaryTier: DictationTier
  private let secondary: DictationLanguage

  init(primaryTier: DictationTier, secondary: DictationLanguage) {
    self.primaryTier = primaryTier
    self.secondary = secondary
  }

  func start(
    locale: Locale,
    inputFormat: AVAudioFormat,
    onTranscript: @escaping @MainActor (String, Bool) -> Void,
    onFailure: @escaping @MainActor (DictationEngineError) -> Void
  ) async throws -> DictationSession {
    let primaryEngine = SpeechAnalyzerDictationEngine(tier: primaryTier, reportsConfidence: true)
    let secondaryEngine = SpeechAnalyzerDictationEngine(
      tier: secondary.tier,
      reportsConfidence: true
    )
    let transcript = TranscriptBox(
      BilingualTranscript(primary: locale, secondary: secondary.locale)
    )

    let report: @MainActor (Bool) -> Void = { isFinal in
      onTranscript(transcript.value.text, isFinal)
    }

    let secondSession: DictationSession
    do {
      secondSession = try await secondaryEngine.startReporting(
        locale: secondary.locale,
        inputFormat: inputFormat,
        onUpdate: { update in
          transcript.value.add(update.piece, isFinal: update.isFinal,
                               finalizedThrough: update.finalizedThrough, to: .secondary)
          report(false)
        },
        onEnd: {
          transcript.value.end(.secondary)
          if transcript.value.isComplete { report(true) }
        },
        onFailure: { [log] error in
          // The second language failing is not the take failing.
          log.error("second language stopped: \(error.localizedDescription, privacy: .public)")
          transcript.value.end(.secondary)
          if transcript.value.isComplete { report(true) }
        }
      )
    } catch {
      log.error("second language did not start: \(error.localizedDescription, privacy: .public)")
      return try await primaryEngine.start(
        locale: locale,
        inputFormat: inputFormat,
        onTranscript: onTranscript,
        onFailure: onFailure
      )
    }

    let firstSession: DictationSession
    do {
      firstSession = try await primaryEngine.startReporting(
        locale: locale,
        inputFormat: inputFormat,
        onUpdate: { update in
          transcript.value.add(update.piece, isFinal: update.isFinal,
                               finalizedThrough: update.finalizedThrough, to: .primary)
          report(false)
        },
        onEnd: {
          transcript.value.end(.primary)
          if transcript.value.isComplete { report(true) }
        },
        onFailure: onFailure
      )
    } catch {
      secondSession.cancel()
      throw error
    }

    return PairSession([firstSession, secondSession])
  }

  /// A transcript being built by escaping closures, all on the main actor.
  @MainActor
  private final class TranscriptBox {
    var value: BilingualTranscript
    init(_ value: BilingualTranscript) { self.value = value }
  }

  /// One microphone, two recognizers.
  private final class PairSession: DictationSession, @unchecked Sendable {
    private let sessions: [DictationSession]

    init(_ sessions: [DictationSession]) {
      self.sessions = sessions
    }

    func append(_ buffer: AVAudioPCMBuffer) {
      for session in sessions { session.append(buffer) }
    }

    func endAudio() {
      for session in sessions { session.endAudio() }
    }

    func cancel() {
      for session in sessions { session.cancel() }
    }
  }
}

extension DictationUpdate {
  var piece: BilingualTranscript.Piece {
    BilingualTranscript.Piece(start: start, end: end, text: text, confidence: confidence)
  }
}
