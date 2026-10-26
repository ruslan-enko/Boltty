import Foundation

enum BolttyAIFollowUp {
  enum Action: Equatable, Sendable {
    case launchNew
    case send(UUID)
    case open(UUID)
    case nothing
  }

  static func confirmPrompt(
    promptIsEmpty: Bool,
    addressedConversation: Conversation?
  ) -> Action {
    guard let addressed = addressedConversation else { return promptIsEmpty ? .nothing : .launchNew }
    return promptIsEmpty ? .open(addressed.id) : .send(addressed.id)
  }

  static func isBusy(reported: AgentReportedState?) -> Bool {
    reported == .running
  }

  enum QueuedSend: Equatable, Sendable {
    case queued
    case replaced
    case steered
  }

  static func queuedMessage(_ outcome: QueuedSend, agent: AgentId) -> String {
    switch outcome {
    case .queued:
      return "Waiting for this turn to finish — this sends next."
    case .replaced:
      return "Replaced the message that was waiting — this sends next."
    case .steered:
      return "Added to the turn that's running."
    }
  }

  static func busyMessage(agent: AgentId) -> String {
    "There's a question above waiting for an answer — reply to it first"
  }

  static func statusLabel(reported: AgentReportedState?) -> String {
    switch reported {
    case .blocked: "Waiting for you"
    case .running: "Working"
    case .finished: "Finished"
    case .failed: "Failed"
    case nil: "Running"
    }
  }
}

struct BolttyAISessionPreview: Equatable, Sendable {
  let id: UUID
  let title: String
  let agent: AgentId
  let state: AgentReportedState?
  let body: String
  var question: AgentQuestion? = nil

  var messages: [ConversationMessage] = []
  var canStop = false
  var stopIsAbrupt = false
  var canSteer = false
  /// The chat's Auto Mode, or `nil` where its agent declares no
  /// `.autoApproval` — then the composer offers no switch for it.
  var autoMode: Bool? = nil
  var notice: String? = nil
  var retryPrompt: String? = nil
  var queuedPrompt: String? = nil
  var isInitialThinking: Bool {
    isBusy && question == nil && (!messages.isEmpty || body.isEmpty) && !messages.contains { $0.role == .agent && !$0.plainText.isEmpty }
  }
  var statusLabel: String { BolttyAIFollowUp.statusLabel(reported: state) }
  var isBusy: Bool { BolttyAIFollowUp.isBusy(reported: state) }

  var withholdsAnswer: Bool {
    guard isBusy, question == nil, notice == nil, retryPrompt == nil,
          queuedPrompt == nil
    else { return false }
    return !messages.contains { $0.failure != nil }
  }

  var visibleMessages: [ConversationMessage] {
    guard withholdsAnswer else { return messages }
    return messages.compactMap { message in
      message.role == .user || message.completedAt != nil ? message : message.settledPart
    }
  }

  var currentStep: String? {
    let activities = inFlightActivities
    if let plan = activities.last(where: { $0.plan != nil })?.plan,
       let index = plan.firstIndex(where: { $0.status == .inProgress }) {
      let count = "\(index + 1) of \(plan.count) · "
      let room = max(BolttyAISessionPreview.stepLabelLimit - count.count, 8)
      let text = plan[index].text
      return count + (text.count > room ? String(text.prefix(room - 1)) + "…" : text)
    }
    let unfinished = activities.last { $0.state == .running || $0.state == .pending }
    guard let activity = unfinished ?? activities.last else { return nil }
    let headline = activity.headline.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !headline.isEmpty else { return nil }
    return headline.middleTruncated(to: BolttyAISessionPreview.stepLabelLimit)
  }

  var workingPhrase: String? {
    let activities = inFlightActivities
    if let plan = activities.last(where: { $0.plan != nil })?.plan,
       plan.contains(where: { $0.status == .inProgress }) {
      return currentStep
    }
    guard let running = activities.last(where: { $0.state == .running || $0.state == .pending })
    else { return nil }
    return AgentActivityGroup.kind(of: running).progressive
  }

