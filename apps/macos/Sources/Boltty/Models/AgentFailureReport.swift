import Foundation

struct AgentFailureReport: Equatable, Sendable {
  let sentence: String
  let details: String
  let retryPrompt: String?

  var offersModelChoice = false

  var offersFolderChoice = false

  var canRetry: Bool { retryPrompt != nil }

  static let universalSentence = "This turn didn't finish — your conversation is saved."

  static let modelGoneSentence = "This model isn't available any more. Choose another, then try again."

  static let folderGoneSentence = "This chat's folder is gone. Choose another, then try again."

  static let folderGoneFixedSentence = "This chat's folder is gone. Put it back to go on here."

  static func saysModelIsGone(_ failure: MessageFailure) -> Bool {
    if failure.name == "provider.no-route" { return true }
    let words = "\(failure.name) \(failure.message)".lowercased()
    return ["model unavailable", "model_not_found", "model not found", "unknown model", "invalid model"]
      .contains { words.contains($0) }
  }

  static func rateLimitSentence(_ hit: RateLimitHit, now: Date = Date()) -> String {
    guard let reset = hit.resetsAt, reset > now else {
      return "Your plan's limit is used up — try again once it resets."
    }
    return "Your plan's limit is used up — it comes back \(AgentUsageWindow.resetPhrase(reset, now: now))."
  }

  static func make(from preview: BolttyAISessionPreview) -> AgentFailureReport? {
    guard !preview.isBusy, preview.question == nil else { return nil }

    let failedState = preview.state == .failed
    if !failedState, let failedAt = preview.messages.lastIndex(where: {
      $0.failure?.isAbort == false
    }),
      preview.messages[(failedAt + 1)...].contains(where: { $0.role == .agent }) {
      return nil
    }

    var evidence: [String] = []
    if let notice = preview.notice?.trimmingCharacters(in: .whitespacesAndNewlines),
       !notice.isEmpty {
      evidence.append(notice)
    }
    for message in preview.messages {
      guard let failure = message.failure, !failure.isAbort else { continue }
      evidence.append(describe(failure))
    }

    guard failedState || !evidence.isEmpty else { return nil }
    let latest = preview.messages.last(where: { $0.failure != nil })?.failure
    let latestHit = latest?.rateLimit
    let modelGone = preview.modelChip?.isGone == true || latest.map(saysModelIsGone) == true

    if preview.folderIsGone {
      return AgentFailureReport(
        sentence: preview.canChooseFolder ? folderGoneSentence : folderGoneFixedSentence,
        details: evidence.joined(separator: "\n\n"),
        retryPrompt: preview.retryPrompt,
        offersFolderChoice: preview.canChooseFolder
      )
    }
    return AgentFailureReport(
      sentence: latestHit.map { rateLimitSentence($0) }
        ?? (modelGone ? modelGoneSentence : universalSentence),
      details: evidence.isEmpty
        ? "The agent reported a failure without saying anything about it."
        : evidence.joined(separator: "\n\n"),
      retryPrompt: preview.retryPrompt,
      offersModelChoice: modelGone && preview.modelChip != nil
    )
  }

  private static func describe(_ failure: MessageFailure) -> String {
    let name = failure.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return message }
    if message.isEmpty || message == name { return name }
    return "\(name): \(message)"
  }
}
