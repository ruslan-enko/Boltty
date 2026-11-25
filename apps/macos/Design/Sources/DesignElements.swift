import AppKit

@MainActor
enum DesignElements {
  static func buttons() -> [DesignSection] {
    func states(_ name: String, _ make: () -> (NSView, PaletteIconButton)) -> [DesignSpecimen] {
      let rest = make(), hover = make(), press = make(), off = make()
      hover.1.mouseEntered(with: NSEvent())
      off.1.isEnabled = false
      press.1.layoutSubtreeIfNeeded()
      DispatchQueue.main.async { press.1.setPressedForTesting(true) }
      return [("", rest), (", hover", hover), (", pressed", press), (", disabled", off)].map {
        DesignSpecimen(name: name + $0.0, view: $0.1.0)
      }
    }
    func disc(_ icon: BolttyIcon, glass: Bool) -> () -> (NSView, PaletteIconButton) {
      {
        let disc = GlassCircleButton(
          icon: icon, accessibilityDescription: icon.rawValue, diameter: glass ? 36 : ComposerControlGroup.target,
          size: ComposerControlGroup.iconSize(chat: true), showsGlass: glass)
        return (disc, disc.button)
      }
    }
    func composer() -> (NSView, PaletteIconButton) {
      let button = icon(.plus)
      ComposerControlGroup.style(button)
      return (button, button)
    }
    func send() -> (NSView, PaletteIconButton) {
      let button = PaletteIconButton()
      button.isBordered = false
      button.title = ""
      button.imagePosition = .imageOnly
      button.image = ComposerControlGroup.sendIcon(.keyReturn, description: "Send")
      button.restingBackground = ComposerControlGroup.sendFill
      button.hoverBackground = ComposerControlGroup.sendHoverFill
      ComposerControlGroup.styleSendDisc(button)
      size(button, ComposerControlGroup.sendDisc)
      return (button, button)
    }
    func pill() -> (NSView, PaletteIconButton) {
      let pill = GlassPillButton.titled("Retry")
      return (pill, pill.button)
    }
    return [
      DesignSection(title: "Composer icon", note: "PaletteIconButton, ComposerControlGroup.style",
                    specimens: states("Attach", composer)),
      DesignSection(title: "Send", note: "PaletteIconButton, ComposerControlGroup.styleSendDisc",
                    specimens: states("Send", send)),
      DesignSection(title: "Glass disc", note: "GlassCircleButton", specimens: states("New Chat", disc(.plus, glass: true))),
      DesignSection(title: "Bare disc", note: "GlassCircleButton, showsGlass: false",
                    specimens: states("Remove", disc(.xmark, glass: false))),
      DesignSection(title: "Pill", note: "GlassPillButton", specimens: states("Retry", pill)),
    ]
  }

  private static func icon(_ icon: BolttyIcon) -> PaletteIconButton {
    let button = PaletteIconButton()
    button.isBordered = false
    button.title = ""
    button.imagePosition = .imageOnly
    button.image = icon.image(size: AgentPaletteMetrics.iconSide(ComposerControlGroup.iconSize(chat: true)))
    size(button, ComposerControlGroup.target)
    return button
  }

