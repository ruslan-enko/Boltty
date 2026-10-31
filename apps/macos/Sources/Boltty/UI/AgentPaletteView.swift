import AppKit
import CoreImage

/// Boltty AI — glass capsule with text input + session switcher list (↓).
final class AgentPaletteView: NSView {
  /// Carries chips, not just characters — a pasted file has no string form the
  /// palette could hand over without deciding what it expands to, and that
  /// decision belongs to `PromptExpansion`, past the controller.
  var onSubmit: ((PromptDraft) -> Void)?
  /// ⌘Return in a chat: the draft, to go into the running turn where the
  /// agent can take it, and to the queue otherwise.
  var onSubmitSteering: ((PromptDraft) -> Void)?
  /// What ✓ sends. The field is the source of truth, dictated or typed alike.
  var currentDraft: PromptDraft { field.draft }
  var onCancel: (() -> Void)?
  var onDraftChange: (() -> Void)?
  private var isRestoringChatDraft = false
  var onStop: (() -> Void)?
  var onSpeakMessage: ((ConversationMessage) -> Void)?

  func setSpeakingMessage(_ id: String?) { previewCard.speakingMessageID = id }

  func setChatDraft(_ draft: PromptDraft) {
    isRestoringChatDraft = true
    defer { isRestoringChatDraft = false }
    field.setDraft(draft)
    hintLabel.isHidden = !field.isEmptyPrompt
    hideNotice()
    syncPromptExpansion()
    syncPromptHeight()
  }

  func suspendChatAnimations() { previewCard.suspendAnimations() }
  /// What `suspendChatAnimations` stopped, for a chat taken up again where it
  /// was left (`AgentPaletteController.resumeAddressing`).
  func resumeChatAnimations() { previewCard.resumeAnimations() }

  /// Hands the card where each sent chip stood, by the path it went out as,
  /// for the flight that lands it on its card. Read before the draft is
  /// cleared — afterwards there is nothing left to read it from.
  func prepareFileFlights(_ files: [(chip: UUID, file: SentFile)]) {
    guard !files.isEmpty else { return }
    let chips = field.chipSnapshots()
    var origins: [String: BolttyAIPreviewCard.FlightOrigin] = [:]
    for (chip, file) in files {
      guard let snapshot = chips[chip] else { continue }
      origins[file.path] = .init(frameInWindow: snapshot.frame, image: snapshot.image)
    }
    previewCard.prepareFileFlights(origins)
  }

  /// A row on the card was confirmed. The palette does not answer the agent
  /// itself — the coordinator owns every path that writes to a session.
  var onAnswerQuestion: ((UUID, AgentQuestion, [String]) -> Void)?
  /// Sends a failed prompt again, through whatever path sent it the first
  /// time. The panel does not own a second way to reach a provider, and a
  /// "Retry" that did would be one.
  var onRetryPrompt: ((UUID, String) -> Void)?
  /// The waiting follow-up was taken back. The panel puts the words in the
  /// composer; the conversation layer forgets them.
  var onCancelQueuedPrompt: ((UUID) -> Void)?
  /// Reaches Settings from inside the panel. Only the no-agents card uses
  /// it: it names that page, and naming a page the reader cannot get to
  /// from here is the dead end the card was rewritten to stop being.
  var onOpenSettings: (() -> Void)?
  /// The paperclip was pressed. The controller owns the panel, because an
  /// `NSOpenPanel` takes key and this one hides when it stops being key.
  var onChooseAttachments: (() -> Void)?
  /// A drag across the screen outside the shell began: the controller
  /// freezes the screen under it (`showFrozenScreen`), or refuses
  /// (`cancelScreenSelection`).
  var onScreenSelectionBegan: (() -> Void)?
  /// In an open chat, the region drawn — global screen coordinates — to be
  /// put in the composer as a chip (`insertScreenSelection`).
  var onScreenRegionSelected: ((CGRect) -> Void)?
  /// Escape, a click off the region, or a region too small to be one.
  var onScreenSelectionCancelled: (() -> Void)?
  /// The dragged regions, drawn where they were taken (under the shell).
  private let screenOutlines = ScreenSelectionOverlay()
  var onSelectSession: ((UUID) -> Void)?
  /// The switcher is about to open and wants its rows.
  var onWillShowSessions: (() -> Void)?
  /// Confirming a switcher row: the controller decides address / send / open.
  var onConfirmSession: ((UUID) -> Void)?
  /// A history row was right-clicked: its id, the click and the row.
  var onSessionContextMenu: ((UUID, NSEvent, NSView) -> Void)?
  var onContentSizeChange: (() -> Void)?
  var onVoiceToggle: (() -> Void)?
  /// ✕ — discard the dictated span. ✓ — stop and send.
  var onVoiceCancel: (() -> Void)?
  var onVoiceConfirm: (() -> Void)?
  var onVoiceEditingInterrupted: (() -> Void)?
  /// The chat this names was left. Said once the panel has let go of it, so
  /// whatever is redrawn from `addressedSessionID` reads the first screen;
  /// said before, the folder chip would keep the chat's folder, locked, on
  /// the prompt.
  var onLeaveAddressing: ((UUID) -> Void)?
  /// The folder chip was clicked. Only ever fires while the chip is editable;
  /// the panel does not own the picker, because opening one makes this window
  /// resign key and the controller is what knows not to hide on that.
  var onChooseWorkingDirectory: (() -> Void)?
  /// The folder chip was clicked: the controller builds the folder menu
  /// (`WorkingDirectoryMenu`) and hands it to `showWorkingDirectoryMenu`.
  var onWorkingDirectoryMenu: (() -> Void)?
  /// **The shell stands at the top of the screen, centred, and does not
  /// move**, as Siri's field stands on iPhone and iPad. It drips out of the
  /// notch and back into it (`beginDrip` / `beginDripOut`, geometry in
  /// `PaletteDrip`), so it has to stand under it.
  ///
  /// The menu bar's height: the panel reaches up behind it (so the shell's
  /// shadow is not cut at its edge) and the shell stands
  /// `lockedTopGap` under it.
  var topReserve: CGFloat = 0 {
    didSet { if topReserve != oldValue { applyPlacement() } }
  }
  /// The user finished dragging a shell's edge. Persist the sizes.
  var onSurfaceSizesChange: ((BolttyAISurfaceSizes) -> Void)?
  /// How big the open chat and the chat list stand — the person's, kept
  /// across opens. The screen caps them when presented.
  var surfaceSizes = BolttyAISurfaceSizes.default {
    didSet { if surfaceSizes != oldValue { applyPlacement() } }
  }

  let field: PromptTextView
  /// Clips and scrolls the prompt. Long prompts move under a fixed capsule
  /// rather than truncating away from the caret.
  private let promptScroll: NSScrollView
  private let selectedAgentImage = BolttyAIMarkView()
  private let micButton = GlassCircleVoiceButton()
  /// Picks files for the prompt — a bare glyph, like the microphone beside it.
  ///
  /// **Drag-and-drop and ⌘V already worked and neither is advertised
  /// anywhere**, so "attach this video" meant knowing a gesture nobody was
  /// told about. Shown only where the adapter declares `.attachments` — a
  /// control the CLI behind it cannot honour is the specific failure
  /// `AgentCapabilities` exists to prevent.
  ///
  /// WORK PAGE 1091:4731 removes the resting glass, keeping the hit target.
  private let attachRestDisc = GlassCircleButton(
    symbol: "plus",
    accessibilityDescription: "Attach a file",
    diameter: AgentPaletteMetrics.voiceOrbDiameter,
    pointSize: ComposerControlGroup.pointSize(chat: false),
    showsGlass: false
  )
  /// The + at the foot's leading edge, apart from the group on the right;
  /// zero wide when it is not offered.
  private let attachRestSlot = NSView()
  private lazy var attachRestWidth = attachRestSlot.widthAnchor.constraint(equalToConstant: 0)
  /// The open chat's Auto Mode — the indicator and the switch in one glyph.
  /// An A in a circle, as a camera's auto mode: lit (filled, full ink) while
  /// Auto Mode is on, at the group's resting ink while every permission
  /// asks. Only in a chat whose agent declares `.autoApproval`
  /// (`BolttyAISessionPreview.autoMode`), so a switch is never drawn for a
  /// CLI that would not honour it.
  private let autoModeButton = GlassCircleButton(
    symbol: "a.circle",
    accessibilityDescription: "Auto Mode",
    diameter: AgentPaletteMetrics.voiceOrbDiameter,
    pointSize: ComposerControlGroup.pointSize(chat: true),
    showsGlass: false
  )
  private let autoModeSlot = NSView()
  private lazy var autoModeWidth = autoModeSlot.widthAnchor.constraint(equalToConstant: 0)
  /// What the glyph last drew — `nil` while it is not offered.
  private var shownAutoMode: (on: Bool, agent: AgentId)?
  /// Turns the open chat's Auto Mode on or off.
  var onSetAutoMode: ((UUID, Bool) -> Void)?
  /// Latest floats independently over the composer. Folder and plan usage
  /// stay in the composer's trailing controls in both prompt and chat states.
  private lazy var latestPillConstraints: [NSLayoutConstraint] = [
    latestPill.centerXAnchor.constraint(equalTo: promptCapsule.centerXAnchor),
    latestPill.bottomAnchor.constraint(
      equalTo: promptCapsule.topAnchor,
      constant: -AgentPaletteMetrics.latestComposerSpacing
    ),
  ]
  /// ↓ Latest, over the composer. The card decides when it is offered
  /// (`BolttyAIPreviewCard.offersLatest`). **A glass disc with the arrow
  /// alone** — the back disc's size and weight; the word is its help tag.
  private let latestPill: GlassCircleButton = {
    let disc = GlassCircleButton(
      symbol: "arrow.down",
      accessibilityDescription: "Latest",
      diameter: AgentPaletteMetrics.previewCloseDiameter,
      pointSize: AgentPaletteMetrics.previewCloseGlyphPointSize,
      weight: AgentPaletteMetrics.previewCloseGlyphWeight
    )
    disc.button.toolTip = "Latest"
    return disc
  }()
  private var offersLatest = false
  /// The chat list's foot: New Chat in the lower right, Settings apart in
  /// the lower left. **Two discs, not one capsule**: a capsule says its
  /// halves act on one thing, and these do not — New Chat belongs to the
  /// chosen tab, Settings to the whole of Boltty. Inside the corner grips,
  /// which give way on them (`resizeEdges`); the rows dissolve under them.
  private let historyNewChatButton = GlassCircleButton(
    symbol: "plus",
    accessibilityDescription: "New Chat",
    diameter: AgentPaletteMetrics.previewCloseDiameter,
    pointSize: AgentPaletteMetrics.previewCloseGlyphPointSize,
    weight: AgentPaletteMetrics.previewCloseGlyphWeight
  )
  private let historySettingsButton = GlassCircleButton(
    symbol: "gearshape",
    accessibilityDescription: "Settings",
    diameter: AgentPaletteMetrics.previewCloseDiameter,
    pointSize: AgentPaletteMetrics.previewCloseGlyphPointSize,
    weight: AgentPaletteMetrics.previewCloseGlyphWeight
  )
  private var showsHistoryFoot: Bool { !historyNewChatButton.isHidden }
  /// Whether this agent reads files at all — see `setAcceptsAttachments`.
  private var acceptsAttachments = false
  /// What the Send slot says while it stops the turn (`sendSlotStops`).
  private var stopTooltip = "Stop response"

  /// ⌘Return. Only in a chat whose turn is running and asks nothing — the
  /// one place it means something different from Return; anywhere else the
  /// key is declined and AppKit does what it did before.
  private func submitSteeringFromKeyboard() -> Bool {
    guard mode == .prompt, let preview = addressedPreview, preview.isBusy,
          previewCard.pendingQuestion == nil, !field.draft.isEffectivelyEmpty
    else { return false }
    onSubmitSteering?(field.draft)
    return true
  }

