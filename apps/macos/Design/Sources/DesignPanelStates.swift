import AppKit

@MainActor
enum DesignPanelState: String, CaseIterable {
  case first = "First screen"
  case draft = "Long draft"
  case attachments = "Attachments"
  case error = "Refusal"
  case list = "Chat list"
  case emptyList = "Empty list"
  case chat = "Chat"
  case answer = "Formatted answer"
  case work = "Work rows"
  case thinking = "Thinking"
  case permission = "Permission"
  case question = "Question"
  case plan = "Plan"
  case failure = "Failure"
  case queued = "Queued message"
  case listening = "Listening"
  case dictation = "Dictation in a chat"

  func section(clear: Bool) -> DesignSection {
    DesignSection(title: rawValue, note: "AgentPaletteView: live, with nothing behind it.", specimens: [
      DesignSpecimen(name: "", view: make(clear: clear), fills: true),
    ])
  }

  func make(clear: Bool) -> AgentPaletteView {
    let view = AgentPaletteView()
    view.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    view.appearance = NSAppearance(named: .darkAqua)
    view.shellUsesClearGlass = clear
    view.setAgentChoices(AgentHistory.tabOrder, planned: .claude)
    view.prepareForPresentation()
    view.setAcceptsAttachments(true)
    view.setWorkingDirectory(.forNewPrompt(path: NSHomeDirectory()))
    view.setUsage(
      AgentUsage(windows: [AgentUsageWindow(kind: .weekly, usedPercent: 40, resetsAt: nil)]), agent: .claude)
    apply(to: view)
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()
    return view
  }

