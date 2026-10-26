import Foundation

struct PendingInteraction: Identifiable, Codable, Equatable, Sendable {
  let id: String
  let conversationID: UUID
  let remoteSessionID: String
  var kind: Kind
  var askedAt: Date
  var resolution: Resolution?
  var isSubmitting: Bool

  init(
    id: String,
    conversationID: UUID,
    remoteSessionID: String,
    kind: Kind,
    askedAt: Date = Date(),
    resolution: Resolution? = nil,
    isSubmitting: Bool = false
  ) {
    self.id = id
    self.conversationID = conversationID
    self.remoteSessionID = remoteSessionID
    self.kind = kind
    self.askedAt = askedAt
    self.resolution = resolution
    self.isSubmitting = isSubmitting
  }

  var isOpen: Bool { resolution == nil }
  var acceptsInput: Bool { resolution == nil && !isSubmitting }

  enum Kind: Codable, Equatable, Sendable {
    case question(QuestionPrompt)
    case permission(PermissionPrompt)
    case plan(PlanPrompt)
  }

  enum Resolution: Codable, Equatable, Sendable {
    case answered([[String]])
    case rejected
    case permission(PermissionDecision)
    case plan(PlanDecision)
    case resolvedElsewhere
    case expired
  }
}

struct QuestionPrompt: Codable, Equatable, Sendable {
  var items: [QuestionItem]
  var toolCallID: String?
}

struct QuestionItem: Codable, Equatable, Sendable {
  var key: String?
  var header: String
  var question: String
  var choices: [AgentChoice]
  var allowsMultiple: Bool
  var allowsCustom: Bool

  init(
    key: String? = nil,
    header: String,
    question: String,
    choices: [AgentChoice],
    allowsMultiple: Bool,
    allowsCustom: Bool
  ) {
    self.key = key
    self.header = header
    self.question = question
    self.choices = choices
    self.allowsMultiple = allowsMultiple
    self.allowsCustom = allowsCustom
  }
}

struct AgentChoice: Codable, Equatable, Identifiable, Sendable {
  let value: String
  var label: String
  var detail: String?

  var id: String { value }

  init(value: String, label: String? = nil, detail: String? = nil) {
    self.value = value
    self.label = label ?? value
    self.detail = detail
  }
}

struct PermissionPrompt: Codable, Equatable, Sendable {
  var action: String
  var resources: [String]
  var savePatterns: [String]
  var toolCallID: String?
}

enum PermissionDecision: String, Codable, Equatable, Sendable {
  case once
  case always
  case reject
}

struct PlanPrompt: Codable, Equatable, Sendable {
  var markdown: String
  var toolCallID: String?

  var title: String {
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("#") else { continue }
      let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
      if !heading.isEmpty { return heading }
    }
    return "Plan"
  }

  static let emptyText = "No plan written yet"
}

enum PlanDecision: String, Codable, Equatable, Sendable {
  case approved
  case cancelled
  case abandoned
}