  /// ⌘.: the Mac's own "stop what is running" stops the turn on screen, by
  /// the Send slot's path. With nothing to stop the chord is left to AppKit,
  /// which reads it as Escape.
  private func stopFromKeyboard() -> Bool {
    guard stopIsAvailable else { return false }
    onStop?()
    return true
  }
  /// A refusal or a short error, on a surface of its own — see
  /// `PaletteNoticeView` and `anchorNotice`.
  private let notice = PaletteNoticeView()
  /// Routing and error notices remain outside the prompt's single capsule.
  private let bottomBar = NSStackView()
  private let directoryChip = WorkingDirectoryChipView()
  private let directorySlot = NSView()
  private lazy var directorySlotWidth = directorySlot.widthAnchor.constraint(equalToConstant: 0)
  private var workingDirectory: WorkingDirectoryChip?
  /// Used plan allowance; the empty track remains when no reading is available.
  private let planRing = PlanUsageRingView(frame: .zero)
  /// Compact from the plan ring disclosure.
  var onCompact: (() -> Void)?
  /// "Claude Code isn't ready — sent to OpenCode instead", with a way to go
  /// and fix it. The one row in the panel that names an agent; see
  /// `AgentRoutingFallback` for why that is the rule rather than a hole in it.
  private let routingRow = NSStackView()
  private let routingLabel = NSTextField(labelWithString: "")
  /// A glass pill, not a stock `.rounded` bezel: a light-grey system button
  /// under a dark glass capsule read as a dialog from somewhere else.
  private let routingButton = GlassPillButton.titled("Open Settings")
  /// Glass + gradient chrome (behind icon/text).
  private let promptHost: PaletteGlassHost
  /// The microphone disc. While recording it stays put; the pill overlays it
  /// only when the pointer is nearby, so the draft remains fully readable.
  private let trailingControls = NSStackView()
  private let sendButton = GlassCircleButton(
    symbol: "return", accessibilityDescription: "Send message",
    diameter: AgentPaletteMetrics.voiceOrbDiameter,
    pointSize: ComposerControlGroup.pointSize(chat: false), showsGlass: false)
  private let sendSlot = NSView()
  private lazy var sendSlotWidth = sendSlot.widthAnchor.constraint(equalToConstant: 0)
  var sendButtonForTesting: PaletteIconButton { sendButton.button }
  var sendSlotStopsForTesting: Bool { sendSlotStops }
  @objc private func sendButtonPressed() {
    if sendSlotStops { onStop?() } else { confirmSelectionOrSubmit() }
  }
  /// **Stop lives in Send's slot**: while a turn can be stopped and there is
  /// nothing typed to queue, the Return glyph becomes the stop square, where
  /// the eye already is while waiting. A typed draft takes the slot back —
  /// Enter queues it, and the button has to say what Enter does.
  private var sendSlotStops = false
  private var returnGlyph = ComposerControlGroup.symbol("return", description: "Send message", chat: false)
  private var stopGlyph = ComposerControlGroup.symbol("stop", description: "Stop", chat: false)
  /// The composer's glyphs at the size of the screen they stand on — 22 on
  /// the first, 16 in a chat (`ComposerControlGroup`). The views travel
  /// between the two, so their symbols are re-made when the screen changes.
  private var composerGlyphsAreChat = false
  private func applyComposerGlyphSize(chat: Bool) {
    guard chat != composerGlyphsAreChat else { return }
    composerGlyphsAreChat = chat
    let size = ComposerControlGroup.pointSize(chat: chat)
    directoryChip.setChatSized(chat)
    attachRestDisc.setPointSize(size)
    micButton.restingGlyphPointSize = size
    returnGlyph = ComposerControlGroup.symbol("return", description: "Send message", chat: chat)
    stopGlyph = ComposerControlGroup.symbol("stop", description: "Stop", chat: chat)
    sendButton.setPointSize(size)
  }
  private func syncSendButton() {
    // The words after the draft answer the same state the Send slot does —
    // the draft, a running turn, a question, listening.
    defer { syncTrailingHint() }
    // The first screen has no Send glyph: Return is said by the key hint
    // after the words; a chat keeps its Send.
    let visible = composerIsUp && !isVoiceListening && composerGlyphsAreChat
    sendButton.isHidden = !visible
    sendButton.diameter = composerControlDiameter
    sendSlotWidth.constant = visible ? composerControlDiameter : 0
    let answering = previewCard.pendingQuestion != nil
    let refusing = previewCard.pendingQuestion?.takesWordsAsRefusal == true && draftHasWords
    previewCard.setComposerHasWords(draftHasWords)
    sendSlotStops = stopIsAvailable && !answering && field.draft.isEffectivelyEmpty
    if sendSlotStops {
      sendButton.button.image = stopGlyph
      sendButton.button.isEnabled = true
      sendButton.button.toolTip = stopTooltip
      sendButton.button.helpShortcut = "⌘."
      sendButton.button.setAccessibilityLabel("Stop")
      trailingControls.setCustomSpacing(visible ? trailingControls.spacing : 0, after: micButton)
      return
    }
    sendButton.button.image = returnGlyph
    sendButton.button.setAccessibilityLabel("Send message")
    sendButton.button.isEnabled = !isVoiceProcessing && (!field.draft.isEffectivelyEmpty || answering)
    sendButton.button.toolTip = refusing
      ? (previewCard.pendingQuestion?.kind == .plan ? Self.planChangesHelp : Self.refusalHelp)
      : answering ? "Answer question" : addressedPreview?.isBusy == true
      ? "Queue message — sends when this turn finishes" : "Send message"
    sendButton.button.helpShortcut = "↵"
    trailingControls.setCustomSpacing(visible ? trailingControls.spacing : 0, after: micButton)
  }
  private let recordingHoverSensor = HoverSensor()
  private var isRecordingControlsRevealed = false
  private var inlineControlConstraints: [NSLayoutConstraint] = []
  private var expandedPromptConstraints: [NSLayoutConstraint] = []
  /// A grown draft's top: flush on the first screen, the frame's padding (less
  /// what the scroll document carries) in a chat.
  private lazy var expandedPromptTop = promptScroll.topAnchor.constraint(
    equalTo: promptForeground.topAnchor)
  /// Stays expanded until cleared, including after stopping dictation. A final
  /// transcript revision must not repeatedly change the wrap width and font.
  private var isPromptExpanded = false
  /// The draft itself outgrew one line — the half of `isPromptExpanded` that
  /// survives leaving a chat. In an open chat the composer is a box whatever
  /// the draft holds (`chatComposerBoxHeight`), so there the layout is
  /// expanded either way.
  private var isDraftExpanded = false
  /// Only recording spreads the glyphs out to the recording gutter. A grown
  /// draft keeps the control group's own spacing on both screens: in a chat
  /// the icons sit along the bottom under full-width text, and spread out
  /// they read as a different group.
  private var usesExpandedControlLayout: Bool { isVoiceListening }
  /// The trailing glyphs' hit target: the screen's glyph and the group's gap
  /// — see `ComposerControlGroup`.
  private var composerControlDiameter: CGFloat { ComposerControlGroup.target(chat: composerGlyphsAreChat) }
  /// Dissolves the prompt's own text at its scrolling edges.
  private let promptEdgeFadeMask = CAGradientLayer()
  private let recordingControls = VoiceRecordingControls(frame: .zero)
  /// The light under the shared shell's glass while dictating. A sibling
  /// *below* the glass, not a filter on it — the glass bends and frosts it as
  /// it moves; see `VoiceEdgeGlowView`.
  private let voiceGlow = VoiceEdgeGlowView(frame: .zero)
  /// The words being said, inside the listening orb as it grows into a
  /// capsule round them. Over the glass and the orb's
  /// surface, so neither greys them; clipped to the shell by `listeningWordsHost`
  /// while the shell springs wider than it was.
  private let listeningWordsHost = PassThroughView()
  private let listeningWords = NSTextField(labelWithString: "")
  /// The width the listening shell is growing to, which the words are laid
  /// out at while it is still on its way.
  private var listeningWordsWidth: CGFloat = 0
  /// Icon + field, always composited in front of glass/gradient.
  private let promptForeground = BolttyAIChromeView()
  /// Presentation target: scales chrome and content together.
  private let promptCapsule = NSView()
  // A single live glass surface survives prompt → list → conversation.
  private let surfaceContainer = NSView()
  /// While the shell drips: where it is headed instead of its own frame.
  private var dripTarget: CGRect?
  private var dripRun = 0
  private let surface = PaletteGlassHost(content: NSView(), cornerRadius: 36, style: .bolttyAI)
  /// Where the notice stands: under the shell, or — in an open chat — over
  /// the transcript just above the composer, where ↓ Latest stands.
  private lazy var noticeCenterX = notice.centerXAnchor.constraint(equalTo: promptCapsule.centerXAnchor)
  private lazy var noticeTopToPrompt = notice.topAnchor.constraint(
    equalTo: promptCapsule.bottomAnchor, constant: AgentPaletteMetrics.noticeShellSpacing)
  private lazy var noticeTopToResults = notice.topAnchor.constraint(
    equalTo: resultsCapsule.bottomAnchor, constant: AgentPaletteMetrics.noticeShellSpacing)
  private lazy var noticeAboveComposer = notice.bottomAnchor.constraint(
    equalTo: promptCapsule.topAnchor, constant: -AgentPaletteMetrics.latestComposerSpacing)
  private lazy var editorLeading = promptScroll.leadingAnchor.constraint(equalTo: promptForeground.leadingAnchor, constant: AgentPaletteMetrics.promptTextLeading)
  private lazy var controlsTop = trailingControls.centerYAnchor.constraint(equalTo: promptForeground.topAnchor, constant: AgentPaletteMetrics.promptSize.height / 2)
  /// Where the glass field ends. At rest it fills the capsule and the voice
  /// control floats *on* it; in a chat the mock puts the disc beside the field
  /// as a sibling node, so the glass has to stop short of it.
  private lazy var promptHostTrailing = promptHost.trailingAnchor.constraint(
    equalTo: promptCapsule.trailingAnchor
  )
  /// Where the text stops. One constraint for both states: at rest it lands on
  /// the same number the expanded set used to hard-code (the disc's gutter plus
  /// its diameter plus the text gap), and in a chat it is the field's own edge
  /// less the field's own padding.
  private lazy var editorTrailing = promptScroll.trailingAnchor.constraint(
    equalTo: promptForeground.trailingAnchor,
    constant: -(AgentPaletteMetrics.restingControlsTrailingInset
      + AgentPaletteMetrics.voiceOrbDiameter + AgentPaletteMetrics.promptMicTextSpacing)
  )
  /// Initial controls align their ink to the new mock. Recording keeps its
  /// existing gutter, and chat controls stand outside the composer field.
  private lazy var controlsTrailing = trailingControls.trailingAnchor.constraint(
    equalTo: promptForeground.trailingAnchor,
    constant: -AgentPaletteMetrics.restingControlsTrailingInset
  )
  private lazy var micWidth = micButton.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceOrbDiameter)
  private lazy var micHeight = micButton.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceOrbDiameter)
  private lazy var hintBaseline = hintLabel.firstBaselineAnchor.constraint(equalTo: promptScroll.topAnchor, constant: PromptTextView.firstBaselineOffsetFromTop)
  /// Whether the adapter says this turn can be stopped.
  ///
  /// The Send slot turns into Stop on it, ⌘. answers to it and the key hints
  /// name it.
  private var stopIsAvailable = false
  private var returnToSessionID: UUID?
  private var surfaceFrame: CGRect = .zero
  /// Where the shell stands now, in this view's coordinates.
  var shellFrame: CGRect { surfaceFrame }
  private var surfaceReady = false
  private lazy var surfaceMotion = PaletteSurfaceMotion { [weak self] rect in
    self?.drawSurface(at: rect)
  }
  private lazy var promptWidthConstraint = promptCapsule.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.promptSize.width)
  /// Whether the shell is the listening capsule right now.
  ///
  /// On the first screen dictation is always the capsule, whatever the
  /// draft already holds; the draft is kept and comes back when the take
  /// ends. In an open chat an empty composer collapses the card to the same
  /// capsule, but a draft that holds words or chips keeps the composer, so
  /// what is being added to stays beside the transcript it answers.
  private var showsCompactListening: Bool {
    isVoiceListening
      && !isResultsExpanded
      && (addressedPreview == nil || voicePrefixDraft?.isEffectivelyEmpty != false)
  }
  var isCompactListeningForTesting: Bool { showsCompactListening }
  var listeningWordsForTesting: String { listeningWords.stringValue }
  var listeningWordsShownForTesting: Bool { listeningWordsHost.alphaValue > 0 }
  var unifiedSurfaceFrameForTesting: CGRect { surfaceFrame }
  var unifiedSurfaceLayerForTesting: CALayer? { surfaceContainer.layer }
  var unifiedSurfaceCornerForTesting: CGFloat { surface.renderedCornerRadius }
  /// The shell's frame, in this view's coordinates.
  var surfaceFrameInView: CGRect { surfaceFrame }
  /// The shell's corner as it is drawn — what the drip lands on.
  var shellCornerRadius: CGFloat { surface.renderedCornerRadius }
  /// Whether a point on screen falls on the shell.
  func surfaceContainsScreenPoint(_ point: NSPoint) -> Bool {
    guard let window, !surfaceFrame.isEmpty else { return false }
    let inWindow = window.convertPoint(fromScreen: point)
    return surfaceFrame.contains(convert(inWindow, from: nil))
  }
  var composerCornerForTesting: (radius: CGFloat, height: CGFloat, curve: CALayerCornerCurve) {
    (promptHost.renderedCornerRadius, promptHost.bounds.height, promptHost.renderedCornerCurve)
  }
  var isComposerVisibleForTesting: Bool { promptCapsule.alphaValue > 0 }

  /// Session rows / scroll — always in front of the list glass wash.
  private let resultsForeground = NSView()
  /// Groups list chrome + rows so height constraints stay on one view.
  private let resultsCapsule = NSView()
  /// Live agent preview, between the prompt and the session list (the list
  /// hides once an addressee is chosen). Content only — the one glass shell
  /// behind it is `surface`.
  private let previewForeground = NSView()
  private let previewCapsule = NSView()
  private let previewCard = BolttyAIPreviewCard()
  private let resultsScroll = NSScrollView()
  private let resultsStack = ResultsListView()
  /// ScreenAgents' tabs. Outside the scroll view, so scrolling the history
  /// never carries the filter off the top of the card.
  private let historyTabs = AgentHistoryTabStripView()
  /// The rows travel up under the strip by `historyTabOverlap`, going soft
  /// and gone as they reach the names, as macOS 27's soft scroll edge does —
  /// no hard cut at the strip's foot. Zero
  /// while the strip is hidden: a search has no strip to pass under.
  private var resultsScrollTop: NSLayoutConstraint!
  private let resultsTopEdge = CAGradientLayer()
  private var resultsOverlap: CGFloat = 0
  /// The placeholder. It ends in an ellipsis where the controls leave it
  /// short — a named folder is wider than a glyph — rather than being cut
  /// mid-word ("Describe your tas").
  private let hintLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.lineBreakMode = .byTruncatingTail
    return label
  }()
  /// The prompt's scroll-position observer, which lives as long as the view.
  /// Held rather than discarded at the call site: an unreleased token is a
  /// registration the centre keeps for the life of the process.
  private let viewObservers = NotificationTokenBag()
  /// Created on first access so `setup()` cannot trap on an IUO that was
  /// still nil when the first `activate` array mentioned it.
  private lazy var resultsHeightConstraint = resultsCapsule.heightAnchor.constraint(equalToConstant: 0)
  private lazy var resultsWidthConstraint = resultsCapsule.widthAnchor.constraint(
    equalToConstant: AgentPaletteMetrics.promptSize.width
  )
  private lazy var resultsTopConstraint = resultsCapsule.topAnchor.constraint(
    equalTo: promptCapsule.bottomAnchor,
    constant: 0
  )
  private lazy var previewHeightConstraint = previewCapsule.heightAnchor.constraint(equalToConstant: 0)
  private lazy var previewWidthConstraint = previewCapsule.widthAnchor.constraint(
    equalToConstant: AgentPaletteMetrics.promptSize.width
  )

  /// **The transcript's band, which is no longer the card's height.**
  ///
  /// The shell is stacked out of this band, the gap under it, the composer and
  /// the floor — and that arithmetic is unchanged. What changed is the card's
  /// own frame: it runs past the band, behind the composer, down to the shell's
  /// floor, so a line scrolling out of the transcript passes under the glass
  /// and is cut by the shell's silhouette instead of ending at a rim of its own.
  ///
  /// Every reader of the old constant wanted this number, not that frame, which
  /// is why the two are named apart rather than one derived at each call site.
  private var previewBandHeight: CGFloat = 0 {
    didSet { applyPreviewBandHeight() }
  }

  /// What the composer and the shell's floor take out of the card, gap
  /// included. Zero outside a chat, where the card hangs *under* the prompt
  /// and has nothing to run behind.
  private var chatComposerBand: CGFloat {
    guard addressedPreview != nil else { return 0 }
    return AgentPaletteMetrics.surfaceStackSpacing
      + promptCapsuleHeightConstraint.constant
      + AgentPaletteMetrics.shellContentInset
  }

  private func applyPreviewBandHeight() {
    previewHeightConstraint.constant = previewBandHeight
      + (previewBandHeight > 0 ? chatComposerBand : 0)
  }
  /// The reply card hangs under the prompt, like the switcher does.
  ///
  /// It was above for one revision. The mock puts it back: you read down from
  /// what you are typing into, and the prompt keeps the screen position it has
  /// in every other palette state — one anchor, not two, so nothing moves when
  /// a card appears.
  private lazy var previewTopConstraint = previewCapsule.topAnchor.constraint(
    equalTo: promptCapsule.bottomAnchor,
    constant: 0
  )
  /// The initial capsule is fixed; the chat composer can use more of the
  /// space already reserved inside its shell.
  private lazy var promptCapsuleHeightConstraint = promptCapsule.heightAnchor.constraint(
    equalToConstant: AgentPaletteMetrics.promptSize.height
  )
  /// Distance from the view's top to the capsule. Updated in `layout` so the
  /// prompt stays at the same screen height whether the window is the old
  /// hug-content panel or the full screen.
  private lazy var promptTopConstraint = promptCapsule.topAnchor.constraint(
    equalTo: topAnchor,
    constant: AgentPaletteMetrics.safeAreaY
  )
  private lazy var promptCenterXConstraint = promptCapsule.centerXAnchor.constraint(
    equalTo: centerXAnchor
  )
  /// An edge drag in flight: which edges, where it started, and the size
  /// the shell had then.
  private var resizeDrag: (
    edges: SurfaceResizeEdges, shell: ResizableShell, start: NSPoint, size: CGSize
  )?
  private lazy var promptScrollHeightConstraint = promptScroll.heightAnchor.constraint(
    equalToConstant: PromptTextView.lineHeight
  )
  private lazy var errorTopToPromptConstraint = bottomBar.topAnchor.constraint(
    equalTo: promptCapsule.bottomAnchor,
    constant: AgentPaletteMetrics.errorTopSpacing
  )
  private lazy var errorTopToResultsConstraint = bottomBar.topAnchor.constraint(
    equalTo: resultsCapsule.bottomAnchor,
    constant: AgentPaletteMetrics.errorTopSpacing
  )
  private lazy var errorTopToPreviewConstraint = bottomBar.topAnchor.constraint(
    equalTo: previewCapsule.bottomAnchor,
    constant: AgentPaletteMetrics.errorTopSpacing
  )
  private var isVoiceListening = false
  private var isVoiceProcessing = false
  /// Text that was already in the field when dictation started. Partial
  /// transcripts replace only the spoken span, not this prefix.
  private var voicePrefixDraft: PromptDraft?
  /// The last transcript actually written into the field; see
  /// `applyVoiceTranscript`.
  private var appliedVoiceTranscript: String?
  /// Where the spoken text begins, in UTF-16 units — everything before it was
  /// typed before the mic went live and must never be touched.
  private var voicePrefixLength: Int?
  private var voiceExpectedText: String?
  private var voiceTranscriptWasInterrupted = false
  private var isApplyingVoiceTranscript = false
  private var promptRemeasureWorkItem: DispatchWorkItem?
  private var isPerformingLayout = false

  /// The switcher's rows, already built.
  ///
  /// What they are built *from* (Boltty's conversations and the CLIs' own
  /// sessions) is not the panel's business; it only draws them.
  private var sessionItems: [BolttyAISessionItem] = []
  /// Transcripts behind those rows, for full-text narrowing. The rows carry
  /// the last message as their subtitle; finding an older turn needs the rest.
  private var sessionTranscripts: [UUID: ConversationTranscript] = [:]
  private var resultItems: [BolttyAISessionItem] = []
  /// The same rows, cut into days. Empty while searching — see
  /// `showsHistoryChrome`.
  ///
  /// `resultItems` stays the flat list on purpose: it is the selection space,
  /// and keyboard movement, Enter and the highlight all index into it. Sections
  /// describe how the list is *drawn*, never what ↑↓ walk through, so grouping
  /// could not put a heading between a row and the one below it.
  private var resultSections: [AgentHistory.Section] = []
  /// Which tab is filtering the history, or `nil` for the Latest tab — every
  /// agent, newest first. The list always opens there; a tab
  /// chosen by hand outlives a collapse, the way a place you were does.
  private(set) var activeHistoryAgent: AgentId?
  /// Headings on screen, keyed by day, so a refresh reuses them for the same
  /// reason the rows are keyed — see `syncResultRows`.
  private var headersByDay: [String: AgentHistorySectionHeaderView] = [:]
  private var selectedResultIndex = -1
  private var isResultsExpanded = false {
    didSet {
      guard isResultsExpanded != oldValue else { return }
      // What the list opened with is the order it keeps while open —
      // `BolttyAISessionList.holding(_:to:)`.
      heldSessionItems = isResultsExpanded ? sessionItems : nil
    }
  }
  private var heldSessionItems: [BolttyAISessionItem]?
  /// What the card's column holds, top to bottom: headings and rows. Only
  /// the lines near what the card shows have a view — see `ResultsListView`.
  private var resultLines: [ResultLine] = []
  /// Where each of `resultItems` stands in `resultLines` — what ↑↓ walk is the
  /// rows alone, and a heading is drawn between them.
  private var resultLineIndexByRow: [Int] = []
  /// Rows keyed by the conversation they draw, so a refresh can reuse the one
  /// that is already on screen. See `syncResultRows`.
  private var rowsByConversation: [UUID: BolttyAISessionRowView] = [:]
  /// Where the pointer was when the keyboard last moved the selection, or `nil`
  /// once the pointer has moved since. Read by `hoverMoved` to tell a real
  /// hover from a row that scrolled under a cursor that never moved.
  private var keyboardSelectionPointerAnchor: NSPoint?
  /// Stands in for the real cursor under test.
  ///
  /// The hover rule is *"did the pointer move"*, and a test that read the live
  /// cursor would be asserting on where the machine's mouse happens to be —
  /// passing or failing depending on whether anyone nudged it mid-run.
  var pointerLocationForTesting: NSPoint?
  private var pointerLocation: NSPoint {
    pointerLocationForTesting ?? NSEvent.mouseLocation
  }
  private var addressedPreview: BolttyAISessionPreview?

  /// What the field's text means right now, and what the open list is for.
  ///
  /// The prompt field used to switch roles invisibly after ↓. The list now
  /// opens first, then typing restores the visible field and makes the filter
  /// explicit; an empty result also says exactly what Enter will do.
  ///
  /// ↓ opens it at the rows; the first typed character brings the field back
  /// and narrows those rows rather than throwing the list away. `/` is not a
  /// way into the search: paths and CLI commands start with it.
  enum Mode: Equatable {
    /// List closed. Enter launches a new agent.
    case prompt
    /// ↓ opened the list before a query has been typed.
    case picking
    /// The visible field is narrowing the open list. Enter opens a match, or
    /// starts the query as a new prompt when there are no matches.
    case search
  }

  private(set) var mode: Mode = .prompt

  /// True while the field holds a query instead of a message — the one state in
  /// which its text must never be sent to an agent.
  var fieldIsQuery: Bool { mode == .search }

  /// What the list filters on. Only search turns the words into a filter;
  /// before the first keystroke the list stays whole.
  private var resultsQuery: String { mode == .search ? field.searchQuery : "" }

  /// Whether the list is history or a result set.
  ///
  /// ↓ opens ScreenAgents: every chat, cut by agent and by day. Typing turns
  /// it into matches for what was typed, and matches have neither an agent you chose
  /// nor a day worth grouping by — a heading over one row is noise, and a tab
  /// strip over a search is a second filter competing with the words. So the
  /// two states keep the same rows and the same card, and only one of them
  /// wears the chrome.
  private var showsHistoryChrome: Bool { mode != .search }


  /// Minted before submission so the mascot shown in Boltty AI is the exact
  /// one the created conversation keeps in the sidebar and transcript.
  private(set) var pendingConversationID = UUID()

  /// The agents Tab walks on the first screen, in the history tabs' order.
  private var agentChoices: [AgentId] = []
  /// Where Enter goes when nothing is chosen — the preferred agent when it is
  /// ready.
  private var plannedAgent: AgentId?
  /// The agent Tab picked for the next new prompt, or `nil` to follow
  /// `plannedAgent`. Cleared each time the panel opens: a fresh Boltty AI
  /// starts on the preferred agent.
  private(set) var chosenAgent: AgentId?
  /// The agent a new prompt will start on.
  var agentForNewPrompt: AgentId? { chosenAgent ?? plannedAgent }
  /// Tab changed the agent; the controller re-reads what that agent can do.
  var onAgentChoiceChange: (() -> Void)?

  var mascotIdentityForTesting: UUID? { selectedAgentImage.mascotIdentity }
  var mascotEmotionForTesting: MascotEmotion? { selectedAgentImage.mascotEmotion }
  /// The palette the face is wearing — the colour half of its identity, which
  /// moves with the agent while `mascotIdentityForTesting` stays put.
  var mascotPaletteIDForTesting: String? { selectedAgentImage.mascotPaletteID }
  /// Outline and gradient both.
  var mascotLookForTesting: MascotLook? { selectedAgentImage.mascotLook }

  /// Shown in place of the session list when no CLI was found at all, so first
  /// run explains itself instead of failing on the first prompt.
  /// Whether the palette is standing in for a missing agent. A flag rather
  /// than the list it is derived from: the card names no agents now, so
  /// keeping the array would be storing something nothing draws.
  private var showsNoAgentsState = false
  private var isShowingInstallHints = false

  /// The visible capsule and its shadow. The enclosing panel stays static.
  var presentationLayer: CALayer? { layer }

  /// Typed prompt text color — adapts to light/dark appearance.
  /// Mock sentence colour — `#fff`, not `labelColor` (that is ~#f5f5f7).
  static let promptTypingTextColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
  /// Agent icon tint — adapts to light/dark appearance.
  /// Opaque sRGB, not `labelColor`. Catalog label colours are vibrant: on
  /// Liquid Glass they pick up the Siri-style sheen and the mark reads as a
  /// glass tile instead of a glyph.
  static let promptIconTintColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
  var usesSystemGlassBackgroundForTesting: Bool {
    promptHost.isUsingGlassForTesting
  }
  var usesDirectionalGlassOverlayForTesting: Bool {
    promptHost.hasVerticalOverlayForTesting
  }
  /// The shell's wash, which is a different question from the composer's: the
  /// first screen's prompt ramp, and none in any other state. The
  /// composer never wears one.
  var surfaceUsesDirectionalGlassOverlayForTesting: Bool {
    surface.hasVerticalOverlayForTesting
  }
  var composerHostsContentInSystemGlassForTesting: Bool {
    promptHost.hostsContentInSystemGlassForTesting
  }
  var voiceOrbUsesSystemGlassForTesting: Bool { micButton.usesSystemGlass }
  var previewCardForTesting: BolttyAIPreviewCard { previewCard }
  var addressedPreviewForTesting: BolttyAISessionPreview? { addressedPreview }
  /// The shell and the composer draw the one shared glass, whatever it
  /// currently is — in every state but the first screen, whose shell alone
  /// wears the prompt ramp (`bolttyAIPrompt`).
  ///
  /// Deliberately not "they all use material X": the point the palette has to
  /// keep is that the three agree, and pinning the material by name here meant
  /// retuning the look broke a test that was never about the look.
  var usesSharedSurfaceStyleForTesting: Bool {
    surface.surfaceStyleForTesting == .bolttyAI
      && promptHost.surfaceStyleForTesting == .bolttyAI
  }
  var initialPromptChromeIsVisibleForTesting: Bool { !promptHost.isHidden }
  var shellUsesGlassForTesting: Bool { surface.isUsingGlassForTesting }
  var composerUsesGlassForTesting: Bool { promptHost.isUsingGlassForTesting }
  var isResultsExpandedForTesting: Bool { isResultsExpanded }
  var resultsCardHeightForTesting: CGFloat { resultsHeightConstraint.constant }
  /// The corner the card is actually wearing, not the one the metric asks for.
  ///
  /// **Read off `surface`, which is the only shell that paints.** This used to
  /// read `resultsHost`, a `PaletteGlassHost` that `updateUnifiedSurface()`
  /// hides unconditionally on every layout pass — so the number it returned was
  /// a property of an invisible view, and the test built on it stayed green
  /// while the card on screen wore a different corner entirely.
  var resultsCardCornerRadiusForTesting: CGFloat { surface.renderedCornerRadius }
  var resultItemsForTesting: [BolttyAISessionItem] { resultItems }
  var selectedResultIndexForTesting: Int { selectedResultIndex }
  var emptyResultsTitleForTesting: String? {
    (resultsStack.arrangedSubviews.first as? BolttyAIEmptyResultsView)?.title
  }
  /// `doCommandBy` normally reads the keyboard event AppKit is dispatching.
  /// Unit tests call the delegate seam directly, so they supply those flags.
  var commandModifierFlagsForTesting: NSEvent.ModifierFlags?
  /// The rows built for the list as it stands, in its order — every row
  /// within reach of the viewport, so all of them for a short list.
  var resultRowViewsForTesting: [BolttyAISessionRowView] {
    resultItems.compactMap { rowsByConversation[$0.id] }
  }
  /// Drives the row's own hover callback, so a test exercises the rule in
  /// `hoverMoved` rather than a copy of it.
  func hoverRowForTesting(at index: Int) {
    guard resultItems.indices.contains(index) else { return }
    rowsByConversation[resultItems[index].id]?.onHover?()
  }
  /// What the composer offers when it is empty.
  var promptPlaceholderForTesting: String { hintLabel.stringValue }
  /// The placeholder's baseline and the first typed line's, in window space —
  /// the two must be one line.
  var placeholderBaselineInWindowForTesting: CGFloat {
    hintLabel.convert(hintLabel.bounds, to: nil).maxY - hintLabel.firstBaselineOffsetFromTop
  }
  var typedBaselineInWindowForTesting: CGFloat? {
    guard let layoutManager = field.layoutManager, let container = field.textContainer,
          (field.textStorage?.length ?? 0) > 0 else { return nil }
    layoutManager.ensureLayout(for: container)
    let line = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
    let baseline = line.minY + layoutManager.location(forGlyphAt: 0).y + field.textContainerOrigin.y
    return field.convert(NSPoint(x: 0, y: baseline), to: nil).y
  }
  var stopTooltipForTesting: String? { stopTooltip }
  var stopHelpShortcutForTesting: String? { sendButton.button.helpShortcut }
  var voiceControlFrameForTesting: CGRect {
    // The disc itself, not the stack that holds it. They were the same view's
    // worth of geometry until the paperclip joined the stack, and the thing
    // every caller means by "the voice control" is the disc.
    promptForeground.convert(micButton.bounds, from: micButton)
  }
  var composerForegroundSizeForTesting: CGSize { promptForeground.bounds.size }
  /// The clip, in the same space as `voiceControlFrameForTesting`.
  var attachDiscFrameForTesting: CGRect {
    promptForeground.convert(attachRestDisc.bounds, from: attachRestDisc)
  }
  var attachRestDiscForTesting: GlassCircleButton { attachRestDisc }
  /// The glass field itself, in the same space as `voiceControlFrameForTesting`,
  /// so a test can ask whether the disc stands beside it or on it.
  var composerFieldFrameForTesting: CGRect {
    promptForeground.convert(promptHost.bounds, from: promptHost)
  }
  /// The composer's box in window space, for measuring where its ink lands.
  var composerBoxInWindowForTesting: CGRect { promptHost.convert(promptHost.bounds, to: nil) }
  /// The first typed letter's ink — its left edge and its capitals' top — in
  /// window space, off the laid-out text and the face's own glyph box.
  var typedFirstInkInWindowForTesting: (left: CGFloat, capTop: CGFloat)? {
    guard let layoutManager = field.layoutManager, let font = field.font,
          let baseline = typedBaselineInWindowForTesting else { return nil }
    let x = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minX
      + layoutManager.location(forGlyphAt: 0).x + field.textContainerOrigin.x
    let glyph = font.boundingRect(forCGGlyph: layoutManager.cgGlyph(at: 0))
    return (field.convert(NSPoint(x: x, y: 0), to: nil).x + glyph.minX, baseline + font.capHeight)
  }
  var promptCapsuleHeightForTesting: CGFloat { promptCapsuleHeightConstraint.constant }
  var isVoiceListeningForTesting: Bool { isVoiceListening }
  var micButtonForTesting: GlassCircleVoiceButton { micButton }
  var isShowingRecordingControlsForTesting: Bool { !recordingControls.isHidden }
  var voiceGlowForTesting: VoiceEdgeGlowView { voiceGlow }
  /// The light is a sibling *below* the shell's glass, so the glass bends it.
  var voiceGlowIsUnderTheGlassForTesting: Bool {
    guard let glow = subviews.firstIndex(of: voiceGlow),
          let glass = subviews.firstIndex(of: surfaceContainer)
    else { return false }
    return glow < glass
  }

  /// Tests drive the hover-reveal without synthesizing a mouse-entered event.
  func setRecordingHoverForTesting(_ hovering: Bool) {
    setRecordingControlsRevealed(hovering, animated: false)
  }
  var resultsCapsuleLayerForTesting: CALayer? { resultsCapsule.layer }
  var resultsForegroundLayerForTesting: CALayer? { resultsForeground.layer }
  /// Whether the card would paint anything right now.
  var isResultsCardVisibleForTesting: Bool {
    !resultsCapsule.isHidden && resultsCapsule.alphaValue > 0
  }
  var resultsCapsuleFrameForTesting: CGRect { resultsCapsule.frame }
  var promptCapsuleFrameForTesting: CGRect { promptCapsule.frame }
  var isPromptExpandedForTesting: Bool { isPromptExpanded }
  /// The three boxes of the dictating capsule, all in this view's own space —
  /// they live in different containers, and what a test measures is the gaps
  /// between them.
  var promptTextFrameForTesting: CGRect { convert(promptScroll.bounds, from: promptScroll) }
  var recordingControlsFrameForTesting: CGRect {
    convert(recordingControls.bounds, from: recordingControls)
  }
  var isAddressingForTesting: Bool { addressedPreview != nil }
  var visibleErrorForTesting: String? { notice.isHidden ? nil : notice.message }
  var errorFrameForTesting: CGRect { convert(notice.bounds, from: notice) }
  var workingDirectoryChipForTesting: WorkingDirectoryChipView { directoryChip }
  var isWorkingDirectoryChipVisibleForTesting: Bool { !directoryChip.isHidden }
  var addressedSessionIDForTesting: UUID? { addressedPreview?.id }
  var isPreviewCardVisibleForTesting: Bool {
    !previewCapsule.isHidden
  }
  var previewBodyForTesting: String { previewCard.bodyForTesting }
  var previewCardHeightForTesting: CGFloat { previewBandHeight }
  /// The corner the preview card is actually wearing, not the one asked for.
  ///
  /// Same correction as `resultsCardCornerRadiusForTesting`: `previewHost` is
  /// hidden on every layout pass, so what the reader sees is `surface`.
  var previewCardCornerRadiusForTesting: CGFloat { surface.renderedCornerRadius }
  var previewForegroundClipForTesting: (radius: CGFloat, curve: CALayerCornerCurve, clips: Bool) {
    guard let layer = previewForeground.layer else { return (0, .circular, false) }
    return (layer.cornerRadius, layer.cornerCurve, layer.masksToBounds)
  }
  var promptTopInsetForTesting: CGFloat { promptTopConstraint.constant }
  var promptCenterXOffsetForTesting: CGFloat { promptCenterXConstraint.constant }
  var previewCapsuleFrameForTesting: CGRect { previewCapsule.frame }
  /// The transcript's band: the part of the card the shell's stack is built
  /// out of. The capsule's own frame runs past it, behind the composer, to the
  /// shell's floor — so a test about *stacking* wants this rect, and a test
  /// about the card running under the glass wants the other one.
  var previewBandFrameForTesting: CGRect {
    let rect = previewCapsule.frame
    return CGRect(
      x: rect.minX,
      y: isFlipped ? rect.minY : rect.maxY - previewBandHeight,
      width: rect.width,
      height: previewBandHeight
    )
  }
  var addressedSessionID: UUID? { addressedPreview?.id }
  var addressedQuestion: AgentQuestion? { addressedPreview?.question }
  /// The two views a Tab press swaps: the agent mark and the placeholder.
  var targetSwapLayerForTesting: CALayer? { selectedAgentImage.layer }
  var placeholderLayerForTesting: CALayer? { hintLabel.layer }
  var promptCapsuleLayerForTesting: CALayer? { promptCapsule.layer }
  var promptForegroundLayerForTesting: CALayer? { promptForeground.layer }
  /// Same rule as the card: filters or rasterization here would collapse the
  /// prompt's glass to its opaque fallback.
  var promptCapsuleRendersOffscreenForTesting: Bool {
    guard let layer = promptCapsule.layer else { return false }
    return layer.shouldRasterize || !(layer.filters?.isEmpty ?? true)
  }
  /// True when anything would push the card through an offscreen pass, which
  /// is where its glass loses the backdrop it samples.
  var resultsCapsuleRendersOffscreenForTesting: Bool {
    guard let layer = resultsCapsule.layer else { return false }
    return layer.shouldRasterize || !(layer.filters?.isEmpty ?? true)
  }

  /// Normalizes the backing layer after Auto Layout before applying a transform.
  /// AppKit may recreate or reposition backing layers while showing a borderless panel.
  @discardableResult
  func preparePresentationLayer() -> CALayer? {
    layoutSubtreeIfNeeded()
    return layer
  }

  override init(frame frameRect: NSRect) {
    // Chrome hosts have empty content — real UI lives in foreground siblings
    // so glass/gradient can never paint over text and icons.
    // Shadow lives on the capsule containers (not the glass host): NSGlassEffectView
    // + layer-backed parents often clip/suppress CALayer shadows on the host itself.
    // Start without a wash, then install the explicit initial/chat recipe in
    // applyPlacement. Content-hosting glass omits the initializer's wash, so
    // starting with .bolttyAI would skip it on the first same-style apply.
    promptHost = PaletteGlassHost(
      content: NSView(),
      cornerRadius: AgentPaletteMetrics.cornerRadius,
      style: .init(material: .regular, drawsOuterShadow: false),
      // The composer is a control, so its content sits *in* the material and
      // the material is left to render itself. The shell above it is a
      // background and keeps what it had.
      hostsContentInGlass: true
    )
    (promptScroll, field) = PromptTextView.makeInScrollView()
    super.init(frame: frameRect)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func reset(error: String? = nil) {
    PaletteHelpPresenter.shared.dismiss()
    endScreenSelection()
    leaveAddressing(animated: false)
    field.clearPrompt()
    hintLabel.isHidden = false
    hideNotice()
    notice.message = ""
    setVoiceListening(false)
    // The palette is going away or coming back — no fade to wait for.
    collapseResults(animated: false)
    if let error {
      showError(error)
    }
    onContentSizeChange?()
  }

  /// Opens or closes the recording UI, and says what the glow should do next.
  ///
  /// `ending` exists because "stopped listening" is not one event. A confirmed
  /// take goes on to the beam while the engine finalises, a discarded one stops
  /// at once, and a failure leaves faster still so it is not competing with the
  /// error message arriving in the same instant. Collapsing all three into one
  /// call is how the beam state would have had nowhere to attach.
  ///
  /// **The prefix outlives the session on purpose.** It used to be cleared
  /// here on stop, which threw the prompt away: `SFSpeechRecognitionTask`
  /// delivers its *final*, polished result after the audio engine has already
  /// stopped, so that last callback ran with no prefix left — rebuilding the
  /// draft from empty and wiping everything typed before the mic went live.
  ///
  /// Ignoring late transcripts would be the wrong fix; the final one is the
  /// better transcription and is exactly what should land. Only a new
  /// dictation may replace the prefix, which the recapture below does.
  func setVoiceListening(_ listening: Bool, ending: VoiceGlowPhase = .completed) {
    if listening, !isVoiceListening {
      voicePrefixDraft = field.draft
      // A new session starts from nothing, so the first result of it always
      // counts as a change even if it repeats the last one of the previous.
      appliedVoiceTranscript = nil
      voicePrefixLength = (field.string as NSString).length
      voiceExpectedText = field.string
      voiceTranscriptWasInterrupted = false
    }
    if listening { setComposerKeyTarget(.text) }
    isVoiceListening = listening
    isVoiceProcessing = !listening && ending == .processing
    refreshMascotEmotion()
    syncVoiceGlowPalette()
    if listening {
      placeVoiceGlow()
      // The orb's gradient fills a shell the take collapses; a composer that
      // stays beside its chat is lit from its foot, as before. Left as it is
      // when the take ends, so the light fades out as what it was.
      voiceGlow.fillsShell = showsCompactListening
      setListeningWords("")
    }
    voiceGlow.setPhase(listening ? .listening : ending)
    if listening {
      recordingControls.startRecording()
    } else {
      recordingControls.stopRecording()
      setRecordingControlsRevealed(false, animated: false)
    }
    applyMicAppearance()
    // The shell's own geometry just changed — the capsule replaces the composer
    // and is a different width. Without this the only thing that re-lays it out
    // is the panel changing size, which happens in the app (the window resizes
    // to the new content) and never offscreen, so the state would be correct
    // and the silhouette stale.
    needsLayout = true
    layoutSubtreeIfNeeded()
    if listening {
      setRecordingControlsRevealed(recordingHoverSensor.isPointerInside, animated: false)
    }
    syncPromptExpansion()
    syncPromptHeight()
    syncSendButton()
    onContentSizeChange?()
  }

  /// Puts the light under the glass — and over the shell with Reduce
  /// Transparency, where the glass is a flat black fill that would hide it, as
  /// the light always stood before it went under. Only ever done while the
  /// glow is idle: taking a view out of the hierarchy stops its clock.
  private func placeVoiceGlow() {
    guard voiceGlow.phase == .idle,
          let glow = subviews.firstIndex(of: voiceGlow),
          let glass = subviews.firstIndex(of: surfaceContainer)
    else { return }
    let underGlass = surface.usesSystemGlass
    guard underGlass != (glow < glass) else { return }
    addSubview(voiceGlow, positioned: underGlass ? .below : .above, relativeTo: surfaceContainer)
  }

  /// Moves the glow without touching the recording controls.
  ///
  /// The two are not the same clock. Audio stops when ✓ is pressed, and the
  /// transcript lands some time after that — the controls belong to the first
  /// moment and the glow to the second.
  func setVoiceGlowPhase(_ phase: VoiceGlowPhase) {
    voiceGlow.setPhase(phase)
    isVoiceProcessing = phase == .processing
    applyMicAppearance()
    syncSendButton()
  }

  /// Whether the glow is still drawing, in any phase.
  var isVoiceGlowActive: Bool { voiceGlow.phase != .idle }

  /// Throws away what was dictated and restores the prompt as it was.
  ///
  /// The prefix is what makes this possible: everything typed or pasted before
  /// the microphone went live was snapshotted then, so cancelling is a restore
  /// rather than a guess at which words were spoken.
  func discardVoiceTranscript() {
    let draft = voicePrefixDraft ?? PromptDraft()
    field.setDraft(draft)
    appliedVoiceTranscript = nil
    voicePrefixLength = (field.string as NSString).length
    hintLabel.isHidden = !field.isEmptyPrompt
    applyPromptForegroundAppearance()
    if isResultsExpanded {
      refreshResults(keepingSelection: true)
    }
  }

  /// One microphone reading, on its way to the voice control's sweep.
  ///
  /// Deliberately a straight pass-through: the smoothing lives in the button,
  /// beside the constants that describe it, rather than being applied here and
  /// again there.
  func applyVoiceLevel(_ level: CGFloat) {
    micButton.setAudioLevel(level)
    recordingControls.setAudioLevel(level)
    voiceGlow.setAudioLevel(level)
  }

  /// Applies a voice transcript into the prompt field (partial or final).
  ///
  /// Dictation rewrites its whole transcript on every partial result, so it
  /// replaces the spoken span only. Typed words and chips from before the
  /// mic went live stay put.
  func applyVoiceTranscript(_ transcript: String) {
    guard !voiceTranscriptWasInterrupted else { return }
    if let expected = voiceExpectedText, field.string != expected { return }
    // Identical results are common and cost a full rebuild each.
    //
    // Apple's volatile results repeat, so an unchanged string arrives
    // whenever the speaker pauses. Each one rebuilt the whole text document,
    // re-laid out the prompt and — with the switcher open — rebuilt every row
    // in the session list. None of that can change the pixels.
    guard transcript != appliedVoiceTranscript else { return }
    appliedVoiceTranscript = transcript
    isApplyingVoiceTranscript = true
    defer {
      isApplyingVoiceTranscript = false
      voiceExpectedText = field.string
    }

    if !replaceSpokenTail(with: transcript) {
      var draft = voicePrefixDraft ?? PromptDraft()
      draft.append(text: transcript)
      field.setDraft(draft)
    }
    hintLabel.isHidden = !field.isEmptyPrompt
    applyPromptForegroundAppearance()
    syncPromptExpansion()
    syncPromptHeight()
    if isResultsExpanded {
      refreshResults(keepingSelection: true)
    }
    if showsCompactListening {
      // The orb grows round the words; the shell is re-measured from them.
      setListeningWords(transcript)
      needsLayout = true
    }
  }

  /// What the listening capsule says: the words of this take alone — a draft
  /// typed before it is in the prompt, out of sight, and silence is the orb.
  private func setListeningWords(_ transcript: String) {
    let words = transcript
      .replacingOccurrences(of: "\u{FFFC}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard words != listeningWords.stringValue else { return }
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.shadowBlurRadius = 6
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingHead
    listeningWords.attributedStringValue = NSAttributedString(string: words, attributes: [
      .font: roundedAppFont(size: AgentPaletteMetrics.listeningWordsFontSize, weight: .medium),
      .foregroundColor: PaletteInk.primary,
      .shadow: shadow,
      .paragraphStyle: paragraph
    ])
  }

  /// The listening shell's width: the orb until a word is heard, then a
  /// capsule round the words, no longer than the prompt.
  ///
  /// Measured off the string, not `sizeToFit()`: a label that truncates at its
  /// head answers that with the width it was given, not the one it wants.
  private func listeningShellWidth() -> CGFloat {
    let orb = AgentPaletteMetrics.listeningOrbDiameter
    guard !listeningWords.stringValue.isEmpty else { return orb }
    let natural = ceil(listeningWords.attributedStringValue.size().width)
    let padded = natural + AgentPaletteMetrics.listeningWordsInset * 2
    return min(AgentPaletteMetrics.listeningMaxWidth, max(orb, padded))
  }

  /// Writes only the part of the transcript that differs from what is shown.
  ///
  /// The engine revises as it goes — Apple's volatile tail, and a second
  /// language's phrase swapped in when it wins — so most results share a long
  /// prefix with the last one. Rewriting
  /// only from the first character that actually changed is what stopped the
  /// prompt re-laying itself out on every result, which is what the lag was.
  ///
  /// Returns `false` when it cannot be sure the document still looks the way it
  /// left it — the caller then rebuilds from the prefix draft, which is always
  /// correct if slower.
  private func replaceSpokenTail(with transcript: String) -> Bool {
    guard let prefixLength = voicePrefixLength else { return false }
    let document = field.string as NSString
    guard document.length >= prefixLength else { return false }

    let shown = document.substring(from: prefixLength)
    // Grapheme clusters, not UTF-16 units: splitting a surrogate pair or an
    // emoji here would corrupt the very character being spoken.
    let common = shown.commonPrefix(with: transcript)
    let commonLength = (common as NSString).length
    field.replaceTail(
      from: prefixLength + commonLength,
      with: String(transcript.dropFirst(common.count))
    )
    return true
  }

  @discardableResult
  func focusField() -> Bool {
    field.isEditable = true
    field.isSelectable = true
    guard window != nil else { return false }

    applyPromptForegroundAppearance()
    let accepted = window?.makeFirstResponder(field) == true
    let end = field.textStorage?.length ?? 0
    field.setSelectedRange(NSRange(location: end, length: 0))
    return accepted
  }

  /// What the folder chip says, or `nil` to draw none.
  ///
  /// Pushed in rather than pulled: the panel has no conversation layer of its
  /// own, and the two facts the chip is made of — whether the store would
  /// accept a change, and whether the adapter honours the folder at all — are
  /// both below it.
  func setWorkingDirectory(_ chip: WorkingDirectoryChip?) {
    let wasHidden = directoryChip.isHidden
    workingDirectory = chip
    if let chip { directoryChip.apply(chip) }
    syncDirectoryChipVisibility()
    // A name that came or went changes the row's width, and the words'
    // trailing edge is worked out from it in the next pass.
    needsLayout = true
    if wasHidden != directoryChip.isHidden { onContentSizeChange?() }
  }

  /// The folder menu, dropped from the chip's lower edge — the system's own
  /// menu, in the panel's dark appearance.
  func showWorkingDirectoryMenu(_ menu: NSMenu) {
    menu.appearance = NSAppearance(named: .darkAqua)
    let gap: CGFloat = 4
    let below = NSPoint(
      x: 0,
      y: directoryChip.isFlipped ? directoryChip.bounds.maxY + gap : -gap)
    menu.popUp(positioning: nil, at: below, in: directoryChip)
  }

  /// Visible exactly where the composer is.
  ///
  /// The listening capsule and the session list each replace the composer
  /// rather than sit above it, and a folder chip hanging under either would
  /// be labelling something that is not on screen.
  private var composerIsUp: Bool {
    !showsCompactListening
      && !(isResultsExpanded && addressedPreview == nil)
  }

  private func syncDirectoryChipVisibility() {
    let composerIsUp = self.composerIsUp
    let hidden = workingDirectory == nil || !composerIsUp
    // Assigned only on a change: this runs inside `layout`, and writing
    // `isHidden` on an arranged subview invalidates the stack every time.
    if directoryChip.isHidden != hidden {
      directoryChip.isHidden = hidden
    }
    let diameter = composerControlDiameter
    directoryChip.diameter = diameter
    planRing.diameter = diameter
    planRing.ringOuterDiameter = ComposerControlGroup.glyph(chat: composerGlyphsAreChat)
    // A ring with nothing to read is not drawn and gives back its gap.
    trailingControls.setCustomSpacing(planRing.hasReading ? trailingControls.spacing : 0, after: planRing)
    // At home the folder is a target like its neighbours; naming a folder,
    // it is a pill as wide as the name (`WorkingDirectoryChipView.slotWidth`).
    let folderWidth: CGFloat = workingDirectory == nil ? 0 : directoryChip.slotWidth
    if directorySlotWidth.constant != folderWidth { directorySlotWidth.constant = folderWidth }
    trailingControls.setCustomSpacing(folderWidth == 0 ? 0 : trailingControls.spacing, after: directorySlot)
    syncAutoModeButton()
    let usageHidden = !composerIsUp || !planRing.hasReading
    planRing.chatIsOpen = addressedPreview != nil
    if planRing.isHidden != usageHidden {
      planRing.isHidden = usageHidden
    }
    syncLatestPill()
  }

  /// Drawn in an open chat whose agent offers Auto Mode, lit while it is on.
  private func syncAutoModeButton() {
    let mode = composerIsUp && composerGlyphsAreChat ? addressedPreview?.autoMode : nil
    let hidden = mode == nil
    if autoModeButton.isHidden != hidden { autoModeButton.isHidden = hidden }
    autoModeButton.diameter = composerControlDiameter
    let width = hidden ? 0 : composerControlDiameter
    if autoModeWidth.constant != width {
      autoModeWidth.constant = width
      needsLayout = true
    }
    trailingControls.setCustomSpacing(hidden ? 0 : trailingControls.spacing, after: autoModeSlot)
    let agent = addressedPreview?.agent ?? .custom
    guard mode != shownAutoMode?.on || agent != shownAutoMode?.agent else { return }
    let wasShown = shownAutoMode?.agent == agent
    shownAutoMode = mode.map { ($0, agent) }
    guard let on = mode else { return }
    let button = autoModeButton.button
    // A switch the pointer just pressed answers in a beat, not a cut.
    if wasShown, !MotionPreferences.reduceMotion, let layer = button.layer {
      let fade = CATransition()
      fade.type = .fade
      fade.duration = Motion.quick
      fade.timingFunction = Motion.standardCurve
      layer.add(fade, forKey: "autoMode")
    }
    button.image = ComposerControlGroup.symbol(
      on ? "a.circle.fill" : "a.circle", description: "Auto Mode", chat: true)
    button.restingTint = on ? ComposerControlGroup.hoverInk : ComposerControlGroup.restingInk
    button.toolTip = Self.autoModeHelp(on: on, agent: agent)
    button.setAccessibilityLabel("Auto Mode")
    button.setAccessibilityValue(on ? "On" : "Off")
  }

  /// The help tag: the state, what it lets through for this agent, and
  /// what a click does.
  static func autoModeHelp(on: Bool, agent: AgentId) -> String {
    let reach = AgentsSettingsPage.autoModeReach(for: agent)
    let line = reach.prefix(1).uppercased() + reach.dropFirst()
    return on
      ? "Auto Mode is on\n\(line)\nClick to ask before every action."
      : "Auto Mode is off\nEvery action asks first. Click to turn on Auto Mode: \(reach)"
  }

  @objc private func autoModeButtonPressed() {
    guard let preview = addressedPreview, let on = preview.autoMode else { return }
    var toggled = preview
    toggled.autoMode = !on
    // Drawn at once; the store's change comes back as the same value.
    addressedPreview = toggled
    syncAutoModeButton()
    onSetAutoMode?(preview.id, !on)
  }

  var autoModeButtonForTesting: GlassCircleButton { autoModeButton }
  var isAutoModeVisibleForTesting: Bool { !autoModeButton.isHidden }
  func pressAutoModeForTesting() { autoModeButtonPressed() }

  /// ↓ Latest gives its place to a notice while one is up.
  private func syncLatestPill() {
    let latestHidden = !offersLatest || addressedPreview == nil || !composerIsUp
      || !notice.isHidden
    setLatestPillShown(!latestHidden)
  }

  /// Usage for the agent Enter will start on. With no plan reading and no
  /// context there is no ring at all.
  func setUsage(_ usage: AgentUsage?, agent: AgentId?) {
    planRing.apply(usage, agent: agent)
    syncDirectoryChipVisibility()
    needsLayout = true
  }

  var planRingForTesting: PlanUsageRingView { planRing }
  var latestPillForTesting: GlassCircleButton { latestPill }

  /// Whether "↓ Latest" is wanted on screen — what the pill is fading toward.
  private var isLatestPillShown = false

  /// "↓ Latest" arrives and leaves as a thing, fading over `quick`, rather
  /// than blinking into place over the transcript. Opacity only, which is
  /// also what Reduce Motion keeps. A fade-out cut short by the pill being
  /// wanted again leaves it shown: the completion asks what is wanted *now*.
  /// With no window to watch, it is set at once.
  private func setLatestPillShown(_ shown: Bool) {
    guard shown != isLatestPillShown else { return }
    isLatestPillShown = shown
    guard let window, window.isVisible else {
      latestPill.alphaValue = 1
      latestPill.isHidden = !shown
      return
    }
    if shown, latestPill.isHidden {
      latestPill.alphaValue = 0
      latestPill.isHidden = false
    }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Motion.quick
      context.timingFunction = Motion.standardCurve
      latestPill.animator().alphaValue = shown ? 1 : 0
    }, completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.isLatestPillShown else { return }
        self.latestPill.isHidden = true
        self.latestPill.alphaValue = 1
      }
    })
  }

  @objc private func scrollTranscriptToLatest() { previewCard.glideToLatest() }

  /// The composer's placeholder once the shell is a chat — WORK PAGE
  /// `1030:5810`. The initial prompt keeps its own (*Describe your task...*).
  static let chatComposerPlaceholder = "Do anything"

  /// While a permission waits, the composer says what typing there does:
  /// the words refuse it and tell the agent what to do instead, as Claude
  /// Code's "No, and tell Claude what to do differently". While a question
  /// that takes a typed answer waits, it says that typing is answering —
  /// OpenCode's terminal offers it as a row of its own.
  static func composerPlaceholder(for preview: BolttyAISessionPreview) -> String {
    if preview.question?.kind == .plan {
      return "Or tell \(preview.agent.shortDisplayName) what to change"
    }
    if preview.question?.takesWordsAsRefusal == true {
      return "Or tell \(preview.agent.shortDisplayName) what to do instead"
    }
    if preview.question?.takesWordsAsAnswer == true {
      return "Or type your own answer"
    }
    return chatComposerPlaceholder
  }

  static let refusalHelp = "Deny, and send these words to the agent"
  static let planChangesHelp = "Request changes, and send these words to the agent"

  /// Typed words, not attachments alone: what a question or a refusal reads.
  private var draftHasWords: Bool {
    !field.draft.typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The open chat's context reading, or `nil` for an agent that gives none.
  func setContext(_ usage: AgentContextUsage?, canCompact: Bool, cacheIsCold: Bool = false) {
    planRing.apply(context: usage, canCompact: canCompact, cacheIsCold: cacheIsCold)
    syncDirectoryChipVisibility()
    needsLayout = true
  }


  /// Says a message was queued, to VoiceOver only.
  ///
  /// **Not `showError`.** Nothing went wrong, and the red line is the one thing
  /// on this panel that means something did. What is *seen* is the card's own
  /// queued row, which stays there for as long as the message is waiting —
  /// this is only the announcement a sighted reader gets from the row
  /// appearing.
  func announceQueued(_ message: String) {
    announce(message)
  }

  /// Says what Stop will do, before it is pressed.
  ///
  /// Where the adapter has a real interrupt the turn keeps whatever it already
  /// wrote. Where the only exit is killing the process (`.terminableTurn`) the
  /// turn is lost and the conversation is not — and that is a different enough
  /// outcome that the button has to say so rather than let it be discovered.
  private func applyStopAffordance(_ preview: BolttyAISessionPreview) {
    stopTooltip = preview.stopIsAbrupt
      ? "Stop — this turn is lost, the chat is kept"
      : "Stop response"
  }

  /// Says where the prompt actually went, when that is not where Settings
  /// says it should.
  ///
  /// Shown at the send it describes and cleared on the next one: this is a
  /// fact about one message, not a standing condition. A banner that sat there
  /// permanently would be nagging about a state the person may well be fine
  /// with until they get round to signing back in.
  func showRoutingFallback(_ fallback: AgentRoutingFallback) {
    routingLabel.stringValue = fallback.sentence
    routingLabel.toolTip = fallback.tooltip
    routingRow.toolTip = fallback.tooltip
    routingRow.isHidden = false
    announce(fallback.sentence)
    anchorErrorLabel()
    onContentSizeChange?()
  }

  func hideRoutingFallback() {
    guard !routingRow.isHidden else { return }
    routingRow.isHidden = true
    anchorErrorLabel()
    onContentSizeChange?()
  }

  var routingFallbackTextForTesting: String? {
    routingRow.isHidden ? nil : routingLabel.stringValue
  }
  func pressRoutingSettingsForTesting() { openSettingsFromRouting() }

  @objc private func openSettingsFromRouting() { onOpenSettings?() }

  func showError(_ message: String) {
    notice.message = message
    refreshMascotEmotion(overriding: .sad)
    let wasHidden = notice.isHidden
    notice.isHidden = false
    anchorNotice()
    syncLatestPill()
    layoutSubtreeIfNeeded()

    // It arrives as a thing — rising a few points into place as it fades in
    // — and a second refusal while one is up only changes the words.
    if wasHidden, let window, window.isVisible {
      notice.alphaValue = 0
      if !MotionPreferences.reduceMotion, let layer = notice.layer {
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -AgentPaletteMetrics.errorRiseOffset
        rise.toValue = 0
        rise.duration = AgentPaletteMetrics.errorRevealDuration
        rise.timingFunction = Motion.standardCurve
        rise.preferringHighFrameRate()
        layer.add(rise, forKey: "noticeRise")
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = AgentPaletteMetrics.errorRevealDuration
        context.timingFunction = Motion.standardCurve
        notice.animator().alphaValue = 1
      }
    } else {
      notice.alphaValue = 1
    }
    announce(message)
    onContentSizeChange?()
  }

  /// The notice goes when the person acts on it — edits the draft, leaves —
  /// and ↓ Latest comes back to the place it borrowed.
  private func hideNotice() {
    guard !notice.isHidden else { return }
    notice.isHidden = true
    notice.alphaValue = 1
    syncLatestPill()
    onContentSizeChange?()
  }

  func render(
    agent: AgentId,
    conversationID: UUID? = nil,
    emotion: MascotEmotion? = nil,
    animated: Bool
  ) {
    if animated { beginTargetSwap() }

    // Identity is split: the *drift* is the conversation's and the *face* is
    // the agent's — the outline and gradient chosen for it in Settings
    // (`MascotLook.face(for:)`).
    //
    // The role is `.image` and there is no tooltip, because the mark is not a
    // control. It used to open a menu of launch targets, and that menu stopped
    // opening when the panel went to automatic routing — which is every build —
    // while the accessibility role kept promising a button for a while after.
    // Clicking it still pokes the face (`pokePromptMark`), which is a reaction
    // rather than a command, and a reaction is not a button either.
    selectedAgentImage.showMascot(
      conversationID: conversationID ?? pendingConversationID,
      emotion: emotion ?? (isVoiceListening ? .listening : .curious),
      look: MascotLook.face(for: agent)
    )
    selectedAgentImage.setAccessibilityLabel("Boltty")
    selectedAgentImage.setAccessibilityRole(.image)
    syncVoiceGlowPalette()
    applyPromptForegroundAppearance()
    onContentSizeChange?()
  }

  /// The rim and the caret wear the face that is on the prompt.
  ///
  /// Still read back off the mark rather than hard-coded: the rim and the face
  /// being the same colour is the point of it, and reading the one from the
  /// other is what keeps that true if either ever moves again.
  private func syncVoiceGlowPalette() {
    let palette = selectedAgentImage.mascotPaletteID
      .flatMap(MascotPalette.palette(withID:))
      ?? MascotPalette.face(for: agentForNewPrompt)
    voiceGlow.apply(palette: palette)
    // The caret's light too: one face, one light, on the words.
    field.caretPalette = palette
  }

  /// A shell with no window has nowhere to travel to.
  ///
  /// `CADisplayLink` retains its target, so a spring still in flight when the
  /// view is torn down keeps itself — and the clock it runs on — alive. One of
  /// those is invisible; a suite's worth of them share the main run loop with
  /// everything else that wants it, which is how a test that waits on the main
  /// actor starts missing a budget it used to make comfortably.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      surfaceMotion.settle()
    }
  }

  func cancelAllAnimationsAndSettle() {
    endDrip()
    surfaceMotion.settle()
    layer?.removeAllAnimations()
    layer?.opacity = 1
    layer?.transform = CATransform3DIdentity
    promptCapsule.layer?.removeAllAnimations()
    promptCapsule.layer?.transform = CATransform3DIdentity
    promptCapsule.alphaValue = 1
    promptHost.layer?.removeAllAnimations()
    promptForeground.layer?.removeAllAnimations()
    resultsCapsule.layer?.removeAllAnimations()
    resultsCapsule.layer?.transform = CATransform3DIdentity
    resultsForeground.layer?.removeAllAnimations()
    previewCapsule.layer?.removeAllAnimations()
    previewCapsule.layer?.transform = CATransform3DIdentity
    previewForeground.layer?.removeAllAnimations()
    field.layer?.removeAllAnimations()
    hintLabel.layer?.removeAllAnimations()
    hintLabel.layer?.filters = nil
    selectedAgentImage.layer?.removeAllAnimations()
    // A Tab swap may still be resolving; its completion block will not run once
    // the animation is gone, so the filter has to be dropped here by hand.
    selectedAgentImage.layer?.filters = nil
    field.alphaValue = 1
    hintLabel.alphaValue = 1
    applyPromptForegroundAppearance()
  }

  /// Back to the first screen, on the preferred agent and with a fresh
  /// conversation id.
  ///
  /// **It draws.** It used to hand the job to `resetTargetSelection`, so calling
  /// this without also calling a setter left the mark showing the previous
  /// conversation's face — a face with an id nobody is about to send anything
  /// to. Every presentation now resets the agent and redraws here, which is the
  /// one place that owns "what the prompt looks like when nothing is typed".
  /// Puts the panel on its first screen for ⌥Space — or, `resumingChat`,
  /// leaves the chat it went away on standing as it was, where Escape still
  /// goes back to the row it came from (`AgentPaletteController.resumeWindow`).
  func prepareForPresentation(resumingChat: Bool = false) {
    if !resumingChat { returnToSessionID = nil }
    surfaceReady = false
    pendingConversationID = UUID()
    if !resumingChat {
      mode = .prompt
      collapseResults(animated: false)
      leaveAddressing(animated: false)
    }
    // The prompt keeps whatever height its last text needed, so a palette that
    // closed on a five-line prompt would reopen five lines tall around an empty
    // field. `resizeToFit` runs on the next line in the controller, so this has
    // to have settled by now.
    syncPromptHeight()
    resetAgentChoice()
    setComposerKeyTarget(.text)
    if !resumingChat { renderPromptMark(animated: false) }
    // Content no longer fades separately from its capsule: the capsule's own
    // fade carries it, and the entrance blur is what stages the text. A second
    // fade on top of both was the third overlapping timeline in one 0.2s window.
    field.alphaValue = 1
    hintLabel.alphaValue = 1
    selectedAgentImage.alphaValue = 1
  }

  /// Pre-entrance state for the prompt capsule: transparent and slightly small,
  /// so the first composited frame after the window is ordered in is never the
  /// settled one.
  func prepareCapsuleForEntrance() {
    // The unified shell is already at its initial geometry before orderFront.
  }

  /// Icon stays fully opaque; typed text and the caret track the label color so
  /// they stay correct if the palette's appearance ever changes.
  private func applyPromptForegroundAppearance() {
    selectedAgentImage.alphaValue = 1
    selectedAgentImage.contentTintColor = Self.promptIconTintColor
    field.textColor = Self.promptTypingTextColor
    field.insertionPointColor = Self.promptTypingTextColor
    field.typingAttributes = field.defaultTypingAttributes
  }

  /// Live session catalog for the ↓ switcher.
  func setSessions(
    _ items: [BolttyAISessionItem],
    transcripts: [UUID: ConversationTranscript] = [:]
  ) {
    if isResultsExpanded, let held = heldSessionItems, !held.isEmpty {
      self.sessionItems = BolttyAISessionList.holding(items, to: held)
    } else {
      self.sessionItems = items
    }
    // What is on screen is what the next update holds to, a new chat included.
    if isResultsExpanded { heldSessionItems = sessionItems }
    self.sessionTranscripts = transcripts
    if isResultsExpanded {
      refreshResults(keepingSelection: true)
    }
  }

  /// What the switcher card is holding — rows, the empty state, or the
  /// no-agents card.
  var resultsStackForTesting: ResultsListView { resultsStack }
  var historyTabsForTesting: AgentHistoryTabStripView { historyTabs }
  /// The day headings the card is actually drawing, top to bottom.
  var historyHeadingsForTesting: [String] {
    resultsStack.arrangedSubviews.compactMap {
      ($0 as? AgentHistorySectionHeaderView)?.title
    }
  }

  func expandResultsForTesting() {
    expandResults()
  }

  // MARK: - Session switcher

  private func expandResults() {
    // Fresh rows first: the controller keeps them current only while the
    // list is open, so a list opening is the moment to ask.
    onWillShowSessions?()
    isResultsExpanded = true
    refreshResults(keepingSelection: false)
  }

  /// Whether the switcher's rows are on screen — the only time they are worth
  /// rebuilding.
  var isShowingSessions: Bool { isResultsExpanded && !showsNoAgentsState }

  /// Closes the switcher. **The card keeps its full geometry until the fade is
  /// over** — that ordering is the whole point of splitting this in two.
  ///
  /// Zeroing the height alongside the fade did not shrink the card, it *crushed*
  /// it: `onContentSizeChange` reaches `resizeToFit`, which lays the panel out
  /// synchronously, so the height landed in the same frame the fade started in.
  /// What the user saw was one frame of a still-opaque card flattened against
  /// the prompt — its rim, read as a bare edge under the capsule — before the
  /// fade had moved at all.
  ///
  /// `animated: false` is for the callers that must have the height back *now*:
  /// `reset` and `prepareForPresentation` both size the panel on the next line,
  /// and a card that only gave up its height a fade later would reopen the
  /// palette at list height.
  private func collapseResults(animated: Bool = true) {
    isResultsExpanded = false
    selectedResultIndex = -1
    keyboardSelectionPointerAnchor = nil
    resultItems = []
    discardResultRows()
    releaseResultsHeight()
    needsLayout = true
    layoutSubtreeIfNeeded()
    if animated { revealSurfaceContent() }
  }

  /// The second half of a collapse: hide the card and hand its height back to
  /// the panel, which is what starts the window shrinking.
  private func releaseResultsHeight() {
    resultsCapsule.isHidden = true
    resultsHeightConstraint.constant = 0
    resultsTopConstraint.constant = 0
    anchorErrorLabel()
    onContentSizeChange?()
  }

  func enterAddressing(_ preview: BolttyAISessionPreview) {
    setComposerKeyTarget(.text)
    // The draft identity has become a saved conversation. Consume it now,
    // so returning with Escape can start another chat without reopening the panel.
    if preview.id == pendingConversationID { pendingConversationID = UUID() }
    if isResultsExpanded { returnToSessionID = preview.id }

    if mode != .prompt {
      if mode == .search {
        field.setDraft(PromptDraft(field.searchQuery))
      }
      mode = .prompt
      applyModeChrome()
    }
    collapseResults(animated: false)
    addressedPreview = preview
    syncAutoModeButton()
    stopIsAvailable = preview.isBusy && preview.canStop
    applyStopAffordance(preview)
    syncSendButton()
    previewCard.apply(preview)
    // The card may still hold this chat, unchanged, from before the panel
    // went away and stopped its clocks; `apply` does not start them again.
    previewCard.resumeAnimations()
    render(
      agent: preview.agent,
      conversationID: preview.id,
      emotion: MascotEmotion(reportedState: preview.state),
      animated: true
    )
    hintLabel.stringValue = Self.composerPlaceholder(for: preview)
    hintLabel.isHidden = !field.isEmptyPrompt
    showPreview(animated: true)
    needsLayout = true
    layoutSubtreeIfNeeded()
    // The composer becomes the chat's box.
    syncPromptExpansion()
    syncPromptHeight()
  }

  func updateAddressing(_ preview: BolttyAISessionPreview) {
    guard addressedPreview?.id == preview.id else { return }
    let changed = preview != addressedPreview
    hintLabel.stringValue = Self.composerPlaceholder(for: preview)
    // **Spoken before the card is rebuilt**, while the previous state is still
    // here to be compared against. A reader with no sight of the panel was
    // told about a queued message, a deletion and a pin, and about none of the
    // three things the product exists to report.
    if let line = BolttyAIAnnouncement.forTransition(from: addressedPreview, to: preview) {
      announce(line)
    }
    addressedPreview = preview
    syncAutoModeButton()
    stopIsAvailable = preview.isBusy && preview.canStop
    applyStopAffordance(preview)
    syncSendButton()
    previewCard.apply(preview)
    render(
      agent: preview.agent,
      conversationID: preview.id,
      emotion: MascotEmotion(reportedState: preview.state),
      animated: false
    )
    // Refresh the scroll document and any state morph inside the fixed shell.
    guard changed else { return }
    previewBandHeight = reservedTranscriptHeight
    needsLayout = true
    layoutSubtreeIfNeeded()
    onContentSizeChange?()
  }

  /// Content never sizes the shell. A grown composer uses the same reserved
  /// space, reducing the transcript's scrolling viewport instead.
  private var reservedTranscriptHeight: CGFloat {
    max(0, chatSurfaceSize.height - chatComposerBand)
  }

  private var isOpenChat: Bool { addressedPreview != nil && !showsCompactListening }

  /// The shell's width in the state it is in: the chat's, the list's, or the
  /// prompt's fixed 520.
  private var stateSurfaceWidth: CGFloat {
    if isOpenChat { return chatSurfaceWidth }
    if isHistoryOpen { return historySurfaceWidth }
    return AgentPaletteMetrics.promptSize.width
  }

  /// The chat list is up, with no chat open over it.
  private var isHistoryOpen: Bool { isResultsExpanded && addressedPreview == nil }

  /// The shell's top: under the menu bar by `lockedTopGap`, whatever state
  /// it is in.
  private var surfaceTopInset: CGFloat {
    topReserve + AgentPaletteMetrics.lockedTopGap
  }

  private var chatSurfaceWidth: CGFloat {
    guard bounds.width > 1 else { return surfaceSizes.chat.width }
    return min(surfaceSizes.chat.width,
               max(1, bounds.width - AgentPaletteMetrics.safeAreaX * 2))
  }

  private var historySurfaceWidth: CGFloat {
    guard bounds.width > 1 else { return surfaceSizes.history.width }
    return min(surfaceSizes.history.width,
               max(1, bounds.width - AgentPaletteMetrics.safeAreaX * 2))
  }

  private var chatSurfaceSize: CGSize {
    let room = bounds.height - surfaceTopInset - AgentPaletteMetrics.safeAreaY
    return CGSize(
      width: chatSurfaceWidth,
      height: max(1, min(surfaceSizes.chat.height, room))
    )
  }

  private var minimumChatSurfaceHeight: CGFloat {
    AgentPaletteMetrics.previewMinHeight + AgentPaletteMetrics.surfaceStackSpacing
      + AgentPaletteMetrics.promptSize.height + AgentPaletteMetrics.chatComposerBoxHeight
      + AgentPaletteMetrics.shellContentInset
  }

  private var historySurfaceHeight: CGFloat {
    let room = bounds.height - surfaceTopInset - AgentPaletteMetrics.safeAreaY
    return max(1, min(surfaceSizes.history.height, room))
  }

  func leaveAddressing(animated: Bool) {
    guard let left = addressedPreview?.id else {
      hidePreview(animated: false)
      return
    }
    addressedPreview = nil
    syncAutoModeButton()
    onLeaveAddressing?(left)
    stopIsAvailable = false
    hidePreview(animated: animated)
    if mode == .prompt {
      renderPromptMark(animated: false)
    }
    // Back to the prompt's capsule, unless the draft itself had grown.
    syncPromptExpansion()
    syncPromptHeight()
  }

  private func showPreview(animated: Bool) {
    previewTopConstraint.constant = AgentPaletteMetrics.previewTopSpacing
    previewBandHeight = addressedPreview == nil ? 0 : reservedTranscriptHeight
    anchorErrorLabel()
    onContentSizeChange?()

    if previewCard.superview == nil {
      previewCard.onStop = { [weak self] in self?.onStop?() }
      previewCard.onClose = { [weak self] in self?.goBack() }
      previewCard.onSpeak = { [weak self] in self?.onSpeakMessage?($0) }
      previewCard.onOffersLatestChange = { [weak self] offers in
        self?.offersLatest = offers
        self?.syncDirectoryChipVisibility()
      }
      previewCard.onRecover = { [weak self] text in
        guard let self else { return }
        var draft = self.currentDraft
        if !draft.isEffectivelyEmpty { draft.append(text: "\n") }
        draft.append(text: text)
        self.setChatDraft(draft)
        self.onDraftChange?()
        _ = self.focusField()
      }
      previewCard.onUseFile = { [weak self] url in
        guard let self else { return }
        // A file on disk becomes a file chip. What the agent then receives is
        // the path, via the same `PromptExpansion` every pasted file takes —
        // no second transport, no engine change.
        var draft = self.currentDraft
        let kind = PromptAttachmentKind.resolve(for: url)
        draft.append(PromptAttachment.file(url, label: draft.nextGeneratedLabel(for: kind)))
        self.setChatDraft(draft)
        self.onDraftChange?()
        _ = self.focusField()
      }
      previewCard.onRetry = { [weak self] prompt in
        guard let self, let id = self.addressedPreview?.id else { return }
        self.onRetryPrompt?(id, prompt)
      }
      previewCard.onCancelQueued = { [weak self] prompt in
        guard let self, let id = self.addressedPreview?.id else { return }
        // Back into the composer first, then forgotten by the layer below: the
        // words were typed, and cancelling a send is not the same as deleting
        // what was written.
        var draft = self.currentDraft
        if !draft.isEffectivelyEmpty { draft.append(text: "\n") }
        draft.append(text: prompt)
        self.setChatDraft(draft)
        self.onDraftChange?()
        self.onCancelQueuedPrompt?(id)
        _ = self.focusField()
      }
      previewCard.onAnswer = { [weak self] question, answers in
        guard let self, let id = self.addressedPreview?.id else { return }
        // Request changes, clicked, sends what the composer says to change.
        let typed = self.field.draft.typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.kind == .plan, answers == [PlanDecision.cancelled.rawValue], !typed.isEmpty {
          self.onAnswerQuestion?(id, question, question.refusing(with: typed))
          return
        }
        self.onAnswerQuestion?(id, question, answers)
      }
      previewForeground.addSubview(previewCard)
      NSLayoutConstraint.activate([
        previewCard.leadingAnchor.constraint(equalTo: previewForeground.leadingAnchor),
        previewCard.trailingAnchor.constraint(equalTo: previewForeground.trailingAnchor),
        previewCard.topAnchor.constraint(equalTo: previewForeground.topAnchor),
        previewCard.bottomAnchor.constraint(equalTo: previewForeground.bottomAnchor),
      ])
    }
    let isAppearing = previewCapsule.isHidden || previewCapsule.alphaValue < 1
    previewCapsule.isHidden = false
    guard animated, isAppearing else {
      previewCapsule.alphaValue = 1
      return
    }
    revealSurfaceContent()
  }

  private func hidePreview(animated: Bool) {
    releasePreviewHeight()
    needsLayout = true
    layoutSubtreeIfNeeded()
    if animated { revealSurfaceContent() }
  }

  private func releasePreviewHeight() {
    previewCard.removeFromSuperview()
    previewCapsule.isHidden = true
    previewCapsule.alphaValue = 0
    previewBandHeight = 0
    previewTopConstraint.constant = 0
    anchorErrorLabel()
    onContentSizeChange?()
  }

  private func refreshResults(keepingSelection: Bool) {
    let previousID = keepingSelection && selectedResultIndex >= 0
      && selectedResultIndex < resultItems.count
      ? resultItems[selectedResultIndex].id
      : nil

    let newSections: [AgentHistory.Section]
    let newItems: [BolttyAISessionItem]
    if showsHistoryChrome {
      newSections = AgentHistory.sections(sessionItems, agent: activeHistoryAgent)
      newItems = newSections.flatMap(\.items)
    } else {
      newSections = []
      newItems = BolttyAISessionList.filter(
        sessionItems,
        transcripts: sessionTranscripts,
        query: resultsQuery
      )
    }
    // Typing narrows the list on every keystroke. Only tear down rows when the
    // content actually changed — otherwise the switcher rebuilds and re-fades
    // under the user's cursor for every character. The empty state is always
    // rebuilt because its message quotes the current query, which can change
    // while the (empty) result set does not.
    let contentChanged = newItems != resultItems || newSections != resultSections
      || newItems.isEmpty
    resultItems = newItems
    resultSections = newSections
    historyTabs.setVisible(showsHistoryChrome)
    setResultsOverlap(showsHistoryChrome ? AgentPaletteMetrics.historyTabOverlap : 0)
    // The history only: a search has its field, and the install hints open
    // on the first screen's mode with nothing to start a chat on.
    setHistoryFootVisible(mode == .picking)
    if showsHistoryChrome {
      // Counted over every row, not over what the filter left — see
      // `AgentHistory.Tab`.
      historyTabs.apply(
        tabs: AgentHistory.tabs(sessionItems), activeAgent: activeHistoryAgent,
        everyone: agentChoices)
    }

    if let previousID, let index = resultItems.firstIndex(where: { $0.id == previousID }) {
      selectedResultIndex = index
    } else if let currentIndex = resultItems.firstIndex(where: \.isCurrent) {
      selectedResultIndex = currentIndex
    } else {
      selectedResultIndex = resultItems.isEmpty ? -1 : 0
    }

    if showInstallHintsIfNeeded() {
      // Nothing to select — the hints are informational, not a switcher list.
    } else if contentChanged {
      syncResultRows()
      if mode == .picking {
        renderAddressee()
      }
    } else {
      applySelectionHighlight(animated: false)
    }

    // Fade in only when the card is actually appearing. `alphaValue < 1` also
    // counts: re-expanding during a collapse fade would otherwise leave the
    // list stranded at whatever opacity the interrupted fade reached.
    let isAppearing = resultsCapsule.isHidden || resultsCapsule.alphaValue < 1

    // Size the card and tell the window to grow *before* unhiding. The
    // panel is a clip rect; painting first leaves the row sliced in half.
    resultsHeightConstraint.constant = measuredResultsCardHeight()
    resultsTopConstraint.constant = AgentPaletteMetrics.resultsTopSpacing
    anchorErrorLabel()
    onContentSizeChange?()

    resultsCapsule.isHidden = false

    guard isAppearing else { return }
    needsLayout = true
    layoutSubtreeIfNeeded()
    revealSurfaceContent()
  }

  /// The shell and its content, laid out for ⌥Space and shown as they are:
  /// the panel arrives at once, with nothing fading in.
  func layoutForPresentation() {
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  /// The Tab swap's blur, per layer.
  private static let targetSwapBlurFilterName = "bolttyTargetSwapBlur"
  private static let targetSwapBlurKey = "targetSwapBlur"

  /// The agents to offer when none are installed. Empty restores normal
  /// switcher behaviour.
  func setInstallHints(_ agents: [AgentId]) {
    showsNoAgentsState = !agents.isEmpty
  }

  /// Opens the install-hint card without requiring ↓. First run with nothing
  /// on PATH should explain itself, not wait for a key the user has no
  /// reason to press.
  func revealInstallHintsIfNeeded() {
    guard showsNoAgentsState, mode == .prompt, field.isEmptyPrompt else { return }
    isResultsExpanded = true
    refreshResults(keepingSelection: false)
  }

  func setCatalogScanning(_ scanning: Bool) {
    if scanning, agentForNewPrompt == nil, field.isEmptyPrompt, mode == .prompt {
      hintLabel.stringValue = "Looking for agents…"
      hintLabel.isHidden = false
      // The sentence says Boltty is busy; the face may as well agree. `.thinking`
      // already exists for an agent that is working, and a scan of `PATH` is
      // the one piece of work Boltty does on its own behalf.
      selectedAgentImage.showMascot(
        conversationID: pendingConversationID,
        emotion: .thinking,
        look: MascotLook.face(for: nil)
      )
    } else if !scanning, agentForNewPrompt == nil, mode == .prompt {
      // The scan ended and found nothing to select — back to waiting.
      refreshMascotEmotion()
    }
  }

  private func measuredResultsCardHeight() -> CGFloat {
    // Search keeps the same outer shell, spending its top band on the field.
    max(0, historySurfaceHeight - (mode == .search ? promptCapsuleHeightConstraint.constant : 0))
  }

  /// A tab was chosen. `nil` is Latest — see `AgentHistoryTabStripView`.
  ///
  /// The selection is deliberately not carried across: the row you were on is
  /// usually not in the tab you just opened, and a filter that scrolled you to
  /// a different chat would be answering a question you did not ask. The list
  /// lands on the current conversation if it is there, and on the top row
  /// otherwise — which is what `refreshResults` does with no selection to keep.
  private func selectHistoryAgent(_ agent: AgentId?) {
    guard agent != activeHistoryAgent else { return }
    activeHistoryAgent = agent
    refreshResults(keepingSelection: false)
  }

  /// ←/→: the neighbouring tab, the same way a click on it would choose it.
  private func stepHistoryTab(by delta: Int) {
    selectHistoryAgent(AgentHistory.adjacentTab(to: activeHistoryAgent, by: delta))
  }

  /// First run with no CLI on PATH. Submitting would only produce an error, so
  /// the palette opens on what to install instead — the same list Settings
  /// shows, at the moment the user actually needs it.
  private func showInstallHintsIfNeeded() -> Bool {
    guard showsNoAgentsState, mode == .prompt, field.isEmptyPrompt else {
      return false
    }
    isShowingInstallHints = true
    discardResultRows()
    resultItems = []
    selectedResultIndex = -1
    let card = BolttyAINoAgentsView()
    card.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
    resultsStack.addArrangedSubview(card)
    return true
  }

  /// Empties the list, rows and all. The card's other occupants — the empty
  /// state, the install hints — are not rows and are torn down with it.
  ///
  /// Every subview, not only the arranged ones: a stranded row is not inert,
  /// it is a mascot still drawing at 60Hz.
  private func discardResultRows() {
    resultsStack.removeAllArrangedSubviews()
    resultLines = []
    resultLineIndexByRow = []
    rowsByConversation = [:]
    headersByDay = [:]
  }

  /// Brings the column in line with `resultItems`, **reusing** the row that
  /// already draws each conversation (`resultLineView`).
  ///
  /// This used to remove every arranged subview and build the list again. It
  /// was not only the cost but what the teardown silently discarded. A
  /// session going from idle to working changes its subtitle, which changed
  /// the item, which rebuilt every row on screen: a press spring mid-settle
  /// was dropped, and the row under the pointer lost its hover with no way to
  /// get it back, because an `.inVisibleRect` tracking area does not re-arm
  /// until the mouse next moves.
  ///
  /// Only three things can actually happen to the list, and each is handled as
  /// itself: a conversation arrives (a line the list builds a row for once it
  /// is near), leaves (release its row), or the order changes (the same rows,
  /// on other lines).
  private func syncResultRows() {
    isShowingInstallHints = false

    guard !resultItems.isEmpty else {
      discardResultRows()
      resultsStack.addArrangedSubview(
        // A search runs over every agent whatever tab is lit, so its empty
        // state is about the query — never "no chats with Claude".
        (showsHistoryChrome ? activeHistoryAgent : nil)
          .map(BolttyAIEmptyResultsView.init(emptyHistoryFor:))
          ?? BolttyAIEmptyResultsView(query: resultsQuery, agent: agentForNewPrompt)
      )
      return
    }

    // A row is released when its chat is gone, not when a filter hides it:
    // switching history tabs back and forth would otherwise build every row of
    // the tab again. Rows it hides the list hides in place.
    let live = Set(sessionItems.map(\.id)).union(resultItems.map(\.id))
    for (id, row) in rowsByConversation where !live.contains(id) {
      row.removeFromSuperview()
      rowsByConversation.removeValue(forKey: id)
    }
    // Headings are released the same way and for the same reason: a day whose
    // last chat moved to today has no heading left to draw.
    let liveDays = Set(resultSections.map(\.id))
    for (day, header) in headersByDay where !liveDays.contains(day) {
      header.removeFromSuperview()
      headersByDay.removeValue(forKey: day)
    }

    // Two lists come out of this: what the card stacks, headings included, and
    // where each row ↑↓ walk stands in it — a heading is drawn between rows but
    // never lands between them in the selection.
    var lines: [ResultLine] = []
    var rowLines: [Int] = []
    lines.reserveCapacity(resultItems.count + resultSections.count)
    rowLines.reserveCapacity(resultItems.count)
    func appendRow(_ item: BolttyAISessionItem) {
      rowLines.append(lines.count)
      lines.append(.row(item))
    }
    if resultSections.isEmpty {
      resultItems.forEach(appendRow)
    } else {
      for section in resultSections {
        lines.append(.heading(section, followsRows: !lines.isEmpty))
        section.items.forEach(appendRow)
      }
    }
    resultLines = lines
    resultLineIndexByRow = rowLines
    // The views are built as the list reaches them, and reused by
    // conversation and by day whenever it asks again.
    resultsStack.setLines(lines.map(\.listLine)) { [weak self] index in
      self?.resultLineView(at: index) ?? NSView()
    }

    scrollSelectedResultVisible()
    syncResultRowHover()
  }

  /// One line of the column, as the list asks for it.
  ///
  /// The row that already draws a conversation is reused rather than rebuilt,
  /// because a rebuild throws away what the row was holding that the model does
  /// not describe: which row the pointer is over, a press spring still
  /// settling, and the tracking area that would only re-arm on the next mouse
  /// move. A session merely changing from idle to working used to cost all of
  /// that.
  private func resultLineView(at index: Int) -> NSView {
    switch resultLines[index] {
    case .heading(let section, let followsRows):
      if let header = headersByDay[section.id] {
        header.apply(section, followsRows: followsRows)
        return header
      }
      let header = AgentHistorySectionHeaderView(section: section, followsRows: followsRows)
      headersByDay[section.id] = header
      return header
    case .row(let item):
      let row: BolttyAISessionRowView
      if let existing = rowsByConversation[item.id] {
        if existing.item != item { existing.apply(item: item) }
        row = existing
      } else {
        row = BolttyAISessionRowView(item: item)
        rowsByConversation[item.id] = row
      }
      bindSessionRowActions(row)
      // Latest mixes every agent, so its rows say whose they are.
      row.setShowsFace(showsHistoryChrome && activeHistoryAgent == nil)
      row.setHighlighted(item.id == selectedResultID, animated: false)
      return row
    }
  }

  /// The chat Enter would open, if the list has one chosen.
  private var selectedResultID: UUID? {
    resultItems.indices.contains(selectedResultIndex) ? resultItems[selectedResultIndex].id : nil
  }

  /// Hands every row where the pointer really is. See
  /// `BolttyAISessionRowView.syncHover`.
  private func syncResultRowHover() {
    guard let window else { return }
    // Laid out first, or a restack is judged by the frames it is leaving.
    resultsScroll.layoutSubtreeIfNeeded()
    let point = window.convertPoint(fromScreen: pointerLocation)
    let uncovered: NSPoint? = isUnderHistoryTabs(point) || isOnHistoryFoot(point) ? nil : point
    for row in rowsByConversation.values {
      row.syncHover(pointerInWindow: uncovered)
    }
  }

  /// Whether a point in the window is in the band where the rows pass under
  /// the tab strip — the strip's, not a row's.
  private func isUnderHistoryTabs(_ pointInWindow: NSPoint) -> Bool {
    guard resultsOverlap > 0, !historyTabs.isHidden else { return false }
    return historyTabs.bounds.contains(historyTabs.convert(pointInWindow, from: nil))
  }

  /// Whether a point in the window is on one of the foot's discs — theirs,
  /// not the row passing under them.
  private func isOnHistoryFoot(_ pointInWindow: NSPoint) -> Bool {
    guard showsHistoryFoot else { return false }
    return [historyNewChatButton, historySettingsButton].contains {
      $0.bounds.contains($0.convert(pointInWindow, from: nil))
    }
  }

  /// Shows or hides the foot's discs, and gives the rows room to scroll
  /// clear of them: the last row can rise above the discs as the first
  /// sinks below the strip.
  private func setHistoryFootVisible(_ visible: Bool) {
    syncHistoryNewChat()
    guard visible != showsHistoryFoot else { return }
    historyNewChatButton.isHidden = !visible
    historySettingsButton.isHidden = !visible
    var insets = resultsStack.edgeInsets
    insets.bottom = AgentPaletteMetrics.resultsVerticalInset
      + (visible ? AgentPaletteMetrics.historyFootHeight : 0)
    resultsStack.edgeInsets = insets
    updateResultsTopEdge()
  }

  /// New Chat is the chosen tab's: All starts on automatic routing, an
  /// agent's tab on that agent. A tab whose agent cannot take a prompt
  /// (not ready, switched off) keeps the disc, disabled, saying why.
  private func syncHistoryNewChat() {
    let button = historyNewChatButton.button
    if let agent = activeHistoryAgent {
      button.isEnabled = agentChoices.contains(agent)
      button.toolTip = button.isEnabled
        ? "New Chat with \(agent.displayName)" : "\(agent.displayName) isn't ready"
    } else {
      button.isEnabled = !agentChoices.isEmpty
      button.toolTip = "New Chat"
    }
    button.helpShortcut = button.isEnabled ? "⌘N" : nil
  }

  /// The + under the list, and ⌘N while it is open: the first screen, on
  /// the chosen tab's agent, with the list's own way back (Escape) gone.
  @objc private func startNewChatFromHistory() {
    _ = startNewChatFromKeyboard()
  }

  private func startNewChatFromKeyboard() -> Bool {
    guard mode == .picking, addressedPreview == nil, historyNewChatButton.button.isEnabled
    else { return false }
    let agent = activeHistoryAgent
    chosenAgent = agent == plannedAgent ? nil : agent
    closeSwitcher()
    selectedAgentImage.pokeMascot()
    if let agent { announce(agent.displayName) }
    onAgentChoiceChange?()
    _ = focusField()
    return true
  }

  @objc private func openSettingsFromHistory() { onOpenSettings?() }

  /// Moves the list's top up under the strip by `overlap`, and its first
  /// line down by the same, so at rest nothing moves.
  private func setResultsOverlap(_ overlap: CGFloat) {
    guard overlap != resultsOverlap else { return }
    resultsOverlap = overlap
    resultsScrollTop.constant = -overlap
    var insets = resultsStack.edgeInsets
    insets.top = AgentPaletteMetrics.resultsVerticalInset + overlap
    resultsStack.edgeInsets = insets
    updateResultsTopEdge()
  }

  /// The list's top edge: sharp below the strip's foot, softening and
  /// dissolving across the overlap — the chat's soft edge
  /// (`BolttyAIPreviewCard.updateScrollEdge`), at the list's top.
  private func updateResultsTopEdge() {
    let height = resultsScroll.bounds.height
    guard height > 0 else { return }
    let overlap = min(resultsOverlap, height)
    let soft = AgentPaletteMetrics.previewScrollEdgeSoftness
    let flipped = resultsScroll.layer?.isGeometryFlipped ?? resultsScroll.isFlipped
    // Gone a little under the names' top; whole at the strip's foot.
    let gone = overlap * 0.25
    var stops: [(y: CGFloat, alpha: CGFloat)] = overlap > 0
      ? ScrollEdgeBlur.smoothstep.map { (gone + (overlap - gone) * $0.t, $0.s) }
      : [(0, 1)]
    if overlap > 0 { stops.insert((0, 0), at: 0) }
    if showsHistoryFoot {
      // Whole a softness above the discs, gone at the foot — the chat's
      // edge under its back disc, upside down.
      let whole = max(
        stops.last?.y ?? 0,
        height - AgentPaletteMetrics.historyFootDiscInset - AgentPaletteMetrics.previewCloseDiameter
          - AgentPaletteMetrics.previewScrollEdgeSoftness
      )
      stops += ScrollEdgeBlur.smoothstep.map { (whole + (height - whole) * $0.t, 1 - $0.s) }
    } else {
      stops.append((height, 1))
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    resultsTopEdge.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
    resultsTopEdge.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
    resultsTopEdge.frame = resultsScroll.bounds
    resultsTopEdge.colors = stops.map { NSColor.black.withAlphaComponent($0.alpha).cgColor }
    resultsTopEdge.locations = stops.map { NSNumber(value: Double(min(1, max(0, $0.y / height)))) }
    CATransaction.commit()

    // Soft before it is gone: the blur is whole a softness below the foot.
    let blur = overlap > 0
      ? ScrollEdgeBlur.ramp(from: 0, to: min(height, overlap + soft), strength: 1, 0)
      : []
    ScrollEdgeBlur.apply(
      to: resultsScroll.layer, stops: blur, height: height,
      radius: AgentPaletteMetrics.scrollEdgeBlurRadius
    )
  }

  private func bindSessionRowActions(_ row: BolttyAISessionRowView) {
    let id = row.item.id
    row.onActivate = { [weak self] in
      self?.selectResult(withID: id)
    }
    row.onHover = { [weak self] in
      self?.hoverMoved(to: id)
    }
    row.onContextMenu = { [weak self, weak row] event in
      guard let self, let row else { return }
      self.onSessionContextMenu?(id, event, row)
    }
    row.hoverIsQuiet = keyboardSelectionPointerAnchor != nil
    row.isCoveredAt = { [weak self] point in
      guard let self else { return false }
      return self.isUnderHistoryTabs(point) || self.isOnHistoryFoot(point)
    }
  }

  /// The pointer moved onto a row, so that row becomes the one Enter means.
  ///
  /// Spotlight and Raycast both do this, and for a reason that shows up as soon
  /// as they do not: hover lights a row and the keyboard outlines a different
  /// one, so two rows read as current and neither answers "what does Enter do".
  ///
  /// **`mouseEntered` is not proof the user moved the pointer.** The rows carry
  /// `.inVisibleRect` tracking areas, so a row sliding under a stationary cursor
  /// enters it too — and ↑/↓ scroll the list by design. Honouring that would
  /// close a loop: the arrow scrolls a row under the cursor, the cursor claims
  /// the selection, the new selection scrolls again. Comparing the pointer
  /// against where it was when the keyboard last chose tells the two apart, and
  /// costs nothing to keep.
  private func hoverMoved(to conversationID: UUID) {
    guard let index = resultItems.firstIndex(where: { $0.id == conversationID }) else { return }

    if let anchor = keyboardSelectionPointerAnchor {
      let now = pointerLocation
      let stationary = abs(anchor.x - now.x) < 0.1 && abs(anchor.y - now.y) < 0.1
      if stationary { return }
    }

    keyboardSelectionPointerAnchor = nil
    setResultHoverQuiet(false)
    guard index != selectedResultIndex else { return }
    selectedResultIndex = index
    applySelectionHighlight(animated: true)
    // Deliberately no scroll: the row is under the pointer, so it is already
    // visible, and scrolling would slide it out from under the cursor.
  }

  /// `animated` only for the pointer. A keystroke moves the selection at
  /// once: ↑/↓ is the most repeated thing done in this list, and a fade per
  /// press left a trail of half-lit rows behind a held key. Raycast, Finder
  /// and Spotlight move it at once too.
  private func applySelectionHighlight(animated: Bool) {
    let selected = selectedResultID
    for row in rowsByConversation.values {
      row.setHighlighted(row.item.id == selected, animated: animated)
    }
    if mode == .picking {
      renderAddressee()
    }
  }

  /// The capsule while ↓ is choosing an addressee.
  ///
  /// Prompt mode's mark answers "what will Enter launch". Picking answers a
  /// different question — "who will Enter talk to" — so the mark follows the
  /// highlighted row and the placeholder names it. Without this the capsule is
  /// pixel-identical to prompt mode, and nothing on screen says Enter changed
  /// meaning. That silence is exactly what the magnifier used to cover, at the
  /// cost of claiming a search that was not happening.
  private func renderAddressee() {
    guard selectedResultIndex >= 0, selectedResultIndex < resultItems.count else {
      renderPromptMark(animated: false)
      hintLabel.isHidden = !field.isEmptyPrompt
      return
    }
    let item = resultItems[selectedResultIndex]
    render(agent: item.agent, conversationID: item.id, emotion: .focused, animated: false)
    // `render` leaves prompt mode's "press Shift-Tab for another agent" behind,
    // and Tab does not cycle targets while picking.
    selectedAgentImage.toolTip = "Message \(item.title)"
    hintLabel.stringValue = "Message this chat"
    hintLabel.isHidden = !field.isEmptyPrompt
  }

  private func moveResultSelection(by delta: Int) {
    guard !resultItems.isEmpty else { return }
    highlightResult(at: min(max(selectedResultIndex + delta, 0), resultItems.count - 1))
  }

  /// Moves the keyboard selection to an exact row. Shared by ↑/↓ and by the
  /// ⌘-digit chords, which land on a row rather than stepping towards one.
  private func highlightResult(at index: Int) {
    guard resultItems.indices.contains(index), index != selectedResultIndex else { return }
    selectedResultIndex = index
    // Remember where the pointer is sitting. The scroll below can slide another
    // row underneath it, and `hoverMoved` needs to know that the enter it is
    // about to receive was caused by this keypress rather than by the user.
    keyboardSelectionPointerAnchor = pointerLocation
    setResultHoverQuiet(true)
    applySelectionHighlight(animated: false)
    scrollSelectedResultVisible()
  }

  /// The keyboard has the list: the pointer's wash waits until it moves.
  private func setResultHoverQuiet(_ quiet: Bool) {
    for row in rowsByConversation.values { row.hoverIsQuiet = quiet }
  }

  /// Keeps the keyboard selection inside the scroll viewport.
  /// Scrolls by the minimum amount, the way Finder and Spotlight do, instead of
  /// recentring the row — and at once, as they do: it answers a keystroke.
  private func scrollSelectedResultVisible() {
    guard resultLineIndexByRow.indices.contains(selectedResultIndex) else { return }
    let clipView = resultsScroll.contentView
    // The scroll view's own subtree, not the palette's. Only the row frames and
    // the clip bounds are read below, and a held arrow key repeats ~25 times a
    // second — laying out the prompt, three glass hosts and the reply card for
    // each of those is work whose answer is never looked at.
    resultsScroll.layoutSubtreeIfNeeded()

    // Where the row stands, built or not: one far down the list has no view
    // until this scroll brings it within reach.
    let rowFrame = resultsStack.frameOfLine(at: resultLineIndexByRow[selectedResultIndex])
    let visible = clipView.bounds
    guard visible.height > 0 else { return }

    var origin = visible.origin
    let inset = AgentPaletteMetrics.resultsVerticalInset
    // The band under the strip is not where a chosen row may stand.
    if rowFrame.minY - inset - resultsOverlap < visible.minY {
      origin.y = max(0, rowFrame.minY - inset - resultsOverlap)
    } else if rowFrame.maxY + inset > visible.maxY {
      origin.y = rowFrame.maxY + inset - visible.height
    } else {
      return
    }

    clipView.setBoundsOrigin(origin)
    resultsScroll.reflectScrolledClipView(clipView)
  }

  private func selectResult(at index: Int) {
    guard index >= 0, index < resultItems.count else { return }
    selectResult(withID: resultItems[index].id)
  }

  /// By conversation rather than by position: a row outlives the index it was
  /// built at, because reordering the list moves rows instead of rebuilding
  /// them, and a captured index would then activate whichever session had since
  /// moved into that slot.
  /// Opens a history row's chat as a click on it does — the row menu's
  /// Open Chat.
  func openResult(withID id: UUID) {
    selectResult(withID: id)
  }

  /// Shows a history row's menu at the pointer, in the panel's dark
  /// appearance, as the folder chip's is.
  func showSessionMenu(_ menu: NSMenu, with event: NSEvent, for row: NSView) {
    menu.appearance = NSAppearance(named: .darkAqua)
    NSMenu.popUpContextMenu(menu, with: event, for: row)
  }

  private func selectResult(withID id: UUID) {
    guard resultItems.contains(where: { $0.id == id }) else { return }
    if let onConfirmSession {
      onConfirmSession(id)
    } else {
      onSelectSession?(id)
    }
  }


  /// Enter means one thing per mode, and the mode is on screen.
  private func confirmSelectionOrSubmit() {
    guard !isVoiceProcessing else { return }
    if isVoiceListening {
      onVoiceConfirm?()
      return
    }
    if let addressedPreview {
      // An agent waiting on a question is not waiting on a message. Enter
      // answers it — with the chosen row, or with what was typed when the
      // agent said a written answer is allowed. Sending the same words as a
      // message instead would leave the question unanswered.
      if let question = previewCard.pendingQuestion {
        guard field.draft.attachments.isEmpty else {
          showError("Answer this question with text or one of its options.")
          return
        }
        let typed = field.draft.typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, question.allowsCustom {
          onAnswerQuestion?(addressedPreview.id, question, [typed])
          return
        }
        // Words on a permission are what to do instead: Return refuses it
        // and hands them over. On a plan they are what to change: Return
        // sends it back with them, never approves it.
        if !typed.isEmpty, question.takesWordsAsRefusal {
          onAnswerQuestion?(addressedPreview.id, question, question.refusing(with: typed))
          return
        }
        if typed.isEmpty, previewCard.confirmOptions() { return }
        showError(typed.isEmpty ? "Choose at least one option." : "Choose one of the offered options.")
        return
      }
      onSubmit?(field.draft)
      return
    }
    guard mode != .prompt else {
      onSubmit?(field.draft)
      return
    }
    guard selectedResultIndex >= 0, selectedResultIndex < resultItems.count else {
      // A query with no matching chat is still useful input. The empty card
      // advertises this exact action, so Enter starts it as a new prompt rather
      // than becoming the only dead Enter state in the panel.
      if mode == .search {
        let query = field.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { onSubmit?(PromptDraft(query)) }
        return
      }
      if mode == .picking {
        onSubmit?(field.draft)
      }
      return
    }
    selectResult(at: selectedResultIndex)
  }

  /// Uses the same routing after dictation finishes as an ordinary Enter.
  func confirmCurrentDraft() {
    confirmSelectionOrSubmit()
  }

  // MARK: - Mode

  /// Opens the switcher at its rows. ↓ is a navigation key and types nothing;
  /// typing afterwards reveals the search field without closing the list.
  func openSwitcher() {
    guard mode == .prompt else { return }
    setComposerKeyTarget(.text)
    leaveAddressing(animated: false)
    mode = .picking
    expandResults()
    applyModeChrome()
  }


  func closeSwitcher() {
    if mode == .search {
      // Drop the marker but keep the words — leaving search reinterprets what
      // was typed, it does not discard it.
      field.setDraft(PromptDraft(field.searchQuery))
    }
    mode = .prompt
    applyModeChrome()
    collapseResults()
  }

  private func applyModeChrome() {
    switch mode {
    case .search:
      // The face stays, looking for something.
      //
      // This was a `magnifyingglass` SF Symbol, which made search the one mode
      // that threw the mascot away — and it threw it away to say a thing the
      // placeholder beside it was already saying in words. A glyph that
      // duplicates the label next to it is not carrying information; it is
      // costing the palette its only piece of identity, at exactly the moment
      // the user is hunting and most needs to know whose window this is.
      selectedAgentImage.showMascot(
        conversationID: pendingConversationID,
        emotion: .focused,
        look: MascotLook.face(for: agentForNewPrompt)
      )
      // The list is chats — every row opens one — so that is what is
      // searched. It said "agents", which is the tab strip's word.
      selectedAgentImage.setAccessibilityLabel("Search chats")
      selectedAgentImage.toolTip = "Searching chats"
      hintLabel.stringValue = "Search chats"
    case .picking:
      renderAddressee()
    case .prompt:
      renderPromptMark(animated: false)
    }
    // The hint is a placeholder: it stands in for text that is not there yet,
    // so any text at all replaces it. Qualifying this by mode left "Search
    // sessions" painted underneath the query the user was typing.
    hintLabel.isHidden = !field.isEmptyPrompt
    applyPromptForegroundAppearance()
    syncTrailingHint()
  }

  // MARK: - The agent a new prompt starts on

  /// What Tab may choose between, and where Enter goes without a choice.
  /// A choice that stopped being launchable is dropped rather than kept
  /// pointing at an agent that would refuse the prompt.
  func setAgentChoices(_ agents: [AgentId], planned: AgentId?) {
    guard agents != agentChoices || planned != plannedAgent else { return }
    let changed = agents != agentChoices
    agentChoices = agents
    plannedAgent = planned
    if let chosen = chosenAgent, !agents.contains(chosen) { chosenAgent = nil }
    syncHistoryNewChat()
    // All wears every agent that can take a prompt, so switching one on or
    // off re-composes it under an open list.
    if changed, isResultsExpanded { refreshResults(keepingSelection: true) }
    if mode == .prompt, addressedPreview == nil {
      renderPromptMark(animated: false)
    }
    syncTrailingHint()
  }

  /// Back to the preferred agent. The panel calls this each time it opens.
  func resetAgentChoice() {
    guard chosenAgent != nil else { return }
    chosenAgent = nil
    if mode == .prompt, addressedPreview == nil {
      renderPromptMark(animated: false)
    }
    onAgentChoiceChange?()
  }

  /// ⇧Tab on the first screen: the next agent a new prompt can start on. The
  /// face turns into that agent's; the placeholder stays the same.
  ///
  /// Only on the first screen, and only with an empty-handed or a typed
  /// prompt — an open chat has its agent fixed, and the history uses ←/→.
  /// Returns whether the face moved. One agent moves nothing; the key is
  /// still consumed, so the field never gains a tab.
  @discardableResult
  private func cycleAgent(by delta: Int) -> Bool {
    guard mode == .prompt, addressedPreview == nil,
          let next = agentChoice(movingFrom: agentForNewPrompt, by: delta)
    else { return false }
    chosenAgent = next == plannedAgent ? nil : next
    renderPromptMark(animated: true)
    selectedAgentImage.pokeMascot()
    announce(next.displayName)
    onAgentChoiceChange?()
    return true
  }

  /// The agent ⇧Tab moves to from `agent`; `nil` with one agent or none.
  private func agentChoice(movingFrom agent: AgentId?, by delta: Int) -> AgentId? {
    guard agentChoices.count > 1 else { return nil }
    let count = agentChoices.count
    let current = agent.flatMap(agentChoices.firstIndex(of:)) ?? (delta > 0 ? -1 : 0)
    return agentChoices[((current + delta) % count + count) % count]
  }

  /// Where Tab is standing on the first screen. The field stays first
  /// responder the whole time: Spotlight selects the control at the end of
  /// its field without leaving the text, and leaving ours would resign the
  /// panel.
  private enum ComposerKeyTarget: Equatable {
    case text
    case folder
    case microphone
  }

  private var composerKeyTarget: ComposerKeyTarget = .text

  /// The first screen, where Tab walks the icons and ⇧Tab walks the agents.
  /// A chat and the switcher hand both keys on, as they always have.
  private var isFirstScreen: Bool {
    mode == .prompt && addressedPreview == nil && !isResultsExpanded
  }

  /// Folder, then microphone, then the text again. The plan ring is not a
  /// stop: it only reads out, it has nothing to press. A hidden control
  /// is skipped, so a screen with no folder still reaches the microphone.
  private var composerKeyStops: [ComposerKeyTarget] {
    var stops: [ComposerKeyTarget] = [.text]
    if !directoryChip.isHidden { stops.append(.folder) }
    if !micButton.isHidden, micButton.isEnabled { stops.append(.microphone) }
    return stops
  }

  private func cycleComposerKey() {
    let stops = composerKeyStops
    let index = stops.firstIndex(of: composerKeyTarget) ?? 0
    setComposerKeyTarget(stops[(index + 1) % stops.count])
  }

  private func setComposerKeyTarget(_ target: ComposerKeyTarget) {
    let resolved: ComposerKeyTarget = switch target {
    case .folder where directoryChip.isHidden: .text
    case .microphone where micButton.isHidden || !micButton.isEnabled: .text
    default: target
    }
    guard resolved != composerKeyTarget else { return }
    composerKeyTarget = resolved
    directoryChip.isKeyboardTarget = resolved == .folder
    micButton.isKeyboardTarget = resolved == .microphone
    field.suppressesCaret = resolved != .text
    switch resolved {
    case .folder:
      announce(directoryChip.accessibilityLabel() ?? "Working folder")
    case .microphone:
      announce("Dictate prompt")
    case .text:
      break
    }
  }

  /// Space on a chosen icon does what a click does. The field never becomes
  /// the button: `performClick` sends the action and leaves the keys here.
  private func activateComposerKeyTarget() {
    switch composerKeyTarget {
    case .text:
      break
    case .folder:
      directoryChip.performClick(nil)
    case .microphone:
      micButton.performClick(nil)
    }
  }

  /// The keys after the typed text, the way macOS 27's Siri field writes
  /// "— Ask Siri": what Return will do, and only that — a second hint beside
  /// it read as a second answer.
  ///
  /// - First screen: "Ask Claude ↵" — the agent Enter starts on.
  /// - A chat whose turn is running: "Queue ↵" — Return does not send there.
  ///   ⌘Return and ⌘. are not hinted; the Send slot turns into Stop.
  /// - A permission waiting: "Deny and send ↵" — words typed there refuse it
  ///   and go to the agent with the refusal.
  /// - A plan waiting: "Request changes ↵" — the words go back with it as
  ///   what to change.
  ///
  /// Only once something is typed, as Siri's — an empty field keeps its
  /// placeholder — and never while listening or choosing from the list. The
  /// field says them once the typing rests (`PromptTextView.trailingHint`).
  func syncTrailingHint() {
    field.trailingHint = trailingHintKeys
  }

  private var trailingHintKeys: [PromptKeyHint] {
    guard mode == .prompt, !isVoiceListening, !field.isEmptyPrompt else { return [] }
    if let preview = addressedPreview {
      if let question = previewCard.pendingQuestion, question.takesWordsAsRefusal, draftHasWords {
        return [PromptKeyHint(words: question.refusalWords, key: "↵")]
      }
      guard preview.isBusy, previewCard.pendingQuestion == nil else { return [] }
      return [PromptKeyHint(words: "Queue", key: "↵")]
    }
    guard let agent = agentForNewPrompt else { return [] }
    return [PromptKeyHint(words: "Ask \(agent.shortDisplayName)", key: "↵")]
  }

  /// "Ask Claude ↵" for each hint — its words and its key, whether drawn or not.
  var trailingHintForTesting: [String] { field.trailingHint.map { "\($0.words) \($0.key)" } }

  /// Clicking the mark pokes the face, and nothing else.
  ///
  /// It used to open a menu of launch targets, and it stopped opening one when
  /// the panel went to automatic routing — while the poke stayed, because the
  /// poke is not part of that decision. A click that lands on a face and does
  /// nothing reads as the face being a picture, which is the one thing this is
  /// here to prevent. ⇧Tab is the way to change the agent.
  @objc func pokePromptMark() {
    selectedAgentImage.pokeMascot()
  }

  private func announce(_ message: String) {
    NSAccessibility.post(
      element: field,
      notification: .announcementRequested,
      userInfo: [.announcement: message]
    )
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    applyIngest(PasteboardIngest.read(sender.draggingPasteboard, into: field.draft))
    return true
  }

  /// The face and the sentence for a new prompt's agent.
  ///
  /// No agent yet — first run, a scan still going, nothing on PATH — and the
  /// prompt carries the preferred agent's face; the placeholder describes the job the
  /// field accepts rather than repeating the product name. The same words
  /// whichever agent is chosen: the face already says who, and "for Grok Build"
  /// in the field read as the product's name for the task rather than as the
  /// agent's.
  private func renderPromptMark(animated: Bool) {
    // The swap's own language — a crossfade *and* a blur resolving out of it —
    // for ⇧Tab.
    if animated { beginTargetSwap() }
    defer {
      syncTrailingHint()
      // A region already drawn wears the face ⇧Tab just chose.
      syncSelectionOverlay()
    }

    hintLabel.stringValue = "Describe your task..."
    selectedAgentImage.showMascot(
      conversationID: pendingConversationID,
      emotion: isVoiceListening ? .listening : .curious,
      look: MascotLook.face(for: agentForNewPrompt)
    )
    selectedAgentImage.setAccessibilityLabel(
      agentForNewPrompt.map { "Boltty AI — \($0.displayName)" } ?? "Boltty AI"
    )
    selectedAgentImage.toolTip = agentForNewPrompt.map {
      agentChoices.count > 1
        ? "Asking \($0.displayName) — press Shift-Tab for another agent"
        : "Asking \($0.displayName)"
    } ?? "Boltty AI — no agent selected yet"
    syncVoiceGlowPalette()
    applyPromptForegroundAppearance()
  }

  private func refreshMascotEmotion(overriding emotion: MascotEmotion? = nil) {
    if let preview = addressedPreview {
      render(
        agent: preview.agent,
        conversationID: preview.id,
        emotion: emotion ?? MascotEmotion(reportedState: preview.state),
        animated: false
      )
    } else if mode == .search {
      // Search wears the face Enter would start a new prompt on — a query
      // that matches nothing is sent as one — and keeps looking for something
      // while it does. Without this branch the case below would reset the
      // expression to `.curious` on the next refresh.
      selectedAgentImage.showMascot(
        conversationID: pendingConversationID,
        emotion: emotion ?? .focused,
        look: MascotLook.face(for: agentForNewPrompt)
      )
    } else {
      // The face of the agent a new prompt starts on — the preferred one's
      // when none is ready (`MascotRoster.restingAgent`), so it can react
      // too: an error raised before any agent was chosen — nothing
      // installed, the scan still running, a paste that was too large —
      // must not leave a cheerfully curious mascot above a red sentence.
      selectedAgentImage.showMascot(
        conversationID: pendingConversationID,
        emotion: emotion ?? (isVoiceListening ? .listening : .curious),
        look: MascotLook.face(for: agentForNewPrompt)
      )
    }
    syncVoiceGlowPalette()
  }

  // A Tab press used to flash the target's name here. It could not work: the
  // hint shares the prompt's position — it is the placeholder — so showing it
  // over a non-empty field painted the name straight through the typed text.
  // The icon swap carries the feedback on its own.

  /// Stages the Tab swap: the mark crossfades *and* resolves out of a blur,
  /// the same "coming into focus" the palette uses to arrive.
  ///
  /// **The mark only.** The placeholder beside it reads *Describe your
  /// task...* for every agent, so it holds still. Animate what changes.
  ///
  /// Installed **before** the new image is assigned, because `CATransition`
  /// animates whatever content change lands in the current transaction.
  ///
  /// The filter goes on the *leaf*, never on `promptForeground` or the capsule:
  /// a non-nil `layer.filters` forces an offscreen pass, and an offscreen pass
  /// anywhere above a `PaletteGlassHost` collapses the live material to its
  /// opaque fallback (the shared glass stays outside foreground filters). The
  /// mark is a sibling of the glass, so blurring it is free of that.
  private func beginTargetSwap() {
    guard !MotionPreferences.reduceMotion, let layer = selectedAgentImage.layer else { return }

    let crossfade = CATransition()
    crossfade.type = .fade
    crossfade.duration = AgentPaletteMetrics.targetSwapFadeDuration
    // `kCATransition`, not a key of our own: a layer files every `CATransition`
    // under that name whatever key it is handed, so a custom one would only
    // mislead the next reader looking for it.
    layer.add(crossfade, forKey: kCATransition)

    guard let blur = CIFilter(name: "CIGaussianBlur") else { return }
    blur.name = Self.targetSwapBlurFilterName
    blur.setValue(0, forKey: kCIInputRadiusKey)
    layer.filters = [blur]

    let resolve = CABasicAnimation(keyPath: "filters.\(Self.targetSwapBlurFilterName).inputRadius")
    resolve.fromValue = AgentPaletteMetrics.targetSwapBlurRadius
    resolve.toValue = 0
    resolve.duration = AgentPaletteMetrics.targetSwapBlurDuration
    resolve.timingFunction = Motion.standardCurve
    resolve.preferringHighFrameRate()

    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak layer] in
      MainActor.assumeIsolated {
        // Tab repeats faster than this animation finishes, and a later swap
        // reuses the same key — an animation still attached means a newer one
        // owns the filter, so dropping it here would strip that one mid-flight.
        guard layer?.animation(forKey: Self.targetSwapBlurKey) == nil else { return }
        // Held only for the swap: a permanent filter would re-composite the
        // mark through Core Image on every frame.
        layer?.filters = nil
      }
    }
    layer.add(resolve, forKey: Self.targetSwapBlurKey)
    CATransaction.commit()
  }

  // MARK: - Setup

  private func setup() {
    wantsLayer = true
    layer?.masksToBounds = false

    field.delegate = self
    field.onPaste = { [weak self] forcePlainText in
      self?.handlePaste(forcePlainText: forcePlainText)
    }
    field.onCommandPeriod = { [weak self] in self?.stopFromKeyboard() ?? false }
    field.onCommandReturn = { [weak self] in self?.submitSteeringFromKeyboard() ?? false }
    field.onCommandN = { [weak self] in self?.startNewChatFromKeyboard() ?? false }
    field.onMouseDown = { [weak self] in self?.setComposerKeyTarget(.text) }
    registerForDraggedTypes([.fileURL, .png, .tiff, .string])
    let agentClick = NSClickGestureRecognizer(
      target: self,
      action: #selector(pokePromptMark)
    )
    selectedAgentImage.addGestureRecognizer(agentClick)
    promptScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
    // Let the prompt give way before the trailing mic does.
    promptScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    selectedAgentImage.translatesAutoresizingMaskIntoConstraints = false
    selectedAgentImage.imageScaling = .scaleProportionallyDown
    selectedAgentImage.contentTintColor = Self.promptIconTintColor
    selectedAgentImage.alphaValue = 1
    selectedAgentImage.wantsLayer = true
    selectedAgentImage.setContentHuggingPriority(.required, for: .horizontal)
    selectedAgentImage.setContentHuggingPriority(.required, for: .vertical)

    promptForeground.translatesAutoresizingMaskIntoConstraints = false
    promptForeground.wantsLayer = true
    promptForeground.addSubview(selectedAgentImage)
    promptForeground.addSubview(promptScroll)

    configureMicButton()
    trailingControls.orientation = .horizontal
    trailingControls.alignment = .centerY
    trailingControls.spacing = AgentPaletteMetrics.restingControlsSpacing
    trailingControls.translatesAutoresizingMaskIntoConstraints = false
    // The disc is hidden while the pill is up, but it still owns this slot —
    // detaching it would let the trailing anchor jump and drag the overlay.
    trailingControls.detachesHiddenViews = false
    sendSlot.translatesAutoresizingMaskIntoConstraints = false
    sendSlot.addSubview(sendButton)
    sendButton.button.target = self
    sendButton.button.action = #selector(sendButtonPressed)
    sendButton.button.setAccessibilityIdentifier("boltty.ask.send")
    NSLayoutConstraint.activate([
      sendSlotWidth,
      sendSlot.heightAnchor.constraint(equalTo: sendButton.heightAnchor),
      sendButton.centerXAnchor.constraint(equalTo: sendSlot.centerXAnchor),
      sendButton.centerYAnchor.constraint(equalTo: sendSlot.centerYAnchor),
    ])
    sendButton.isHidden = true
    directorySlot.translatesAutoresizingMaskIntoConstraints = false
    directorySlot.addSubview(directoryChip)
    NSLayoutConstraint.activate([
      directorySlotWidth,
      directorySlot.heightAnchor.constraint(equalTo: directoryChip.heightAnchor),
      directoryChip.centerXAnchor.constraint(equalTo: directorySlot.centerXAnchor),
      directoryChip.centerYAnchor.constraint(equalTo: directorySlot.centerYAnchor),
    ])
    autoModeSlot.translatesAutoresizingMaskIntoConstraints = false
    autoModeSlot.addSubview(autoModeButton)
    autoModeButton.button.target = self
    autoModeButton.button.action = #selector(autoModeButtonPressed)
    autoModeButton.button.setAccessibilityIdentifier("boltty.ask.autoMode")
    autoModeButton.isHidden = true
    NSLayoutConstraint.activate([
      autoModeWidth,
      autoModeSlot.heightAnchor.constraint(equalTo: autoModeButton.heightAnchor),
      autoModeButton.centerXAnchor.constraint(equalTo: autoModeSlot.centerXAnchor),
      autoModeButton.centerYAnchor.constraint(equalTo: autoModeSlot.centerYAnchor),
    ])
    trailingControls.setViews(
      [planRing, directorySlot, autoModeSlot, micButton, sendSlot], in: .leading)
    // One group on both screens: the same targets and the same three inks.
    ComposerControlGroup.style(directoryChip)
    ComposerControlGroup.style(attachRestDisc.button)
    ComposerControlGroup.style(autoModeButton.button)
    ComposerControlGroup.style(sendButton.button)
    recordingControls.translatesAutoresizingMaskIntoConstraints = false
    recordingControls.isHidden = true
    recordingControls.alphaValue = 0
    recordingControls.onCancel = { [weak self] in self?.onVoiceCancel?() }
    recordingControls.onConfirm = { [weak self] in self?.onVoiceConfirm?() }
    recordingHoverSensor.translatesAutoresizingMaskIntoConstraints = false
    recordingHoverSensor.onHoverChange = { [weak self] hovering in
      self?.setRecordingControlsRevealed(hovering, animated: true)
    }
    promptForeground.addSubview(trailingControls)
    // **The + stands alone at the foot's leading edge**: files come in on
    // the left, the rest of the group stands on
    // the right — ring, folder, microphone, Return. Its ink is the box's one
    // inset from the rim, as the words' is above it.
    promptForeground.addSubview(attachRestSlot)
    NSLayoutConstraint.activate([
      attachRestSlot.leadingAnchor.constraint(
        equalTo: promptForeground.leadingAnchor,
        constant: AgentPaletteMetrics.chatComposerControlsTrailingInset),
      attachRestSlot.centerYAnchor.constraint(equalTo: trailingControls.centerYAnchor),
    ])
    promptForeground.addSubview(recordingHoverSensor)
    promptForeground.addSubview(recordingControls)

    hintLabel.stringValue = "Describe your task..."
    hintLabel.font = PromptTextView.promptFont
    hintLabel.textColor = AgentPaletteMetrics.chatComposerPlaceholderInk
    hintLabel.translatesAutoresizingMaskIntoConstraints = false
    // Layer-backed so the Tab swap can crossfade and blur it — see
    // `beginTargetSwap`.
    hintLabel.wantsLayer = true
    hintLabel.setContentHuggingPriority(.required, for: .horizontal)
    hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    hintLabel.isHidden = false
    promptForeground.addSubview(hintLabel)

    NSLayoutConstraint.activate([
      // Centred on where the box's middle is, rather than pinned by its leading
      // edge: the view is now a `promptMarkHitSize` click target around a face
      // that is still drawn at `promptMascotSize`, so what has to stay put is
      // the centre the mascot is laid out against, not an edge that moved.
      selectedAgentImage.centerXAnchor.constraint(
        equalTo: promptForeground.leadingAnchor,
        constant: AgentPaletteMetrics.promptLeadingInset + AgentPaletteMetrics.iconSize / 2
      ),
      // The mark and controls keep the compact row's screen position while
      // the long draft scrolls independently underneath them.
      selectedAgentImage.centerYAnchor.constraint(
        equalTo: promptForeground.topAnchor,
        constant: AgentPaletteMetrics.promptSize.height / 2
      ),
      selectedAgentImage.widthAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.promptMarkHitSize
      ),
      selectedAgentImage.heightAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.promptMarkHitSize
      ),

      // From the capsule's edge, not the mark's: the mark's box is now free to
      // grow for the face and for the pointer without dragging the sentence
      // along. See `AgentPaletteMetrics.promptTextLeading`.
      editorLeading,
      // One line high to start, sized for the tallest thing a line can hold —
      // a chip is taller than the type beside it, so sizing to the font would
      // clip it. `syncPromptHeight` raises this by whole lines as text wraps.
      promptScrollHeightConstraint,


      // `micHitSize`, not a second copy of the same arithmetic — the metric
      // existed and these constraints had drifted into recomputing it.
      micWidth,
      micHeight,

      hintLabel.leadingAnchor.constraint(equalTo: promptScroll.leadingAnchor),
      // Baselines, not boxes. The prompt's box is sized for a chip and lays its
      // text out from the top; the label's box hugs its own font and centres
      // inside the same row. Centring both left the placeholder sitting ~3pt
      // below the text it stands in for, so type appeared to jump on the first
      // keystroke.
      hintBaseline,
      hintLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingControls.leadingAnchor,
        constant: -AgentPaletteMetrics.promptMicTextSpacing
      ),
      controlsTrailing,
      controlsTop,
      // Confirm sits on the microphone disc: the pill's trailing padding hangs
      // past the disc, which is why this is `+ padding` rather than equal.
      recordingControls.trailingAnchor.constraint(
        equalTo: trailingControls.trailingAnchor,
        constant: AgentPaletteMetrics.voiceControlsPadding
      ),
      recordingControls.centerYAnchor.constraint(equalTo: trailingControls.centerYAnchor),
      recordingHoverSensor.leadingAnchor.constraint(equalTo: recordingControls.leadingAnchor),
      recordingHoverSensor.trailingAnchor.constraint(equalTo: recordingControls.trailingAnchor),
      recordingHoverSensor.topAnchor.constraint(equalTo: recordingControls.topAnchor),
      recordingHoverSensor.bottomAnchor.constraint(equalTo: recordingControls.bottomAnchor),
    ])

    // Only the editor changes geometry; the controls are fixed above it.
    // The trailing edge is the same in both sets — `editorTrailing` — because
    // the two used to state the same distance twice, once relative to the disc
    // and once as that distance spelled out.
    inlineControlConstraints = [
      promptScroll.centerYAnchor.constraint(equalTo: promptForeground.centerYAnchor),
    ]
    expandedPromptConstraints = [expandedPromptTop]
    NSLayoutConstraint.activate(inlineControlConstraints + [editorTrailing])

    applyPromptForegroundAppearance()
    applyMicAppearance()
    // After the height constraints exist: adding the field to the hierarchy
    // can notify a content-height change, and that used to unwrap IUOs.
    field.onContentHeightChange = { [weak self] in
      guard let self else { return }
      guard !self.isPerformingLayout else {
        self.schedulePromptRemeasure()
        return
      }
      self.syncPromptExpansion()
      self.syncPromptHeight()
      self.refreshPromptEdgeFades()
    }
    // The width the sentence wraps in is not settled until the scroll view has
    // tiled. Do not change its constraint set inside that layout pass; settle
    // expansion once TextKit has received the final width.
    field.onWrapWidthChange = { [weak self] in
      guard let self else { return }
      if self.updatePromptHeights() { self.refreshPromptEdgeFades() }
      // TextKit can finish updating its container after setFrameSize returns.
      // Coalesce one final measurement outside that layout transaction; the
      // last animation frame must not retain the previous width's line count.
      self.schedulePromptRemeasure()
    }
    promptScroll.contentView.postsBoundsChangedNotifications = true
    // Held, not dropped. `[weak self]` keeps this from being a leak in the
    // reference-cycle sense, but an unreleased token is still a registration
    // the centre keeps for the life of the process.
    viewObservers.keep(NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: promptScroll.contentView,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.refreshPromptEdgeFades()
        self?.field.syncTrailingHintView()
        self?.field.syncCaret()
      }
    })

    resultsStack.edgeInsets = NSEdgeInsets(
      top: AgentPaletteMetrics.resultsVerticalInset,
      left: 0,
      bottom: AgentPaletteMetrics.resultsVerticalInset,
      right: 0
    )
    resultsStack.translatesAutoresizingMaskIntoConstraints = false

    resultsScroll.drawsBackground = false
    resultsScroll.hasVerticalScroller = true
    resultsScroll.hasHorizontalScroller = false
    resultsScroll.autohidesScrollers = true
    resultsScroll.borderType = .noBorder
    resultsScroll.scrollerStyle = .overlay
    // Drawn along the shell's corners instead (`scrollIndicator`).
    resultsScroll.verticalScroller = PaletteInvisibleScroller()
    resultsScroll.scrollerStyle = .overlay
    resultsScroll.documentView = resultsStack
    resultsScroll.translatesAutoresizingMaskIntoConstraints = false
    // Every scroll — wheel, ↑/↓, a restack — moves rows under a pointer that
    // may not have moved, and the rows' tracking areas miss some of the exits.
    resultsScroll.contentView.postsBoundsChangedNotifications = true
    viewObservers.keep(NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: resultsScroll.contentView,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.syncResultRowHover()
        self?.syncScrollIndicator()
      }
    })
    observeScrollIndicator(of: resultsScroll)
    observeScrollIndicator(of: previewCard.transcriptScroll)

    resultsScrollTop = resultsScroll.topAnchor.constraint(equalTo: historyTabs.bottomAnchor)
    resultsForeground.translatesAutoresizingMaskIntoConstraints = false
    resultsForeground.wantsLayer = true
    resultsForeground.layer?.backgroundColor = NSColor.clear.cgColor
    // The strip over the list, which scrolls up under it.
    resultsForeground.addSubview(resultsScroll)
    resultsForeground.addSubview(historyTabs)
    resultsScroll.wantsLayer = true
    resultsScroll.layer?.mask = resultsTopEdge
    resultsScroll.postsFrameChangedNotifications = true
    viewObservers.keep(NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification,
      object: resultsScroll,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.updateResultsTopEdge()
      }
    })
    historyTabs.onSelect = { [weak self] agent in
      self?.selectHistoryAgent(agent)
    }
    let footInset = AgentPaletteMetrics.historyFootDiscInset
    for (disc, action, id) in [
      (historyNewChatButton, #selector(startNewChatFromHistory), "boltty.ask.history.newChat"),
      (historySettingsButton, #selector(openSettingsFromHistory), "boltty.ask.history.settings"),
    ] {
      disc.button.target = self
      disc.button.action = action
      disc.setAccessibilityIdentifier(id)
      disc.isHidden = true
      resultsForeground.addSubview(disc)
    }
    historySettingsButton.button.toolTip = "Settings"
    NSLayoutConstraint.activate([
      historyNewChatButton.trailingAnchor.constraint(
        equalTo: resultsForeground.trailingAnchor, constant: -footInset),
      historyNewChatButton.bottomAnchor.constraint(
        equalTo: resultsForeground.bottomAnchor, constant: -footInset),
      historySettingsButton.leadingAnchor.constraint(
        equalTo: resultsForeground.leadingAnchor, constant: footInset),
      historySettingsButton.bottomAnchor.constraint(
        equalTo: resultsForeground.bottomAnchor, constant: -footInset),
    ])
    NSLayoutConstraint.activate([
      historyTabs.leadingAnchor.constraint(equalTo: resultsForeground.leadingAnchor),
      historyTabs.trailingAnchor.constraint(equalTo: resultsForeground.trailingAnchor),
      historyTabs.topAnchor.constraint(equalTo: resultsForeground.topAnchor),
      resultsScroll.leadingAnchor.constraint(equalTo: resultsForeground.leadingAnchor),
      resultsScroll.trailingAnchor.constraint(equalTo: resultsForeground.trailingAnchor),
      // The scroll hangs off the strip's bottom in both states: hiding the
      // strip zeroes its height (`setVisible`) rather than unpinning it, so
      // there is one chain here instead of two that can disagree. It reaches
      // `resultsOverlap` up under the strip (`setResultsOverlap`).
      resultsScrollTop,
      resultsScroll.bottomAnchor.constraint(equalTo: resultsForeground.bottomAnchor),
      resultsStack.leadingAnchor.constraint(equalTo: resultsScroll.contentView.leadingAnchor),
      resultsStack.trailingAnchor.constraint(equalTo: resultsScroll.contentView.trailingAnchor),
      resultsStack.topAnchor.constraint(equalTo: resultsScroll.contentView.topAnchor),
      resultsStack.widthAnchor.constraint(equalTo: resultsScroll.contentView.widthAnchor),
    ])

    notice.isHidden = true
    notice.setAccessibilityIdentifier("boltty.ask.notice")

    directoryChip.onChoose = { [weak self] in self?.onWorkingDirectoryMenu?() }
    planRing.onCompact = { [weak self] in self?.onCompact?() }
    directoryChip.isHidden = true
    latestPill.button.target = self
    latestPill.button.action = #selector(scrollTranscriptToLatest)
    latestPill.setAccessibilityIdentifier("boltty.ask.chat.latest")
    latestPill.isHidden = true

    routingLabel.font = roundedAppFont(size: AgentPaletteMetrics.promptNoteFontSize)
    routingLabel.textColor = PaletteInk.secondary
    routingLabel.lineBreakMode = .byTruncatingTail
    routingLabel.translatesAutoresizingMaskIntoConstraints = false
    routingButton.button.target = self
    routingButton.button.action = #selector(openSettingsFromRouting)
    routingButton.button.setAccessibilityIdentifier("boltty.ask.routing.openSettings")
    routingButton.setContentHuggingPriority(.required, for: .horizontal)
    routingRow.orientation = .horizontal
    routingRow.alignment = .centerY
    routingRow.spacing = 8
    routingRow.translatesAutoresizingMaskIntoConstraints = false
    routingRow.setViews([routingLabel, routingButton], in: .leading)
    routingRow.isHidden = true

    bottomBar.orientation = .vertical
    // Notices wrap to the same width as the field.
    bottomBar.alignment = .leading
    bottomBar.spacing = AgentPaletteMetrics.errorTopSpacing
    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.setViews([routingRow], in: .leading)

    promptCapsule.translatesAutoresizingMaskIntoConstraints = false
    promptCapsule.wantsLayer = true
    promptCapsule.layer?.masksToBounds = false
    promptHost.translatesAutoresizingMaskIntoConstraints = false
    resultsCapsule.translatesAutoresizingMaskIntoConstraints = false
    resultsCapsule.wantsLayer = true
    resultsCapsule.layer?.masksToBounds = false
    resultsCapsule.isHidden = true
    resultsForeground.setAccessibilityIdentifier("boltty.ask.sessions")

    previewCapsule.translatesAutoresizingMaskIntoConstraints = false
    previewCapsule.wantsLayer = true
    previewCapsule.layer?.masksToBounds = false
    previewForeground.translatesAutoresizingMaskIntoConstraints = false
    previewForeground.wantsLayer = true
    previewForeground.layer?.backgroundColor = NSColor.clear.cgColor
    previewCapsule.isHidden = true
    // The transcript is a rectangular viewport inside the shared shell: its
    // outer silhouette is clipped by `drawSurface`, not by a capsule of its own.
    previewForeground.layer?.cornerRadius = 0
    previewForeground.layer?.masksToBounds = true
    applyFloatingShadow(
      to: promptCapsule,
      cornerRadius: AgentPaletteMetrics.cornerRadius
    )

    // Capsule: glass chrome under, icon/text always on the front edge.
    promptCapsule.addSubview(promptHost)
    promptCapsule.addSubview(promptForeground)
    promptHost.layer?.zPosition = 0
    promptForeground.layer?.zPosition = 10
    // List: same split so the blue wash never covers row titles.
    resultsCapsule.addSubview(resultsForeground)
    resultsForeground.layer?.zPosition = 10
    previewCapsule.addSubview(previewForeground)
    previewForeground.layer?.zPosition = 10
    surface.translatesAutoresizingMaskIntoConstraints = true
    surface.wantsLayer = true
    surfaceContainer.wantsLayer = true
    surfaceContainer.addSubview(surface)
    // **Not in an `NSGlassEffectContainerView`**: the container draws the
    // glass itself, above everything in the host — the wash goes under it,
    // the corner the host clips with its layer is ignored, and the shell
    // comes out a flat grey rectangle.
    // Under the shell: an outline the shell stands over is the shell's.
    screenOutlines.frame = bounds
    screenOutlines.autoresizingMask = [.width, .height]
    addSubview(screenOutlines)
    // **Under the glass**, so the glass bends and frosts it as it moves. The
    // glass samples what is beneath it in the window — a sibling placed below
    // it is bent, frosted and dimmed by the material. Hits fall through
    // (`hitTest` is nil); the words stay sharp on top.
    voiceGlow.translatesAutoresizingMaskIntoConstraints = true
    addSubview(voiceGlow)
    addSubview(surfaceContainer)
    // **And the orb on it**: the glass frosts
    // what is under it into a wash, so the listening orb — the gradient and
    // its lit rim — stands over the glass, crisp to its edge, drawn from the
    // light's own clock. See `VoiceGlowSheenView`.
    voiceGlow.sheen.translatesAutoresizingMaskIntoConstraints = true
    addSubview(voiceGlow.sheen)
    // The words being said stand on top of both: the glass would frost them
    // and the orb's surface tint them.
    listeningWordsHost.translatesAutoresizingMaskIntoConstraints = true
    listeningWordsHost.wantsLayer = true
    listeningWordsHost.layer?.masksToBounds = true
    listeningWordsHost.alphaValue = 0
    listeningWords.translatesAutoresizingMaskIntoConstraints = true
    // **Head**, not tail: once the capsule is as long as the prompt, the words
    // still coming are at the end.
    listeningWords.lineBreakMode = .byTruncatingHead
    listeningWords.cell?.truncatesLastVisibleLine = true
    listeningWords.maximumNumberOfLines = 1
    listeningWords.isSelectable = false
    listeningWordsHost.addSubview(listeningWords)
    addSubview(listeningWordsHost)
    scrollIndicator.translatesAutoresizingMaskIntoConstraints = true
    scrollIndicator.autoresizingMask = [.width, .height]
    // **The transcript goes in first, so the composer sits over it.**
    //
    // Sibling order is both the paint order and the hit order, and the card now
    // reaches under the composer — added the other way round, the extended band
    // would cover the field and swallow the clicks meant for it.
    addSubview(previewCapsule)
    addSubview(promptCapsule)
    addSubview(resultsCapsule)
    addSubview(bottomBar)
    addSubview(latestPill)
    NSLayoutConstraint.activate(latestPillConstraints)
    addSubview(notice)
    NSLayoutConstraint.activate([noticeCenterX, noticeTopToPrompt])

    // Collapsed: zero spacing so the panel keeps the capsule-only height.
    errorTopToResultsConstraint.isActive = false
    errorTopToPreviewConstraint.isActive = false

    NSLayoutConstraint.activate([
      promptCenterXConstraint,
      promptTopConstraint,
      promptWidthConstraint,
      promptCapsuleHeightConstraint,

      promptHost.leadingAnchor.constraint(equalTo: promptCapsule.leadingAnchor),
      promptHostTrailing,
      promptHost.topAnchor.constraint(equalTo: promptCapsule.topAnchor),
      promptHost.bottomAnchor.constraint(equalTo: promptCapsule.bottomAnchor),

      promptForeground.leadingAnchor.constraint(equalTo: promptCapsule.leadingAnchor),
      promptForeground.trailingAnchor.constraint(equalTo: promptCapsule.trailingAnchor),
      promptForeground.topAnchor.constraint(equalTo: promptCapsule.topAnchor),
      promptForeground.bottomAnchor.constraint(equalTo: promptCapsule.bottomAnchor),

      resultsCapsule.centerXAnchor.constraint(equalTo: promptCapsule.centerXAnchor),
      resultsTopConstraint,
      resultsWidthConstraint,
      resultsHeightConstraint,

      resultsForeground.leadingAnchor.constraint(equalTo: resultsCapsule.leadingAnchor),
      resultsForeground.trailingAnchor.constraint(equalTo: resultsCapsule.trailingAnchor),
      resultsForeground.topAnchor.constraint(equalTo: resultsCapsule.topAnchor),
      resultsForeground.bottomAnchor.constraint(equalTo: resultsCapsule.bottomAnchor),

      previewCapsule.centerXAnchor.constraint(equalTo: promptCapsule.centerXAnchor),
      previewTopConstraint,
      previewWidthConstraint,
      previewHeightConstraint,

      previewForeground.leadingAnchor.constraint(equalTo: previewCapsule.leadingAnchor),
      previewForeground.trailingAnchor.constraint(equalTo: previewCapsule.trailingAnchor),
      previewForeground.topAnchor.constraint(equalTo: previewCapsule.topAnchor),
      previewForeground.bottomAnchor.constraint(equalTo: previewCapsule.bottomAnchor),

      bottomBar.leadingAnchor.constraint(equalTo: promptCapsule.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: promptCapsule.trailingAnchor),
      errorTopToPromptConstraint,
    ])

    // Behind the composer: over the transcript and
    // the shell's glass, under the composer where the two meet in the corner.
    resizeGrabber.isHidden = true
    addSubview(resizeGrabber, positioned: .below, relativeTo: promptCapsule)
    // Over everything on the shell: it is the shell's own edge that it
    // follows, past the composer and the tabs alike.
    scrollIndicator.frame = bounds
    addSubview(scrollIndicator)
  }

  override func setFrameSize(_ newSize: NSSize) {
    let heightChanged = abs(newSize.height - frame.height) > 0.5
    super.setFrameSize(newSize)
    applyPlacement()
    // The card's ceiling is a share of the room under the prompt, so only a
    // change in height can move it. A width-only change — and every resize that
    // reports the size it already had — leaves the answer exactly where it is.
    if heightChanged, addressedPreview != nil {
      previewBandHeight = reservedTranscriptHeight
    }
  }

  override func layout() {
    isPerformingLayout = true
    defer { isPerformingLayout = false }
    applyPlacement()
    super.layout()
    // The panel moves to another screen when it opens there. Only then:
    // reading the draft on every frame of the shell's spring is not free.
    if window?.frame != outlinedWindowFrame { syncScreenOutlines() }
    updateUnifiedSurface()
    // What a press would do can change under a pointer that has not moved —
    // the list opening, a turn starting, the shell landing beside a region.
    syncPointerWhereItIs()
    // The shared shell owns the shadow. Nested composer chrome has none.
    //
    // **And none of the three may clip.** A container that clips imposes its own
    // corner on the glass inside it, and these carry the *resting prompt's*
    // 37.25 from `applyFloatingShadow` — so a composer asking for 12 rendered as
    // a 37.25 capsule, with the host's own radius correct and invisible. Setting
    // it in `setup()` does not hold: the value is back to `true` before the
    // first layout, which is the same reason `shadowOpacity` is re-zeroed here
    // rather than set once.
    for capsule in [promptCapsule, resultsCapsule, previewCapsule] {
      capsule.layer?.shadowOpacity = 0
      // Guarded: `clipsToBounds` invalidates layout on every write, and writing
      // the value it already holds from inside `layout()` spins the run loop —
      // the same trap `syncResultsCardCorner` was written around.
      if capsule.clipsToBounds { capsule.clipsToBounds = false }
    }
  }

  /// Stands the shell at the top of the screen, centred — every state keeps
  /// that top and that centre.
  private func applyPlacement() {
    let size = bounds.size
    guard size.width > 1, size.height > 1 else { return }
    let anchor = shellAnchor
    let top = anchor?.top ?? surfaceTopInset
    let offset = anchor?.offset ?? 0
    let chat = addressedPreview != nil
    applyComposerGlyphSize(chat: chat)
    promptHost.apply(surfaceStyle: chat ? .bolttyAIComposer : .bolttyAI)
    // The first screen alone wears the black ramp over its glass.
    applySurfaceStyle(showsInitialPrompt ? .bolttyAIPrompt : .bolttyAI)
    errorTopToPromptConstraint.constant = AgentPaletteMetrics.errorTopSpacing
    // **A capsule while it is a bar, a rounded rectangle once it is a box.**
    // The mock states both as arbitrary values on one component — 100 at h=36,
    // 20 at h=68 — so a grown composer is not a longer pill, and this does not
    // have to be derived from anything.
    let height = promptCapsuleHeightConstraint.constant
    let grown = height > AgentPaletteMetrics.chatComposerHeight + 1
    // A box keeps one corner however many lines it holds: the
    // one-line box's, which the shell is concentric with.
    promptHost.cornerRadius = chat
      ? (grown ? AgentPaletteMetrics.chatComposerRestingCornerRadius
        : AgentPaletteMetrics.chatComposerCornerRadius)
      : AgentPaletteMetrics.cornerRadius
    field.setChatComposerStyle(chat)
    selectedAgentImage.isHidden = chat
    hintLabel.font = chat ? PromptTextView.chatComposerFont : PromptTextView.promptFont
    // White at 50% on both screens: in primary ink a placeholder reads as
    // typed text.
    hintLabel.textColor = AgentPaletteMetrics.chatComposerPlaceholderInk
    editorLeading.constant = chat
      ? AgentPaletteMetrics.chatComposerTextLeading
      : AgentPaletteMetrics.promptTextLeading
    // Notices under the field start where its words do, not at its rim —
    // flush with the capsule's edge they read as a stray line.
    bottomBar.edgeInsets = NSEdgeInsets(
      top: 0, left: editorLeading.constant, bottom: 0, right: editorLeading.constant)
    // A glass disc keeps its 44 — listening is the one state that shows it.
    micWidth.constant = isVoiceListening
      ? AgentPaletteMetrics.voiceOrbDiameter
      : composerControlDiameter
    micHeight.constant = micWidth.constant
    micButton.setShowsGlass(isVoiceListening)
    // **In a chat the glyphs stand inside the field, on its first line**
    // (WORK PAGE `982:5127`): the same bare clip and microphone the initial
    // prompt draws, so the composer reads as the prompt it continues. A grown
    // chat draft gives its full width to text and puts the icons at the bottom.
    // Recording confirmation stays attached to the microphone in that row.
    let bottomControls = chat && isPromptExpanded
    let restingInset = usesExpandedControlLayout
      ? AgentPaletteMetrics.promptTrailingInset
      : chat
        ? AgentPaletteMetrics.chatComposerControlsTrailingInset
        : AgentPaletteMetrics.restingControlsTrailingInset
    controlsTrailing.constant = -restingInset
    // Bare glyphs keep their round hit targets with no gap between them; a
    // hidden clip closes its own gap in `applyAttachPlacement`, so the text
    // reclaims it.
    trailingControls.spacing = usesExpandedControlLayout
      ? AgentPaletteMetrics.chatComposerMicSpacing
      : AgentPaletteMetrics.restingControlsSpacing
    applyAttachPlacement()
    syncDirectoryChipVisibility()
    syncSendButton()
    promptHostTrailing.constant = 0
    editorTrailing.constant = bottomControls
      ? -AgentPaletteMetrics.chatComposerTextLeading
      : -restingEditorTrailing(chat: chat)
    // The placeholder stands on the line its own glyphs would occupy: the
    // editor's own inset and face, as they are set now — the chat's box
    // carries an inset of its own, and a baseline worked out for the prompt's
    // centred line put the words five points above the caret.
    hintBaseline.constant = field.typedBaselineFromTop
    _ = updatePromptHeights()
    expandedPromptTop.constant = bottomControls ? AgentPaletteMetrics.chatComposerGrownTextTop : 0
    controlsTop.constant = bottomControls
      ? promptCapsuleHeightConstraint.constant
        - (AgentPaletteMetrics.chatComposerControlsPadding + ComposerControlGroup.glyph / 2)
      : (chat ? AgentPaletteMetrics.chatComposerHeight / 2 : AgentPaletteMetrics.promptSize.height / 2)
    let inset = chat ? AgentPaletteMetrics.shellContentInset : 0
    let width = chat ? chatSurfaceSize.width
      : isHistoryOpen ? historySurfaceWidth : AgentPaletteMetrics.promptSize.width
    promptWidthConstraint.constant = width - inset * 2
    // Inside a chat it keeps clear of the transcript's walls; under the
    // shell it may be as wide as the shell.
    notice.maximumWidth = chat
      ? promptWidthConstraint.constant - AgentPaletteMetrics.noticeChatInset * 2
      : width
    anchorNotice()
    resultsWidthConstraint.constant = historySurfaceWidth
    previewWidthConstraint.constant = chatSurfaceSize.width
    if addressedPreview != nil {
      previewBandHeight = reservedTranscriptHeight
    }
    if isResultsExpanded && addressedPreview == nil {
      resultsHeightConstraint.constant = measuredResultsCardHeight()
    }
    // The transcript still scrolls behind the composer. Its document inset
    // clears the composer alone; folder and plan no longer take another band.
    applyPreviewBandHeight()
    previewCard.setFloatingBottomInset(
      chip: 0,
      composer: chat ? chatComposerBand : 0
    )
    promptTopConstraint.constant = top
      + (chat
          ? previewBandHeight + AgentPaletteMetrics.surfaceStackSpacing
          : 0)
    promptCenterXConstraint.constant = offset
    resultsTopConstraint.constant = mode == .search ? 0 : -promptCapsuleHeightConstraint.constant
    // **The transcript starts at the shell's rim, not one gap below it.**
    //
    // The composer's term above adds `surfaceStackSpacing`; this one has to take
    // it back, or the gap lands on the wrong side of the transcript — 26.667pt of
    // bare glass above the card and the card's floor welded to the composer.
    //
    // Two visible defects came out of that one missing term, and neither looked
    // like it. The close disc is inset from the *card*, so it sat 56 from the
    // shell's top rim against 29.333 from its left one. And the transcript's
    // square clip (`previewForeground.masksToBounds`) landed on flat glass
    // mid-shell instead of at the rim, where the shell's silhouette mask would
    // have cut the top line with the card's own corner — which is what the
    // reference draws.
    previewTopConstraint.constant = -(promptCapsuleHeightConstraint.constant
      + previewBandHeight
      + (chat ? AgentPaletteMetrics.surfaceStackSpacing : 0))
  }

  private var wantedSurfaceStyle = PaletteSurfaceStyle.bolttyAI
  private var surfaceStyleIsScheduled = false

  /// **The black ramp is worn only once the state has settled.** Leaving a
  /// state for another lays the panel out in between — `collapseResults` and
  /// `hidePreview` both do — when there is no list and no chat yet, which
  /// reads as the first screen; applied at once, the ramp would show for
  /// that one layout and fade out over the chat's glass. Going *to*
  /// the ramp waits for the end of the turn, by which time a transient has
  /// been corrected and the want is the current style again; going *away*
  /// from it is at once, as the fade is timed to the shell's spring.
  private func applySurfaceStyle(_ style: PaletteSurfaceStyle) {
    wantedSurfaceStyle = style
    guard style != surface.currentSurfaceStyle else { return }
    guard style.wash != nil, window?.isVisible == true else {
      surface.apply(surfaceStyle: style)
      return
    }
    guard !surfaceStyleIsScheduled else { return }
    surfaceStyleIsScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.surfaceStyleIsScheduled = false
      self.surface.apply(surfaceStyle: self.wantedSurfaceStyle)
    }
  }

  /// The first screen is the prompt capsule alone, without an outer rim or footer.
  private var showsInitialPrompt: Bool {
    addressedPreview == nil && !isResultsExpanded && !showsCompactListening
  }

  private func updateUnifiedSurface() {
    guard bounds.width > 1, bounds.height > 1 else { return }
    let chat = addressedPreview != nil
    let listening = showsCompactListening
    let list = isResultsExpanded && !chat
    let searching = list && mode == .search
    let top = shellAnchor?.top ?? surfaceTopInset

    // Listening is an orb: a ball of
    // glass with the voice's light in it, which grows into a capsule round the
    // words as they are said, and is the orb again in silence.
    let width: CGFloat
    if listening {
      width = listeningShellWidth()
    } else {
      width = isOpenChat ? chatSurfaceSize.width
        : isHistoryOpen ? historySurfaceWidth : AgentPaletteMetrics.promptSize.width
    }
    let unclamped: CGFloat
    if listening {
      unclamped = AgentPaletteMetrics.listeningOrbDiameter
    } else if list {
      unclamped = historySurfaceHeight
    } else if chat {
      unclamped = chatSurfaceSize.height
    } else {
      unclamped = promptCapsuleHeightConstraint.constant
    }
    let height = unclamped

    let rect = CGRect(
      x: bounds.midX + promptCenterXConstraint.constant - width / 2,
      y: bounds.height - top - height,
      width: width,
      height: height
    )
    promptHost.isHidden = !chat || listening
    listeningWordsWidth = width
    let saysWords = listening && !listeningWords.stringValue.isEmpty
    if saysWords != (listeningWordsHost.alphaValue > 0) {
      if saysWords, !MotionPreferences.reduceMotion, window?.isVisible == true {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = Motion.standard
          context.timingFunction = Motion.emphasizedCurve
          listeningWordsHost.animator().alphaValue = 1
        }
      } else {
        listeningWordsHost.alphaValue = saysWords ? 1 : 0
      }
    }
    promptCapsule.alphaValue = (list && !searching) || listening ? 0 : 1
    previewCapsule.alphaValue = listening ? 0 : 1
    resultsCapsule.alphaValue = 1
    // Inside the layout pass, so no content-size callback from here — the
    // stack re-lays itself out and the panel is the screen either way.
    syncDirectoryChipVisibility()
    // A region asked about moves the shell from under the notch to beside
    // it and back: across the screen, a spring would be a fly-by.
    let jumps = placedPhase != screenSelectionPhase
    placedPhase = screenSelectionPhase
    _ = surfaceMotion.move(
      to: dripTarget ?? rect,
      in: self,
      animated: resizeDrag == nil && surfaceReady && !jumps
        && window?.isVisible == true && !MotionPreferences.reduceMotion
    )
    surfaceReady = true
    if resizeTarget != rect {
      resizeTarget = rect
      window?.invalidateCursorRects(for: self)
    }
    drawSurface(at: surfaceFrame)
  }

  private func drawSurface(at rect: CGRect) {
    surfaceFrame = rect
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surfaceContainer.frame = rect
    surface.frame = surfaceContainer.bounds
    voiceGlow.frame = rect
    voiceGlow.sheen.frame = rect
    // Initial input, chat and history each keep their own corner.
    // Compact listening retains the pill silhouette.
    let isChat = addressedPreview != nil && !showsCompactListening
    let isList = addressedPreview == nil && isResultsExpanded
    surface.cornerRadius = AgentPaletteMetrics.surfaceCornerRadius(
      forHeight: rect.height,
      shape: isChat ? .chat : (isList ? .list : (showsInitialPrompt ? .initial : .pill))
    )
    surface.layoutSubtreeIfNeeded()
    // The *rendered* corner from here on, not the requested one: the shadow and
    // the text clip have to agree with the silhouette the glass actually drew,
    // or the shell wears two outlines a few points apart.
    let corner = surface.renderedCornerRadius
    let curve = surface.renderedCornerCurve
    voiceGlow.surfaceCornerRadius = corner
    voiceGlow.surfaceCornerCurve = curve
    layoutListeningWords(in: rect, corner: corner, curve: curve)
    layoutResizeGrabber(in: rect, corner: corner)
    scrollIndicatorShell = (rect, corner)
    syncScrollIndicator()
    applyFloatingShadow(to: surfaceContainer, cornerRadius: corner)
    // Clip live text to the moving shell; never scale or snapshot the editor.
    let clippedContent = [promptForeground, resultsForeground, previewForeground]
    for content in clippedContent {
      let mask = (content.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
      mask.frame = content.bounds
      let local = convert(rect, to: content)
      // `CGPath` has no squircle, so where the glass drew one the mask is built
      // from a layer that can: a circular path against a continuous rim parts
      // company along the wall by more than a glyph is wide, and the text is
      // what sits in that gap.
      if curve == .continuous {
        mask.path = nil
        mask.backgroundColor = NSColor.black.cgColor
        mask.frame = local
        mask.applyPaletteCorner(radius: corner)
        mask.masksToBounds = true
      } else {
        mask.backgroundColor = nil
        mask.masksToBounds = false
        mask.path = CGPath(
          roundedRect: local,
          cornerWidth: corner,
          cornerHeight: corner,
          transform: nil
        )
      }
      content.layer?.mask = mask
    }
    CATransaction.commit()
  }

  /// The words stand from the capsule's left end at the width it is growing
  /// to, so as it springs wider they slide with that end and the newest word
  /// is uncovered by the other, rather than jumping each time one is heard.
  private func layoutListeningWords(in rect: CGRect, corner: CGFloat, curve: CALayerCornerCurve) {
    listeningWordsHost.frame = rect
    listeningWordsHost.layer?.cornerRadius = corner
    listeningWordsHost.layer?.cornerCurve = curve
    let inset = AgentPaletteMetrics.listeningWordsInset
    let height = ceil(listeningWords.intrinsicContentSize.height)
    // By its alignment rect: a label draws its text 2pt in from its frame,
    // and measured without them a one-word take read "…".
    listeningWords.frame = listeningWords.frame(forAlignmentRect: CGRect(
      x: inset,
      y: ((rect.height - height) / 2).rounded(),
      width: max(0, listeningWordsWidth - inset * 2),
      height: height
    ))
  }

  private func revealSurfaceContent() {
    let content = addressedPreview != nil ? previewForeground : isResultsExpanded ? resultsForeground : promptForeground
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = content.layer?.presentation()?.opacity ?? 0
    fade.toValue = 1
    fade.duration = AgentPaletteMetrics.surfaceContentDuration
    fade.timingFunction = Motion.emphasizedCurve
    content.layer?.add(fade, forKey: "surfaceContent")
  }

  @objc private func goBack() {
    guard addressedPreview != nil else { closeSwitcher(); return }
    let previous = returnToSessionID
    returnToSessionID = nil
    leaveAddressing(animated: true)
    if let previous {
      openSwitcher()
      if let index = resultItems.firstIndex(where: { $0.id == previous }) {
        selectedResultIndex = index
        applySelectionHighlight(animated: false)
        scrollSelectedResultVisible()
      }
    }
    _ = focusField()
  }

  // MARK: - Resizing

  /// **The open chat and the chat list can be resized** — by the arc in
  /// their lower right corner, by their sides and by their foot. The top is
  /// the shell's anchor, under the menu bar.
  ///
  /// **Why there is a visible handle.** Thin edge grips and the system's
  /// resize cursors are not enough here: the panel never activates Boltty,
  /// so the cursor is not the app's to change and nothing says where the
  /// grip is; the shell's corners are large arcs, so corner grips stand in
  /// transparent glass; and a press a few points off the edge is a press on
  /// empty glass, which hides the panel. So the corner
  /// wears iPadOS 26's grabber (`resizeGrabber`) that lights up under the
  /// pointer, the grips are wider and reach outside the edge, and a press
  /// near the edge never dismisses.
  ///
  /// **The centre stays where it is**: the shell is locked to the top and
  /// the middle of the screen, so a side dragged out takes the other with
  /// it — the width grows by twice the drag.
  private enum ResizableShell { case chat, history }

  private var resizableShell: ResizableShell? {
    if isOpenChat { return .chat }
    if isHistoryOpen { return .history }
    return nil
  }

  /// Where the shell is headed, for the grips: the spring's frame lags it.
  private var resizeTarget: CGRect = .zero

  /// The corner's grabber: an arc that follows the shell's lower right
  /// corner a few points inside its rim — iPadOS 26's window handle.
  private let resizeGrabber = PaletteResizeGrabberView(frame: .zero)
  private var resizeHoverArea: NSTrackingArea?

  private func resizeEdges(at point: NSPoint) -> SurfaceResizeEdges? {
    guard resizableShell != nil, !resizeTarget.isEmpty else { return nil }
    // The foot's discs stand inside the lower corners' grips; on a disc the
    // press is the disc's.
    if isOnHistoryFoot(convert(point, to: nil)) { return nil }
    return SurfaceResizeEdges.at(point, of: resizeTarget)
  }

  /// Near the shell's edge but on no grip: a near miss, not a dismissal.
  private func isNearShellEdge(_ point: NSPoint) -> Bool {
    guard resizableShell != nil, !resizeTarget.isEmpty else { return false }
    let outer = AgentPaletteMetrics.surfaceResizeOuterGrip
    return resizeTarget.insetBy(dx: -outer, dy: -outer).contains(point)
  }

  private func beginResize(edges: SurfaceResizeEdges, shell: ResizableShell, at point: NSPoint) {
    let size = shell == .chat
      ? CGSize(width: chatSurfaceWidth, height: chatSurfaceSize.height)
      : CGSize(width: historySurfaceWidth, height: historySurfaceHeight)
    resizeDrag = (edges, shell, point, size)
    resizeGrabber.isEngaged = true
    // A direct manipulation must not leave a spring behind the pointer.
    surfaceMotion.settle()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let drag = resizeDrag else {
      super.mouseDragged(with: event)
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    let dx = point.x - drag.start.x
    // Unflipped: the pointer going down is a negative `dy`.
    let dy = point.y - drag.start.y
    let minimum = drag.shell == .chat
      ? AgentPaletteMetrics.chatSurfaceMinimumSize
      : AgentPaletteMetrics.historySurfaceMinimumSize
    let room = CGSize(
      width: bounds.width - AgentPaletteMetrics.safeAreaX * 2,
      height: bounds.height - surfaceTopInset - AgentPaletteMetrics.safeAreaY
    )
    func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
      AgentPaletteMetrics.onPixelGrid(min(max(value, low), max(low, high)))
    }
    var size = drag.size
    // Both sides move: the centre is fixed.
    if drag.edges.contains(.right) { size.width += dx * 2 }
    if drag.edges.contains(.left) { size.width -= dx * 2 }
    if drag.edges.contains(.bottom) { size.height -= dy }
    size.width = clamp(size.width, minimum.width, room.width)
    size.height = clamp(size.height, minimum.height, room.height)
    switch drag.shell {
    case .chat: surfaceSizes.chat = size
    case .history: surfaceSizes.history = size
    }
    layoutSubtreeIfNeeded()
  }

  override func mouseUp(with event: NSEvent) {
    guard resizeDrag != nil else {
      super.mouseUp(with: event)
      return
    }
    resizeDrag = nil
    resizeGrabber.isEngaged = false
    onSurfaceSizesChange?(surfaceSizes)
    window?.invalidateCursorRects(for: self)
    syncPointer(at: convert(event.locationInWindow, from: nil))
  }

  /// A press on a grip is this view's, whatever stands under it — the
  /// transcript's scroller, the list's rows.
  override func hitTest(_ point: NSPoint) -> NSView? {
    if resizeEdges(at: convert(point, from: superview)) != nil { return self }
    return super.hitTest(point)
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard resizableShell != nil, !resizeTarget.isEmpty else { return }
    for region in SurfaceResizeEdges.regions(of: resizeTarget) {
      addCursorRect(region.rect, cursor: NSCursor.frameResize(position: region.cursor, directions: .all))
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let resizeHoverArea { removeTrackingArea(resizeHoverArea) }
    // Always, not only while key: the panel never activates the app, and the
    // grabber's light is the feedback the cursor may not be allowed to give.
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    resizeHoverArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    syncPointer(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    syncPointer(at: nil)
  }

  /// Lights the grabber whenever the pointer is on any grip, and dresses the
  /// pointer for what a press there would do (`pointerCursor(at:)`).
  private func syncPointer(at point: NSPoint?) {
    guard resizeDrag == nil else { return }
    let onGrip = point.flatMap(gripRegion(at:)) != nil
    if onGrip != resizeGrabber.isHovered { resizeGrabber.isHovered = onGrip }
    if let cursor = heldCursor ?? point.flatMap(pointerCursor(at:)) {
      wear(cursor)
    } else {
      releasePointerCursor()
    }
  }

  /// The pointer, dressed again where it stands — after something under it
  /// changed without it moving.
  private func syncPointerWhereItIs() {
    guard let window, window.isVisible else { return }
    let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    syncPointer(at: bounds.contains(point) ? point : nil)
  }

  /// Whether the pointer wears a cursor this view set. Given back as the
  /// arrow when the pointer leaves that ground — the text view's I-beam and
  /// the other cursor rects take it from there.
  private var ownsPointer = false
  /// The cursor a press in progress wears whatever passes under it — a
  /// handle's resize arrow while it is pulled.
  private var heldCursor: NSCursor?

  /// The arrow again, if the pointer wears one of this view's cursors. The
  /// controller calls it as the panel goes: a resize arrow left behind would
  /// stand over the app the panel uncovers.
  func releasePointerCursor() {
    guard ownsPointer else { return }
    ownsPointer = false
    NSCursor.arrow.set()
  }

  /// Sets `cursor` and remembers that this view did. Never in the unit-test
  /// host: the panel makes the cursor reach the screen from the background
  /// (`BackgroundCursor`), and a suite laying out a shown panel would put
  /// the developer's pointer in a resize arrow while they work.
  private func wear(_ cursor: NSCursor) {
    guard !AppDelegate.isHostingUnitTests else { return }
    cursor.set()
    ownsPointer = true
  }

  private func gripRegion(at point: NSPoint) -> (rect: CGRect, edges: SurfaceResizeEdges, cursor: NSCursor.FrameResizePosition)? {
    guard resizableShell != nil, !resizeTarget.isEmpty else { return nil }
    return SurfaceResizeEdges.regions(of: resizeTarget).first { $0.rect.contains(point) }
  }

  /// The resize arrow on a grip of the shell or a handle of a drawn region;
  /// `nil` anywhere else, the arrow staying the arrow. **No crosshair over
  /// the glass and no hand inside a region**: selecting is a plain drag, and
  /// only a handle says it can be pulled.
  private func pointerCursor(at point: NSPoint) -> NSCursor? {
    if let region = gripRegion(at: point) {
      return NSCursor.frameResize(position: region.cursor, directions: .all)
    }
    if isNearShellEdge(point) || !isEmptyGlass(point) { return nil }
    if screenSelectionPhase == .editing, let handle = screenOutlines.handle(at: point) {
      return NSCursor.frameResize(position: handle.resizePosition, directions: .all)
    }
    return nil
  }

  /// The scroll indicator along the shell's right edge and round its
  /// corners — for the open chat's transcript and the history's list.
  private let scrollIndicator = PaletteCornerScrollIndicator(frame: .zero)
  private var scrollIndicatorShell: (rect: CGRect, corner: CGFloat)?

  /// The scroll view the shell shows now, if it shows one.
  private var indicatedScroll: NSScrollView? {
    if addressedPreview != nil {
      return showsCompactListening ? nil : previewCard.transcriptScroll
    }
    return isResultsExpanded ? resultsScroll : nil
  }

  /// Shows the thumb on a scroll the person made — a gesture, a wheel, a
  /// drag on the strip — never on the transcript following a reply.
  private func observeScrollIndicator(of scroll: NSScrollView) {
    scroll.contentView.postsBoundsChangedNotifications = true
    for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
      viewObservers.keep(NotificationCenter.default.addObserver(
        forName: name, object: scroll, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.indicatedScroll === scroll else { return }
          self.syncScrollIndicator()
          if self.scrollIndicatorReading != nil { self.scrollIndicator.flash() }
        }
      })
    }
    guard scroll !== resultsScroll else { return }
    viewObservers.keep(NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.syncScrollIndicator() }
    })
  }

  private var scrollIndicatorReading: PaletteCornerScrollIndicator.Reading? {
    indicatedScroll.flatMap(PaletteCornerScrollIndicator.reading(of:))
  }

  /// Puts the thumb where the shown scroll stands, on the shell as it is
  /// drawn this frame; takes it away where there is nothing to scroll.
  ///
  /// **In the history it lives inside the list's scroll view**: the fade
  /// and the blur the rows dissolve through under the
  /// tabs are on that view's layer, so a thumb drawn there runs up under
  /// the tabs and goes soft with the rows. Its track starts at the scroll
  /// view's top, inside that band, and only the foot bends. In a chat it
  /// stands over the shell, round both corners.
  private func syncScrollIndicator() {
    guard let shell = scrollIndicatorShell, shell.rect.width > 1,
          let scroll = indicatedScroll,
          let reading = PaletteCornerScrollIndicator.reading(of: scroll)
    else {
      scrollIndicator.conceal(animated: false)
      return
    }
    let host: NSView = scroll === resultsScroll ? resultsScroll : self
    if scrollIndicator.superview !== host {
      scrollIndicator.removeFromSuperview()
      host.addSubview(scrollIndicator, positioned: .above, relativeTo: nil)
    }
    if scrollIndicator.frame != host.bounds { scrollIndicator.frame = host.bounds }
    let rect = host === self ? shell.rect : scrollIndicator.convert(shell.rect, from: self)
    let clearance = host === self ? 0 : max(0, rect.maxY - scrollIndicator.bounds.maxY)
    scrollIndicator.place(in: rect, corner: shell.corner, reading: reading, topClearance: clearance)
  }

  /// Puts the grabber in the corner of the shell as it is drawn this frame.
  private func layoutResizeGrabber(in rect: CGRect, corner: CGFloat) {
    let shows = resizableShell != nil && rect.width > 1
    resizeGrabber.isHidden = !shows
    guard shows else { return }
    resizeGrabber.frame = bounds
    resizeGrabber.place(in: rect, corner: corner)
  }

  /// The error sits under the palette's bottom edge, whatever that currently
  /// is: the switcher while it is open, the prompt otherwise — including while
  /// addressing, where the card is above the prompt rather than below it.
  private func anchorErrorLabel() {
    anchorNotice()
    errorTopToPreviewConstraint.isActive = false
    errorTopToResultsConstraint.isActive = false
    errorTopToPromptConstraint.isActive = false
    if addressedPreview != nil {
      errorTopToPromptConstraint.isActive = true
    } else if isResultsExpanded {
      errorTopToResultsConstraint.isActive = true
    } else {
      errorTopToPromptConstraint.isActive = true
    }
  }

  /// The notice under the shell's foot — the prompt, or the list while it is
  /// open — or, in an open chat, over the transcript above the composer: the
  /// chat's foot is the composer, and under it is outside the shell.
  private func anchorNotice() {
    let inChat = addressedPreview != nil
    let wanted = inChat ? noticeAboveComposer
      : isResultsExpanded ? noticeTopToResults : noticeTopToPrompt
    // Runs inside layout: a constraint switched off and on again on every
    // pass would ask for another pass, for ever.
    guard !wanted.isActive else { return }
    for constraint in [noticeTopToPrompt, noticeTopToResults, noticeAboveComposer]
    where constraint !== wanted {
      constraint.isActive = false
    }
    wanted.isActive = true
  }

  /// Empty glass is the rest of the screen. A click there is "go away", not
  /// a drag of an invisible window.
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let edges = resizeEdges(at: point), let shell = resizableShell {
      beginResize(edges: edges, shell: shell, at: point)
      return
    }
    // A press that just missed a grip is not a request to go away.
    if isNearShellEdge(point) { return }
    guard isEmptyGlass(point) else {
      super.mouseDown(with: event)
      return
    }
    if screenSelectionPhase == .editing {
      editScreenSelection(from: point)
      return
    }
    guard acceptsScreenSelection else {
      onCancel?()
      return
    }
    trackScreenSelection(from: point)
  }

  /// Whether `point` is the rest of the screen rather than Boltty AI: not
  /// the shell, not a card standing off it, not the bloom of its rim — a
  /// click on the bloom is still a click on Boltty AI, not on the empty
  /// glass that hides it.
  private func isEmptyGlass(_ point: NSPoint) -> Bool {
    if surfaceFrame.contains(point) { return false }
    if isVoiceGlowActive, voiceGlow.frame.contains(point) { return false }
    if !previewCapsule.isHidden, previewCapsule.frame.contains(point) { return false }
    if isResultsExpanded, !resultsCapsule.isHidden, resultsCapsule.frame.contains(point) {
      return false
    }
    if !notice.isHidden, notice.frame.contains(point) { return false }
    return true
  }

  // MARK: - Selecting the screen

  /// Asking about a region of the screen, after macOS 27's "Ask Siri about
  /// selected area": a drag on the empty glass
  /// freezes and dims the screen, the region's border wears the agent's
  /// mascot gradient, and on the first screen the shell stands beside it.
  enum ScreenSelectionPhase: Equatable {
    case idle
    /// The region is being dragged out; the shell is out of the way.
    case drawing
    /// The region is drawn and the shell stands beside it; its handles move
    /// and resize it. The first screen only — in a chat it becomes a chip.
    case editing
  }

  private(set) var screenSelectionPhase: ScreenSelectionPhase = .idle {
    didSet { if screenSelectionPhase != oldValue { needsLayout = true } }
  }
  /// The region in global screen coordinates: the window grows to the whole
  /// screen once a drag begins, so view coordinates would move under it.
  private var screenSelectionGlobal: CGRect?
  /// The frozen screen and its frame, global screen coordinates.
  private var frozenScreenGlobal: (image: CGImage, frame: CGRect)?
  /// The phase the shell was last placed for — a change of phase moves it
  /// without the spring, which would fly it across the screen.
  private var placedPhase: ScreenSelectionPhase = .idle

  /// Where the region being asked about stands, while the shell is beside it.
  var screenSelectionFrame: CGRect? {
    screenSelectionPhase == .editing ? screenSelectionGlobal : nil
  }

  /// Whether a press on the empty glass may become a region of the screen:
  /// only on the first screen — never in an open chat — with no list, pill
  /// or take up. Whatever the agent: one that cannot see pictures is handed
  /// the text read off the region (`PromptExpansion`).
  private var acceptsScreenSelection: Bool {
    onScreenSelectionBegan != nil && mode == .prompt && addressedPreview == nil
      && !isVoiceListening && !showsCompactListening
      && !isResultsExpanded
  }

  /// Follows a press on the empty glass to its release. Moved past
  /// `screenSelectionDragThreshold` it draws a region; otherwise it was a
  /// click, which puts the panel away — or, over a region already drawn,
  /// lets go of that region.
  private func trackScreenSelection(from start: CGPoint, replacing: Bool = false) {
    guard let window else {
      onCancel?()
      return
    }
    let origin = window.convertPoint(toScreen: convert(start, to: nil))
    var isDrag = false
    while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      let here = NSEvent.mouseLocation
      if !isDrag, hypot(here.x - origin.x, here.y - origin.y)
        >= AgentPaletteMetrics.screenSelectionDragThreshold {
        isDrag = true
        beginScreenDrawing()
      }
      // Refused when it began (no Screen Recording): the press runs out to
      // its release and draws nothing.
      if isDrag, screenSelectionPhase == .drawing {
        screenSelectionGlobal = clampedToScreen(Self.region(from: origin, to: here))
        syncSelectionOverlay()
      }
      if event.type == .leftMouseUp { break }
    }
    guard isDrag else {
      if replacing { cancelScreenSelection() } else { onCancel?() }
      return
    }
    finishScreenDrawing()
  }

  /// Over a drawn region: a handle resizes it, inside moves it, outside draws
  /// a new one (or, with no drag, lets it go).
  private func editScreenSelection(from point: CGPoint) {
    guard let window, let region = screenSelectionGlobal else { return }
    let handle = screenOutlines.handle(at: point)
    let inside = convert(window.convertFromScreen(region), from: nil).contains(point)
    guard handle != nil || inside else {
      trackScreenSelection(from: point, replacing: true)
      return
    }
    let origin = NSEvent.mouseLocation
    let minimum = AgentPaletteMetrics.screenSelectionMinimumSide
    heldCursor = handle.map { NSCursor.frameResize(position: $0.resizePosition, directions: .all) }
    heldCursor.map(wear)
    defer {
      heldCursor = nil
      syncPointerWhereItIs()
    }
    while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      let here = NSEvent.mouseLocation
      if let handle {
        screenSelectionGlobal = clampedToScreen(handle.resizing(region, to: here, minimum: minimum))
      } else {
        screenSelectionGlobal = movedOnScreen(region.offsetBy(dx: here.x - origin.x, dy: here.y - origin.y))
      }
      syncSelectionOverlay()
      needsLayout = true
      if event.type == .leftMouseUp { break }
    }
  }

  private func beginScreenDrawing() {
    PaletteHelpPresenter.shared.dismiss()
    hideNotice()
    screenSelectionPhase = .drawing
    screenOutlines.showsHandles = false
    screenOutlines.isDimmed = true
    onScreenSelectionBegan?()
  }

  private func finishScreenDrawing() {
    let minimum = AgentPaletteMetrics.screenSelectionMinimumSide
    guard screenSelectionPhase == .drawing, let region = screenSelectionGlobal,
          region.width >= minimum, region.height >= minimum else {
      cancelScreenSelection()
      return
    }
    if addressedPreview != nil {
      // A chat keeps its card: the region becomes a chip in its composer,
      // and the screen comes back once it has (`endScreenSelection`).
      onScreenRegionSelected?(region)
      return
    }
    screenSelectionPhase = .editing
    screenOutlines.showsHandles = true
    syncSelectionOverlay()
    syncPointerWhereItIs()
    _ = focusField()
  }

  private static func region(from start: CGPoint, to end: CGPoint) -> CGRect {
    CGRect(
      x: min(start.x, end.x), y: min(start.y, end.y),
      width: abs(end.x - start.x), height: abs(end.y - start.y)
    )
  }

  /// `rect` cut to the screen the panel is on.
  private func clampedToScreen(_ rect: CGRect) -> CGRect {
    guard let screen = window?.screen?.frame else { return rect }
    return rect.intersection(screen)
  }

  /// `rect` kept whole on the screen the panel is on.
  private func movedOnScreen(_ rect: CGRect) -> CGRect {
    guard let screen = window?.screen?.frame else { return rect }
    var moved = rect
    moved.origin.x = min(max(rect.minX, screen.minX), screen.maxX - rect.width)
    moved.origin.y = min(max(rect.minY, screen.minY), screen.maxY - rect.height)
    return moved
  }

  /// The frozen screen, under the region while it is asked about. `frame` is
  /// the display's, in global screen coordinates.
  func showFrozenScreen(_ image: CGImage, frame: CGRect) {
    guard screenSelectionPhase != .idle else { return }
    frozenScreenGlobal = (image, frame)
    syncSelectionOverlay()
  }

  /// In a chat, the region as a chip at the caret.
  func insertScreenSelection(_ selection: ScreenSelection) {
    let chip = PromptAttachment(
      kind: .image,
      payload: .screen(selection),
      label: field.draft.nextGeneratedLabel(for: .image)
    )
    applyIngest(.attachments([chip]))
  }

  /// Escape, a click off the region, or a refusal: the screen is the screen
  /// again and the shell goes back under the notch.
  func cancelScreenSelection() {
    guard screenSelectionPhase != .idle else { return }
    endScreenSelection()
    onScreenSelectionCancelled?()
  }

  /// Done with the region — sent with the prompt, or put in a chat as a chip.
  func endScreenSelection() {
    screenSelectionPhase = .idle
    screenSelectionGlobal = nil
    frozenScreenGlobal = nil
    screenOutlines.showsHandles = false
    screenOutlines.isDimmed = false
    screenOutlines.selection = nil
    screenOutlines.frozen = nil
    syncScreenOutlines()
    syncPointerWhereItIs()
  }

  /// The border's colours: the agent's mascot gradient, lifted to read on
  /// the dim — the chat's agent in a chat, the face on the prompt otherwise.
  private var selectionPalette: [NSColor] {
    // The agent's own face, not the mark's: the mark swaps through a
    // crossfade, and read off it the border kept the agent Tab had left.
    let look = addressedPreview.map { MascotLook.face(for: $0.agent) }
      ?? MascotLook.face(for: agentForNewPrompt)
    return look.palette.light(atLeast: AgentPaletteMetrics.screenSelectionLightness)
  }

  private func syncSelectionOverlay() {
    guard let window else { return }
    func local(_ rect: CGRect) -> CGRect { convert(window.convertFromScreen(rect), from: nil) }
    screenOutlines.palette = selectionPalette
    screenOutlines.selection = screenSelectionGlobal.map(local)
    screenOutlines.frozen = frozenScreenGlobal.map { (image: $0.image, frame: local($0.frame)) }
  }

  /// Where the shell stands while a region is asked about: out of the way
  /// while it is drawn, beside it once it is — to its right, else its left,
  /// else under or over it — and inside the screen whatever the region.
  /// `top` is from the view's top; `offset` from its centre.
  private var shellAnchor: (top: CGFloat, offset: CGFloat)? {
    switch screenSelectionPhase {
    case .idle:
      return nil
    case .drawing:
      return (top: -bounds.height, offset: 0)
    case .editing:
      guard let window, let global = screenSelectionGlobal else { return nil }
      let region = convert(window.convertFromScreen(global), from: nil)
      let width = AgentPaletteMetrics.promptSize.width
      let height = promptCapsuleHeightConstraint.constant
      let gap = AgentPaletteMetrics.screenSelectionShellGap
      let highest = bounds.height - topReserve - gap
      var left: CGFloat
      var shellTop = region.maxY
      if region.maxX + gap + width <= bounds.maxX - gap {
        left = region.maxX + gap
      } else if region.minX - gap - width >= bounds.minX + gap {
        left = region.minX - gap - width
      } else {
        left = min(max(region.midX - width / 2, bounds.minX + gap), bounds.maxX - gap - width)
        shellTop = region.minY - gap >= height + gap
          ? region.minY - gap
          : region.maxY + gap + height
      }
      left = max(left, bounds.minX + gap)
      shellTop = min(max(shellTop, height + gap), highest)
      return (top: bounds.height - shellTop, offset: left + width / 2 - bounds.midX)
    }
  }

  /// One border per screen chip in the draft, where it was taken.
  private func syncScreenOutlines() {
    outlinedWindowFrame = window?.frame
    guard let window else {
      screenOutlines.outlines = []
      return
    }
    screenOutlines.palette = selectionPalette
    screenOutlines.outlines = field.draft.attachments.compactMap { attachment in
      guard case let .screen(selection) = attachment.payload else { return nil }
      return convert(window.convertFromScreen(selection.frame), from: nil)
    }
    syncSelectionOverlay()
  }

  /// The window frame the outlines were last placed against.
  private var outlinedWindowFrame: CGRect?

  var screenOutlinesForTesting: [CGRect] { screenOutlines.drawnRectsForTesting }
  var screenGlowRegionsForTesting: [CGRect] { screenOutlines.glowRegionsForTesting }
  var screenSelectionPaletteForTesting: [NSColor] { screenOutlines.palette }
  var screenSelectionHandleCountForTesting: Int { screenOutlines.handleCountForTesting }
  var isScreenFrozenForTesting: Bool { screenOutlines.isFrozenForTesting }
  var shellFrameForTesting: CGRect { surfaceFrame }
  func pointerCursorForTesting(at point: CGPoint) -> NSCursor? { pointerCursor(at: point) }
  /// A drag of `region` (this view's coordinates) on the empty glass, start
  /// to release.
  func selectScreenRegionForTesting(_ region: CGRect) {
    guard acceptsScreenSelection, let window else { return }
    beginScreenDrawing()
    guard screenSelectionPhase == .drawing else { return }
    screenSelectionGlobal = window.convertToScreen(convert(region, to: nil))
    syncSelectionOverlay()
    finishScreenDrawing()
  }
  func pressEscapeForTesting() {
    _ = textView(field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
  }

  // MARK: - The drip

  /// **The shell itself drips out of the notch** — its own glass, with
  /// everything on it, not a separate drop. It is put down as a seed tucked
  /// into `source` (the notch, in this view's space, where the camera
  /// housing hides it), falls on the shell's own spring at
  /// `dripFallResponse`, and `dripSpreadAfter` into the fall is retargeted
  /// into its frame — a retargeted spring keeps its speed, so the fall turns
  /// into the spread with no jolt. Everything on the shell is clipped to it
  /// every frame (`drawSurface`) and fades in as it spreads. No neck: the
  /// shell's glass cannot stand in a glass container (see `setup`).
  func beginDrip(from source: CGRect) {
    layoutSubtreeIfNeeded()
    let shell = resizeTarget
    guard !shell.isEmpty, !MotionPreferences.reduceMotion else { return }
    dripRun += 1
    let run = dripRun
    let stations = PaletteDrip.stations(source: source, shell: shell)
    surfaceMotion.response = AgentPaletteMetrics.dripFallResponse
    dripTarget = stations.fallen
    _ = surfaceMotion.move(to: stations.seed, in: self, animated: false)
    _ = surfaceMotion.move(to: stations.fallen, in: self, animated: true)
    fadeShellContent(in: true)
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Motion.scaled(AgentPaletteMetrics.dripSpreadAfter)
    ) { [weak self] in
      guard let self, self.dripRun == run else { return }
      self.dripTarget = nil
      self.surfaceMotion.response = AgentPaletteMetrics.dripSpreadResponse
      self.needsLayout = true
      self.layoutSubtreeIfNeeded()
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Motion.scaled(AgentPaletteMetrics.dripInDuration)
    ) { [weak self] in
      guard let self, self.dripRun == run else { return }
      self.surfaceMotion.response = AgentPaletteMetrics.surfaceResponse
    }
  }

  /// The drip backwards: everything on the shell fades, and the shell
  /// shrinks to the drop it fell as and rises back into `source`. The
  /// controller puts the panel away once `dripOutDuration` has passed.
  func beginDripOut(into source: CGRect) {
    let shell = resizeTarget
    guard !shell.isEmpty, !MotionPreferences.reduceMotion else { return }
    dripRun += 1
    let run = dripRun
    let stations = PaletteDrip.stations(source: source, shell: shell)
    fadeShellContent(in: false)
    surfaceMotion.response = AgentPaletteMetrics.dripShrinkResponse
    dripTarget = stations.fallen
    _ = surfaceMotion.move(to: stations.fallen, in: self, animated: true)
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Motion.scaled(AgentPaletteMetrics.dripRiseAfter)
    ) { [weak self] in
      guard let self, self.dripRun == run else { return }
      self.surfaceMotion.response = AgentPaletteMetrics.dripRiseResponse
      self.dripTarget = stations.seed
      _ = self.surfaceMotion.move(to: stations.seed, in: self, animated: true)
    }
  }

  /// Back to a shell standing in its own frame, with nothing of a drip left
  /// on it — after a drip out, and before anything settles the shell.
  func endDrip() {
    dripRun += 1
    let wasDripping = dripTarget != nil
    dripTarget = nil
    surfaceMotion.response = AgentPaletteMetrics.surfaceResponse
    for view in shellContentViews { view.layer?.removeAnimation(forKey: Self.dripFadeKey) }
    if wasDripping { needsLayout = true }
  }

  var isDrippingForTesting: Bool { dripTarget != nil }

  private static let dripFadeKey = "boltty.drip.fade"

  /// What stands on the shell: every view of the panel but the glass.
  private var shellContentViews: [NSView] { subviews.filter { $0 !== surfaceContainer } }

  /// Everything on the shell fades in as the drop spreads, or out as it
  /// leaves — scheduled in Core Animation's time, so a busy main thread
  /// cannot hold it back.
  private func fadeShellContent(in arriving: Bool) {
    for view in shellContentViews {
      guard let layer = view.layer else { continue }
      layer.removeAnimation(forKey: Self.dripFadeKey)
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = arriving ? 0 : 1
      fade.toValue = arriving ? 1 : 0
      fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        + (arriving ? AgentPaletteMetrics.dripContentInAfter : 0)
      fade.duration = arriving ? AgentPaletteMetrics.dripContentInDuration : Motion.quick
      fade.timingFunction = Motion.standardCurve
      fade.fillMode = arriving ? .backwards : .forwards
      fade.isRemovedOnCompletion = arriving
      layer.add(fade, forKey: Self.dripFadeKey)
    }
  }

  /// The geometry each capsule's shadow was last built for.
  ///
  /// `layout` runs far more often than the shadow changes — every wrapping
  /// keystroke, every resize of the list, every preview tick — and rebuilding a
  /// `CGPath` plus eight layer writes each time is work for an answer that is
  /// almost always the one already installed. Keyed by the capsule, because the
  /// prompt and the card move independently.
  private var shadowGeometry: [ObjectIdentifier: (bounds: CGRect, radius: CGFloat)] = [:]

  /// Spotlight/Raycast-style ambient elevation under each capsule.
  /// Applied on the capsule (not PaletteGlassHost) so glass material cannot suppress it.
  private func applyFloatingShadow(to view: NSView, cornerRadius: CGFloat) {
    view.wantsLayer = true
    guard let layer = view.layer else { return }

    // The same rule the card itself uses, or the silhouette behind it and the
    // card are two shapes a few points apart — which is what a crooked edge is.
    let cornerCurve = AgentPaletteMetrics.cornerCurve(
      radius: cornerRadius,
      shorterSide: min(view.bounds.width, view.bounds.height)
    )
    let key = ObjectIdentifier(view)
    if let last = shadowGeometry[key],
       last.radius == cornerRadius,
       last.bounds == view.bounds,
       layer.cornerCurve == cornerCurve {
      return
    }
    shadowGeometry[key] = (view.bounds, cornerRadius)

    layer.masksToBounds = false
    layer.cornerRadius = cornerRadius
    layer.cornerCurve = cornerCurve
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOpacity = PaletteGlassHost.floatingShadowOpacity
    layer.shadowRadius = PaletteGlassHost.floatingShadowRadius
    layer.shadowOffset = PaletteGlassHost.floatingShadowOffset
    // **An explicit path, always** — `nil` is not the harmless fallback it
    // looks like. With no path Core Animation derives the shadow from the
    // composited alpha of the subtree, which rasterizes this layer; and these
    // capsules are *ancestors of the glass*, so that pass would strip
    // `NSGlassEffectView` of the backdrop it samples and collapse it to opaque
    // black. The empty-bounds case is the one exception, because there is
    // nothing to render into a path yet.
    //
    // The path is circular even where `cornerCurve` is `.continuous`:
    // `CGPath(roundedRect:)` has no squircle. That residual is a couple of
    // points along the wall, well inside the 13.4pt blur, and buying it back
    // would mean hand-rolling a superellipse — a cost worth paying only if it
    // ever becomes visible.
    if view.bounds.isEmpty {
      layer.shadowPath = nil
    } else {
      layer.shadowPath = CGPath(
        roundedRect: view.bounds,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
      )
    }
    if view === surfaceContainer { applyAmbientShadow(in: layer, cornerRadius: cornerRadius) }
  }

  /// The shell's second, broad shadow: the one a Mac window casts.
  ///
  /// The contact shadow above is tight — 13.4 with almost no fall — and on
  /// its own the shell reads as having none. A window's is two: that edge,
  /// and a wide
  /// soft pool cast downward. This is the pool, a sublayer of the shell's
  /// container behind the glass — a sibling of the glass, never its
  /// ancestor — with the shell's own shape cut out of it, so it falls
  /// around the shell and never darkens the glass from inside.
  private let ambientShadow = CALayer()
  private let ambientShadowCutout = CAShapeLayer()

  private func applyAmbientShadow(in container: CALayer, cornerRadius: CGFloat) {
    if ambientShadow.superlayer !== container {
      ambientShadow.shadowColor = NSColor.black.cgColor
      ambientShadow.shadowOpacity = PaletteGlassHost.ambientShadowOpacity
      ambientShadow.shadowRadius = PaletteGlassHost.ambientShadowRadius
      ambientShadow.shadowOffset = PaletteGlassHost.ambientShadowOffset
      ambientShadow.zPosition = -1
      ambientShadowCutout.fillRule = .evenOdd
      ambientShadow.mask = ambientShadowCutout
      container.insertSublayer(ambientShadow, at: 0)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let bounds = container.bounds
    guard !bounds.isEmpty else {
      ambientShadow.shadowPath = nil
      return
    }
    let shape = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ambientShadow.frame = bounds
    ambientShadow.shadowPath = shape
    // Everything the blur can reach, less the shell itself.
    let reach = PaletteGlassHost.ambientShadowRadius * 3 + abs(PaletteGlassHost.ambientShadowOffset.height)
    let cutout = CGMutablePath()
    cutout.addRect(bounds.insetBy(dx: -reach, dy: -reach))
    cutout.addPath(shape)
    ambientShadowCutout.frame = bounds
    ambientShadowCutout.path = cutout
  }

  /// The reserved state geometry, notices and transparent shadow bleed.
  /// The controller uses a full-screen panel; this also serves offscreen hosts.
  override var fittingSize: NSSize {
    let base = AgentPaletteMetrics.panelSize()
    var extraHeight = max(
      0,
      promptCapsuleHeightConstraint.constant - AgentPaletteMetrics.promptSize.height
    )
    if addressedPreview != nil {
      extraHeight += AgentPaletteMetrics.resultsTopSpacing
      extraHeight += previewHeightConstraint.constant
      extraHeight += AgentPaletteMetrics.resultsShadowBleed
    } else if isResultsExpanded {
      extraHeight += AgentPaletteMetrics.resultsTopSpacing
      extraHeight += resultsHeightConstraint.constant
      // Room for the card's drop shadow to fall off instead of being clipped by
      // the panel edge. Transparent, and the panel grows downwards.
      extraHeight += AgentPaletteMetrics.resultsShadowBleed
    }
    if !routingRow.isHidden {
      extraHeight += AgentPaletteMetrics.errorTopSpacing
        + max(bottomBar.fittingSize.height, AgentPaletteMetrics.errorMinimumHeight)
    }
    if !notice.isHidden, addressedPreview == nil {
      extraHeight += AgentPaletteMetrics.noticeShellSpacing + notice.fittingSize.height
    }
    return CGSize(width: base.width, height: base.height + extraHeight)
  }



  /// Switches a wrapped draft to its scrolling layout inside the fixed shell.
  /// The chat composer can grow within that reserved space.
  ///
  /// Expand once per draft. No animated width/font interpolation on a live
  /// editor: it reflows each glyph at every frame and moves the insertion point.
  private func syncPromptExpansion() {
    isDraftExpanded = !field.isEmptyPrompt && (isDraftExpanded || field.wrapsBeyondOneLine)
    let expanded = isDraftExpanded || isOpenChat
    guard expanded != isPromptExpanded else { return }
    isPromptExpanded = expanded
    NSLayoutConstraint.deactivate(expanded ? inlineControlConstraints : expandedPromptConstraints)
    NSLayoutConstraint.activate(expanded ? expandedPromptConstraints : inlineControlConstraints)
    field.setExpandedStyle(expanded)
    syncPromptHeight()
    layoutSubtreeIfNeeded()
    syncPromptHeight()
    layoutSubtreeIfNeeded()
    field.scrollRangeToVisible(field.selectedRange())
  }

  /// TextKit can report a height while its ancestor is still in AppKit's
  /// layout transaction. Re-entering layout from that callback is illegal;
  /// one coalesced measurement on the next main-loop turn reaches the same
  /// final geometry without nesting layout passes.
  private func schedulePromptRemeasure() {
    promptRemeasureWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.syncPromptExpansion()
      self?.syncPromptHeight()
    }
    promptRemeasureWorkItem = work
    DispatchQueue.main.async(execute: work)
  }

  /// Fades the prompt's text where it scrolls out of view.
  ///
  /// The same rule the reply card follows, and for the same reason: a hard clip
  /// through the middle of a line reads as a rendering fault rather than as
  /// more text. Both fades are a *maximum* — the first and last lines are never
  /// dimmed for no reason.
  private func refreshPromptEdgeFades() {
    let visible = promptScroll.documentVisibleRect
    let height = visible.height
    guard height > 0 else { return }

    guard field.isScrollable else {
      promptEdgeFadeMask.isHidden = true
      promptScroll.layer?.mask = nil
      return
    }

    let contentHeight = field.frame.height
    let maximum = PromptTextView.textOnlyLineHeight
    let scrolled = max(0, visible.minY)
    let remaining = max(0, contentHeight - height - scrolled)
    let top = min(min(maximum, scrolled) / height, 0.5)
    let bottom = min(min(maximum, remaining) / height, 0.5)

    let opaque = NSColor.black.cgColor
    let clear = NSColor.black.withAlphaComponent(0).cgColor

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    promptEdgeFadeMask.isHidden = false
    promptEdgeFadeMask.frame = promptScroll.bounds
    promptEdgeFadeMask.colors = [clear, opaque, opaque, clear]
    promptEdgeFadeMask.locations = [
      0,
      NSNumber(value: Double(top)),
      NSNumber(value: Double(1 - bottom)),
      1,
    ]
    promptScroll.layer?.mask = promptEdgeFadeMask
    CATransaction.commit()
  }

  private func syncPromptHeight() {
    guard updatePromptHeights() else { return }
    if addressedPreview != nil {
      previewBandHeight = reservedTranscriptHeight
    }
    refreshPromptEdgeFades()
    // Let the host settle the editor and scroll viewport before painting.
    onContentSizeChange?()
  }

  /// Writes the two height constants and says whether either moved.
  ///
  /// Split out so `layout` can re-measure without calling back out to the
  /// panel: a constant that changes already invalidates the layout, so AppKit
  /// runs another pass by itself, where `onContentSizeChange` from inside
  /// `layout` would re-enter it.
  @discardableResult
  private func updatePromptHeights() -> Bool {
    field.maximumViewportHeight = isOpenChat
      ? max(PromptTextView.lineHeight,
          chatSurfaceSize.height - AgentPaletteMetrics.previewMinHeight
            - AgentPaletteMetrics.surfaceStackSpacing - AgentPaletteMetrics.shellContentInset
            - (isPromptExpanded
                ? AgentPaletteMetrics.chatComposerGrownTextTop
                  + AgentPaletteMetrics.chatComposerGrownControlsBand
                : 0))
      : AgentPaletteMetrics.promptGrownMaximumHeight
    let textHeight = field.clampedContentHeight
    let extra = textHeight - PromptTextView.lineHeight
    let bottomControls = addressedPreview != nil && isPromptExpanded
    // The first screen's capsule grows with a wrapped draft
    // (`promptGrownInset`); one line keeps the resting 79.
    let capsuleHeight = !isOpenChat
      ? (isPromptExpanded
          ? max(AgentPaletteMetrics.promptSize.height, textHeight)
          : AgentPaletteMetrics.promptSize.height)
      : isPromptExpanded
        ? (bottomControls
            ? max(AgentPaletteMetrics.chatComposerBoxHeight,
                  AgentPaletteMetrics.chatComposerGrownTextTop + textHeight
                    + AgentPaletteMetrics.chatComposerGrownControlsBand)
            : textHeight)
        : AgentPaletteMetrics.chatComposerHeight + max(0, extra)

    guard abs(promptScrollHeightConstraint.constant - textHeight) > 0.5
      || abs(promptCapsuleHeightConstraint.constant - capsuleHeight) > 0.5
    else { return false }

    promptScrollHeightConstraint.constant = textHeight
    promptCapsuleHeightConstraint.constant = capsuleHeight
    return true
  }

  private func configureMicButton() {
    // Resting clip: the same action as the chat's, wearing the resting disc.
    attachRestSlot.translatesAutoresizingMaskIntoConstraints = false
    attachRestSlot.addSubview(attachRestDisc)
    attachRestDisc.button.target = self
    attachRestDisc.button.action = #selector(attachButtonPressed)
    attachRestDisc.button.toolTip = "Attach a file"
    attachRestDisc.setAccessibilityIdentifier("boltty.ask.attach")
    attachRestDisc.button.setAccessibilityIdentifier("boltty.ask.attach")
    attachRestDisc.button.setAccessibilityLabel("Attach a file")
    attachRestDisc.isHidden = true
    NSLayoutConstraint.activate([
      attachRestWidth,
      attachRestDisc.centerXAnchor.constraint(equalTo: attachRestSlot.centerXAnchor),
      attachRestDisc.centerYAnchor.constraint(equalTo: attachRestSlot.centerYAnchor),
      attachRestSlot.heightAnchor.constraint(equalTo: attachRestDisc.heightAnchor),
    ])

    micButton.translatesAutoresizingMaskIntoConstraints = false
    // **The bezel is the button's own** (`setShowsGlass`). Setting
    // `isBordered = false` or `.regularSquare` here makes the button believe
    // it is already at rest, so the first `setShowsGlass(false)` returns
    // before it puts the `mic` glyph up and the bars stay on screen.
    micButton.imagePosition = .imageOnly
    // The symbol is already rendered at its final point size; letting AppKit
    // scale it would reintroduce a fractional offset.
    micButton.imageScaling = .scaleNone
    micButton.setButtonType(.momentaryChange)
    micButton.setContentHuggingPriority(.required, for: .horizontal)
    micButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    micButton.setAccessibilityIdentifier("boltty.ask.mic")
    micButton.target = self
    micButton.action = #selector(micButtonPressed)
    // No image: `GlassCircleVoiceButton` draws its own bars, because an SF Symbol is
    // one fixed picture of sound and these have to answer the microphone
    // individually. Setting an image here would draw a second waveform on top
    // of the real one.
  }

  /// Idle vs listening: tint, help tag, and the label VoiceOver reads.
  private func applyMicAppearance() {
    micButton.setListening(isVoiceListening)
    // Glass and bars only while it listens; at rest, in the prompt and in a
    // chat alike, it is the bare `mic` glyph.
    micButton.setShowsGlass(isVoiceListening)
    micButton.isEnabled = !isVoiceProcessing
    micButton.toolTip = isVoiceProcessing ? "Processing recording…" : isVoiceListening
      ? "Listening — hover for controls"
      : "Dictate prompt"
    micButton.setAccessibilityLabel(isVoiceProcessing ? "Processing recording" : isVoiceListening ? "Listening" : "Dictate prompt")
    micButton.setAccessibilityValue(isVoiceProcessing ? "Processing" : isVoiceListening ? "Listening" : "Idle")
    if isVoiceListening {
      micButton.setAccessibilityCustomActions([
        NSAccessibilityCustomAction(name: "Cancel dictation") { [weak self] in
          self?.onVoiceCancel?()
          return true
        },
        NSAccessibilityCustomAction(name: "Send dictation") { [weak self] in
          self?.onVoiceConfirm?()
          return true
        },
      ])
    } else {
      micButton.setAccessibilityCustomActions(nil)
    }
  }

  /// Whether this agent can be sent a file at all. Hidden rather than
  /// disabled: a greyed paperclip invites a click and then explains itself,
  /// and there is nothing here to explain — this agent simply does not read
  /// files.
  func setAcceptsAttachments(_ accepts: Bool) {
    guard acceptsAttachments != accepts else { return }
    acceptsAttachments = accepts
    applyAttachPlacement()
    needsLayout = true
  }

  /// Whether the + stands, and how wide its slot is.
  ///
  /// One place rather than three, because the answer depends on two things at
  /// once — whether the agent reads files, and whether the shell is a chat —
  /// and splitting it is how a hidden control keeps its gap. The initial
  /// prompt and the chat draw the same bare glyph.
  private func applyAttachPlacement() {
    // Only in a chat: the first screen carries ring, folder and microphone.
    // A drop or a paste still attaches there.
    let showsRest = acceptsAttachments && composerGlyphsAreChat
    attachRestDisc.isHidden = !showsRest
    attachRestDisc.diameter = composerControlDiameter
    attachRestWidth.constant = showsRest ? composerControlDiameter : 0
  }

  /// One width calculation for the icons sharing the field: folder, plan,
  /// optional attachment, microphone and (in a chat) Send. Hidden slots give
  /// their width and following gap back to the editor.
  /// The room the words leave beside the controls, **as the controls stand
  /// at rest** — whatever recording spreads them to.
  ///
  /// Recording swaps the microphone for its 44 disc, moves the row to the
  /// recording gutter and hides Send, but the words keep rest's width, so a
  /// take neither starts nor ends by rewrapping the draft; while a take runs
  /// the first line can reach under the spread glyphs. With nothing to read
  /// the ring has no slot.
  private func restingEditorTrailing(chat: Bool) -> CGFloat {
    let inset = chat
      ? AgentPaletteMetrics.chatComposerControlsTrailingInset
      : AgentPaletteMetrics.restingControlsTrailingInset
    let gap = AgentPaletteMetrics.restingControlsSpacing
    let target = composerControlDiameter
    let folder = directorySlotWidth.constant == 0 ? 0 : directorySlotWidth.constant + gap
    let plan = planRing.hasReading ? target + gap : 0
    let autoMode = autoModeWidth.constant == 0 ? 0 : target + gap
    // Send stands at rest wherever the glyphs are a chat's (`syncSendButton`).
    let send = composerIsUp && composerGlyphsAreChat ? target + gap : 0
    let words = chat
      ? AgentPaletteMetrics.chatComposerTextControlsGap
      : AgentPaletteMetrics.promptMicTextSpacing
    return inset + folder + plan + autoMode + target + send + words
  }

  var attachControlFrameInPaletteForTesting: CGRect { convert(attachRestDisc.bounds, from: attachRestDisc) }
  var voiceControlFrameInPaletteForTesting: CGRect { convert(micButton.bounds, from: micButton) }

  var isAttachVisibleForTesting: Bool { !attachRestDisc.isHidden }
  var isAttachDiscVisibleForTesting: Bool { !attachRestDisc.isHidden }
  func pressAttachForTesting() { attachButtonPressed() }

  @objc private func attachButtonPressed() { onChooseAttachments?() }

  /// Puts chosen files into the draft by the same route a drop takes.
  func appendAttachments(_ urls: [URL]) {
    applyIngest(PasteboardIngest.attachments(for: urls, into: field.draft))
  }

  @objc private func micButtonPressed() {
    // The disc is a toggle only while idle. Once it is listening, ✕ and ✓
    // are the two ways out, and they live on the hover pill — a click on the
    // disc just reveals that pill rather than stopping the session.
    if isVoiceListening {
      setRecordingControlsRevealed(true, animated: true)
      return
    }
    onVoiceToggle?()
  }

  /// Compact disc while speaking; the full pill only under the pointer.
  private func setRecordingControlsRevealed(_ revealed: Bool, animated: Bool) {
    let show = revealed && isVoiceListening
    guard show != isRecordingControlsRevealed else { return }
    isRecordingControlsRevealed = show
    applyRecordingControlsVisibility(show, animated: animated)
  }

  private func applyRecordingControlsVisibility(_ revealed: Bool, animated: Bool) {
    if revealed {
      recordingControls.isHidden = false
      micButton.isHidden = false
    }
    let changes = {
      self.recordingControls.alphaValue = revealed ? 1 : 0
      self.micButton.alphaValue = revealed ? 0 : 1
    }
    // `@Sendable` because that is what `runAnimationGroup` takes. The body is
    // still main-actor work either way — Core Animation calls the completion
    // back on the thread the group ran on — so `assumeIsolated` states the fact
    // rather than deferring the hide into a later turn, where a second toggle
    // could already have landed.
    let finish: @Sendable () -> Void = { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.recordingControls.isHidden = !revealed
        self.micButton.isHidden = revealed && self.isVoiceListening
        if !self.isVoiceListening {
          self.micButton.alphaValue = 1
          self.micButton.isHidden = false
        }
      }
    }
    if animated, !MotionPreferences.reduceMotion {
      NSAnimationContext.runAnimationGroup(
        { context in
          context.duration = AgentPaletteMetrics.hoverFadeDuration
          context.timingFunction = Motion.standardCurve
          context.allowsImplicitAnimation = true
          changes()
        },
        completionHandler: finish
      )
    } else {
      changes()
      finish()
    }
  }
}

