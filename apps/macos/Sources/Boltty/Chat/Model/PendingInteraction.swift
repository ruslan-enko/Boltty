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
  var isLate: Bool { resolution == .askGone }

  var goneResolution: Resolution {
    if case .question = kind { return .askGone }
    return .expired
  }

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
    case askGone
  }
}

struct QuestionPrompt: Codable, Equatable, Sendable {
  var items: [QuestionItem]
  var toolCallID: String?

  func lateAnswer(_ answers: [[String]]) -> String {
    zip(items, answers).map { item, values in
      let said = values.map { value in
        item.choices.first { $0.value == value }?.label ?? value
      }
      return "«\(item.question)» — \(said.joined(separator: ", "))"
    }
    .joined(separator: "\n")
  }
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
  var offersAlways: Bool? = nil
  /// What the CLI's own "always" does, in its words or from its record of where it saves.
  var alwaysReach: String? = nil
  var offersRejectAlways: Bool? = nil

  static func elicitation(
    server: String, mode: String?, message: String?, schema: JSONObject?, toolCallID: String?
  ) -> PermissionPrompt? {
    guard (mode ?? "form") == "form", schema?.object("properties")?.raw.isEmpty ?? true,
          let message, !message.isEmpty
    else { return nil }
    return PermissionPrompt(
      action: server, resources: [message], savePatterns: [], toolCallID: toolCallID, offersAlways: false)
  }
}

enum PermissionDecision: String, Codable, Equatable, Sendable {
  case once
  case always
  case reject
  case rejectAlways
}

struct PlanPrompt: Codable, Equatable, Sendable {
  var markdown: String
  var toolCallID: String?
  /// Optional so plans stored before it still read.
  var endedTurn: Bool?
  /// The answers the agent's own CLI offers, in its order; absent on plans stored before.
  var answers: [PlanAnswer]?

  var isAnsweredByMessage: Bool { endedTurn == true }

  var offered: [PlanAnswer] { answers ?? [.approve, .requestChanges, .quit] }

  var title: String {
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("#") else { continue }
      let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
      if !heading.isEmpty { return heading }
    }
    return "Plan"
  }

  static let emptyText = String(localized: "No plan written yet")
}

enum PlanDecision: String, Codable, Equatable, Sendable {
  case approved
  case cancelled
  case abandoned
}

/// A plan's answer in its CLI's words. Claude Code's approvals name the mode the work goes on in.
enum PlanAnswer: String, Codable, Equatable, Sendable {
  case approve, requestChanges, quit
  case implement, stayInPlan
  case bypass, useAuto, acceptEdits, approveEdits, keepPlanning
  case proceed

  var decision: PlanDecision {
    switch self {
    case .approve, .implement, .bypass, .useAuto, .acceptEdits, .approveEdits, .proceed: .approved
    case .requestChanges, .stayInPlan, .keepPlanning: .cancelled
    case .quit: .abandoned
    }
  }

  var takesWords: Bool { decision == .cancelled }

  var mode: String? {
    switch self {
    case .bypass: ClaudeCodeClient.bypassMode
    case .useAuto: "auto"
    case .acceptEdits: "acceptEdits"
    case .approveEdits: "default"
    default: nil
    }
  }

  /// What goes as the next message where the plan ended the turn.
  var message: String? {
    switch self {
    case .implement: "Implement the plan."
    case .proceed: "The user has approved this document."
    default: nil
    }
  }

  var title: String {
    switch self {
    case .approve: String(localized: "Approve")
    case .requestChanges: String(localized: "Request Changes")
    case .quit: String(localized: "Quit")
    case .implement: String(localized: "Yes, Implement This Plan")
    case .stayInPlan: String(localized: "No, Stay in Plan Mode")
    case .bypass: String(localized: "Yes, and Bypass Permissions")
    case .useAuto: String(localized: "Yes, and Use Auto Mode")
    case .acceptEdits: String(localized: "Yes, Auto-Accept Edits")
    case .approveEdits: String(localized: "Yes, Manually Approve Edits")
    case .keepPlanning: String(localized: "No, Keep Planning")
    case .proceed: String(localized: "Proceed")
    }
  }
}
