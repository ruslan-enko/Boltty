import AVFoundation
import Foundation
import Speech

@MainActor
final class VoiceDictationService {
  typealias SpeechAuthorizationCompletion = @Sendable (
    SFSpeechRecognizerAuthorizationStatus
  ) -> Void
  typealias SpeechAuthorizationRequester = (
    @escaping SpeechAuthorizationCompletion
  ) -> Void

  enum State: Equatable {
    case idle
    case requestingPermission
    case listening
  }

  var onTranscript: ((String) -> Void)?
  var onAudioLevel: ((CGFloat) -> Void)?
  var onStateChange: ((State) -> Void)?
  var onFinalTranscript: (() -> Void)?
  var onError: ((String) -> Void)?

  var localeIdentifier: String = DictationLanguageCatalog.followSystemIdentifier
  /// A second language to listen for beside the first
  /// (`DictationLanguageCatalog.noSecondLanguageIdentifier`: none).
  var secondLocaleIdentifier: String = DictationLanguageCatalog.noSecondLanguageIdentifier

  private let audioEngine = AVAudioEngine()
  private let usageDescription: (String) -> String?
  private let requestSpeechAuthorization: SpeechAuthorizationRequester
  private var session: DictationSession?
  private var finalizingSession: DictationSession?
  private var generation = 0
  private var hasInstalledAudioTap = false
  private var cachedLanguages: [DictationLanguage]?

  private(set) var state: State = .idle {
    didSet {
      guard state != oldValue else { return }
      onStateChange?(state)
    }
  }

  init(
    usageDescription: @escaping (String) -> String? = {
      Bundle.main.object(forInfoDictionaryKey: $0) as? String
    },
    requestSpeechAuthorization: @escaping SpeechAuthorizationRequester = {
      SFSpeechRecognizer.requestAuthorization($0)
    }
  ) {
    self.usageDescription = usageDescription
    self.requestSpeechAuthorization = requestSpeechAuthorization
  }

  func toggle() {
    switch state {
    case .listening, .requestingPermission:
      stop()
    case .idle:
      requestPermissionAndStart()
    }
  }

  func stop() {
    guard state != .requestingPermission else {
      cancel()
      return
    }
    stopAudioCapture()
    state = .idle
  }

  func cancel() {
    generation += 1
    stopAudioCapture(cancel: true)
    finalizingSession?.cancel()
    finalizingSession = nil
    state = .idle
  }

  func invalidateLanguageCache() {
    cachedLanguages = nil
  }