extension AgentPaletteView: NSTextViewDelegate {
  func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                replacementString: String?) -> Bool {
    // Space on a Tab-chosen icon presses it, the way Spotlight presses the
    // microphone. Anything else typed there goes into the words, and the
    // icon lets go so the caret comes back.
    if composerKeyTarget != .text {
      if replacementString == " " {
        activateComposerKeyTarget()
        return false
      }
      setComposerKeyTarget(.text)
    }
    // An empty composer lets Space toggle multiple choices. Once a written
    // answer has started, every space belongs to that answer as usual.
    if replacementString == " ", field.isEmptyPrompt, addressedPreview != nil,
       previewCard.toggleFocusedOption() { return false }
    // A digit on an empty composer answers by number where the question
    // takes no typed answer (`AgentQuestion.answersByNumber`) — Claude
    // Code's 1, 2, 3. Anywhere else it is the first letter of the reply.
    if let typed = replacementString, typed.count == 1, let number = Int(typed), number > 0,
       field.isEmptyPrompt, addressedPreview != nil,
       previewCard.chooseOption(number: number) { return false }
    return true
  }

  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    let isTab = commandSelector == #selector(insertTab(_:))
    let isBacktab = commandSelector == #selector(insertBacktab(_:))
    // Any other key leaves the icon and comes back to the words. Tab and
    // ⇧Tab are the two that stay on it — ⇧Tab changes the agent and leaves
    // the icon where it is.
    if !isTab, !isBacktab, composerKeyTarget != .text {
      setComposerKeyTarget(.text)
    }
    // ←/→ walk the agent tabs while the history is up. Only there: in a search
    // the field holds words and the arrows move the caret through them, and
    // over the install hints there is no strip to walk.
    if commandSelector == #selector(moveLeft(_:)) || commandSelector == #selector(moveRight(_:)) {
      guard addressedPreview == nil, isResultsExpanded, mode == .picking,
            !isShowingInstallHints, field.isEmptyPrompt else { return false }
      stepHistoryTab(by: commandSelector == #selector(moveLeft(_:)) ? -1 : 1)
      return true
    }
    if commandSelector == #selector(moveDown(_:)) {
      // Rows first: while the agent is waiting for an answer, ↓ is how you get
      // to it. Only then the old rule.
      if addressedPreview != nil, previewCard.isAnswering,
         previewCard.moveOptionFocus(by: 1) { return true }
      // The card is the surface now; ↓ must not summon the switcher underneath
      // it, which left the list and the reply on screen at once with no way to
      // tell which one Enter was aimed at. Handed to the text view so a
      // multi-line reply still navigates.
      if addressedPreview != nil { return false }
      if !isResultsExpanded {
        openSwitcher()
      } else {
        moveResultSelection(by: 1)
      }
      return true
    }
    if commandSelector == #selector(moveUp(_:)) {
      // ↑ goes back the way ↓ came: out of the card, into the list it was
      // picked from. Same destination as Escape, because they are the same
      // gesture — leaving. From anywhere but the top line it is still an
      // editing key, and moves inside the reply.
      if addressedPreview != nil {
        // Inside the rows, ↑ walks back up them. Past the first one it means
        // what it has always meant here — leaving.
        if previewCard.isAnswering, previewCard.focusedOptionIndex > 0 {
          previewCard.moveOptionFocus(by: -1)
          return true
        }
        guard field.isCaretOnFirstLine else { return false }
        leaveAddressing(animated: true)
        openSwitcher()
        return true
      }
      if isResultsExpanded {
        if selectedResultIndex <= 0 {
          // ↑ past the first row leaves the switcher the way ↓ entered it.
          //
          // Collapsing alone was not enough, and left no way back: `mode` stayed
          // `.search`, so the capsule kept the magnifier and "Search sessions"
          // with no list under it, ↓ refused to reopen (`enterSearchMode` guards
          // on `.prompt`), and Enter took the search branch with nothing
          // selected — the palette was stuck, and nothing on screen said why.
          // Only a backspace on empty text could recover it.
          if mode != .prompt {
            closeSwitcher()
          } else {
            // Install hints: informational, not a mode. Nothing to leave.
            collapseResults()
          }
        } else {
          moveResultSelection(by: -1)
        }
        return true
      }
      return false
    }
    // Tab walks the folder and the microphone, then the text — Spotlight's
    // field, where the microphone at the end is a selection and not a tab
    // stop. Handing the key back inserted a tab, which reads as several
    // spaces. ⇧Tab is the agent, forward, and one agent still consumes it
    // so the field gains nothing. A chat and the switcher hand both keys
    // on. While the composer is away (listening) the key is eaten and moves
    // nothing.
    if isTab {
      guard isFirstScreen else { return false }
      if composerIsUp, !isVoiceListening { cycleComposerKey() }
      return true
    }
    if isBacktab {
      guard isFirstScreen else { return false }
      if composerIsUp, !isVoiceListening { cycleAgent(by: 1) }
      return true
    }
    if commandSelector == #selector(deleteBackward(_:)) {
      // Backspacing past the last character of a query closes the switcher.
      if mode != .prompt, field.searchQuery.isEmpty {
        closeSwitcher()
        return true
      }
      return false
    }
    if commandSelector == #selector(insertNewline(_:))
        || commandSelector == #selector(insertNewlineIgnoringFieldEditor(_:)) {
      let modifiers = (commandModifierFlagsForTesting ?? NSApp.currentEvent?.modifierFlags ?? [])
        .intersection(.deviceIndependentFlagsMask)
      if !modifiers.intersection([.shift, .option]).isEmpty {
        textView.insertText("\n", replacementRange: textView.selectedRange())
        return true
      }
      if isVoiceListening {
        // Enter is ✓, not "send what is on screen". Both engines hand back
        // their polished text *after* the audio stops, so submitting here would
        // send the partial transcript with the mistakes still in it.
        onVoiceConfirm?()
        return true
      }
      confirmSelectionOrSubmit()
      return true
    }
    if commandSelector == #selector(cancelOperation(_:)) {
      if screenSelectionPhase != .idle {
        cancelScreenSelection()
        return true
      }
      if addressedPreview != nil {
        goBack()
        return true
      }
      if isResultsExpanded {
        closeSwitcher()
        return true
      }
      onCancel?()
      return true
    }
    return false
  }

  func textDidChange(_ notification: Notification) {
    needsLayout = true
    syncSendButton()
    syncScreenOutlines()
    if mode == .picking, !isRestoringChatDraft, !field.isEmptyPrompt {
      // ↓ initially lets the rows take over the shell. The first character
      // brings the field back as a search and keeps the list below it, narrowed
      // by what was typed.
      setComposerKeyTarget(.text)
      mode = .search
      applyModeChrome()
    }
    if !isRestoringChatDraft { onDraftChange?() }
    if !isRestoringChatDraft, !isApplyingVoiceTranscript { hideNotice() }
    if !voiceTranscriptWasInterrupted, !isApplyingVoiceTranscript, let expected = voiceExpectedText,
       field.string != expected {
      // Editing takes ownership of the draft; a later recognizer revision
      // must not overwrite a correction, an undo or a newly pasted chip.
      voiceTranscriptWasInterrupted = true
      onVoiceEditingInterrupted?()
      setVoiceListening(false)
    }
    syncPromptExpansion()
    // The hint is a placeholder: it stands in for text that is not there yet,
    // so any text at all replaces it. Qualifying this by mode left "Search
    // sessions" painted underneath the query the user was typing.
    hintLabel.isHidden = !field.isEmptyPrompt
    if isResultsExpanded {
      refreshResults(keepingSelection: true)
    }
  }


  /// Routes ⌘V through `PasteboardIngest`, which decides whether the clipboard
  /// is a chip or characters.
  private func handlePaste(forcePlainText: Bool) {
    applyIngest(
      PasteboardIngest.read(
        .general,
        into: field.draft,
        forcePlainText: forcePlainText
      )
    )
  }

  private func applyIngest(_ outcome: PasteboardIngest.Outcome) {
    switch outcome {
    case let .attachments(attachments):
      field.insertChips(attachments)
      hideNotice()
    case let .plainText(text):
      field.insertPlainText(text)
      hideNotice()
    case let .tooManyFiles(limit):
      showError("Too many files — paste up to \(limit) at once.")
    case .nothing:
      break
    }
    hintLabel.isHidden = !field.isEmptyPrompt
    syncPromptExpansion()
    syncPromptHeight()
    if isResultsExpanded {
      refreshResults(keepingSelection: true)
    }
  }
}

