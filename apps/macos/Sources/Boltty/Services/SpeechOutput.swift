import AVFoundation
import Combine
import NaturalLanguage

/// A voice the Mac has, as a value: what Settings lists and what is chosen.
struct SpeechVoice: Identifiable, Equatable, Sendable {
  enum Quality: Int, Comparable, Sendable {
    case standard, enhanced, premium
    static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
  }

  let id: String
  let name: String
  /// BCP 47, as the system spells it: `en-US`, `uk-UA`.
  let language: String
  let quality: Quality

  /// `en`, `uk`: what a voice is chosen by, whatever its region.
  var languageCode: String { SpeechVoice.code(of: language) }

  var displayName: String {
    switch quality {
    case .standard: name
    case .enhanced: "\(name) (Enhanced)"
    case .premium: "\(name) (Premium)"
    }
  }

  /// Among voices of one quality, the Mac's own reading voices before
  /// Eloquence's and the novelty voices (Albert, Bad News…), and the compact
  /// download before the super-compact one built in.
  var standing: Int {
    guard id.hasPrefix("com.apple.voice.") else { return 0 }
    return id.contains(".super-compact.") ? 1 : 2
  }

  static func code(of language: String) -> String {
    String(language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
  }

  /// The chosen voice when it is still installed and speaks this language;
  /// otherwise the best one for it — the person's region first among equals.
  static func choose(
    language code: String, among voices: [SpeechVoice], chosen: String?, region: String?
  ) -> SpeechVoice? {
    let candidates = voices.filter { $0.languageCode == code }
    if let chosen, let voice = candidates.first(where: { $0.id == chosen }) { return voice }
    return candidates.max { a, b in
      if a.quality != b.quality { return a.quality < b.quality }
      if a.standing != b.standing { return a.standing < b.standing }
      let aHome = region.map { a.language.hasSuffix($0) } ?? false
      let bHome = region.map { b.language.hasSuffix($0) } ?? false
      if aHome != bHome { return !aHome }
      return a.name > b.name
    }
  }
}

/// The languages Boltty speaks: Siri's on macOS 27 (per
/// apple.com/macos/feature-availability — English,
/// Arabic, Mandarin and Cantonese, Danish, Dutch, Finnish, French, German,
/// Italian, Japanese, Korean, Norwegian, Portuguese, Russian, Spanish,
/// Swedish, Thai, Turkish, Vietnamese). An answer in any other is shown and
/// never said: the Mac's voice for it, where there is one, is not one to
/// listen to — Ukrainian's is Lesya, compact. Codes are
/// `SpeechVoice.code(of:)`'s; both Chinese are `zh`.
enum SpeechLanguages {
  static let spoken: [String] = [
    "en", "ar", "zh", "da", "nl", "fi", "fr", "de", "it", "ja", "ko", "nb", "pt", "ru", "es",
    "sv", "th", "tr", "vi",
  ]

  static func speaks(_ code: String?) -> Bool {
    guard let code else { return false }
    return spoken.contains(normalised(code))
  }

  /// Norwegian is `nb` to the voices and sometimes `no` to a language tag.
  static func normalised(_ code: String) -> String {
    let base = SpeechVoice.code(of: code)
    return base == "no" || base == "nn" ? "nb" : base
  }
}

/// Boltty's voice: an answer said aloud, sentence by sentence, in the voice
/// the person chose for its language — Supertonic's on this Mac where it is
/// chosen, downloaded and speaks the language, the Mac's own otherwise.
@MainActor
final class SpeechOutput: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
  struct Preferences: Equatable, Sendable {
    var voiceByLanguage: [String: String] = [:]
    var rate: Double = 1
    /// Supertonic's folder and preset when it is chosen and ready.
    var local: Local?
  }

  struct Local: Equatable, Sendable {
    var folder: URL
    var voice: String
  }

  /// Supertonic's preset until the person picks one: the clearest in
  /// Ukrainian when read back by Parakeet (3.6 % CER, Lesya 6.0 %).
  static let defaultLocalVoice = "M3"

  /// The languages the local voice reads now; empty while it is off.
  private(set) static var localLanguages: Set<String> = []

  /// What is being said: a message's id, or a preview's.
  @Published private(set) var speakingID: String?
  /// Counts up when macOS adds or removes a voice, so Settings lists it.
  @Published private(set) var voicesChanged = 0