  private var inFlightActivities: [AgentActivity] {
    guard let reply = messages.last(where: { $0.role == .agent && $0.completedAt == nil })
    else { return [] }
    return reply.parts.compactMap {
      if case let .activity(activity) = $0 { return activity }
      return nil
    }
  }

  static let stepLabelLimit = 34

  var hasNothingToShowYet: Bool {
    guard withholdsAnswer else { return false }
    if messages.contains(where: { $0.role == .agent && $0.completedAt != nil }) { return false }
    if streamingTail != nil { return false }
    return !visibleMessages.contains { $0.role == .agent && $0.hasProse }
  }

  var streamingTail: String? {
    guard withholdsAnswer,
          let reply = messages.last(where: { $0.role == .agent && $0.completedAt == nil })
    else { return nil }
    let lastActivity = reply.parts.lastIndex {
      if case .activity = $0 { return true }
      return false
    }
    let afterWork = lastActivity.map { $0 + 1 } ?? 0
    guard let growing = reply.parts[afterWork...].last(where: {
      if case .text = $0 { return true }
      return false
    }), case let .text(part) = growing else { return nil }
    let tail = StreamingProse.split(part.text).open
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return tail.isEmpty ? nil : tail
  }

  var displayBody: String {
    guard let question, !body.contains(question.prompt) else { return body }
    return body.isEmpty ? question.prompt : body + "\n\n" + question.prompt
  }
}

extension ConversationMessage {
  var settledPart: ConversationMessage? {
    let lastActivity = parts.lastIndex(where: {
      if case .activity = $0 { return true }
      return false
    })
    let afterWork = lastActivity.map { $0 + 1 } ?? 0
    let growing = parts[afterWork...].lastIndex(where: {
      if case .text = $0 { return true }
      return false
    })
    guard let growing else {
      guard let lastActivity else { return nil }
      var settled = self
      settled.parts = Array(parts[...lastActivity])
      return settled
    }
    var kept = Array(parts[..<growing])
    if case var .text(part) = parts[growing] {
      let closed = StreamingProse.split(part.text).closed
      if !closed.isEmpty {
        part.text = closed + "\n\n"
        kept.append(.text(part))
      }
    }
    guard kept.contains(where: {
      switch $0 {
      case .activity: return true
      case let .text(part): return !part.text.isEmpty
      default: return false
      }
    }) else { return nil }
    var settled = self
    settled.parts = kept
    return settled
  }

  var proseIsClosed: Bool {
    guard let index = parts.lastIndex(where: { if case .text = $0 { return true }; return false }),
          case let .text(part) = parts[index]
    else { return true }
    if parts[(index + 1)...].contains(where: { if case .activity = $0 { return true }; return false }) {
      return true
    }
    return StreamingProse.split(part.text).open.isEmpty
  }

  var hasProse: Bool {
    parts.contains {
      if case let .text(part) = $0 {
        return !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      return false
    }
  }
}

enum StreamingProse {
  static func split(_ text: String) -> (closed: String, open: String) {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
    var fence: Character?
    var sawContent = false
    var boundary: Int?
    for (index, line) in lines.enumerated() {
      let trimmed = line.drop { $0 == " " || $0 == "\t" }
      if let open = fence {
        if trimmed.hasPrefix(String(repeating: open, count: 3)) { fence = nil }
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fence = trimmed.first
        sawContent = true
        continue
      }
      if trimmed.isEmpty {
        if sawContent { boundary = index }
        continue
      }
      sawContent = true
    }
    guard let boundary else { return ("", text.replacingOccurrences(of: "\r\n", with: "\n")) }
    let closed = lines[..<boundary].joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let open = lines[boundary...].joined(separator: "\n")
      .trimmingCharacters(in: .newlines)
    return (closed, open)
  }
}