/// Words drawn over the shell that take no clicks: a press on them is a
/// press on the shell under them.
private final class PassThroughView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A hover target that reports the pointer and takes no clicks.
///
/// The recording cluster over the microphone is revealed rather than drawn,
/// and needs a zone that keeps reporting while the control it reveals is
/// still hidden. `hitTest` returns `nil`, so whatever is underneath
/// stays clickable and selectable; tracking fires regardless.
private final class HoverSensor: NSView {
  var onHoverChange: ((Bool) -> Void)?
  private(set) var isPointerInside = false
  private var trackingArea: NSTrackingArea?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    isPointerInside = true
    onHoverChange?(true)
  }

  override func mouseExited(with event: NSEvent) {
    isPointerInside = false
    onHoverChange?(false)
  }
}

/// Foreground chrome sits *over* glass, not inside it. Vibrancy would let
/// Liquid Glass paint Siri-style highlights onto the mark and type.
private final class BolttyAIChromeView: NSView {
  override var allowsVibrancy: Bool { false }
}

private final class BolttyAIMarkView: NSImageView {
  private var helpArea: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let helpArea { removeTrackingArea(helpArea) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    helpArea = area
  }
  override func mouseEntered(with event: NSEvent) {
    if let toolTip { PaletteHelpPresenter.shared.schedule(for: self, text: toolTip) }
  }
  override func mouseExited(with event: NSEvent) { PaletteHelpPresenter.shared.dismiss(for: self) }

