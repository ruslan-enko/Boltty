import Combine
import Foundation
import NaturalLanguage

/// `en`, `uk`: a language tag's language, whatever its region.
enum LanguageCode {
  static func of(_ tag: String) -> String {
    String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
  }
}

/// Boltty's voice: an answer said aloud, sentence by sentence, by Supertonic
/// on this Mac. Nothing is said until it is downloaded, nor in a language it
/// does not speak: the Mac's own voices are not used, because in Boltty they
/// are the compact ones (Siri's are spoken only for Apple's apps).
@MainActor
final class SpeechOutput: ObservableObject {
  struct Preferences: Equatable, Sendable {
    var rate: Double = 1
    /// Supertonic's folder and preset once it is downloaded.
    var local: Local?
  }

  struct Local: Equatable, Sendable {
    var folder: URL
    var voice: String
  }

  /// Supertonic's preset until the person picks one: the clearest in
  /// Ukrainian when read back by Parakeet (3.6 % CER).
  static let defaultLocalVoice = "M3"

  /// The languages said now; empty until Supertonic is here.
  private(set) static var languages: Set<String> = []

  /// What is being said: a message's id, or a preview's.
  @Published private(set) var speakingID: String?

  static let rateRange: ClosedRange<Double> = 0.6...1.8

  private let preferences: () -> Preferences
  /// Pieces still to be heard, by number.
  private var pending: Set<Int> = []
  private var starts: [Int: () -> Void] = [:]
  private lazy var local = SupertonicSpeaker()
  private var piece = 0

  init(preferences: @escaping () -> Preferences) {
    self.preferences = preferences
  }

  /// Reads the preferences again: the model was downloaded or removed.
  /// Loads it ahead of the first answer.
  func preferencesChanged() {
    let chosen = preferences().local
    Self.languages = chosen == nil ? [] : SupertonicText.languages
    guard chosen?.folder != local.folder else { return }
    if speakingID != nil { stop() }
    local.folder = chosen?.folder
    local.warm()
  }

  /// Whether Boltty says text in `language` (a code or a tag).
  static func canSpeak(_ language: String?) -> Bool {
    guard let language else { return false }
    return languages.contains(LanguageCode.of(language))
  }

  /// Whether an answer would be said: the language it is written in.
  static func canSpeak(text: String) -> Bool {
    canSpeak(language(of: SpokenText.speakable(text)))
  }

  func canSpeak(_ language: String?) -> Bool { Self.canSpeak(language) }

  /// The language a text is in, for choosing how it is read.
  nonisolated static func language(of text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    return recognizer.dominantLanguage.map { LanguageCode.of($0.rawValue) }
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
    let code = language ?? Self.language(of: text) ?? LanguageCode.of(Locale.current.identifier)
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
    let code = language ?? Self.language(of: piece) ?? LanguageCode.of(Locale.current.identifier)
    guard let token = enqueue(piece, language: code) else { return }
    if let onStart { starts[token] = onStart }
  }

  /// Whether anything said for `id` is still to be heard.
  func isSaying(_ id: String) -> Bool { speakingID == id }

  func stop() {
    pending.removeAll()
    starts.removeAll()
    local.stop()
    if speakingID != nil { speakingID = nil }
  }

  /// Hands `text` to Supertonic and returns what it is known by until it has
  /// been heard; nil when it cannot be said.
  @discardableResult
  private func enqueue(_ text: String, language code: String) -> Int? {
    let prefs = preferences()
    guard let chosen = prefs.local, SupertonicText.languages.contains(code) else {
      if pending.isEmpty { speakingID = nil }
      return nil
    }
    piece += 1
    let token = piece
    pending.insert(token)
    let rate = min(max(prefs.rate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
    local.say(
      text, language: code, delivery: .init(voice: chosen.voice, rate: rate),
      onStart: { [weak self] in self?.started(token) },
      onFinish: { [weak self] _ in self?.finished(token) })
    return token
  }

  private func started(_ token: Int) {
    guard pending.contains(token) else { return }
    starts.removeValue(forKey: token)?()
  }

  private func finished(_ token: Int) {
    starts.removeValue(forKey: token)
    guard pending.remove(token) != nil, pending.isEmpty else { return }
    speakingID = nil
  }
}
