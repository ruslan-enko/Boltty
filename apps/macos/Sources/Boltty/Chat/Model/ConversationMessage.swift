import Foundation

struct ConversationMessage: Identifiable, Codable, Equatable, Sendable {
  enum Role: String, Codable, Equatable, Sendable {
    case user
    case agent
  }

  let id: String
  var role: Role
  var createdAt: Date
  var completedAt: Date?
  var parts: [ConversationPart]
  var failure: MessageFailure?

  init(
    id: String,
    role: Role,
    createdAt: Date,
    completedAt: Date? = nil,
    parts: [ConversationPart] = [],
    failure: MessageFailure? = nil
  ) {
    self.id = id
    self.role = role
    self.createdAt = createdAt
    self.completedAt = completedAt
    self.parts = parts
    self.failure = failure
  }

  var plainText: String {
    parts.compactMap { part -> String? in
      if case let .text(text) = part { return text.text }
      return nil
    }
    .joined(separator: "\n\n")
  }

  func containsText(_ needle: String) -> Bool {
    parts.contains { part in
      guard case let .text(text) = part else { return false }
      return text.text.range(of: needle, options: [.caseInsensitive]) != nil
    }
  }

  mutating func upsert(_ part: ConversationPart) {
    guard let index = parts.firstIndex(where: { $0.id == part.id }) else {
      parts.append(part)
      return
    }
    parts[index] = ConversationPart.merged(existing: parts[index], incoming: part)
  }

  mutating func appendDelta(_ delta: String, toPart partID: String, kind: ConversationPart.TextKind) {
    if let index = parts.firstIndex(where: { $0.id == partID }) {
      guard case var .text(existing) = parts[index], existing.kind == kind else {
        if case var .reasoning(existing) = parts[index], kind == .reasoning {
          existing.text += delta
          parts[index] = .reasoning(existing)
        }
        return
      }
      existing.text += delta
      parts[index] = .text(existing)
      return
    }
    let part = TextPart(id: partID, kind: kind, text: delta)
    parts.append(kind == .reasoning ? .reasoning(part) : .text(part))
  }

  mutating func removePart(id partID: String) {
    parts.removeAll { $0.id == partID }
  }
}

struct MessageFailure: Codable, Equatable, Sendable {
  var name: String
  var message: String
  var rateLimit: RateLimitHit?
  var isAbort: Bool { name == "MessageAbortedError" || name == "aborted" }
}

enum ConversationPart: Identifiable, Codable, Equatable, Sendable {
  case text(TextPart)
  case reasoning(TextPart)
  case activity(AgentActivity)
  case attachment(ConversationAttachment)

  enum TextKind: String, Codable, Equatable, Sendable {
    case text
    case reasoning
  }

  var id: String {
    switch self {
    case let .text(part), let .reasoning(part): return part.id
    case let .activity(activity): return activity.id
    case let .attachment(attachment): return attachment.id
    }
  }

  var isEmpty: Bool {
    switch self {
    case let .text(part), let .reasoning(part):
      return part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .activity, .attachment:
      return false
    }
  }

  static func merged(existing: ConversationPart, incoming: ConversationPart) -> ConversationPart {
    guard case let .activity(old) = existing, case var .activity(new) = incoming else {
      return incoming
    }
    if new.name.isEmpty { new.name = old.name }
    if new.summary == nil { new.summary = old.summary }
    if new.detail == nil { new.detail = old.detail }
    if new.files.isEmpty { new.files = old.files }
    if new.startedAt == nil { new.startedAt = old.startedAt }
    if new.endedAt == nil { new.endedAt = old.endedAt }
    if new.plan == nil { new.plan = old.plan }
    return .activity(new)
  }
}

struct TextPart: Identifiable, Codable, Equatable, Sendable {
  let id: String
  var kind: ConversationPart.TextKind
  var text: String
}

struct AgentActivity: Identifiable, Codable, Equatable, Sendable {
  enum State: String, Codable, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
  }

  let id: String
  var name: String
  var summary: String?
  var state: State
  var detail: String?
  var files: [String]
  var startedAt: Date?
  var endedAt: Date?
  var plan: [PlanStep]?

  init(
    id: String,
    name: String,
    summary: String? = nil,
    state: State = .pending,
    detail: String? = nil,
    files: [String] = [],
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    plan: [PlanStep]? = nil
  ) {
    self.id = id
    self.name = name
    self.summary = summary
    self.state = state
    self.detail = detail
    self.files = files
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.plan = plan
  }

  var headline: String {
    if let summary, !summary.isEmpty { return summary }
    if let file = files.first { return "\(name) \((file as NSString).lastPathComponent)" }
    return name
  }
}

struct PlanStep: Codable, Equatable, Sendable {
  enum Status: String, Codable, Equatable, Sendable {
    case pending, inProgress, completed
  }

  var text: String
  var status: Status
}

struct ConversationAttachment: Identifiable, Codable, Equatable, Sendable {
  let id: String
  var displayName: String
  var url: URL?
  var mimeType: String?
  var byteCount: Int?
  var isAnalysable: Bool

  init(
    id: String,
    displayName: String,
    url: URL? = nil,
    mimeType: String? = nil,
    byteCount: Int? = nil,
    isAnalysable: Bool = true
  ) {
    self.id = id
    self.displayName = displayName
    self.url = url
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.isAnalysable = isAnalysable
  }
}