  private let mascot = MascotNSView(conversationID: UUID(), look: MascotLook.face(for: nil))
  /// The conversation the face currently belongs to, for the tests that assert
  /// the card re-aims rather than redraws.
  private(set) var mascotIdentity: UUID?
  private(set) var mascotEmotion: MascotEmotion?
  /// The palette actually on the face, read back so a test can assert which
  /// agent the mark is speaking for.
  var mascotPaletteID: String? {
    mascot.isHidden ? nil : mascot.paletteID
  }
  /// The outline and the gradient, for a test that asserts which agent the
  /// mark is speaking for.
  var mascotLook: MascotLook? {
    mascot.isHidden ? nil : mascot.look
  }


  override var allowsVibrancy: Bool { false }

  /// The face above the prompt, wearing the agent it speaks for.
  ///
  /// **Its own outline and gradient** (`MascotLook.face(for:)`) — the same
  /// one its history tab and its chat card wear — or the preferred agent's
  /// when no agent is speaking.
  ///
  /// The drift is still reseeded per conversation, so two chats breathe
  /// differently while wearing one face.
  func showMascot(
    conversationID: UUID,
    emotion: MascotEmotion,
    look: MascotLook
  ) {
    if mascotIdentity != conversationID {
      mascot.reseed(conversationID: conversationID, look: look)
    } else {
      mascot.apply(look: look)
    }
    mascotIdentity = conversationID
    mascotEmotion = emotion
    image = nil
    if mascot.superview == nil { addSubview(mascot) }
    mascot.isHidden = false
    mascot.emotion = emotion
    mascot.reduceMotion = MotionPreferences.reduceMotion
    needsLayout = true
  }

