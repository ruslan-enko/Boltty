import Foundation

/// Which agent Ask Boltty asks, in which model: what Settings chose where it can
/// still be had, otherwise the fastest that phase 0 measured (Claude Code ·
/// Haiku, ~1.5 s to the first word from a warm process).
struct AskBolttyTarget: Equatable, Sendable {
  var providerID: String
  var model: ModelSelection?
  var effort: String?
  var readOnly: Bool
}

enum AskBolttyConfiguration {
  static let preferredProvider = AgentId.claude
  static let preferredModelHint = "haiku"

  /// Ask Boltty sends a picture of the screen, so only an agent that takes one.
  static func canAnswer(_ capabilities: AgentCapabilities) -> Bool {
    capabilities.contains(.images) || capabilities.contains(.attachments)
  }

  static func resolve(
    settings: AppSettings,
    candidates: [String],
    models: [String: [AgentModelOption]]
  ) -> AskBolttyTarget? {
    let chosen = settings.askBolttyProviderID.flatMap { candidates.contains($0) ? $0 : nil }
    guard let providerID = chosen
      ?? (candidates.contains(preferredProvider.rawValue) ? preferredProvider.rawValue : nil)
      ?? candidates.first
    else { return nil }

    let options = models[providerID] ?? []
    let model: AgentModelOption?
    if chosen != nil, let id = settings.askBolttyModelID {
      model = options.first { $0.selection.modelID == id }
    } else if providerID == preferredProvider.rawValue {
      model = options.first { option in
        option.selection.modelID.lowercased().contains(preferredModelHint)
          || option.selection.displayName.lowercased().contains(preferredModelHint)
      }
    } else {
      model = nil
    }
    let effort = chosen == nil ? nil : settings.askBolttyEffort.flatMap { effort in
      (model?.effortOptions ?? []).contains { $0.value == effort } ? effort : nil
    }
    return AskBolttyTarget(
      providerID: providerID, model: model?.selection, effort: effort,
      readOnly: settings.askBolttyReadOnly)
  }
}

/// What an Ask Boltty question carries to the agent besides the person's words.
enum AskBolttyPrompt {
  static func text(
    question: String, context: String?, screenshotPath: String, readOnly: Bool, traced: Bool = false
  ) -> String {
    bracket(context: context, screenshotPath: screenshotPath, readOnly: readOnly, traced: traced)
      + question
  }

  /// Everything before the question, the blank line after it included — what
  /// the chat card lifts back to the screen's picture (`SentFile.expansion`).
  static func bracket(
    context: String?, screenshotPath: String, readOnly: Bool, traced: Bool
  ) -> String {
    let screen = context.map { "their whole screen, in \($0)" } ?? "their whole screen"
    let marks = traced
      ? "the red line is what they traced around with the pointer while asking, and the red ring is where the pointer stopped"
      : "the red ring is where their pointer is"
    let tools = readOnly
      ? "Answer from what you see: do not run commands or change anything. If the picture did not come with this message, open the screenshot file to look at it; that one read is allowed."
      : "Answer from what you see — if the picture did not come with this message, open the screenshot file first; run commands or change files only if they clearly ask you to."
    return """
      [Talk: the person asked this out loud about their screen. The picture is \(screen); \
      \(marks). Screenshot: \(screenshotPath). \
      Your answer is read aloud: one or two short spoken sentences, never more, in the language they \
      asked in, no markdown, no lists, no code, one step at a time. \
      To show them where something is, put <point x="…" y="…" label="…"/> right before the \
      sentence that names it: x and y from 0 to 1000 across the picture (0 0 is its top left), \
      at the centre of that thing; the tag is not read aloud. At most one per sentence, none \
      when nothing on the screen is meant. \
      To show more, draw, in the same 0 to 1000, right before the sentence it illustrates: \
      <circle x="…" y="…" r="…" label="…"/> round something (r in the across scale), \
      <box x1="…" y1="…" x2="…" y2="…" label="…"/>, <arrow x1="…" y1="…" x2="…" y2="…" label="…"/> \
      from the first point to the second, <line x1="…" y1="…" x2="…" y2="…"/>, \
      <path d="M x y L x y Q cx cy x y C … Z"/> for any outline, <label x="…" y="…" text="…"/>. \
      For something that is not on the screen — a figure, a diagram, how a layout could be — \
      draw it on a board beside you instead: <board>those same tags, 0 to 1000 across a \
      square</board>. Keep labels to a few words; write formulas in plain Unicode \
      (a² + b² = c², ∠ABC = 90°). Draw only when it helps; most answers need none. \(tools)]


      """
  }
}
