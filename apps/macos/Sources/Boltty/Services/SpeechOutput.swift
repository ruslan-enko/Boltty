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
/// the person chose for its language, on the Mac's own synthesizer.
@MainActor
final class SpeechOutput: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
  struct Preferences: Equatable, Sendable {
    var voiceByLanguage: [String: String] = [:]
    var rate: Double = 1
  }

  /// What is being said: a message's id, or a preview's.
  @Published private(set) var speakingID: String?
  /// Counts up when macOS adds or removes a voice, so Settings lists it.
  @Published private(set) var voicesChanged = 0

  static let rateRange: ClosedRange<Double> = 0.6...1.8

  private let synthesizer = AVSpeechSynthesizer()
  private let preferences: () -> Preferences
  private var pending: Set<ObjectIdentifier> = []
  private var starts: [ObjectIdentifier: () -> Void] = [:]

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

  /// Whether Boltty says text in `language` (a code or a tag): one of
  /// Siri's languages, with a voice on this Mac for it.
  static func canSpeak(_ language: String?) -> Bool {
    guard let language, SpeechLanguages.speaks(language) else { return false }
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
    let utterance = enqueue(piece, language: code)
    if let onStart { starts[ObjectIdentifier(utterance)] = onStart }
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
    if speakingID != nil { speakingID = nil }
  }

  @discardableResult
  private func enqueue(_ piece: String, language code: String) -> AVSpeechUtterance {
    let utterance = AVSpeechUtterance(string: piece)
    let prefs = preferences()
    utterance.voice = voice(for: code).flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
      ?? AVSpeechSynthesisVoice(language: code)
    let rate = Double(AVSpeechUtteranceDefaultSpeechRate)
      * min(max(prefs.rate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
    utterance.rate = Float(min(max(rate, Double(AVSpeechUtteranceMinimumSpeechRate)),
                               Double(AVSpeechUtteranceMaximumSpeechRate)))
    pending.insert(ObjectIdentifier(utterance))
    synthesizer.speak(utterance)
    return utterance
  }

  private func started(_ utterance: ObjectIdentifier) {
    guard pending.contains(utterance) else { return }
    starts.removeValue(forKey: utterance)?()
  }

  private func finished(_ utterance: ObjectIdentifier) {
    starts.removeValue(forKey: utterance)
    guard pending.remove(utterance) != nil, pending.isEmpty else { return }
    speakingID = nil
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
  ) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.started(id) }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.finished(id) }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.finished(id) }
  }
}