  /// A hop and a full turn — `MascotNSView.poke`.
  func pokeMascot() {
    guard !mascot.isHidden else { return }
    mascot.poke()
  }

  override func layout() {
    super.layout()
    // Centred and overhanging rather than filling: the mark view keeps the
    // `iconSize` box the placeholder is laid out against, and only the face
    // grows past it. See `AgentPaletteMetrics.mascotOversize`.
    let side = AgentPaletteMetrics.promptMascotSize
    mascot.frame = CGRect(
      x: bounds.midX - side / 2,
      y: bounds.midY - side / 2,
      width: side,
      height: side
    )
  }
}


/// Critically damped native geometry spring. Retargeting preserves position and
/// velocity; only the glass shell is laid out on ticks, never the transcript.
@MainActor
final class PaletteSurfaceMotion: NSObject {
  private var link: CADisplayLink?
  private var watchdog: Timer?
  private var current = [CGFloat](repeating: 0, count: 4)
  private var velocity = [CGFloat](repeating: 0, count: 4)
  private var target = [CGFloat](repeating: 0, count: 4)
  private var lastTime: CFTimeInterval = 0
  private var initialized = false
  private let render: (CGRect) -> Void
  /// How quickly the shell gets where it is going: `surfaceResponse`, except
  /// while it drips, whose fall and spread each have their own.
  var response: CGFloat = AgentPaletteMetrics.surfaceResponse
  init(render: @escaping (CGRect) -> Void) { self.render = render }