  private static func size(_ view: NSView, _ side: CGFloat) {
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      view.widthAnchor.constraint(equalToConstant: side), view.heightAnchor.constraint(equalToConstant: side),
    ])
  }

  static func chips() -> [DesignSection] {
    func folder(_ path: String, branch: String? = nil) -> NSView {
      let view = WorkingDirectoryChipView(frame: .zero)
      view.apply(WorkingDirectoryChip(path: path, isEditable: true, branch: branch))
      view.setChatSized(true)
      return view
    }
    func ring(_ percent: Int) -> NSView {
      let view = PlanUsageRingView(frame: .zero)
      view.apply(
        AgentUsage(windows: [AgentUsageWindow(kind: .weekly, usedPercent: percent, resetsAt: nil)]), agent: .claude)
      return view
    }
    return [
      DesignSection(title: "Folder", note: "WorkingDirectoryChipView", specimens: [
        DesignSpecimen(name: "Home", view: folder(NSHomeDirectory())),
        DesignSpecimen(name: "Folder", view: folder("/Projects/boltty")),
        DesignSpecimen(name: "With a branch", view: folder("/Projects/boltty", branch: "main")),
        DesignSpecimen(name: "Long", view: folder("/Projects/a-very-long-folder-name-that-gives-way", branch: "feature/one")),
      ]),
      DesignSection(title: "Plan ring", note: "PlanUsageRingView", specimens: [0, 25, 79, 80, 100].map { percent in
        DesignSpecimen(name: "\(percent)% used", view: ring(percent))
      }),
    ]
  }

  static func cards() -> [DesignSection] {
    let home = NSHomeDirectory()
    let picture = Bundle.main.url(forResource: "general", withExtension: "png", subdirectory: "Icons/Settings")
      ?? URL(fileURLWithPath: home)
    let attachments: [(String, PromptAttachment)] = [
      ("Picture", .file(picture, label: "image1")),
      ("Video", .file(URL(fileURLWithPath: home + "/Desktop/Upload 1.mp4"), label: "file1")),
      ("Long path", .file(URL(fileURLWithPath: home + "/Documents/Projects/boltty/apps/macos/Sources/README.md"), label: "file2")),
      ("Folder", .file(URL(fileURLWithPath: home + "/Documents"), label: "file3")),
      ("Pasted text", PromptAttachment(
        kind: .text, payload: .text("A long pasted text, its first lines shown on the card."), label: "text1")),
    ]
    let hovered = PromptAttachmentCard(attachment: attachments[1].1, corner: AgentPaletteMetrics.attachmentCardCornerInChat)
    hovered.setHoveredForTesting(true)
    let side = AgentPaletteMetrics.attachmentCardSide
    func failure(_ report: AgentFailureReport) -> NSView {
      let card = BolttyAIFailureCard(frame: .zero)
      card.apply(report)
      return card
    }
    let notice = PaletteNoticeView(frame: .zero)
    notice.message = "Claude Code is not installed. Install it, then try again."
    let column = AgentPaletteMetrics.chatSurfaceSize.width - 48
    return [
      DesignSection(title: "Attachment", note: "PromptAttachmentCard", specimens: attachments.map {
        DesignSpecimen(
          name: $0.0,
          view: PromptAttachmentCard(attachment: $0.1, corner: AgentPaletteMetrics.attachmentCardCornerInChat),
          width: side, height: side, tile: CGSize(width: 150, height: 150))
      } + [DesignSpecimen(
        name: "Hover", view: hovered, width: side, height: side, tile: CGSize(width: 150, height: 150))]),
      DesignSection(title: "Failure", note: "BolttyAIFailureCard", specimens: [
        DesignSpecimen(name: "Any failure", view: failure(AgentFailureReport(
          sentence: AgentFailureReport.universalSentence, details: "Provider request failed with HTTP 529: overloaded",
          retryPrompt: "Again")), width: column, tile: CGSize(width: 0, height: 170), isWide: true),
        DesignSpecimen(name: "The model is gone", view: failure(AgentFailureReport(
          sentence: AgentFailureReport.modelGoneSentence, details: "provider.no-route", retryPrompt: "Again",
          offersModelChoice: true)), width: column, tile: CGSize(width: 0, height: 170), isWide: true),
        DesignSpecimen(name: "The folder is gone", view: failure(AgentFailureReport(
          sentence: AgentFailureReport.folderGoneSentence, details: "No such file or directory", retryPrompt: nil,
          offersFolderChoice: true)), width: column, tile: CGSize(width: 0, height: 170), isWide: true),
      ]),
      DesignSection(title: "Notice", note: "PaletteNoticeView", specimens: [
        DesignSpecimen(name: "Refusal", view: notice, tile: CGSize(width: 0, height: 100), isWide: true),
      ]),
    ]
  }

  static func rows() -> [DesignSection] {
    func session(_ title: String, _ agent: AgentId, state: AgentReportedState? = nil, unread: Bool = false,
                 lit: Bool = false) -> NSView {
      var item = BolttyAISessionItem(
        id: UUID(), title: title, subtitle: "", agent: agent, isCurrent: false, updatedAt: Date())
      item.state = state
      item.hasUnread = unread
      let row = BolttyAISessionRowView(item: item)
      row.setShowsFace(true)
      if lit { row.setHighlighted(true, animated: false) }
      return row
    }
    func option(_ label: String, _ detail: String?, multiple: Bool = false, chosen: Bool = false,
                focused: Bool = false) -> NSView {
      let row = BolttyAIOptionRow(option: .init(label: label, detail: detail), multiple: multiple, number: 1)
      row.isChosen = chosen
      row.isFocused = focused
      return row
    }
    let width = AgentPaletteMetrics.promptGrownWidth - 60
    func wide(_ name: String, _ view: NSView, height: CGFloat = 76) -> DesignSpecimen {
      DesignSpecimen(name: name, view: view, width: width, tile: CGSize(width: 0, height: height), isWide: true)
    }
    let tabs = AgentHistoryTabStripView(frame: .zero)
    tabs.apply(
      tabs: AgentHistory.tabOrder.map { AgentHistory.Tab(agent: $0, count: 3) }, activeAgent: nil,
      everyone: AgentHistory.tabOrder)
    tabs.onSelect = { [weak tabs] agent in
      tabs?.apply(
        tabs: AgentHistory.tabOrder.map { AgentHistory.Tab(agent: $0, count: 3) }, activeAgent: agent,
        everyone: AgentHistory.tabOrder)
    }
    let file = PaletteFileRowView(path: DesignSources.root.appendingPathComponent("UI/PaletteFileRowView.swift").path)
    file.onUse = { _ in }
    return [
      DesignSection(title: "Chat row", note: "BolttyAISessionRowView", specimens: [
        wide("Rest", session("Review the interface", .claude)),
        wide("Chosen", session("Review the interface", .claude, lit: true)),
        wide("Unread", session("Fix the layout", .codex, unread: true)),
        wide("Working", session("Rename the episodes", .opencode, state: .running)),
        wide("Long", session(
          "A title that is far too long for the row and has to give way at its end, whatever the width", .grok)),
      ]),
      DesignSection(title: "Tabs", note: "AgentHistoryTabStripView. Press one.", specimens: [wide("Agents", tabs, height: 110)]),
      DesignSection(title: "Answer to a question", note: "BolttyAIOptionRow", specimens: [
        wide("Rest", option("Original", "Scooby-Doo, Where Are You!")),
        wide("Focused", option("Original", "Scooby-Doo, Where Are You!", focused: true)),
        wide("Chosen", option("Original", nil, chosen: true)),
        wide("Several, chosen", option("Original", nil, multiple: true, chosen: true)),
      ]),
      DesignSection(title: "File", note: "PaletteFileRowView", specimens: [
        wide("Here", file, height: 100),
        wide("Gone", PaletteFileRowView(path: "/nowhere/gone.pdf"), height: 100),
      ]),
    ]
  }

  static func help() -> [DesignSection] {
    func hints(_ list: [PaletteKeyHints.Hint], progress: CGFloat = 0) -> NSView {
      let view = PaletteKeyHints(frame: .zero)
      view.setHints(list)
      view.progress = progress
      view.show()
      return view
    }
    let button = icon(.mic)
    ComposerControlGroup.style(button)
    button.toolTip = "Dictate"
    button.helpShortcut = "⌘D"
    return [
      DesignSection(title: "Help tag", note: "PaletteHelpPresenter. Rest on the microphone.", specimens: [
        DesignSpecimen(name: "Dictate", view: button),
      ]),
      DesignSection(title: "Key hints", note: "PaletteKeyHints", specimens: [
        DesignSpecimen(name: "Cancel", view: hints([.init(key: "esc", words: "Cancel")])),
        DesignSpecimen(
          name: "Ask", view: hints([.init(key: "⏎", words: "Ask"), .init(key: "esc", words: "Cancel")]),
          tile: CGSize(width: 260, height: 110)),
        DesignSpecimen(
          name: "About to ask", view: hints(
            [.init(key: "⏎", words: "Ask"), .init(key: "esc", words: "Cancel")], progress: 0.6),
          tile: CGSize(width: 260, height: 110)),
      ]),
    ]
  }

  static func askBoltty(clear: Bool) -> [DesignSection] {
    let look = MascotLook.face(for: .claude)
    let answer = AskAnswerSampleView(look: look)
    answer.show(canMakeChanges: false, look: look)
    let done = AskAnswerSampleView(look: look)
    done.show(canMakeChanges: true, look: look)
    let listening = DictationSampleView(look: look)
    listening.show(phrase: "What does this button do", look: look, clearGlass: clear)
    return [
      DesignSection(title: "Answer", note: "The face beside the pointer and its bubble.", specimens: [
        DesignSpecimen(
          name: "Looks and answers", view: answer, width: AskAnswerSampleView.size.width,
          height: AskAnswerSampleView.size.height, tile: CGSize(width: 360, height: 180)),
        DesignSpecimen(
          name: "Does it", view: done, width: AskAnswerSampleView.size.width,
          height: AskAnswerSampleView.size.height, tile: CGSize(width: 360, height: 180)),
      ]),
      DesignSection(title: "Listening", note: "ListeningWordsView in the orb's glass.", specimens: [
        DesignSpecimen(
          name: "Words arriving", view: listening, width: DictationSampleView.size.width,
          height: DictationSampleView.size.height, tile: CGSize(width: 360, height: 200)),
      ]),
    ]
  }
}