  private func apply(to view: AgentPaletteView) {
    switch self {
    case .first:
      break
    case .draft:
      view.setChatDraft(PromptDraft(
        "Rename every episode in Season 1 and Season 2 to its English title, keep the S01E01 numbering, "
          + "and do not touch the subtitles that sit beside them"))
    case .attachments:
      var draft = PromptDraft("Compare these")
      draft.append(.file(URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Upload 1.mp4"), label: "file1"))
      draft.append(.file(URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Report.pdf"), label: "file2"))
      draft.append(PromptAttachment(
        kind: .text, payload: .text("A long pasted text, its first lines shown on the card."), label: "text1"))
      view.field.setDraft(draft)
    case .error:
      view.showError("Claude Code is not installed. Install it, then try again.")
    case .list:
      view.setSessions(Self.sessions)
      view.expandResultsForTesting()
    case .emptyList:
      view.setSessions([])
      view.expandResultsForTesting()
    case .chat:
      view.enterAddressing(Self.preview(.finished, [
        Self.user("u0", "Hey, what's the latest on Brightside Health?"),
        Self.agent("a0", "From the last call notes, they need to see **Slack** and **SSO** before they go ahead with a pilot."),
        Self.user("u1", "Those shipped last week, let them know"),
        Self.agent("a1", "Done. The update is shared and linked in #brightside-shared."),
      ]))
    case .answer:
      view.enterAddressing(Self.preview(.finished, [
        Self.user("u0", "Plan the prism studio"), Self.agent("a0", Self.markdown),
      ]))
    case .work:
      view.enterAddressing(Self.preview(.running, [Self.user("u0", "Update the tests"), Self.worked], canStop: true))
    case .thinking:
      view.enterAddressing(Self.preview(.running, [Self.user("u0", "Update the tests")], canStop: true))
    case .permission:
      view.enterAddressing(Self.asking(AgentQuestion(
        kind: .permission, requestID: "p", header: "Bash", prompt: "Run this command?",
        detail: "for f in *.mp4; do mv \"$f\" \"$(rename \"$f\")\"; done",
        options: [.init(label: "Allow Once", detail: nil), .init(label: "Always Allow", detail: "this session"),
                  .init(label: "Deny", detail: nil)],
        allowsMultiple: false, allowsCustom: false)))
    case .question:
      view.enterAddressing(Self.asking(AgentQuestion(
        kind: .question, requestID: "q", header: "Titles", prompt: "Which spelling should the titles use?",
        options: [.init(label: "Original", detail: "Scooby-Doo, Where Are You!"),
                  .init(label: "Short", detail: "Scooby-Doo"), .init(label: "Keep as they are", detail: nil)],
        allowsMultiple: false, allowsCustom: true)))
    case .plan:
      view.enterAddressing(Self.asking(AgentQuestion(
        kind: .plan, requestID: "l", header: nil, prompt: "Carry out this plan?",
        detail: "1. Collapse the control sections.\n2. Add scene presets.\n3. Check the exports.",
        options: [.init(label: "Approve", detail: nil), .init(label: "Request Changes", detail: nil),
                  .init(label: "Quit", detail: nil)],
        allowsMultiple: false, allowsCustom: true)))
    case .failure:
      var preview = Self.preview(.failed, [
        Self.user("u0", "Rename the episodes"),
        ConversationMessage(
          id: "a1", role: .agent, createdAt: Date(), parts: [],
          failure: MessageFailure(name: "ProviderError", message: "Provider request failed with HTTP 529: overloaded")),
      ])
      preview.retryPrompt = "Rename the episodes"
      view.enterAddressing(preview)
    case .queued:
      var preview = Self.preview(.running, [Self.user("u0", "Update the tests"), Self.worked], canStop: true)
      preview.queuedPrompt = "And commit when they pass"
      view.enterAddressing(preview)
    case .listening:
      view.setVoiceListening(true)
      view.applyVoiceTranscript("Rename the episodes to their English titles")
    case .dictation:
      view.enterAddressing(Self.preview(.finished, [
        Self.user("u0", "Rename the episodes"), Self.agent("a0", "Found 25 files in two seasons."),
      ]))
      view.setVoiceListening(true)
      view.applyVoiceTranscript("Now move the subtitles with them")
    }
  }

  private static func user(_ id: String, _ text: String) -> ConversationMessage {
    ConversationMessage(
      id: id, role: .user, createdAt: Date(), parts: [.text(TextPart(id: id + "t", kind: .text, text: text))])
  }

  private static func agent(_ id: String, _ text: String) -> ConversationMessage {
    ConversationMessage(
      id: id, role: .agent, createdAt: Date(), completedAt: Date(),
      parts: [.text(TextPart(id: id + "t", kind: .text, text: text))])
  }

  private static func preview(
    _ state: AgentReportedState?, _ messages: [ConversationMessage], canStop: Bool = false
  ) -> BolttyAISessionPreview {
    var preview = BolttyAISessionPreview(id: UUID(), title: "Chat", agent: .claude, state: state, body: "")
    preview.messages = messages
    preview.canStop = canStop
    preview.modelChip = BolttyAIModelChip(name: "Opus", effort: "High", help: "Model")
    return preview
  }

  private static func asking(_ question: AgentQuestion) -> BolttyAISessionPreview {
    var preview = preview(.blocked, [
      user("u0", "Rename the episodes to their English titles"), agent("a0", "Found 25 files in two seasons."),
    ])
    preview.question = question
    return preview
  }

  private static var worked: ConversationMessage {
    ConversationMessage(
      id: "a0", role: .agent, createdAt: Date().addingTimeInterval(-40),
      parts: [
        .text(TextPart(id: "p1", kind: .text, text: "I'll look at what changed since the last commit.\n\n")),
        .activity(AgentActivity(id: "r1", name: "read", summary: "config.ts", state: .completed)),
        .activity(AgentActivity(id: "r2", name: "read", summary: "App.tsx", state: .completed)),
        .activity(AgentActivity(
          id: "b1", name: "bash", summary: "npm run build", state: .failed, detail: "error: missing module")),
        .text(TextPart(id: "p2", kind: .text, text: "The build misses a module; adding it, then the tests.\n\n")),
        .activity(AgentActivity(id: "b2", name: "bash", summary: "npm test", state: .running)),
      ])
  }

  private static var sessions: [BolttyAISessionItem] {
    let rows: [(String, AgentId, AgentReportedState?, Bool, Double)] = [
      ("Rename the episodes", .opencode, .running, false, 0),
      ("Review the interface", .claude, nil, true, 0),
      ("Fix the layout", .codex, nil, false, 0),
      ("Move the old backups", .grok, nil, false, 1),
      ("A title far too long for its row, which has to give way at its end whatever the width is", .antigravity, nil, false, 1),
      ("Find the receipt", .claude, nil, false, 4),
      ("Plan the trip", .codex, nil, false, 4),
      ("Sort the downloads", .claude, nil, false, 9),
    ]
    return rows.map { title, agent, state, unread, days in
      BolttyAISessionItem(
        id: UUID(), title: title, subtitle: "", agent: agent, isCurrent: false,
        updatedAt: Date().addingTimeInterval(-days * 86_400), state: state, hasUnread: unread)
    }
  }

  private static let markdown = """
    # Prism studio

    The renderer lives in `prism_generator.html`, and the controls call `applyPreset(name)` when a \
    [preset](https://example.com) is chosen.

    ## What changes

    1. Collapse the control sections.
    2. Add **scene presets**.
       - Shape, finish and light
       - Saved in `localStorage`

    ### The preset table

    | Preset | Finish | Light |
    | --- | --- | --- |
    | Studio | Matte | Softbox |
    | Neon | Gloss | Rim |

    ```js
    function applyPreset(name) {
      const preset = presets[name];
      scene.material = preset.finish;
    }
    ```

    > Presets never touch the camera, so a framed shot stays framed.

    ---

    Say the word and I'll start with the sections.
    """
}