  /// Returns whether this call actually started or retargeted a travel, so a
  /// caller can hang a one-shot effect (the morph blur) on the trip rather than
  /// on every layout pass — `layout()` runs far more often than the shell moves.
  @discardableResult
  func move(to rect: CGRect, in view: NSView, animated: Bool) -> Bool {
    let next = [rect.minX, rect.minY, rect.width, rect.height]
    if !initialized || !animated {
      initialized = true
      target = next
      settle()
      return false
    }
    guard next != target else { return false }
    target = next
    if link == nil {
      lastTime = Motion.now
      let link = view.displayLink(target: self, selector: #selector(tick))
      link.preferredFrameRateRange = MotionPreferences.highFrameRateRange
      link.add(to: .main, forMode: .common)
      self.link = link
    }
    watchdog?.invalidate()
    let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.settle() }
    }
    RunLoop.main.add(timer, forMode: .common)
    watchdog = timer
    return true
  }

  func settle() {
    link?.invalidate()
    link = nil
    watchdog?.invalidate()
    watchdog = nil
    current = target
    velocity = [CGFloat](repeating: 0, count: 4)
    paint()
  }

  @objc private func tick() {
    guard !MotionPreferences.reduceMotion else { settle(); return }
    let now = Motion.now
    let dt = CGFloat(min(now - lastTime, 1.0 / 15))
    lastTime = now
    advance(by: dt)
  }

  /// Exact critical-spring step, shared by the display clock and motion tests.
  func advance(by dt: CGFloat) {
    let omega: CGFloat = 2 * .pi / max(response, 0.01)
    let decay = exp(-omega * dt)
    for i in current.indices {
      let delta = current[i] - target[i]
      let c = velocity[i] + omega * delta
      current[i] = target[i] + (delta + c * dt) * decay
      velocity[i] = (velocity[i] - omega * c * dt) * decay
    }
    if zip(current, target).allSatisfy({ abs($0 - $1) < 0.1 }) && velocity.allSatisfy({ abs($0) < 1 }) {
      settle()
    } else { paint() }
  }

  private func paint() {
    render(CGRect(x: current[0], y: current[1], width: max(1, current[2]), height: max(1, current[3])))
  }
}

