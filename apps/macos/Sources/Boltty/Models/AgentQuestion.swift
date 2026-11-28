import Foundation

enum AgentReportedState: Equatable, Sendable {
  case blocked
  case running
  case finished
  case failed
}

struct AgentQuestion: Equatable, Sendable {
  enum Kind: String, Equatable, Sendable {
    case question
    case permission
    case plan
  }

  struct Option: Equatable, Sendable {
    let label: String
    let detail: String?
    var value: String

    init(label: String, detail: String?, value: String? = nil) {
      self.label = label
      self.detail = detail
      self.value = value ?? label
    }
  }

  let kind: Kind
  let requestID: String
  let header: String?
  let prompt: String
  var detail: String? = nil
  let options: [Option]
  let allowsMultiple: Bool
  let allowsCustom: Bool
  var copyText: String? = nil
  var isLate: Bool = false

  var keyboardFooter: String {
    if takesWordsAsAnswer {
      return allowsMultiple
        ? String(localized: "↑↓ move · Space chooses · ↵ sends · or type your own answer below")
        : String(localized: "↑↓ move · ↵ confirms · click a row, or type your own answer below")
    }
    let numbers = answersByNumber ? (options.count == 1 ? "1" : "1–\(options.count)") : nil
    if allowsMultiple {
      return numbers.map { String(localized: "↑↓ move · Space or \($0) chooses · ↵ sends · click a row to choose it") }
        ?? String(localized: "↑↓ move · Space chooses · ↵ sends · click a row to choose it")
    }
    return numbers.map { String(localized: "↑↓ move · ↵ confirms · \($0) or click a row to confirm it") }
      ?? String(localized: "↑↓ move · ↵ confirms · click a row to confirm it")
  }

  var answersByNumber: Bool {
    !allowsCustom && !takesWordsAsRefusal && (1...9).contains(options.count)
  }

  var takesWordsAsRefusal: Bool { kind == .permission || planWordsOption != nil }

  /// The plan's answer that carries words, where its CLI offers one.
  var planWordsOption: Option? {
    guard kind == .plan else { return nil }
    return options.first { PlanAnswer(rawValue: $0.value)?.takesWords == true }
  }

  func refusing(with words: String) -> [String] {
    if let option = planWordsOption { return [option.value, words] }
    return Self.refusal(saying: words)
  }

  var refusalWords: String { planWordsOption?.label ?? String(localized: "Deny and send") }

  var returnReachableCount: Int {
    guard kind == .plan else { return options.count }
    return max(options.filter { PlanAnswer(rawValue: $0.value)?.decision != .abandoned }.count, 1)
  }

  var takesWordsAsAnswer: Bool { kind == .question && allowsCustom }

  static let typedAnswerFooter = String(localized: "↵ sends what you typed as the answer")

  static func answer(_ values: [String], carries typed: String) -> Bool {
    let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return false }
    return values.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == words }
  }

  static func refusal(saying words: String) -> [String] {
    [PermissionDecision.reject.rawValue, words]
  }

  static func alwaysAllowScope(savePatterns: [String]) -> String {
    let patterns = savePatterns
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !patterns.isEmpty else { return String(localized: "this session") }
    return patterns.count == 1
      ? String(localized: "this chat, for \(patterns[0])")
      : String(localized: "this chat, for \(patterns.count) rules")
  }
}
