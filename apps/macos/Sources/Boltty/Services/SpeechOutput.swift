import Combine
import Foundation
import NaturalLanguage

enum LanguageCode {
  static func of(_ tag: String) -> String {
    String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
  }
}

@MainActor
final class SpeechOutput: ObservableObject {
  struct Preferences: Equatable, Sendable {
    var rate: Double = 1
    var local: Local?
  }

  struct Local: Equatable, Sendable {
    var folder: URL
    var voice: String
  }

  static let defaultLocalVoice = "M3"

  private(set) static var languages: Set<String> = []
  static func setLanguagesForTesting(_ value: Set<String>) { languages = value }
  var holdsPiecesForTesting = false
  func finishPiecesForTesting() { for token in pending { finished(token) } }

  @Published private(set) var speakingID: String?

  static let rateRange: ClosedRange<Double> = 0.6...1.8

  private let preferences: () -> Preferences
  private var pending: Set<Int> = []
  private var starts: [Int: () -> Void] = [:]
  private lazy var local = SupertonicSpeaker()
  private var piece = 0

  init(preferences: @escaping () -> Preferences) {
    self.preferences = preferences
  }

  func preferencesChanged() {
    let chosen = preferences().local
    Self.languages = chosen == nil ? [] : SupertonicText.languages
    guard chosen?.folder != local.folder else { return }
    if speakingID != nil { stop() }
    local.folder = chosen?.folder
    local.warm()
  }

  static func canSpeak(_ language: String?) -> Bool {
    guard let language else { return false }
    return languages.contains(LanguageCode.of(language))
  }

  static func canSpeak(text: String) -> Bool {
    canSpeak(language(of: SpokenText.speakable(text)))
  }

  func canSpeak(_ language: String?) -> Bool { Self.canSpeak(language) }

  nonisolated static func language(of text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    return recognizer.dominantLanguage.map { LanguageCode.of($0.rawValue) }
  }

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

  func say(_ piece: String, id: String, language: String?, onStart: (() -> Void)? = nil) {
    if speakingID != id {
      stop()
      speakingID = id
    }
    let code = language ?? Self.language(of: piece) ?? LanguageCode.of(Locale.current.identifier)
    guard let token = enqueue(piece, language: code) else { return }
    if let onStart { starts[token] = onStart }
  }

  func isSaying(_ id: String) -> Bool { speakingID == id }

  func stop() {
    pending.removeAll()
    starts.removeAll()
    local.stop()
    if speakingID != nil { speakingID = nil }
  }

  @discardableResult
  private func enqueue(_ text: String, language code: String) -> Int? {
    if holdsPiecesForTesting {
      piece += 1
      pending.insert(piece)
      return piece
    }
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