/// Which sides of a resizable shell a press is on. Only the sides and the
/// foot: the top is the shell's anchor and its move handle.
struct SurfaceResizeEdges: OptionSet, Equatable {
  let rawValue: Int
  static let left = SurfaceResizeEdges(rawValue: 1 << 0)
  static let right = SurfaceResizeEdges(rawValue: 1 << 1)
  static let bottom = SurfaceResizeEdges(rawValue: 1 << 2)

  /// The edges under `point`, in unflipped coordinates (the foot is
  /// `frame.minY`): the first of `regions` that holds it.
  static func at(_ point: NSPoint, of frame: CGRect) -> SurfaceResizeEdges? {
    regions(of: frame).first { $0.rect.contains(point) }?.edges
  }

  /// The grips, corners first. An edge is found `surfaceResizeInnerGrip`
  /// inside it and `surfaceResizeOuterGrip` outside; a lower corner is a
  /// square reaching `surfaceResizeCornerReach` in along both of its edges —
  /// most of a 58pt corner, which is where the grabber stands — and the
  /// outer grip out. The sides stop short of the top, which is the move
  /// handle and where the back disc and the tabs are. One list for the press
  /// and the cursor, so the two cannot disagree about where a grip is.
  static func regions(
    of frame: CGRect
  ) -> [(rect: CGRect, edges: SurfaceResizeEdges, cursor: NSCursor.FrameResizePosition)] {
    let outer = AgentPaletteMetrics.surfaceResizeOuterGrip
    let inner = AgentPaletteMetrics.surfaceResizeInnerGrip
    let reach = AgentPaletteMetrics.surfaceResizeCornerReach
    let top = AgentPaletteMetrics.surfaceResizeTopClearance
    let corner = reach + outer
    let sideBottom = frame.minY + reach
    let sideHeight = max(0, frame.maxY - top - sideBottom)
    return [
      (CGRect(x: frame.maxX - reach, y: frame.minY - outer, width: corner, height: corner),
       [.right, .bottom], .bottomRight),
      (CGRect(x: frame.minX - outer, y: frame.minY - outer, width: corner, height: corner),
       [.left, .bottom], .bottomLeft),
      (CGRect(x: frame.minX - outer, y: sideBottom, width: outer + inner, height: sideHeight),
       .left, .left),
      (CGRect(x: frame.maxX - inner, y: sideBottom, width: outer + inner, height: sideHeight),
       .right, .right),
      (CGRect(x: frame.minX + reach, y: frame.minY - outer,
              width: max(0, frame.width - reach * 2), height: outer + inner),
       .bottom, .bottom),
    ]
  }
}

/// iPadOS 26's window handle, on Boltty AI's shell: a short arc that follows
/// the lower right corner a few points outside the rim, off the glass. Not
/// there at rest; it comes up under the pointer and while dragged. It draws and never takes a press —
/// the grips under it are the palette view's (`SurfaceResizeEdges`).
@MainActor
final class PaletteResizeGrabberView: NSView {
  var isHovered = false { didSet { if isHovered != oldValue { applyInk() } } }
  var isEngaged = false { didSet { if isEngaged != oldValue { applyInk() } } }

  private let arc = CAShapeLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    arc.fillColor = nil
    arc.lineWidth = AgentPaletteMetrics.resizeGrabberLineWidth
    arc.lineCap = .round
    // Outside the glass it stands on whatever is behind the panel, so a
    // light page needs the soft dark edge iPadOS gives its handle too.
    arc.shadowColor = NSColor.black.cgColor
    arc.shadowOpacity = 0.35
    arc.shadowRadius = 2
    arc.shadowOffset = .zero
    layer?.addSublayer(arc)
    applyInk(animated: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var allowsVibrancy: Bool { false }

  var pathBoundsForTesting: CGRect { arc.path?.boundingBox ?? .null }

  /// The arc for a shell drawn at `rect` (unflipped, in this view's space)
  /// with `corner`: a circle's arc of the corner's radius and the outset,
  /// centred on the corner's centre, spanning the diagonal.
  func place(in rect: CGRect, corner: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    arc.frame = bounds
    let radius = max(1, corner + AgentPaletteMetrics.resizeGrabberOutset)
    let centre = CGPoint(x: rect.maxX - corner, y: rect.minY + corner)
    let half = AgentPaletteMetrics.resizeGrabberHalfAngle
    let diagonal = -CGFloat.pi / 4
    let path = CGMutablePath()
    path.addArc(
      center: centre, radius: radius,
      startAngle: diagonal - half, endAngle: diagonal + half, clockwise: false
    )
    arc.path = path
    CATransaction.commit()
  }

  private func applyInk(animated: Bool = true) {
    let ink = (isHovered || isEngaged
      ? AgentPaletteMetrics.resizeGrabberLitInk
      : AgentPaletteMetrics.resizeGrabberRestingInk).cgColor
    let previous = arc.presentation()?.strokeColor ?? arc.strokeColor
    arc.strokeColor = ink
    arc.shadowOpacity = isHovered || isEngaged ? 0.35 : 0
    guard animated, !MotionPreferences.reduceMotion else { return }
    let fade = CABasicAnimation(keyPath: "strokeColor")
    fade.fromValue = previous
    fade.toValue = ink
    fade.duration = Motion.quick
    fade.timingFunction = Motion.standardCurve
    arc.add(fade, forKey: "ink")
  }
}

/// One line of the history's column: a day's heading, or a chat's row.
private enum ResultLine {
  /// `followsRows`: another day's rows stand above it.
  case heading(AgentHistory.Section, followsRows: Bool)
  case row(BolttyAISessionItem)

  /// Its place in the list — known before its view is built.
  var listLine: ResultsListView.Line {
    switch self {
    case .heading(let section, let followsRows):
      ResultsListView.Line(
        id: section.id,
        height: AgentPaletteMetrics.historyHeaderHeight(followsRows: followsRows)
      )
    case .row(let item):
      ResultsListView.Line(id: item.id, height: AgentPaletteMetrics.resultsRowHeight)
    }
  }
}