  static let rateRange: ClosedRange<Double> = 0.6...1.8

  private let synthesizer = AVSpeechSynthesizer()
  private let preferences: () -> Preferences
  /// What is still to be heard: Apple's utterances by object, Supertonic's
  /// pieces by number.
  private var pending: Set<AnyHashable> = []
  private var starts: [AnyHashable: () -> Void] = [:]
  private lazy var local = SupertonicSpeaker()
  private var localPiece = 0

  init(preferences: @escaping () -> Preferences) {
    self.preferences = preferences
    super.init()
    synthesizer.delegate = self
    Self.warmVoices()
    NotificationCenter.default.addObserver(
      self, selector: #selector(voicesDidChange),
      name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
  }

  /// Posted on whatever thread macOS likes, so not the main actor's.
  @objc nonisolated private func voicesDidChange() {
    Task { @MainActor in
      Self.forgetVoices()
      self.voicesChanged += 1
    }
  }

  /// Reads the preferences again: Settings changed the engine or voice, or
  /// the model was downloaded or removed. Loads the local voice ahead of the
  /// first answer.
  func preferencesChanged() {
    let chosen = preferences().local
    Self.localLanguages = chosen == nil ? [] : SupertonicText.languages
    guard chosen?.folder != local.folder else { return }
    if speakingID != nil { stop() }
    local.folder = chosen?.folder
    local.warm()
  }

  /// Why the local voice did not speak last time, if it did not.
  var localFailure: String? { local.failure }

  /// Whether Boltty says text in `language` (a code or a tag): one the local
  /// voice reads, or one of Siri's languages with a voice on this Mac for it.
  static func canSpeak(_ language: String?) -> Bool {
    guard let language else { return false }
    if localLanguages.contains(SpeechVoice.code(of: language)) { return true }
    guard SpeechLanguages.speaks(language) else { return false }
    let code = SpeechLanguages.normalised(language)
    return installedVoices().contains { SpeechLanguages.normalised($0.language) == code }
  }

  /// Whether an answer would be said: the language it is written in.
  static func canSpeak(text: String) -> Bool {
    canSpeak(language(of: SpokenText.speakable(text)))
  }

  func canSpeak(_ language: String?) -> Bool { Self.canSpeak(language) }

  /// Listing the Mac's voices costs ~100 ms (180 voices), too much to ask
  /// before every sentence. It is read once — away from the main
  /// thread when there is time (`warmVoices`) — and again only when macOS
  /// says the set changed (a voice downloaded or removed).
  private static var voiceList: [SpeechVoice]?
  private static var voiceWatcher: NSObjectProtocol?

  static func installedVoices() -> [SpeechVoice] {
    if let voiceList { return voiceList }
    let list = readVoices()
    remember(list)
    return list
  }

  /// Reads the list off the main thread, so the first answer does not wait on it.
  static func warmVoices() {
    guard voiceList == nil else { return }
    Task.detached(priority: .utility) {
      let list = readVoices()
      await MainActor.run { if voiceList == nil { remember(list) } }
    }
  }

  /// Siri's voices are listed to every app but spoken only for Apple's: in
  /// Boltty they come out as compact Samantha, muffled, with no error
  /// (macOS 27.2, same code in an Apple-signed process gives Siri at 48 kHz).
  /// `gryphon-neural` is the bundle behind one of them and does the same.
  nonisolated static func isAppleOnly(_ identifier: String) -> Bool {
    identifier.hasPrefix("com.apple.siri.") || identifier.contains("gryphon-neural")
  }

  nonisolated private static func readVoices() -> [SpeechVoice] {
    AVSpeechSynthesisVoice.speechVoices().filter { !isAppleOnly($0.identifier) }.map { voice in
      let quality: SpeechVoice.Quality = switch voice.quality {
      case .premium: .premium
      case .enhanced: .enhanced
      default: .standard
      }
      return SpeechVoice(
        id: voice.identifier, name: voice.name, language: voice.language, quality: quality)
    }
  }

  private static func remember(_ list: [SpeechVoice]) {
    voiceList = list
    guard voiceWatcher == nil else { return }
    voiceWatcher = NotificationCenter.default.addObserver(
      forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { forgetVoices() }
    }
  }

  private static func forgetVoices() { voiceList = nil }

  /// The language a text is in, for choosing its voice.
  nonisolated static func language(of text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    return recognizer.dominantLanguage.map { SpeechVoice.code(of: $0.rawValue) }
  }

  /// Says a whole answer, or stops it when it is the one being said.
  func toggle(markdown: String, id: String) {
    if speakingID == id { return stop() }
    speak(markdown: markdown, id: id)
  }

  func speak(markdown: String, id: String, language: String? = nil) {
    stop()
    let text = SpokenText.speakable(markdown)
    var chunker = SentenceChunker()
    let pieces = chunker.append(text + "\n") + chunker.finish()
    guard !pieces.isEmpty else { return }
    let code = language ?? Self.language(of: text) ?? SpeechVoice.code(of: Locale.current.identifier)
    guard Self.canSpeak(code) else { return }
    speakingID = id
    for piece in pieces { enqueue(piece, language: code) }
  }

  /// Adds one piece, already speakable, to what is being said for `id`:
  /// Ask Boltty feeds an answer this way a sentence at a time as it arrives.
  /// A piece for another id stops what was being said first.
  /// `onStart` runs as the voice begins this piece — Ask Boltty's caption and its
  /// pointing follow what is heard, not what is queued.
  func say(_ piece: String, id: String, language: String?, onStart: (() -> Void)? = nil) {
    if speakingID != id {
      stop()
      speakingID = id
    }
    let code = language ?? Self.language(of: piece) ?? SpeechVoice.code(of: Locale.current.identifier)
    let token = enqueue(piece, language: code)
    if let onStart { starts[token] = onStart }
  }

  /// The voice an answer in `code` is read in.
  func voice(for code: String) -> SpeechVoice? {
    SpeechVoice.choose(
      language: code, among: Self.installedVoices(),
      chosen: preferences().voiceByLanguage[code], region: Locale.current.region?.identifier)
  }

  /// Whether anything said for `id` is still to be heard.
  func isSaying(_ id: String) -> Bool { speakingID == id }

  func stop() {
    pending.removeAll()
    starts.removeAll()
    if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    local.stop()
    if speakingID != nil { speakingID = nil }
  }

  /// Hands `piece` to the voice for its language and returns what it is
  /// known by until it has been heard.
  @discardableResult
  private func enqueue(_ piece: String, language code: String) -> AnyHashable {
    let prefs = preferences()
    if let chosen = prefs.local, SupertonicText.languages.contains(code) {
      localPiece += 1
      let token = AnyHashable(localPiece)
      pending.insert(token)
      let rate = min(max(prefs.rate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
      local.say(
        piece, language: code, delivery: .init(voice: chosen.voice, rate: rate),
        onStart: { [weak self] in self?.started(token) },
        onFinish: { [weak self] said in
          guard let self else { return }
          // A model that will not load or speak leaves the piece to the
          // Mac's voice, where it has one, rather than to silence.
          if !said, self.pending.contains(token), SpeechLanguages.speaks(code) {
            let start = self.starts.removeValue(forKey: token)
            let fallback = self.speakWithApple(piece, language: code)
            if let start { self.starts[fallback] = start }
          }
          self.finished(token)
        })
      return token
    }
    return speakWithApple(piece, language: code)
  }

  private func speakWithApple(_ piece: String, language code: String) -> AnyHashable {
    let utterance = AVSpeechUtterance(string: piece)
    let prefs = preferences()
    utterance.voice = voice(for: code).flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
      ?? AVSpeechSynthesisVoice(language: code)
    let rate = Double(AVSpeechUtteranceDefaultSpeechRate)
      * min(max(prefs.rate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
    utterance.rate = Float(min(max(rate, Double(AVSpeechUtteranceMinimumSpeechRate)),
                               Double(AVSpeechUtteranceMaximumSpeechRate)))
    let token = AnyHashable(ObjectIdentifier(utterance))
    pending.insert(token)
    synthesizer.speak(utterance)
    return token
  }

  private func started(_ token: AnyHashable) {
    guard pending.contains(token) else { return }
    starts.removeValue(forKey: token)?()
  }

  private func finished(_ token: AnyHashable) {
    starts.removeValue(forKey: token)
    guard pending.remove(token) != nil, pending.isEmpty else { return }
    speakingID = nil
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
  ) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.started(AnyHashable(id)) }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.finished(AnyHashable(id)) }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.finished(AnyHashable(id)) }
  }
}
