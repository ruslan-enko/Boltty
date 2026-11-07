import Foundation

/// Which agent Ask Boltty asks, in which model: what Settings chose, else the
/// preferred agent in its default model, at the model's fastest effort.
struct AskBolttyTarget: Equatable, Sendable {
  var providerID: String
  var model: ModelSelection?
  var effort: String?
  var readOnly: Bool
}

enum AskBolttyConfiguration {
  /// An answer is one or two spoken sentences, so it thinks as little as the
  /// model allows short of switching thinking off: a CLI's own default is its
  /// highest (Antigravity's Flash took 14 s at high, 7 s at low, 1.4.12).
  /// `minimal` and `none` are passed over while `low` is offered: they lose
  /// the pointing and drawing.
  static func fastestEffort(_ options: [AgentEffortOption]) -> String? {
    let values = options.map(\.value)
    return effortOrder.first { values.contains($0) } ?? values.first
  }

  private static let effortOrder = ["low", "minimal", "none", "medium", "high", "xhigh", "max"]

  /// Ask Boltty sends a picture of the screen, so only an agent that takes one.
  static func canAnswer(_ capabilities: AgentCapabilities) -> Bool {
    capabilities.contains(.images) || capabilities.contains(.attachments)
  }

  static func resolve(
    settings: AppSettings,
    candidates: [String],
    models: [String: [AgentModelOption]]
  ) -> AskBolttyTarget? {
    let ready: (String?) -> String? = { id in id.flatMap { candidates.contains($0) ? $0 : nil } }
    guard let providerID = ready(settings.askBolttyProviderID)
      ?? ready(settings.agentPreset?.rawValue)
      ?? candidates.first
    else { return nil }
    let options = models[providerID] ?? []
    let model = options.option(stored: settings.askBolttyModelID)
    let effort = fastestEffort(model?.effortOptions ?? [])
    return AskBolttyTarget(
      providerID: providerID, model: model?.selection, effort: effort,
      readOnly: settings.askBolttyReadOnly)
  }
}

/// What an Ask Boltty question carries to the agent besides the person's words.
enum AskBolttyPrompt {
  static func text(question: String, region: AskBolttyRegion, readOnly: Bool) -> String {
    bracket(region: region, readOnly: readOnly) + question
  }

  /// Everything before the question, the blank line after it included — what
  /// the chat card lifts back to the region's picture (`SentFile.expansion`).
  static func bracket(region: AskBolttyRegion, readOnly: Bool) -> String {
    let what = region.isWholeScreen ? "their whole screen" : "their screen"
    let screen = region.context.map { "\(what), in \($0)" } ?? what
    let area = region.isWholeScreen
      ? "They asked about the whole screen."
      : "The red outline on it is the area they selected to ask about; the second picture is that area up close. Only the window under the area and the menu bar are shown: the rest is hidden on purpose, so do not guess at it."
    let pictures = region.isWholeScreen
      ? "Screenshot: \(region.screenPath)."
      : "Screenshots: \(region.screenPath) (the screen), \(region.areaPath) (the area)."
    let text = region.recognizedText.map {
      " The text read off the area:\n<screen-text>\n\($0)\n</screen-text>\n"
    } ?? " "
    let tools = readOnly
      ? "Answer from what you see: do not run commands or change anything. If they ask you to change something, say in one sentence that for now you can only look, and that “Can make changes” in Settings › Ask Boltty lets you. You may search the web when the question needs it, and give the link. If the pictures did not come with this message, open the screenshot files to look at them; those reads are allowed."
      : "Answer from what you see — if the pictures did not come with this message, open the screenshot files first; search the web when the question needs it. When they clearly ask you to do something, do it without saying what you are about to do: run the commands or change the files, then say in one sentence what you did. Otherwise change nothing."
    let place = region.finderPlace.map { place in
      let selected = place.selected.isEmpty
        ? "" : " Selected in it: \(place.selected.joined(separator: ", "))."
      return "The area is over the Finder folder \(place.folder), which is what “here” means.\(selected) "
    } ?? (region.isOverUnreadFinder
      ? "The area is over Finder, but which folder it shows could not be read: ask them rather than guess. "
      : "")
    return """
      [Talk: the person asked this about their screen. The first picture is \(screen); \
      \(area) \(pictures)\(text)\(place)\
      Your answer is shown beside them, and may be read aloud: one or two short sentences, \
      never more, in the language they asked in, no markdown, no lists, no code, one step at \
      a time; a link goes in as it is. \
      To show them where something is, put <point x="…" y="…" label="…"/> right before the \
      sentence that names it: x and y from 0 to 1000 across the first picture (0 0 is its top \
      left), at the centre of that thing; the tag is not read aloud. At most one per sentence, \
      none when nothing on the screen is meant. \
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

/// The part of the screen a question is about, as written for the agent.
struct AskBolttyRegion: Equatable, Sendable {
  /// The screen at `ScreenRegionCapture.screenLongEdge`, the area outlined and
  /// all but its window hidden: what a point's 0–1000 is measured across.
  var screenPath: String
  /// The area up close.
  var areaPath: String
  var context: String?
  var recognizedText: String?
  var isWholeScreen: Bool
  var finderPlace: FinderPlace? = nil
  /// Over Finder, with no folder to name: refused, too slow, or Recents.
  var isOverUnreadFinder = false
}
