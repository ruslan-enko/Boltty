import AVFoundation
import Foundation
import Speech

protocol DictationSession: AnyObject, Sendable {
  func append(_ buffer: AVAudioPCMBuffer)
  func endAudio()
  func cancel()
}

/// One result of a recognizer, with what choosing between two of them needs
/// (`BilingualTranscript`). Times are seconds on the take's own clock.
struct DictationUpdate: Sendable, Equatable {
  var text: String
  var isFinal: Bool
  var start: Double
  var end: Double
  /// `nil` where the model reports none — Apple's Ukrainian dictation model,
  /// and every volatile result of every model.
  var confidence: Double?
  /// Everything up to here is final.
  var finalizedThrough: Double
}

@MainActor
protocol DictationEngine: AnyObject {
  func start(
    locale: Locale,
    inputFormat: AVAudioFormat,
    onTranscript: @escaping @MainActor (String, Bool) -> Void,
    onFailure: @escaping @MainActor (DictationEngineError) -> Void
  ) async throws -> DictationSession
}

enum DictationEngineError: LocalizedError, Equatable {
  case languageUnsupported(String)
  case modelNotInstalled(String)
  case modelDownloadFailed(String)
  case engineUnavailable
  case startFailed

  var errorDescription: String? {
    switch self {
    case let .languageUnsupported(name):
      "\(name) is not available for on-device dictation on this Mac."
    case let .modelNotInstalled(name):
      "\(name) is not downloaded yet. Open Settings ▸ Boltty AI to install it."
    case let .modelDownloadFailed(name):
      "Downloading the \(name) dictation model failed."
    case .engineUnavailable:
      "Speech recognition is currently unavailable."
    case .startFailed:
      "Voice input stopped. Please try again."
    }
  }
}

// MARK: - SFSpeechRecognizer

@MainActor
final class LegacyDictationEngine: DictationEngine {
  static let displayName = "Apple (on-device)"

  func start(
    locale: Locale,
    inputFormat: AVAudioFormat,
    onTranscript: @escaping @MainActor (String, Bool) -> Void,
    onFailure: @escaping @MainActor (DictationEngineError) -> Void
  ) async throws -> DictationSession {
    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
      throw DictationEngineError.languageUnsupported(Self.name(of: locale))
    }
    guard recognizer.isAvailable else {
      throw DictationEngineError.engineUnavailable
    }
    guard recognizer.supportsOnDeviceRecognition else {
      throw DictationEngineError.modelNotInstalled(Self.name(of: locale))
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    request.requiresOnDeviceRecognition = true

    let session = LegacySession(request: request)
    let task = recognizer.recognitionTask(with: request) { @Sendable result, error in
      let transcript = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let failed = error != nil
      Task { @MainActor in
        if let transcript {
          onTranscript(transcript, isFinal)
        }
        if failed {
          onFailure(.startFailed)
        }
      }
    }
    session.task = task
    return session
  }

  private static func name(of locale: Locale) -> String {
    Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
  }

  private final class LegacySession: DictationSession, @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    var task: SFSpeechRecognitionTask?

    init(request: SFSpeechAudioBufferRecognitionRequest) {
      self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
      request.append(buffer)
    }

    func endAudio() {
      request.endAudio()
    }

    func cancel() {
      request.endAudio()
      task?.cancel()
      task = nil
    }
  }
}
