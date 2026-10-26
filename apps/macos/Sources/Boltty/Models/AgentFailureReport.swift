import Foundation

/// A failed turn, as something a person can read and act on.
///
/// **The raw text is evidence, not a message.** `EngineNotice` carries the
/// CLI's own last stderr line verbatim where it has one — that is deliberate,
/// and it is the right thing to *keep* (`ConversationEngine.reason` exists so
/// a startup failure is never reported as something else). It is the wrong
/// thing to *lead with*: `agy: unknown flag --output-format` is the answer to
/// a question nobody asked, sitting where the reply should have been.
///
/// So the split is: one sentence Boltty wrote, and the provider's own words
/// underneath a disclosure, unedited and copyable. Nothing is thrown away and
/// nothing technical is the first thing read.
///
/// Mapping particular errors to particular sentences is deliberately *not*
/// here. One universal sentence is honest about what Boltty currently knows;
/// a per-adapter phrasebook is a separate piece of work, and guessing at it
/// from an error string is how a wrong explanation gets shown confidently.
///
/// **The one exception is a refused plan**, and it is not read off a string:
/// `MessageFailure.rateLimit` is set only from a signal the CLI marks as that
/// (Claude Code's `rate_limit_event`, Codex's `codexErrorInfo`). What to do
/// about it is different from every other failure — wait — so it says when.
struct AgentFailureReport: Equatable, Sendable {
  /// What Boltty says happened. Written here, never taken from a provider.
  let sentence: String
  /// The provider's and the engine's own words, verbatim, in the order they
  /// were produced. Never shown until the reader asks for it.
  let details: String
  /// The prompt to send again, when there is one to send.
  let retryPrompt: String?

  var canRetry: Bool { retryPrompt != nil }

  /// One sentence for every failure, on purpose — see the type's note.
  static let universalSentence = "This turn didn't finish — your conversation is saved."

  /// A turn the plan refused, and when it can run again.
  static func rateLimitSentence(_ hit: RateLimitHit, now: Date = Date()) -> String {
    guard let reset = hit.resetsAt, reset > now else {
      return "Your plan's limit is used up — try again once it resets."
    }
    return "Your plan's limit is used up — it comes back \(AgentUsageWindow.resetPhrase(reset, now: now))."
  }

  /// Builds the report for a preview, or `nil` when nothing failed.
  ///
  /// A turn still running is never a failure, whatever else is on the
  /// conversation: a notice can arrive mid-turn (an auto-approval change that
  /// did not take), and that belongs in the panel's transient error line, not
  /// in a card that says the turn is over.
  ///
  /// An interrupt is not a failure either. `MessageFailure.isAbort` is the
  /// error OpenCode raises when the user pressed Stop, and drawing a failure
  /// card for a thing the user just asked for would be the app arguing.
  static func make(from preview: BolttyAISessionPreview) -> AgentFailureReport? {
    guard !preview.isBusy, preview.question == nil else { return nil }

    let failedState = preview.state == .failed
    if !failedState, let failedAt = preview.messages.lastIndex(where: {
      $0.failure?.isAbort == false
    }),
      preview.messages[(failedAt + 1)...].contains(where: { $0.role == .agent }) {
      // A failure belongs to the turn that produced it. Once the agent has
      // spoken again, the failure is history, not the state of the chat —
      // drawing it under newer replies reads as the latest turn failing.
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
    // Only the newest failure speaks for the card: an old refusal must not
    // explain a new, different failure.
    let latestHit = preview.messages.last(where: { $0.failure != nil })?.failure?.rateLimit

    return AgentFailureReport(
      sentence: latestHit.map { rateLimitSentence($0) } ?? universalSentence,
      // An empty details block would be a disclosure that opens onto nothing.
      // Say that much rather than draw an empty drawer.
      details: evidence.isEmpty
        ? "The agent reported a failure without saying anything about it."
        : evidence.joined(separator: "\n\n"),
      retryPrompt: preview.retryPrompt
    )
  }

  /// `name: message`, minus the repetition. Several adapters set both fields
  /// from the same string, and printing it twice makes the evidence look
  /// duplicated rather than corroborated.
  private static func describe(_ failure: MessageFailure) -> String {
    let name = failure.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return message }
    if message.isEmpty || message == name { return name }
    return "\(name): \(message)"
  }
}