  private func requestPermissionAndStart() {
    cancel()
    let generation = generation
    guard hasRequiredUsageDescriptions else {
      fail("Voice input is unavailable in this Boltty build. Please update or reinstall Boltty.")
      return
    }

    state = .requestingPermission

    requestSpeechAuthorization { @Sendable [weak self] status in
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation,
              self.state == .requestingPermission else { return }
        guard status == .authorized else {
          self.fail(Self.speechAuthorizationMessage(for: status))
          return
        }
        self.requestMicrophonePermissionAndStart(generation: generation)
      }
    }
  }

  private func requestMicrophonePermissionAndStart(generation: Int) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      Task { await startListening(generation: generation) }
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { @Sendable [weak self] granted in
        Task { @MainActor [weak self] in
          guard let self, self.generation == generation,
                self.state == .requestingPermission else { return }
          if granted {
            await self.startListening(generation: generation)
          } else {
            self.fail("Microphone access is required for voice input.")
          }
        }
      }
    case .denied, .restricted:
      fail("Microphone access is required for voice input. Enable it in System Settings.")
    @unknown default:
      fail("Microphone access is unavailable.")
    }
  }

  private func startListening(generation: Int) async {
    guard self.generation == generation, state == .requestingPermission else { return }
    let languages = await currentLanguages()
    guard self.generation == generation, state == .requestingPermission else { return }
    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      fail("No microphone input is available.")
      return
    }

    guard
      let language = DictationLanguageCatalog.resolve(
        identifier: localeIdentifier,
        systemIdentifier: Locale.current.identifier,
        in: languages
      )
    else {
      fail(DictationEngineError.languageUnsupported(Self.chosenLanguageName(localeIdentifier))
        .localizedDescription)
      return
    }

    let second = DictationLanguageCatalog.resolveSecond(
      identifier: secondLocaleIdentifier,
      primary: language,
      systemIdentifier: Locale.current.identifier,
      in: languages
    )

    guard let started = await makeSession(
      for: language,
      second: second,
      inputFormat: format,
      generation: generation
    )
    else { return }
    guard self.generation == generation, state == .requestingPermission else {
      started.cancel()
      return
    }
    beginCapture(with: started, inputNode: inputNode, format: format)
  }

  private func makeSession(
    for language: DictationLanguage,
    second: DictationLanguage?,
    inputFormat: AVAudioFormat,
    generation: Int
  ) async -> DictationSession? {
    do {
      return try await DictationCatalog.engine(for: language, second: second).start(
        locale: language.locale,
        inputFormat: inputFormat,
        onTranscript: { [weak self] transcript, isFinal in
          guard let self, self.generation == generation else { return }
          self.onTranscript?(transcript)
          if isFinal {
            self.stop()
            self.generation += 1
            self.finalizingSession = nil
            self.onFinalTranscript?()
          }
        },
        onFailure: { [weak self] error in
          guard let self, self.generation == generation,
                self.state == .listening || self.finalizingSession != nil else { return }
          self.fail(error.localizedDescription)
        }
      )
    } catch let error as DictationEngineError {
      guard self.generation == generation else { return nil }
      fail(error.localizedDescription)
      return nil
    } catch {
      guard self.generation == generation else { return nil }
      fail(DictationEngineError.startFailed.localizedDescription)
      return nil
    }
  }

  private func beginCapture(
    with started: DictationSession,
    inputNode: AVAudioInputNode,
    format: AVAudioFormat
  ) {
    let generation = generation
    session = started
    inputNode.installTap(
      onBus: 0,
      bufferSize: 1_024,
      format: format,
      block: Self.makeAudioTap(session: started) { [weak self] level in
        Task { @MainActor in
          guard let self, self.generation == generation, self.state == .listening else { return }
          self.onAudioLevel?(level)
        }
      }
    )
    hasInstalledAudioTap = true

    do {
      audioEngine.prepare()
      try audioEngine.start()
      state = .listening
    } catch {
      fail("Boltty could not start the microphone.")
    }
  }

  private func currentLanguages() async -> [DictationLanguage] {
    if let cachedLanguages { return cachedLanguages }
    let languages = await DictationCatalog.languages()
    cachedLanguages = languages
    return languages
  }

  private func stopAudioCapture(cancel: Bool = false) {
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    if hasInstalledAudioTap {
      audioEngine.inputNode.removeTap(onBus: 0)
      hasInstalledAudioTap = false
    }
    let stopped = session
    session = nil
    if cancel {
      stopped?.cancel()
    } else if let stopped {
      finalizingSession = stopped
      stopped.endAudio()
    }
  }

  nonisolated static func makeAudioTap(
    session: DictationSession,
    level: (@Sendable (CGFloat) -> Void)? = nil
  ) -> AVAudioNodeTapBlock {
    { @Sendable buffer, _ in
      session.append(buffer)
      guard let level else { return }
      level(loudness(of: buffer))
    }
  }

  nonisolated static func loudness(of buffer: AVAudioPCMBuffer) -> CGFloat {
    guard let channel = buffer.floatChannelData?[0] else { return 0 }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return 0 }

    var sum: Float = 0
    for index in 0..<count {
      let sample = channel[index]
      sum += sample * sample
    }
    let rms = (sum / Float(count)).squareRoot()
    guard rms > 0 else { return 0 }

    let floorDecibels: Float = -50
    let decibels = 20 * log10(rms)
    guard decibels > floorDecibels else { return 0 }
    return CGFloat(min(1, (decibels - floorDecibels) / -floorDecibels))
  }

  private func fail(_ message: String) {
    cancel()
    onError?(message)
  }

  private static func chosenLanguageName(_ identifier: String) -> String {
    guard identifier != DictationLanguageCatalog.followSystemIdentifier else {
      return Locale.current.localizedString(forIdentifier: Locale.current.identifier)
        ?? Locale.current.identifier
    }
    return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
  }

  private var hasRequiredUsageDescriptions: Bool {
    let keys = ["NSSpeechRecognitionUsageDescription", "NSMicrophoneUsageDescription"]
    return keys.allSatisfy { key in
      guard let value = usageDescription(key)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      else {
        return false
      }
      return !value.isEmpty
    }
  }

  private static func speechAuthorizationMessage(
    for status: SFSpeechRecognizerAuthorizationStatus
  ) -> String {
    switch status {
    case .denied:
      "Speech recognition access is required. Enable it in System Settings."
    case .restricted:
      "Speech recognition is restricted on this Mac."
    case .notDetermined:
      "Speech recognition permission was not granted."
    case .authorized:
      ""
    @unknown default:
      "Speech recognition is unavailable."
    }
  }
}
