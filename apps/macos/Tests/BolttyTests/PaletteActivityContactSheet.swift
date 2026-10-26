import AppKit
import XCTest
@testable import Boltty

@MainActor
final class PaletteActivityContactSheet: XCTestCase {
  func testRenderTheFixedSurfaces() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for state in ["initial", "history", "chat"] {
      let view = AgentPaletteView()
      view.appearance = NSAppearance(named: .darkAqua)
      view.frame = CGRect(x: 0, y: 0, width: 1440, height: 982)
      view.setAgentChoices([.claude], planned: .claude)
      view.prepareForPresentation()
      view.setAcceptsAttachments(true)
      view.setWorkingDirectory(.forNewPrompt(path: NSHomeDirectory(), honoursWorkingDirectory: true))
      if state == "history" {
        view.setSessions([.row("Review the interface", .claude), .row("Fix the layout", .codex)],
                         activeSessionID: nil)
        view.expandResultsForTesting()
      } else if state == "chat" {
        view.enterAddressing(.init(id: UUID(), title: "Chat", agent: .claude,
                                  state: .finished, body: "Done. The panel keeps its size as the conversation changes."))
      }
      view.cancelAllAnimationsAndSettle()
      view.layoutSubtreeIfNeeded()
      let ground = NSView(frame: view.frame)
      ground.wantsLayer = true
      ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
      ground.addSubview(view)
      let rect = view.unifiedSurfaceFrameForTesting.insetBy(dx: -40, dy: -40)
      try write(ground, to: directory.appendingPathComponent("fixed-\(state).png"), rect: rect)
    }
  }

  func testRenderTheCardWithToolCalls() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let tools = [
      AgentActivity(id: "t1", name: "read", summary: "AgentPaletteView.swift",
                    state: .completed, files: ["/x/AgentPaletteView.swift"]),
      AgentActivity(id: "t2", name: "bash", summary: "swift build -c release",
                    state: .completed,
                    detail: "Compiling Boltty (48 sources)\nwarning: unused result\nBuild complete in 41.2s"),
      AgentActivity(id: "t3", name: "write", summary: "PaletteActivityRowView.swift",
                    state: .running),
      AgentActivity(id: "t4", name: "bash", summary: "sips -g pixelWidth shot.png",
                    state: .failed, detail: "sips: shot.png: No such file or directory"),
    ]
    let answer = ConversationMessage(
      id: "a", role: .agent, createdAt: Date(), completedAt: Date(),
      parts: [.text(TextPart(id: "t", kind: .text, text: "Looked at the card and the metrics."))]
        + tools.map { ConversationPart.activity($0) }
        + [.text(TextPart(id: "t2", kind: .text,
                          text: "The rows now carry the state; the prose carries the words."))]
    )
    let question = ConversationMessage(
      id: "u", role: .user, createdAt: Date(),
      parts: [.text(TextPart(id: "ut", kind: .text, text: "Розберись із рядками інструментів"))]
    )

    for open in [false, true] {
      let ground = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
      ground.wantsLayer = true
      ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor

      let rows = [PaletteChatMessageView(message: question),
                  PaletteChatMessageView(message: answer)]
      var y: CGFloat = 400
      for row in rows {
        ground.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = true
        row.frame = NSRect(x: 24, y: 0, width: 464,
                           height: PaletteChatMessageView.height(for: row === rows[0] ? question : answer,
                                                                 width: 464))
        row.layoutSubtreeIfNeeded()
      }
      let openSet = Set([AgentActivityGroup.id(of: tools)])
        .union(tools.compactMap { PaletteActivityRowView.opens($0) ? $0.id : nil })
      if open { rows[1].setExpandedActivities(openSet) }
      for (index, row) in rows.enumerated() {
        let message = index == 0 ? question : answer
        let expanded: Set<String> = open && index == 1 ? openSet : []
        let height = PaletteChatMessageView.height(for: message, width: 464, expanded: expanded)
        y -= height + 14
        row.frame = NSRect(x: 24, y: y, width: 464, height: height)
        row.layoutSubtreeIfNeeded()
      }
      try write(ground, to: directory.appendingPathComponent(
        open ? "tool-rows-open.png" : "tool-rows-closed.png"))
    }
    print("BOLTTY_TOOL_ROWS \(directory.path)")
  }

  func testRenderTheOpenChat() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let paragraph = "For a CLI-comfortable dev on Apple Silicon, the free CLI route "
      + "(realesrgan-ncnn-vulkan) genuinely covers most needs — but the single best "
      + "quality upscaler on Mac in 2026 is still Topaz Gigapixel, now subscription-only "
      + "at $149/yr. The sweet spot for most people is Upscayl (free GUI) or its underlying CLI"
    func agent(_ id: String, _ text: String) -> ConversationMessage {
      ConversationMessage(
        id: id, role: .agent, createdAt: Date(), completedAt: Date(),
        parts: [.text(TextPart(id: id + "t", kind: .text, text: text))])
    }
    func user(_ id: String, _ text: String) -> ConversationMessage {
      ConversationMessage(
        id: id, role: .user, createdAt: Date(),
        parts: [.text(TextPart(id: id + "t", kind: .text, text: text))])
    }
    let ask = "Topaz Gigapixel, now subscription-only at $149/yr."
    let cases: [(String, [ConversationMessage], AgentReportedState?, Bool, String)] = [
      ("open-chat-running.png", [user("u0", "Best upscaler on a Mac?"), agent("a0", paragraph),
                                 user("u1", ask)], .running, false,
       "I couldn't find anything specific for the great idea in your personal data."),
      ("open-chat-latest.png", [user("u0", "Best upscaler on a Mac?"),
                                agent("a0", [paragraph, paragraph, paragraph, paragraph]
                                  .joined(separator: "\n\n")),
                                user("u1", ask), agent("a1", paragraph)], nil, true, ""),
    ]
    for (name, messages, state, scrollUp, draft) in cases {
      let view = AgentPaletteView()
      view.appearance = NSAppearance(named: .darkAqua)
      view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
      view.setAgentChoices([.claude], planned: .claude)
      view.prepareForPresentation()
      view.setAcceptsAttachments(true)
      view.setWorkingDirectory(.forNewPrompt(path: NSHomeDirectory(), honoursWorkingDirectory: true))
      view.setUsage(
        AgentUsage(windows: [AgentUsageWindow(kind: .weekly, usedPercent: 25, resetsAt: nil)]),
        agent: .claude)
      var preview = BolttyAISessionPreview(
        id: UUID(), title: "Chat", agent: .claude, state: state, body: "")
      preview.messages = messages
      view.enterAddressing(preview)
      view.setContext(AgentContextUsage(usedTokens: 68_000, limitTokens: 200_000), canCompact: true)
      if !draft.isEmpty { view.setChatDraft(PromptDraft(draft)) }
      view.cancelAllAnimationsAndSettle()
      view.layoutSubtreeIfNeeded()
      if scrollUp {
        view.previewCardForTesting.scrollForTesting(to: 0)
        view.layoutSubtreeIfNeeded()
      }
      let ground = NSView(frame: view.frame)
      ground.wantsLayer = true
      ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
      ground.addSubview(view)
      try write(ground, to: directory.appendingPathComponent(name))
    }
    print("BOLTTY_OPEN_CHAT \(directory.path)")
  }

  func testRenderTheMessengerChat() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func user(_ id: String, _ text: String) -> ConversationMessage {
      ConversationMessage(
        id: id, role: .user, createdAt: Date(),
        parts: [.text(TextPart(id: id + "t", kind: .text, text: text))])
    }
    let file = URL(fileURLWithPath: #filePath).path
    let icon = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("AppIcon.icon/Assets/Icon.png").path
    let answer = ConversationMessage(
      id: "a0", role: .agent, createdAt: Date(), completedAt: Date(),
      parts: [
        .text(TextPart(id: "a0t", kind: .text, text:
          "From last meeting's call notes, they need to see support for Slack integration "
          + "and SSO before they proceed with a pilot.")),
        .activity(AgentActivity(id: "r1", name: "read", summary: "call-notes.md", state: .completed)),
        .activity(AgentActivity(id: "r2", name: "grep", summary: "Brightside", state: .completed)),
        .activity(AgentActivity(id: "r3", name: "edit", summary: "PaletteFileRowView.swift",
                                state: .completed, files: [file])),
        .text(TextPart(id: "a0u", kind: .text, text:
          "PG plan and Brightside Health's account notes in CRM are up to date with the latest.\n\n"
          + "## What shipped\n\nThree things they asked about:\n\n"
          + "- **Slack:** the integration is live for every workspace.\n"
          + "- **SSO:** SAML and OIDC, both.\n\nRenamed 25 files:\n\n"
          + "```\nГде ты, Скуби-Ду (1969) — S01E01.mp4\n→ Scooby-Doo, Where Are You! (1969) — S01E01.mp4\n```\n\n"
          + "Same for every file in `Season 1` and `Season 2`. I'll keep an eye on the pilot.")),
      ])
    let cases: [(String, [ConversationMessage])] = [
      ("messenger-chat.png", [
        user("u0", "Hey, what's the latest update we have on Brightside Health?"), answer,
        user("u1", "Perfect, those shipped last week, post an update to let them know"),
        ConversationMessage(
          id: "a1", role: .agent, createdAt: Date(), completedAt: Date(),
          parts: [.text(TextPart(id: "a1t", kind: .text, text:
            "Got it! Product updates shared and linked in #brightside-shared."))]),
      ]),
      ("messenger-chat-sent-files.png", [
        user("u0", "Hey, what's the latest update we have on Brightside Health?"), answer,
        SentFile.lift(user("u1", "Put \(icon) on the slide and check it against \(file)"), files: [
          SentFile(path: icon, label: "image1", name: "image1.png"),
          SentFile(path: file, label: "file1", name: "PaletteActivityContactSheet.swift"),
        ]),
        SentFile.lift(user("u2", icon), files: [SentFile(path: icon, label: "image1", name: "Icon.png")]),
      ]),
      ("messenger-chat-pinned.png", [
        user("u0", "Hey, what's the latest update we have on Brightside Health?"), answer,
        user("u1", "Thanks!"),
        ConversationMessage(
          id: "a1", role: .agent, createdAt: Date(), completedAt: Date(),
          parts: [.text(TextPart(id: "a1t", kind: .text, text: "Any time."))]),
      ]),
    ]
    for (name, messages) in cases {
      let view = AgentPaletteView()
      view.appearance = NSAppearance(named: .darkAqua)
      view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
      view.setAgentChoices([.claude], planned: .claude)
      view.prepareForPresentation()
      view.setAcceptsAttachments(true)
      view.setWorkingDirectory(.forNewPrompt(path: NSHomeDirectory(), honoursWorkingDirectory: true))
      var preview = BolttyAISessionPreview(
        id: UUID(), title: "Chat", agent: .claude, state: nil, body: "")
      preview.messages = messages
      view.enterAddressing(preview)
      view.cancelAllAnimationsAndSettle()
      view.layoutSubtreeIfNeeded()
      let ground = NSView(frame: view.frame)
      ground.wantsLayer = true
      ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
      ground.addSubview(view)
      try write(ground, to: directory.appendingPathComponent(name), settle: {
        view.previewCardForTesting.scrollToLatestForTesting()
      })
      if name == "messenger-chat-sent-files.png" {
        try write(ground, to: directory.appendingPathComponent("messenger-chat-sent-files-top.png"), settle: {
          let card = view.previewCardForTesting
          guard let row = card.messageRowForTesting("u1"),
                let document = row.enclosingScrollView?.documentView else { return }
          card.scrollForTesting(to: row.convert(row.bounds, to: document).minY - 90)
        })
      }
      if name == "messenger-chat.png" {
        view.previewCardForTesting.messageRowForTesting("a0")?.hoverForTesting(true)
        try write(ground, to: directory.appendingPathComponent("messenger-chat-hover.png"), settle: {
          view.previewCardForTesting.scrollForTesting(to: 0)
        })
      }
    }
    print("BOLTTY_MESSENGER_CHAT \(directory.path)")
  }

  func testRenderTheReferenceAnswer() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let started = Date().addingTimeInterval(-40)
    let request = ConversationMessage(
      id: "u0", role: .user, createdAt: started,
      parts: [.text(TextPart(id: "u0t", kind: .text,
                             text: "Hey, let's work on this artifact file and make it even more awesome."))])
    func reply(done: Bool, tail: Bool) -> ConversationMessage {
      ConversationMessage(
        id: "a0", role: .agent, createdAt: started, completedAt: done ? Date() : nil,
        parts: [
          .text(TextPart(id: "p1", kind: .text, text:
            "I'll look through the project and use the brainstorming skill to identify useful "
            + "improvements to the artifact.\n\n")),
          .reasoning(TextPart(id: "r1", kind: .reasoning, text: "Let me look around first.")),
          .activity(AgentActivity(id: "c1", name: "shell", summary: "ls -la /workspace/home", state: .completed,
                                  detail: "prism_generator.html\nREADME.md")),
          .activity(AgentActivity(id: "c2", name: "shell", summary: "find /workspace -name '*.html'",
                                  state: .completed)),
          .activity(AgentActivity(id: "c3", name: "Read", summary: "Read prism_generator.html", state: .completed)),
          .activity(AgentActivity(id: "c4", name: "Read", summary: "Read SKILL.md", state: .completed)),
          .activity(AgentActivity(id: "c5", name: "shell", summary: "cat /workspace/home/prism_generator.html",
                                  state: .completed)),
          .text(TextPart(id: "p2", kind: .text, text:
            "I found prism_generator.html, a 3D prism studio with materials, lighting, camera controls, "
            + "and exports.\n\nI'd start with a focused interface upgrade:\n\n"
            + "- Collapsible control sections to reduce scrolling.\n"
            + "- One-click scene presets combining shape, finish, and lighting.\n"
            + "- A compact toolbar for camera reset, rotation, and screenshots.\n"
            + "- Better spacing and touch controls on mobile.\n\n"
            + "This is a bounded change within the existing HTML file. I'd verify the controls and "
            + "exports afterward.\n\nDoes that direction fit what you have in mind?"
            + (tail ? "\n\nThe brainstorming skill requires \"approval... before implementation,\" so "
                + "I'm checking the direction with you first" : ""))),
        ])
    }
    let markdown = ConversationMessage(
      id: "a0", role: .agent, createdAt: started, completedAt: Date(),
      parts: [.text(TextPart(id: "m", kind: .text, text: """
        # Prism studio

        The renderer lives in `prism_generator.html`, and the controls call `applyPreset(name)` \
        when a [preset](https://example.com) is chosen.

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
        | Clay | Velvet | Overhead |

        ```js
        function applyPreset(name) {
          const preset = presets[name];
          scene.material = preset.finish;
        }
        ```

        > Presets never touch the camera, so a framed shot stays framed.

        ---

        #### Next

        Say the word and I'll start with the sections.
        """))])
    let cases: [(String, AgentReportedState?, [ConversationMessage])] = [
      ("reference-answer.png", .running, [request, reply(done: false, tail: true)]),
      ("reference-answer-finished.png", .finished, [request, reply(done: true, tail: false)]),
      ("reference-markdown.png", .finished, [request, markdown]),
    ]
    for (name, state, messages) in cases {
      let view = AgentPaletteView()
      view.appearance = NSAppearance(named: .darkAqua)
      view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
      view.setAgentChoices([.claude], planned: .claude)
      view.prepareForPresentation()
      view.setAcceptsAttachments(true)
      view.setWorkingDirectory(.forNewPrompt(path: NSHomeDirectory(), honoursWorkingDirectory: true))
      var preview = BolttyAISessionPreview(id: UUID(), title: "Chat", agent: .claude, state: state, body: "")
      preview.messages = messages
      preview.canStop = state == .running
      view.enterAddressing(preview)
      view.cancelAllAnimationsAndSettle()
      view.layoutSubtreeIfNeeded()
      let ground = NSView(frame: view.frame)
      ground.wantsLayer = true
      ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
      ground.addSubview(view)
      let rect = view.unifiedSurfaceFrameForTesting.insetBy(dx: -16, dy: -16)
      try write(ground, to: directory.appendingPathComponent(name), rect: rect, settle: {
        view.previewCardForTesting.scrollToLatestForTesting()
        view.previewCardForTesting.streamingTailForTesting.arriveForTesting(every: 0.06)
      })
      try write(ground, to: directory.appendingPathComponent(name.replacingOccurrences(of: ".png", with: "-top.png")),
                rect: rect, settle: {
        view.previewCardForTesting.scrollForTesting(to: 0)
        view.previewCardForTesting.streamingTailForTesting.arriveForTesting(every: 0.06)
      })
      if state == .running {
        let line = view.previewCardForTesting.workingLineForTesting
        line.layoutSubtreeIfNeeded()
        let scale: CGFloat = 4
        let size = line.bounds.size
        if let layer = line.layer, size.width > 0,
           let context = CGContext(
             data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
          context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
          context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
          context.scaleBy(x: scale, y: scale)
          layer.render(in: context)
          if let image = context.makeImage(),
             let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try png.write(to: directory.appendingPathComponent("reference-thinking.png"))
          }
        }
      }
      if name == "reference-markdown.png" {
        try write(ground, to: directory.appendingPathComponent("reference-markdown-bottom.png"), rect: rect,
                  settle: { view.previewCardForTesting.scrollForTesting(to: 520) })
        continue
      }
      if state == .finished {
        view.previewCardForTesting.turnHeaderForTesting("u0")?.pressForTesting()
        try write(ground, to: directory.appendingPathComponent("reference-answer-unfolded.png"), rect: rect,
                  settle: {
          view.previewCardForTesting.messageRowForTesting("a0")?.activityGroupsForTesting.first?.pressForTesting()
          view.previewCardForTesting.scrollForTesting(to: 0)
        })
      }
    }
    print("BOLTTY_REFERENCE_ANSWER \(directory.path)")
  }

  func testRenderTheTour() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func user(_ id: String, _ text: String) -> ConversationMessage {
      ConversationMessage(id: id, role: .user, createdAt: Date(),
                          parts: [.text(TextPart(id: id + "t", kind: .text, text: text))])
    }
    func agent(_ id: String, _ text: String) -> ConversationMessage {
      ConversationMessage(id: id, role: .agent, createdAt: Date(), completedAt: Date(),
                          parts: [.text(TextPart(id: id + "t", kind: .text, text: text))])
    }
    let ask = user("u0", "Rename the episodes to their English titles")
    let reply = agent("a0", "Found 25 files in two seasons.")
    func chat(_ state: AgentReportedState?, _ messages: [ConversationMessage],
              _ edit: (inout BolttyAISessionPreview) -> Void = { _ in }) -> BolttyAISessionPreview {
      var preview = BolttyAISessionPreview(id: UUID(), title: "Chat", agent: .claude, state: state, body: "")
      preview.messages = messages
      edit(&preview)
      return preview
    }
    let failed = ConversationMessage(
      id: "a1", role: .agent, createdAt: Date(), parts: [],
      failure: MessageFailure(name: "ProviderError",
                              message: "Provider request failed with HTTP 529: overloaded"))
    let states: [(String, (AgentPaletteView) -> Void)] = [
      ("draft", { $0.setChatDraft(PromptDraft(
        "Rename every episode in Season 1 and Season 2 to its English title, keep the "
          + "S01E01 numbering, and do not touch the subtitles that sit beside them")) }),
      ("error", { $0.showError("Claude Code is not installed. Install it, then try again.") }),
      ("chat-error", { view in
        view.enterAddressing(chat(.finished, [ask, reply]))
        view.showError("This chat is open in OpenCode right now. Sending from here too would put two of you in it.")
      }),
      ("install-hints", { $0.setInstallHints([.codex, .grok]); $0.revealInstallHintsIfNeeded() }),
      ("thinking", { $0.enterAddressing(chat(.running, [ask])) }),
      ("listening", { view in
        view.setVoiceListening(true)
        view.applyVoiceTranscript("Rename the episodes to their English")
      }),
      ("permission", { $0.enterAddressing(chat(.blocked, [ask, reply]) {
        $0.question = AgentQuestion(
          kind: .permission, requestID: "p", header: "Bash",
          prompt: "Run mv on 25 files in ~/Movies/Scooby-Doo?",
          detail: "for f in *.mp4; do mv \"$f\" \"$(rename \"$f\")\"; done",
          options: [.init(label: "Allow once", detail: nil),
                    .init(label: "Always allow", detail: "this session"),
                    .init(label: "Deny", detail: nil)],
          allowsMultiple: false, allowsCustom: false)
      }) }),
      ("question", { $0.enterAddressing(chat(.blocked, [ask, reply]) {
        $0.question = AgentQuestion(
          kind: .question, requestID: "q", header: "Titles",
          prompt: "Which spelling should the titles use?",
          options: [.init(label: "Original", detail: "Scooby-Doo, Where Are You!"),
                    .init(label: "Short", detail: "Scooby-Doo"),
                    .init(label: "Keep Russian", detail: nil)],
          allowsMultiple: true, allowsCustom: false)
      }) }),
      ("failure", { $0.enterAddressing(chat(.failed, [ask, failed]) {
        $0.retryPrompt = ask.plainText
      }) }),
      ("queued", { $0.enterAddressing(chat(.running, [ask, reply]) {
        $0.queuedPrompt = "And move the subtitles with them"
      }) }),
      ("history-empty", { view in
        view.setSessions([], activeSessionID: nil)
        view.expandResultsForTesting()
      }),
    ]
    for (name, apply) in states {
      let view = AgentPaletteView()
      view.appearance = NSAppearance(named: .darkAqua)
      view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
      view.setAgentChoices([.claude, .codex], planned: .claude)
      view.prepareForPresentation()
      view.setAcceptsAttachments(true)
      view.setWorkingDirectory(.forNewPrompt(path: NSHomeDirectory(), honoursWorkingDirectory: true))
      view.setUsage(
        AgentUsage(windows: [AgentUsageWindow(kind: .weekly, usedPercent: 40, resetsAt: nil)]),
        agent: .claude)
      apply(view)
      view.cancelAllAnimationsAndSettle()
      view.layoutSubtreeIfNeeded()
      let ground = NSView(frame: view.frame)
      ground.wantsLayer = true
      ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
      ground.addSubview(view)
      try write(ground, to: directory.appendingPathComponent("tour-\(name).png"),
                settle: { view.cancelAllAnimationsAndSettle() })
    }
    print("BOLTTY_TOUR \(directory.path)")
  }

  func testRenderTheArrivalLight() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let width: CGFloat = 520, rowHeight: CGFloat = 92, swatch: CGFloat = 22
    let agents = AgentHistory.tabOrder
    let ground = NSView(frame: CGRect(x: 0, y: 0, width: width + 32, height: rowHeight * CGFloat(agents.count) + 16))
    ground.appearance = NSAppearance(named: .darkAqua)
    ground.wantsLayer = true
    ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
    var tails: [PaletteStreamingTailView] = []
    for (row, agent) in agents.enumerated() {
      let top = ground.bounds.height - 16 - rowHeight * CGFloat(row)
      let tail = PaletteStreamingTailView()
      tail.translatesAutoresizingMaskIntoConstraints = true
      tail.frame = CGRect(x: 16, y: top - 44, width: width, height: 44)
      ground.addSubview(tail)
      tail.apply(
        "The renderer lives in one file, and the controls call a preset whenever one is chosen from the menu",
        column: width, agent: agent)
      tails.append(tail)
      for (index, colour) in MascotLook.face(for: agent).palette.arrivalLight.enumerated() {
        let chip = NSView(frame: CGRect(
          x: 16 + CGFloat(index) * (swatch + 6), y: top - 44 - 8 - swatch, width: swatch, height: swatch))
        chip.wantsLayer = true
        chip.layer?.backgroundColor = colour.cgColor
        ground.addSubview(chip)
      }
    }
    try write(ground, to: directory.appendingPathComponent("arrival-light.png"), settle: {
      tails.forEach { $0.arriveForTesting(every: 0.07) }
    })
    print("BOLTTY_ARRIVAL_LIGHT \(directory.path)")
  }

  func testRenderTheWorkingLine() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let started = Date().addingTimeInterval(-94)
    var parts: [ConversationPart] = [
      .text(TextPart(id: "p1", kind: .text, text: "Подивлюся, що змінилося з останнього коміту.\n\n")),
    ]
    for index in 0..<7 {
      parts.append(.activity(AgentActivity(
        id: "s\(index)", name: "shell", summary: nil, state: .completed)))
    }
    parts.append(.text(TextPart(id: "p2", kind: .text, text: "Тепер запущу тести.\n\n")))
    parts.append(.activity(AgentActivity(id: "run", name: "shell", summary: nil, state: .running)))
    let reply = ConversationMessage(id: "a1", role: .agent, createdAt: started, parts: parts)
    let request = ConversationMessage(
      id: "u1", role: .user, createdAt: started,
      parts: [.text(TextPart(id: "u1t", kind: .text, text: "Онови тести й закоміть"))])
    for open in [false, true] {
      let view = AgentPaletteView()
      view.appearance = NSAppearance(named: .darkAqua)
      view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
      view.setAgentChoices([.claude], planned: .claude)
      view.prepareForPresentation()
      var preview = BolttyAISessionPreview(
        id: UUID(), title: "Chat", agent: .claude, state: .running, body: "")
      preview.messages = [request, reply]
      preview.canStop = true
      view.enterAddressing(preview)
      if open {
        view.previewCardForTesting.messageRowForTesting("a1")?.activityGroupsForTesting.first?.pressForTesting()
      }
      view.cancelAllAnimationsAndSettle()
      view.layoutSubtreeIfNeeded()
      let ground = NSView(frame: view.frame)
      ground.wantsLayer = true
      ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
      ground.addSubview(view)
      try write(ground, to: directory.appendingPathComponent(
        open ? "working-line-open.png" : "working-line.png"),
        rect: view.unifiedSurfaceFrameForTesting.insetBy(dx: -16, dy: -16))
    }
    print("BOLTTY_WORKING_LINE \(directory.path)")
  }

  func testRenderAStretchOfSteps() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let started = Date().addingTimeInterval(-40)
    let edited = directory.appendingPathComponent("config.ts")
    try "export const config = {}\n".write(to: edited, atomically: true, encoding: .utf8)
    func step(_ id: String, _ tool: String, _ path: String) -> ConversationMessage {
      ConversationMessage(
        id: id, role: .agent, createdAt: started, completedAt: started,
        parts: [
          .reasoning(TextPart(id: id + "r", kind: .reasoning, text: "hm")),
          .activity(AgentActivity(id: id + "c", name: tool, state: .completed, files: [path])),
        ])
    }
    let request = ConversationMessage(
      id: "u1", role: .user, createdAt: started,
      parts: [.text(TextPart(id: "u1t", kind: .text, text: "Додай конфіг для toloka"))])
    let opening = ConversationMessage(
      id: "s0", role: .agent, createdAt: started, completedAt: started,
      parts: [.text(TextPart(id: "s0t", kind: .text, text: "Подивлюся, як влаштований App.tsx."))])
    let messages = [
      request, opening, step("s1", "read", "/x/App.tsx"), step("s2", "read", "/x/App.tsx"),
      step("s3", "read", "/x/types.ts"), step("s4", "edit", edited.path),
    ]
    for open in [false, true] {
      let view = AgentPaletteView()
      view.appearance = NSAppearance(named: .darkAqua)
      view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
      view.setAgentChoices([.opencode], planned: .opencode)
      view.prepareForPresentation()
      var preview = BolttyAISessionPreview(
        id: UUID(), title: "Chat", agent: .opencode, state: .running, body: "")
      preview.messages = messages
      preview.canStop = true
      view.enterAddressing(preview)
      if open {
        view.previewCardForTesting.messageRowForTesting("s1")?.activityGroupsForTesting.first?.pressForTesting()
      }
      view.cancelAllAnimationsAndSettle()
      view.layoutSubtreeIfNeeded()
      let ground = NSView(frame: view.frame)
      ground.wantsLayer = true
      ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
      ground.addSubview(view)
      try write(ground, to: directory.appendingPathComponent(open ? "stretch-open.png" : "stretch.png"),
                rect: view.unifiedSurfaceFrameForTesting.insetBy(dx: -16, dy: -16))
    }
  }

  func testRenderTheFailureCard() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let view = AgentPaletteView()
    view.appearance = NSAppearance(named: .darkAqua)
    view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    view.setAgentChoices([.opencode], planned: .opencode)
    view.prepareForPresentation()
    var preview = BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .failed, body: "")
    let started = Date().addingTimeInterval(-260)
    preview.messages = [
      ConversationMessage(
        id: "u0", role: .user, createdAt: started,
        parts: [.text(TextPart(id: "u0t", kind: .text, text: "так виправи це все"))]),
      ConversationMessage(
        id: "a0", role: .agent, createdAt: started, completedAt: Date(),
        parts: [.activity(AgentActivity(id: "t1", name: "shell", summary: nil, state: .completed))],
        failure: MessageFailure(name: "ProviderError", message: "HTTP 529: overloaded")),
    ]
    view.enterAddressing(preview)
    view.previewCardForTesting.failureCardForTesting.toggleDetailsForTesting()
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()
    let ground = NSView(frame: view.frame)
    ground.wantsLayer = true
    ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
    ground.addSubview(view)
    try write(ground, to: directory.appendingPathComponent("failure-card.png"),
      rect: view.unifiedSurfaceFrameForTesting.insetBy(dx: -16, dy: -16))
  }

  func testRenderTheQuestion() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let view = AgentPaletteView()
    view.appearance = NSAppearance(named: .darkAqua)
    view.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    view.setAgentChoices([.opencode], planned: .opencode)
    view.prepareForPresentation()
    var preview = BolttyAISessionPreview(
      id: UUID(), title: "Chat", agent: .opencode, state: .blocked, body: "")
    preview.messages = [
      ConversationMessage(
        id: "u0", role: .user, createdAt: Date(),
        parts: [.text(TextPart(id: "u0t", kind: .text, text: "Додай сповіщення"))]),
      ConversationMessage(
        id: "a0", role: .agent, createdAt: Date(), completedAt: Date(),
        parts: [.text(TextPart(id: "a0t", kind: .text,
          text: "`python_requires=\">=3.8\"`, хоча код тепер використовує PEP 604 `str | None` — це потребує 3.10+."))]),
    ]
    preview.question = AgentQuestion(
      kind: .question, requestID: "q1", header: "Сповіщення", prompt: "Сповіщення",
      options: [
        .init(label: "Лише читати прапорець (Рекомендовано)",
              detail: "ui_manager надсилає сповіщення тільки якщо прапорці true. Прапорці поки можна змінити лише вручну у файлі preferences.json."),
        .init(label: "Прапорці + перемикач у TUI",
              detail: "Додати гарячу клавішу (напр. n) для ввімкнення/вимкнення сповіщень зі збереженням у preferences."),
        .init(label: "Прапорці + ключ командного рядка",
              detail: "Окрім читання — CLI-прапорець, напр. --no-notifications, та заперечення для GUI-скриптів."),
      ],
      allowsMultiple: false, allowsCustom: false)
    view.enterAddressing(preview)
    view.cancelAllAnimationsAndSettle()
    view.layoutSubtreeIfNeeded()
    let ground = NSView(frame: view.frame)
    ground.wantsLayer = true
    ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
    ground.addSubview(view)
    try write(ground, to: directory.appendingPathComponent("question.png"),
      rect: view.unifiedSurfaceFrameForTesting.insetBy(dx: -16, dy: -16))
    print("BOLTTY_QUESTION \(directory.path)")
  }

  func testRenderTheTurnHeader() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let ground = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 40))
    ground.appearance = NSAppearance(named: .darkAqua)
    ground.wantsLayer = true
    ground.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
    let header = PaletteTurnHeaderView()
    ground.addSubview(header)
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: 12),
      header.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -12),
      header.centerYAnchor.constraint(equalTo: ground.centerYAnchor),
    ])
    let start = Date(timeIntervalSince1970: 0)
    header.apply(PaletteTurnHeader(
      id: "turn", startedAt: start, endedAt: start.addingTimeInterval(4860),
      isRunning: false, isCollapsed: true))
    let url = URL(fileURLWithPath: dir).appendingPathComponent("turn-header.png")
    try write(ground, to: url)
  }

  private func write(
    _ view: NSView, to url: URL, rect: CGRect? = nil, settle: (() -> Void)? = nil
  ) throws {
    let window = view.window ?? NSWindow(
      contentRect: view.bounds, styleMask: [.borderless],
      backing: .buffered, defer: false
    )
    if window.contentView !== view { window.contentView = view }
    view.layoutSubtreeIfNeeded()
    if let settle {
      settle()
      view.layoutSubtreeIfNeeded()
    }
    window.displayIfNeeded()

    let capture = rect ?? view.bounds
    guard let rep = view.bitmapImageRepForCachingDisplay(in: capture) else {
      return XCTFail("no bitmap")
    }
    view.cacheDisplay(in: capture, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
      return XCTFail("no PNG came out")
    }
    try png.write(to: url)
  }
}
