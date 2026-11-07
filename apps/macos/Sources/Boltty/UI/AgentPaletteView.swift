import AppKit
import CoreImage

final class AgentPaletteView: NSView, PaletteHelpRoomProviding {
  var helpRoom: NSRect? { convert(surface.bounds, from: surface) }

  var onSubmit: ((PromptDraft) -> Void)?
  var onSubmitSteering: ((PromptDraft) -> Void)?
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
  func resumeChatAnimations() { previewCard.resumeAnimations() }

  func prepareFileFlights(_ files: [(attachment: UUID, file: SentFile)]) {
    guard !files.isEmpty else { return }
    let cards = attachmentStrip.cardSnapshots()
    var origins: [String: BolttyAIPreviewCard.FlightOrigin] = [:]
    for (attachment, file) in files {
      guard let snapshot = cards[attachment] else { continue }
      origins[file.path] = .init(frameInWindow: snapshot.frame, image: snapshot.image)
    }
    previewCard.prepareFileFlights(origins)
  }

  var onAnswerQuestion: ((UUID, AgentQuestion, [String]) -> Void)?
  var onRetryPrompt: ((UUID, String) -> Void)?
  var onCancelQueuedPrompt: ((UUID) -> Void)?
  var onOpenSettings: (() -> Void)?
  var onChooseAttachments: (() -> Void)?
  var onScreenSelectionBegan: (() -> Void)?
  var onScreenRegionReady: (() -> Void)?
  var onScreenRegionSelected: ((CGRect) -> Void)?
  var onScreenSelectionCancelled: (() -> Void)?
  private let screenOutlines = ScreenSelectionOverlay()
  private let selectionPointerHint = ScreenSelectionPointerHint()
  private var selectionPointerHintTimer: Timer?
  var onSelectSession: ((UUID) -> Void)?
  var onWillShowSessions: (() -> Void)?
  var onConfirmSession: ((UUID) -> Void)?
  var onSessionContextMenu: ((UUID, NSEvent, NSView) -> Void)?
  var onContentSizeChange: (() -> Void)?
  var onVoiceToggle: (() -> Void)?
  var onVoiceCancel: (() -> Void)?
  var onLetGoOfRegion: (() -> Void)?
  var onVoiceConfirm: (() -> Void)?
  var onVoiceEditingInterrupted: (() -> Void)?
  var onLeaveAddressing: ((UUID) -> Void)?
  var onChooseWorkingDirectory: (() -> Void)?
  var onWorkingDirectoryMenu: (() -> Void)?
  var topReserve: CGFloat = 0 {
    didSet { if topReserve != oldValue { applyPlacement() } }
  }
  var onSurfaceSizesChange: ((BolttyAISurfaceSizes) -> Void)?
  var surfaceSizes = BolttyAISurfaceSizes.default {
    didSet { if surfaceSizes != oldValue { applyPlacement() } }
  }

  let field: PromptTextView
  private let promptScroll: NSScrollView
  private let selectedAgentImage = BolttyAIMarkView()
  private let micButton = GlassCircleVoiceButton()
  private weak var heldSelection: NSTextView?
  private let attachRestDisc = GlassCircleButton(
    icon: .plus,
    accessibilityDescription: "Attach a file",
    diameter: AgentPaletteMetrics.voiceOrbDiameter,
    size: ComposerControlGroup.iconSize(chat: false),
    showsGlass: false
  )
  private let attachRestSlot = NSView()
  private lazy var attachRestWidth = attachRestSlot.widthAnchor.constraint(equalToConstant: 0)
  private let modelChipButton: PaletteIconButton = {
    let button = PaletteIconButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.imagePosition = .noImage
    button.font = AgentPaletteView.modelChipFont
    (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
    return button
  }()
  private static let modelChipFont = roundedAppFont(size: AgentPaletteMetrics.typeSecondary, weight: .medium)
  private static let modelChipMaxWidth: CGFloat = 164
  private let modelChipSlot = NSView()
  private lazy var modelChipWidth = modelChipSlot.widthAnchor.constraint(equalToConstant: 0)
  private var shownModelChip: BolttyAIModelChip?
  var onModelMenu: (() -> Void)?
  private lazy var latestPillConstraints: [NSLayoutConstraint] = [
    latestPill.centerXAnchor.constraint(equalTo: promptCapsule.centerXAnchor),
    latestPill.bottomAnchor.constraint(
      equalTo: promptCapsule.topAnchor,
      constant: -AgentPaletteMetrics.latestComposerSpacing
    ),
  ]
  private let latestPill: GlassCircleButton = {
    let disc = GlassCircleButton(
      icon: .arrowDown,
      accessibilityDescription: "Latest",
      diameter: AgentPaletteMetrics.previewCloseDiameter,
      size: AgentPaletteMetrics.previewCloseGlyphPointSize
    )
    disc.button.toolTip = "Latest"
    return disc
  }()
  private var offersLatest = false
  private let historyNewChatButton = GlassCircleButton(
    icon: .plus,
    accessibilityDescription: "New Chat",
    diameter: AgentPaletteMetrics.previewCloseDiameter,
    size: AgentPaletteMetrics.previewCloseGlyphPointSize
  )
  private let historySettingsButton = GlassCircleButton(
    icon: .settings,
    accessibilityDescription: "Settings",
    diameter: AgentPaletteMetrics.previewCloseDiameter,
    size: AgentPaletteMetrics.previewCloseGlyphPointSize
  )
  private var showsHistoryFoot: Bool { !historyNewChatButton.isHidden }
  private var acceptsAttachments = false
  private var stopTooltip = "Stop response"

  private func submitSteeringFromKeyboard() -> Bool {
    guard mode == .prompt, let preview = addressedPreview, preview.isBusy,
          previewCard.pendingQuestion == nil, !field.draft.isEffectivelyEmpty
    else { return false }
    onSubmitSteering?(field.draft)
    return true
  }

  private func stopFromKeyboard() -> Bool {
    guard stopIsAvailable else { return false }
    onStop?()
    return true
  }
  private let notice = PaletteNoticeView()
  private let bottomBar = NSStackView()
  private let directoryChip = WorkingDirectoryChipView()
  private let directorySlot = NSView()
  private lazy var directorySlotWidth = directorySlot.widthAnchor.constraint(equalToConstant: 0)
  private var workingDirectory: WorkingDirectoryChip?
  private let planRing = PlanUsageRingView(frame: .zero)
  var onCompact: (() -> Void)?
  private let routingRow = NSStackView()
  private let routingLabel = NSTextField(labelWithString: "")
  private let routingButton = GlassPillButton.titled("Open Settings")
  private let promptHost: PaletteGlassHost
  private let trailingControls = NSStackView()
  private let leadingControls = NSStackView()
  private let sendButton = GlassCircleButton(
    icon: .keyReturn, accessibilityDescription: "Send message",
    diameter: ComposerControlGroup.sendDisc,
    size: ComposerControlGroup.sendIconSize, showsGlass: false)
  private let sendSlot = NSView()
  private lazy var sendSlotWidth = sendSlot.widthAnchor.constraint(equalToConstant: 0)
  var sendButtonForTesting: PaletteIconButton { sendButton.button }
  var sendSlotStopsForTesting: Bool { sendSlotStops }
  @objc private func sendButtonPressed() {
    if sendSlotStops { onStop?() } else { confirmSelectionOrSubmit() }
  }
  private var sendSlotStops = false
  private let returnGlyph = ComposerControlGroup.sendIcon(.keyReturn, description: "Send message")
  private let stopGlyph = ComposerControlGroup.sendIcon(.stop, description: "Stop")
  private var composerGlyphsAreChat = false
  private func applyComposerGlyphSize(chat: Bool) {
    guard chat != composerGlyphsAreChat else { return }
    composerGlyphsAreChat = chat
    let size = ComposerControlGroup.iconSize(chat: chat)
    directoryChip.setChatSized(chat)
    attachRestDisc.setPointSize(size)
    micButton.restingIconSize = size
    placeDirectorySlot(inChat: chat)
  }
  private func placeDirectorySlot(inChat chat: Bool) {
    let from = chat ? trailingControls : leadingControls
    guard from.views.contains(directorySlot) else { return }
    from.removeView(directorySlot)
    if chat {
      leadingControls.addView(directorySlot, in: .leading)
    } else {
      let afterRing = (trailingControls.views(in: .leading).firstIndex(of: planRing) ?? -1) + 1
      trailingControls.insertView(directorySlot, at: afterRing, in: .leading)
    }
  }
  private func syncSendButton() {
    defer { syncTrailingHint() }
    let visible = composerIsUp && !isVoiceListening && composerGlyphsAreChat
    sendButton.isHidden = !visible
    sendSlotWidth.constant = visible ? ComposerControlGroup.sendDisc : 0
    trailingControls.setCustomSpacing(visible ? ComposerControlGroup.sendGap : 0, after: micButton)
    let answering = previewCard.pendingQuestion != nil
    let refusing = previewCard.pendingQuestion?.takesWordsAsRefusal == true && draftHasWords
    previewCard.setComposerHasWords(draftHasWords)
    sendSlotStops = stopIsAvailable && !answering && field.draft.isEffectivelyEmpty
    if sendSlotStops {
      sendButton.button.image = stopGlyph
      setSendDiscEnabled(true)
      sendButton.button.toolTip = stopTooltip
      sendButton.button.helpShortcut = "⌘."
      sendButton.button.setAccessibilityLabel("Stop")
      return
    }
    sendButton.button.image = returnGlyph
    sendButton.button.setAccessibilityLabel("Send message")
    setSendDiscEnabled(!isVoiceProcessing && (!field.draft.isEffectivelyEmpty || answering))
    sendButton.button.toolTip = refusing
      ? (previewCard.pendingQuestion?.kind == .plan ? Self.planChangesHelp : Self.refusalHelp)
      : answering ? "Answer question" : addressedPreview?.isBusy == true
      ? "Queue message — sends when this turn finishes" : "Send message"
    sendButton.button.helpShortcut = "↵"
  }
  private func setSendDiscEnabled(_ enabled: Bool) {
    let button = sendButton.button
    button.isEnabled = enabled
    let fill = enabled ? ComposerControlGroup.sendFill : ComposerControlGroup.sendDisabledFill
    button.hoverBackground = enabled ? ComposerControlGroup.sendHoverFill : fill
    guard button.restingBackground != fill else { return }
    button.restingBackground = fill
    if button.isHovered {
      button.layer?.removeAnimation(forKey: "hoverBackground")
      button.layer?.backgroundColor = button.hoverBackground.cgColor
    }
  }
  private let recordingHoverSensor = HoverSensor()
  private var isRecordingControlsRevealed = false
  private var inlineControlConstraints: [NSLayoutConstraint] = []
  private var expandedPromptConstraints: [NSLayoutConstraint] = []
  private lazy var expandedPromptTop = promptScroll.topAnchor.constraint(
    equalTo: promptForeground.topAnchor)
  private var isPromptExpanded = false
  private var isDraftExpanded = false
  private var usesExpandedControlLayout: Bool { isVoiceListening }
  private var composerControlDiameter: CGFloat { ComposerControlGroup.target(chat: composerGlyphsAreChat) }
  private let promptEdgeFadeMask = CAGradientLayer()
  private let recordingControls = VoiceRecordingControls(frame: .zero)
  private let voiceGlow = VoiceEdgeGlowView(frame: .zero)
  private let backdrop = AgentBackdropView(frame: .zero)
  private let listeningWordsHost = PassThroughView()
  private let listeningWords = ListeningWordsView(frame: .zero)
  private let listeningFace = MascotNSView(conversationID: UUID(), look: MascotLook.face(for: nil))
  private var faceFlight: (from: CGRect, start: CFTimeInterval)?
  private var faceFlightTimer: Timer?
  private var listeningWordsWidth: CGFloat = 0
  private let promptForeground = BolttyAIChromeView()
  private let attachmentStrip = PromptAttachmentStrip()
  private lazy var promptForegroundTop = promptForeground.topAnchor.constraint(
    equalTo: promptCapsule.topAnchor)
  private lazy var attachmentStripHeight = attachmentStrip.heightAnchor.constraint(equalToConstant: 0)
  private var bandTravel: (from: CGFloat, to: CGFloat, fromHeight: CGFloat)?
  private let promptCapsule = NSView()
  private let surfaceContainer = NSView()
  private var dripTarget: CGRect?
  private var isDrippingIn = false
  private var dripRun = 0
  private let surface = PaletteGlassHost(content: NSView(), cornerRadius: 36, style: .bolttyAI)
  private lazy var noticeCenterX = notice.centerXAnchor.constraint(equalTo: promptCapsule.centerXAnchor)
  private lazy var noticeTopToPrompt = notice.topAnchor.constraint(
    equalTo: promptCapsule.bottomAnchor, constant: AgentPaletteMetrics.noticeShellSpacing)
  private lazy var noticeTopToResults = notice.topAnchor.constraint(
    equalTo: resultsCapsule.bottomAnchor, constant: AgentPaletteMetrics.noticeShellSpacing)
  private lazy var noticeAboveComposer = notice.bottomAnchor.constraint(
    equalTo: promptCapsule.topAnchor, constant: -AgentPaletteMetrics.latestComposerSpacing)
  private lazy var editorLeading = promptScroll.leadingAnchor.constraint(equalTo: promptForeground.leadingAnchor, constant: AgentPaletteMetrics.promptTextLeading)
  private lazy var controlsTop = trailingControls.centerYAnchor.constraint(equalTo: promptForeground.topAnchor, constant: AgentPaletteMetrics.promptSize.height / 2)
  private lazy var promptHostTrailing = promptHost.trailingAnchor.constraint(
    equalTo: promptCapsule.trailingAnchor
  )
  private lazy var editorTrailing = promptScroll.trailingAnchor.constraint(
    equalTo: promptForeground.trailingAnchor,
    constant: -(AgentPaletteMetrics.restingControlsTrailingInset
      + AgentPaletteMetrics.voiceOrbDiameter + AgentPaletteMetrics.promptMicTextSpacing)
  )
  private lazy var controlsTrailing = trailingControls.trailingAnchor.constraint(
    equalTo: promptForeground.trailingAnchor,
    constant: -AgentPaletteMetrics.restingControlsTrailingInset
  )
  private lazy var micWidth = micButton.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceOrbDiameter)
  private lazy var micHeight = micButton.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceOrbDiameter)
  private lazy var hintBaseline = hintLabel.firstBaselineAnchor.constraint(equalTo: promptScroll.topAnchor, constant: PromptTextView.firstBaselineOffsetFromTop)
  private var stopIsAvailable = false
  private var returnToSessionID: UUID?
  private var surfaceFrame: CGRect = .zero
  private var surfaceReady = false
  private lazy var surfaceMotion = PaletteSurfaceMotion { [weak self] rect in
    self?.drawSurface(at: rect)
  }
  private lazy var promptWidthConstraint = promptCapsule.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.promptSize.width)
  private var showsCompactListening: Bool {
    (isVoiceListening || (isVoiceProcessing && voiceGlow.fillsShell) || isHandingOver
      || holdsQuestionWords || (awaitsRegionVoice && field.string.isEmpty))
      && !isResultsExpanded
      && (addressedPreview == nil || voicePrefixDraft?.isEffectivelyEmpty != false)
  }
  private var holdsQuestionWords = false {
    didSet { if holdsQuestionWords != oldValue { needsLayout = true } }
  }

  func holdWordsForQuestion() { holdsQuestionWords = showsCompactListening }
  func releaseQuestionWords() { holdsQuestionWords = false }
  var isCompactListeningForTesting: Bool { showsCompactListening }
  var listeningWordsForTesting: String { listeningWords.text }
  var listeningWordsShownForTesting: Bool { listeningWordsHost.alphaValue > 0 }
  var unifiedSurfaceFrameForTesting: CGRect { surfaceFrame }
  var unifiedSurfaceLayerForTesting: CALayer? { surfaceContainer.layer }
  var unifiedSurfaceCornerForTesting: CGFloat { surface.renderedCornerRadius }
  var surfaceFrameInView: CGRect { surfaceFrame }
  var composerCornerForTesting: (radius: CGFloat, height: CGFloat, curve: CALayerCornerCurve) {
    (promptHost.renderedCornerRadius, promptHost.bounds.height, promptHost.renderedCornerCurve)
  }
  var isComposerVisibleForTesting: Bool { promptCapsule.alphaValue > 0 }

  private let resultsForeground = NSView()
  private let resultsCapsule = NSView()
  private let previewForeground = NSView()
  private let previewCapsule = NSView()
  private let previewCard = BolttyAIPreviewCard()
  private let resultsScroll = NSScrollView()
  private let resultsStack = ResultsListView()
  private let historyTabs = AgentHistoryTabStripView()
  private var resultsScrollTop: NSLayoutConstraint!
  private let resultsTopEdge = CAGradientLayer()
  private var resultsOverlap: CGFloat = 0
  private let hintLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.lineBreakMode = .byTruncatingTail
    return label
  }()
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

  private var previewBandHeight: CGFloat = 0 {
    didSet { applyPreviewBandHeight() }
  }

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
  private lazy var previewTopConstraint = previewCapsule.topAnchor.constraint(
    equalTo: promptCapsule.bottomAnchor,
    constant: 0
  )
  private lazy var promptCapsuleHeightConstraint = promptCapsule.heightAnchor.constraint(
    equalToConstant: AgentPaletteMetrics.promptSize.height
  )
  private lazy var promptTopConstraint = promptCapsule.topAnchor.constraint(
    equalTo: topAnchor,
    constant: AgentPaletteMetrics.safeAreaY
  )
  private lazy var promptCenterXConstraint = promptCapsule.centerXAnchor.constraint(
    equalTo: centerXAnchor
  )
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
  private var voicePrefixDraft: PromptDraft?
  private var appliedVoiceTranscript: String?
  /// Where the spoken text begins, in UTF-16 units — everything before it was
  /// typed before the mic went live and must never be touched.
  private var voicePrefixLength: Int?
  private var voiceExpectedText: String?
  private var voiceTranscriptWasInterrupted = false
  private var isApplyingVoiceTranscript = false
  private var promptRemeasureWorkItem: DispatchWorkItem?
  private var isPerformingLayout = false

  private var sessionItems: [BolttyAISessionItem] = []
  private var sessionTranscripts: [UUID: ConversationTranscript] = [:]
  private var resultItems: [BolttyAISessionItem] = []
  /// `resultItems` stays flat: it is the selection space that keyboard movement,
  /// Enter and the highlight index into.
  private var resultSections: [AgentHistory.Section] = []
  private(set) var activeHistoryAgent: AgentId?
  private var headersByDay: [String: AgentHistorySectionHeaderView] = [:]
  private var selectedResultIndex = -1
  private var isResultsExpanded = false {
    didSet {
      guard isResultsExpanded != oldValue else { return }
      heldSessionItems = isResultsExpanded ? sessionItems : nil
    }
  }
  private var heldSessionItems: [BolttyAISessionItem]?
  private var resultLines: [ResultLine] = []
  private var resultLineIndexByRow: [Int] = []
  private var rowsByConversation: [UUID: BolttyAISessionRowView] = [:]
  private var keyboardSelectionPointerAnchor: NSPoint?
  var pointerLocationForTesting: NSPoint?
  private var pointerLocation: NSPoint {
    pointerLocationForTesting ?? NSEvent.mouseLocation
  }
  private var addressedPreview: BolttyAISessionPreview?

  enum Mode: Equatable {
    case prompt
    case picking
    case search
  }

  private(set) var mode: Mode = .prompt

  /// True while the field holds a query instead of a message — the one state in
  /// which its text must never be sent to an agent.
  var fieldIsQuery: Bool { mode == .search }

  private var resultsQuery: String { mode == .search ? field.searchQuery : "" }

  private var showsHistoryChrome: Bool { mode != .search }

  private(set) var pendingConversationID = UUID()

  private var agentChoices: [AgentId] = []
  private var plannedAgent: AgentId?
  private(set) var chosenAgent: AgentId?
  var agentForNewPrompt: AgentId? { chosenAgent ?? plannedAgent }
  var onAgentChoiceChange: (() -> Void)?

  var mascotIdentityForTesting: UUID? { selectedAgentImage.mascotIdentity }
  var mascotEmotionForTesting: MascotEmotion? { selectedAgentImage.mascotEmotion }
  var mascotPaletteIDForTesting: String? { selectedAgentImage.mascotPaletteID }
  var mascotLookForTesting: MascotLook? { selectedAgentImage.mascotLook }

  private var showsNoAgentsState = false
  private var isShowingInstallHints = false

  var presentationLayer: CALayer? { layer }

  static let promptTypingTextColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
  static let promptIconTintColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
  var usesSystemGlassBackgroundForTesting: Bool {
    promptHost.isUsingGlassForTesting
  }
  var usesDirectionalGlassOverlayForTesting: Bool {
    promptHost.hasVerticalOverlayForTesting
  }
  var surfaceUsesDirectionalGlassOverlayForTesting: Bool {
    surface.hasVerticalOverlayForTesting
  }
  var composerHostsContentInSystemGlassForTesting: Bool {
    promptHost.hostsContentInSystemGlassForTesting
  }
  var voiceOrbUsesSystemGlassForTesting: Bool { micButton.usesSystemGlass }
  var previewCardForTesting: BolttyAIPreviewCard { previewCard }
  var addressedPreviewForTesting: BolttyAISessionPreview? { addressedPreview }
  var initialPromptChromeIsVisibleForTesting: Bool { !promptHost.isHidden }
  var shellUsesGlassForTesting: Bool { surface.isUsingGlassForTesting }
  var isResultsExpandedForTesting: Bool { isResultsExpanded }
  var resultsCardHeightForTesting: CGFloat { resultsHeightConstraint.constant }
  var resultsCardCornerRadiusForTesting: CGFloat { surface.renderedCornerRadius }
  var resultItemsForTesting: [BolttyAISessionItem] { resultItems }
  var selectedResultIndexForTesting: Int { selectedResultIndex }
  var emptyResultsTitleForTesting: String? {
    (resultsStack.arrangedSubviews.first as? BolttyAIEmptyResultsView)?.title
  }
  var commandModifierFlagsForTesting: NSEvent.ModifierFlags?
  var resultRowViewsForTesting: [BolttyAISessionRowView] {
    resultItems.compactMap { rowsByConversation[$0.id] }
  }
  func hoverRowForTesting(at index: Int) {
    guard resultItems.indices.contains(index) else { return }
    rowsByConversation[resultItems[index].id]?.onHover?()
  }
  var promptPlaceholderForTesting: String { hintLabel.stringValue }
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
    promptForeground.convert(micButton.bounds, from: micButton)
  }
  var composerForegroundSizeForTesting: CGSize { promptForeground.bounds.size }
  var attachDiscFrameForTesting: CGRect {
    promptForeground.convert(attachRestDisc.bounds, from: attachRestDisc)
  }
  var attachRestDiscForTesting: GlassCircleButton { attachRestDisc }
  var composerFieldFrameForTesting: CGRect {
    promptForeground.convert(promptHost.bounds, from: promptHost)
  }
  var composerBoxInWindowForTesting: CGRect { promptHost.convert(promptHost.bounds, to: nil) }
  var typedFirstInkInWindowForTesting: (left: CGFloat, capTop: CGFloat)? {
    guard let layoutManager = field.layoutManager, let font = field.font,
          let baseline = typedBaselineInWindowForTesting else { return nil }
    let x = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minX
      + layoutManager.location(forGlyphAt: 0).x + field.textContainerOrigin.x
    let glyph = font.boundingRect(forCGGlyph: layoutManager.cgGlyph(at: 0))
    return (field.convert(NSPoint(x: x, y: 0), to: nil).x + glyph.minX, baseline + font.capHeight)
  }
  var promptCapsuleHeightForTesting: CGFloat { promptCapsuleHeightConstraint.constant }
  var attachmentStripForTesting: PromptAttachmentStrip { attachmentStrip }
  var surfaceMotionForTesting: PaletteSurfaceMotion { surfaceMotion }
  var isVoiceListeningForTesting: Bool { isVoiceListening }
  var isVoiceListeningNow: Bool { isVoiceListening }
  var micButtonForTesting: GlassCircleVoiceButton { micButton }
  var isShowingRecordingControlsForTesting: Bool { !recordingControls.isHidden }
  var voiceGlowForTesting: VoiceEdgeGlowView { voiceGlow }
  var voiceGlowIsUnderTheGlassForTesting: Bool {
    guard let glow = subviews.firstIndex(of: voiceGlow),
          let glass = subviews.firstIndex(of: surfaceContainer)
    else { return false }
    return glow < glass
  }

  func setRecordingHoverForTesting(_ hovering: Bool) {
    setRecordingControlsRevealed(hovering, animated: false)
  }
  var resultsCapsuleLayerForTesting: CALayer? { resultsCapsule.layer }
  var resultsForegroundLayerForTesting: CALayer? { resultsForeground.layer }
  var isResultsCardVisibleForTesting: Bool {
    !resultsCapsule.isHidden && resultsCapsule.alphaValue > 0
  }
  var resultsCapsuleFrameForTesting: CGRect { resultsCapsule.frame }
  var promptCapsuleFrameForTesting: CGRect { promptCapsule.frame }
  var isPromptExpandedForTesting: Bool { isPromptExpanded }
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
  var previewCardCornerRadiusForTesting: CGFloat { surface.renderedCornerRadius }
  var previewForegroundClipForTesting: (radius: CGFloat, curve: CALayerCornerCurve, clips: Bool) {
    guard let layer = previewForeground.layer else { return (0, .circular, false) }
    return (layer.cornerRadius, layer.cornerCurve, layer.masksToBounds)
  }
  var promptTopInsetForTesting: CGFloat { promptTopConstraint.constant }
  var promptCenterXOffsetForTesting: CGFloat { promptCenterXConstraint.constant }
  var previewCapsuleFrameForTesting: CGRect { previewCapsule.frame }
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
  var targetSwapLayerForTesting: CALayer? { selectedAgentImage.layer }
  var placeholderLayerForTesting: CALayer? { hintLabel.layer }
  var promptCapsuleLayerForTesting: CALayer? { promptCapsule.layer }
  var promptForegroundLayerForTesting: CALayer? { promptForeground.layer }
  var promptCapsuleRendersOffscreenForTesting: Bool {
    guard let layer = promptCapsule.layer else { return false }
    return layer.shouldRasterize || !(layer.filters?.isEmpty ?? true)
  }
  var resultsCapsuleRendersOffscreenForTesting: Bool {
    guard let layer = resultsCapsule.layer else { return false }
    return layer.shouldRasterize || !(layer.filters?.isEmpty ?? true)
  }

  @discardableResult
  func preparePresentationLayer() -> CALayer? {
    layoutSubtreeIfNeeded()
    return layer
  }

  override init(frame frameRect: NSRect) {
    // Shadow lives on the capsule containers: NSGlassEffectView and layer-backed
    // parents often clip CALayer shadows on the host. Start without a wash:
    // content-hosting glass omits the initializer's wash, so starting with
    // .bolttyAI would skip it on the first same-style apply.
    promptHost = PaletteGlassHost(
      content: NSView(),
      cornerRadius: AgentPaletteMetrics.cornerRadius,
      style: .init(material: .regular, drawsOuterShadow: false),
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
    collapseResults(animated: false)
    if let error {
      showError(error)
    }
    onContentSizeChange?()
  }

  func setVoiceListening(_ listening: Bool, ending: VoiceGlowPhase = .completed) {
    let collapses = listening && !isVoiceListening && !isResultsExpanded
      && (addressedPreview == nil || field.draft.isEffectivelyEmpty)
    if collapses, screenSelectionPhase == .idle { beginFaceFlight() } else if !listening { endFaceFlight() }
    regionVoiceWait?.cancel()
    regionVoiceWait = nil
    awaitsRegionVoice = false
    if listening, !isVoiceListening {
      voicePrefixDraft = field.draft
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

  private func placeVoiceGlow() {
    guard voiceGlow.phase == .idle,
          let glow = subviews.firstIndex(of: voiceGlow),
          let glass = subviews.firstIndex(of: surfaceContainer)
    else { return }
    let underGlass = surface.usesSystemGlass
    guard underGlass != (glow < glass) else { return }
    addSubview(voiceGlow, positioned: underGlass ? .below : .above, relativeTo: surfaceContainer)
  }

  func setVoiceGlowPhase(_ phase: VoiceGlowPhase) {
    voiceGlow.setPhase(phase)
    let processing = phase == .processing
    if processing != isVoiceProcessing {
      isVoiceProcessing = processing
      needsLayout = true
    }
    applyMicAppearance()
    syncSendButton()
  }

  var isVoiceGlowActive: Bool { voiceGlow.phase != .idle }

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

  func applyVoiceLevel(_ level: CGFloat) {
    micButton.setAudioLevel(level)
    recordingControls.setAudioLevel(level)
    voiceGlow.setAudioLevel(level)
  }

  func applyVoiceTranscript(_ transcript: String) {
    guard !voiceTranscriptWasInterrupted else { return }
    if let expected = voiceExpectedText, field.string != expected { return }
    // Apple's volatile results repeat whenever the speaker pauses; each one would
    // rebuild the document and the list.
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
      setListeningWords(transcript)
      needsLayout = true
    }
  }

  private func setListeningWords(_ transcript: String) {
    let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let before = listeningWords.wordCount
    listeningWords.setText(words, animated: window?.isVisible == true)
    if listeningWords.wordCount > before { listeningFace.nod() }
  }

  private func listeningShellSize() -> CGSize {
    let orb = AgentPaletteMetrics.listeningOrbDiameter
    guard !listeningWords.text.isEmpty, !isHandingOver else { return CGSize(width: orb, height: orb) }
    let inset = AgentPaletteMetrics.listeningWordsInset
    let room = AgentPaletteMetrics.listeningMaxWidth - inset * 2
    let measured = listeningWords.measure(width: room)
    let width = min(AgentPaletteMetrics.listeningMaxWidth, max(orb, measured.widest + inset * 2))
    let height = AgentPaletteMetrics.listeningWordedHeight(
      lines: measured.lines, lineHeight: listeningWords.lineHeight)
    return CGSize(width: width, height: height)
  }

  private func replaceSpokenTail(with transcript: String) -> Bool {
    guard let prefixLength = voicePrefixLength else { return false }
    let document = field.string as NSString
    guard document.length >= prefixLength else { return false }

    let shown = document.substring(from: prefixLength)
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

  private var readingText: NSTextView? {
    guard let text = window?.firstResponder as? NSTextView, text !== field, !text.isEditable,
          !field.isHiddenOrHasHiddenAncestor
    else { return nil }
    return text
  }

  func returnFocusAfterReadingPress() {
    guard let text = readingText else { return }
    if heldSelection !== text { heldSelection?.setSelectedRange(NSRange()) }
    let selects = text.selectedRange().length > 0
    if text is PaletteAnswerTextView {
      heldSelection = selects ? text : nil
    } else if selects {
      heldSelection = nil
      return
    }
    applyPromptForegroundAppearance()
    window?.makeFirstResponder(field)
  }

  func routeKeyFromReadingText(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
    if modifiers == [.command], event.latinCharactersIgnoringModifiers == "c" {
      guard window?.firstResponder === field, field.selectedRange().length == 0,
            let held = heldSelection, held.selectedRange().length > 0,
            !held.isHiddenOrHasHiddenAncestor, held.window === window
      else { return false }
      held.copy(nil)
      return true
    }
    guard readingText != nil, modifiers.isDisjoint(with: [.command, .control]) else { return false }
    applyPromptForegroundAppearance()
    window?.makeFirstResponder(field)
    return false
  }

  func setWorkingDirectory(_ chip: WorkingDirectoryChip?) {
    let wasHidden = directoryChip.isHidden
    workingDirectory = chip
    if let chip { directoryChip.apply(chip) }
    syncDirectoryChipVisibility()
    needsLayout = true
    if wasHidden != directoryChip.isHidden { onContentSizeChange?() }
  }

  func showWorkingDirectoryMenu(_ menu: NSMenu) {
    menu.appearance = NSAppearance(named: .darkAqua)
    let gap: CGFloat = 4
    let below = NSPoint(
      x: 0,
      y: directoryChip.isFlipped ? directoryChip.bounds.maxY + gap : -gap)
    menu.popUp(positioning: nil, at: below, in: directoryChip)
  }

  private var composerIsUp: Bool {
    !showsCompactListening
      && !(isResultsExpanded && addressedPreview == nil)
  }

  private func syncDirectoryChipVisibility() {
    let composerIsUp = self.composerIsUp
    let hidden = workingDirectory == nil || !composerIsUp || asksAboutRegion
    if directoryChip.isHidden != hidden {
      directoryChip.isHidden = hidden
    }
    let diameter = composerControlDiameter
    directoryChip.diameter = diameter
    planRing.diameter = diameter
    planRing.ringOuterDiameter = ComposerControlGroup.glyph(chat: composerGlyphsAreChat)
    trailingControls.setCustomSpacing(planRing.hasReading ? trailingControls.spacing : 0, after: planRing)
    let folderWidth: CGFloat = workingDirectory == nil || asksAboutRegion ? 0 : directoryChip.slotWidth
    if directorySlotWidth.constant != folderWidth { directorySlotWidth.constant = folderWidth }
    let folderStack = composerGlyphsAreChat ? leadingControls : trailingControls
    folderStack.setCustomSpacing(folderWidth == 0 ? 0 : folderStack.spacing, after: directorySlot)
    syncModelChip()
    let usageHidden = !composerIsUp || !planRing.hasReading || asksAboutRegion
    planRing.chatIsOpen = addressedPreview != nil
    if planRing.isHidden != usageHidden {
      planRing.isHidden = usageHidden
    }
    syncLatestPill()
  }

  private var asksAboutRegion: Bool {
    screenSelectionPhase != .idle && addressedPreview == nil
  }

  private func syncModelChip() {
    let chip = composerIsUp && composerGlyphsAreChat ? addressedPreview?.modelChip : nil
    let hidden = chip == nil
    if modelChipButton.isHidden != hidden { modelChipButton.isHidden = hidden }
    let width = chip.map {
      let words = NSAttributedString(string: $0.title, attributes: [.font: Self.modelChipFont])
      return min(ceil(words.size().width) + ComposerControlGroup.gap, Self.modelChipMaxWidth)
    } ?? 0
    if modelChipWidth.constant != width {
      modelChipWidth.constant = width
      needsLayout = true
    }
    leadingControls.setCustomSpacing(hidden ? 0 : leadingControls.spacing, after: modelChipSlot)
    guard chip != shownModelChip else { return }
    let wasShown = shownModelChip != nil
    shownModelChip = chip
    guard let chip else { return }
    let button = modelChipButton
    if wasShown, !MotionPreferences.reduceMotion, let layer = button.layer {
      let fade = CATransition()
      fade.type = .fade
      fade.duration = Motion.quick
      fade.timingFunction = Motion.standardCurve
      layer.add(fade, forKey: "modelChip")
    }
    button.title = chip.title
    button.restingTint = chip.isGone ? AgentPaletteMetrics.failureCardAccent : ComposerControlGroup.restingInk
    button.toolTip = chip.help
    button.setAccessibilityLabel("Model")
    button.setAccessibilityValue(chip.title)
  }

  @objc private func modelChipPressed() { onModelMenu?() }

  func showModelMenu(_ menu: NSMenu) {
    menu.appearance = NSAppearance(named: .darkAqua)
    let gap: CGFloat = 4
    let below = NSPoint(
      x: 0,
      y: modelChipButton.isFlipped ? modelChipButton.bounds.maxY + gap : -gap)
    menu.popUp(positioning: nil, at: below, in: modelChipButton)
  }

  var modelChipButtonForTesting: PaletteIconButton { modelChipButton }
  var isModelChipVisibleForTesting: Bool { !modelChipButton.isHidden }
  func pressModelChipForTesting() { modelChipPressed() }

  private func syncLatestPill() {
    let latestHidden = !offersLatest || addressedPreview == nil || !composerIsUp
      || !notice.isHidden
    setLatestPillShown(!latestHidden)
  }

  func setUsage(_ usage: AgentUsage?, agent: AgentId?) {
    planRing.apply(usage, agent: agent)
    syncDirectoryChipVisibility()
    needsLayout = true
  }

  var planRingForTesting: PlanUsageRingView { planRing }
  var latestPillForTesting: GlassCircleButton { latestPill }

  private var isLatestPillShown = false

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

  static let chatComposerPlaceholder = "Describe a task or ask a question"

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

  private var draftHasWords: Bool {
    !field.draft.typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func setContext(_ usage: AgentContextUsage?, canCompact: Bool, cacheIsCold: Bool = false) {
    planRing.apply(context: usage, canCompact: canCompact, cacheIsCold: cacheIsCold)
    syncDirectoryChipVisibility()
    needsLayout = true
  }

  func announceQueued(_ message: String) {
    announce(message)
  }

  private func applyStopAffordance(_ preview: BolttyAISessionPreview) {
    stopTooltip = preview.stopIsAbrupt
      ? "Stop — this turn is lost, the chat is kept"
      : "Stop response"
  }

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

  private func syncVoiceGlowPalette() {
    let palette = selectedAgentImage.mascotPaletteID
      .flatMap(MascotPalette.palette(withID:))
      ?? MascotPalette.face(for: agentForNewPrompt)
    voiceGlow.apply(palette: palette)
    if let look = selectedAgentImage.mascotLook { listeningFace.apply(look: look) }
    listeningWords.colors = VoiceEdgeGlowLayout.rayColors(from: palette)
    field.caretPalette = palette
  }

  /// `CADisplayLink` retains its target, so a spring in flight when the view is
  /// torn down would keep itself and its clock alive.
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
    selectedAgentImage.layer?.filters = nil
    field.alphaValue = 1
    hintLabel.alphaValue = 1
    applyPromptForegroundAppearance()
  }

  func prepareForPresentation(resumingChat: Bool = false) {
    if !resumingChat { returnToSessionID = nil }
    surfaceReady = false
    pendingConversationID = UUID()
    if !resumingChat {
      mode = .prompt
      collapseResults(animated: false)
      leaveAddressing(animated: false)
    }
    syncPromptHeight()
    resetAgentChoice()
    setComposerKeyTarget(.text)
    if !resumingChat { renderPromptMark(animated: false) }
    field.alphaValue = 1
    hintLabel.alphaValue = 1
    selectedAgentImage.alphaValue = 1
  }

  func prepareCapsuleForEntrance() {
  }

  private func applyPromptForegroundAppearance() {
    selectedAgentImage.alphaValue = 1
    selectedAgentImage.contentTintColor = Self.promptIconTintColor
    field.textColor = Self.promptTypingTextColor
    field.insertionPointColor = Self.promptTypingTextColor
    field.typingAttributes = field.defaultTypingAttributes
  }

  func setSessions(
    _ items: [BolttyAISessionItem],
    transcripts: [UUID: ConversationTranscript] = [:]
  ) {
    if isResultsExpanded, let held = heldSessionItems, !held.isEmpty {
      self.sessionItems = BolttyAISessionList.holding(items, to: held)
    } else {
      self.sessionItems = items
    }
    if isResultsExpanded { heldSessionItems = sessionItems }
    self.sessionTranscripts = transcripts
    if isResultsExpanded {
      refreshResults(keepingSelection: true)
    }
  }

  var resultsStackForTesting: ResultsListView { resultsStack }
  var historyTabsForTesting: AgentHistoryTabStripView { historyTabs }
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
    onWillShowSessions?()
    isResultsExpanded = true
    refreshResults(keepingSelection: false)
  }

  var isShowingSessions: Bool { isResultsExpanded && !showsNoAgentsState }

  /// The card keeps its full geometry until the fade is over: zeroing the height
  /// with the fade lays the panel out synchronously and crushes the still-opaque
  /// card for a frame.
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

  private func releaseResultsHeight() {
    resultsCapsule.isHidden = true
    resultsHeightConstraint.constant = 0
    resultsTopConstraint.constant = 0
    anchorErrorLabel()
    onContentSizeChange?()
  }

  func enterAddressing(_ preview: BolttyAISessionPreview) {
    setComposerKeyTarget(.text)
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
    syncModelChip()
    stopIsAvailable = preview.isBusy && preview.canStop
    applyStopAffordance(preview)
    syncSendButton()
    // In the panel first, at its width. The first chat since launch was measured
    // with the card nowhere: its words wrapped narrow, its floor stayed that
    // tall, and a long chat opened on the blank under its end.
    showPreview(animated: true)
    needsLayout = true
    layoutSubtreeIfNeeded()
    previewCard.apply(preview)
    previewCard.resumeAnimations()
    render(
      agent: preview.agent,
      conversationID: preview.id,
      emotion: MascotEmotion(reportedState: preview.state),
      animated: true
    )
    hintLabel.stringValue = Self.composerPlaceholder(for: preview)
    hintLabel.isHidden = !field.isEmptyPrompt
    needsLayout = true
    layoutSubtreeIfNeeded()
    syncPromptExpansion()
    syncPromptHeight()
  }

  func updateAddressing(_ preview: BolttyAISessionPreview) {
    guard addressedPreview?.id == preview.id else { return }
    let changed = preview != addressedPreview
    hintLabel.stringValue = Self.composerPlaceholder(for: preview)
    if let line = BolttyAIAnnouncement.forTransition(from: addressedPreview, to: preview) {
      announce(line)
    }
    addressedPreview = preview
    syncModelChip()
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
    guard changed else { return }
    previewBandHeight = reservedTranscriptHeight
    needsLayout = true
    layoutSubtreeIfNeeded()
    onContentSizeChange?()
  }

  private var reservedTranscriptHeight: CGFloat {
    max(0, chatSurfaceSize.height - chatComposerBand)
  }

  private var isOpenChat: Bool { addressedPreview != nil && !showsCompactListening }

  private var promptSurfaceWidth: CGFloat {
    isDraftExpanded ? AgentPaletteMetrics.promptGrownWidth : AgentPaletteMetrics.promptSize.width
  }

  private var isHistoryOpen: Bool { isResultsExpanded && addressedPreview == nil }

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
    syncModelChip()
    onLeaveAddressing?(left)
    stopIsAvailable = false
    hidePreview(animated: animated)
    if mode == .prompt {
      renderPromptMark(animated: false)
    }
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
        let draft = self.currentDraft
        let kind = PromptAttachmentKind.resolve(for: url)
        self.applyIngest(.attachments([
          PromptAttachment.file(url, label: draft.nextGeneratedLabel(for: kind)),
        ]))
        self.onDraftChange?()
        _ = self.focusField()
      }
      previewCard.onRetry = { [weak self] prompt in
        guard let self, let id = self.addressedPreview?.id else { return }
        self.onRetryPrompt?(id, prompt)
      }
      previewCard.onChooseModel = { [weak self] in self?.onModelMenu?() }
      previewCard.onCancelQueued = { [weak self] prompt in
        guard let self, let id = self.addressedPreview?.id else { return }
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
      newSections = AgentHistory.sections(listedSessionItems, agent: activeHistoryAgent)
      newItems = newSections.flatMap(\.items)
    } else {
      newSections = []
      newItems = BolttyAISessionList.filter(
        listedSessionItems,
        transcripts: sessionTranscripts,
        query: resultsQuery
      )
    }
    let contentChanged = newItems != resultItems || newSections != resultSections
      || newItems.isEmpty
    resultItems = newItems
    resultSections = newSections
    historyTabs.setVisible(showsHistoryChrome)
    setResultsOverlap(showsHistoryChrome ? AgentPaletteMetrics.historyTabOverlap : 0)
    setHistoryFootVisible(mode == .picking)
    if showsHistoryChrome {
      historyTabs.apply(
        tabs: AgentHistory.tabs(listedSessionItems, agents: listedAgents), activeAgent: activeHistoryAgent,
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
    } else if contentChanged {
      syncResultRows()
      if mode == .picking {
        renderAddressee()
      }
    } else {
      let faces = showsHistoryChrome && activeHistoryAgent == nil
      for row in rowsByConversation.values { row.setShowsFace(faces) }
      applySelectionHighlight(animated: false)
      scrollSelectedResultVisible()
    }

    let isAppearing = resultsCapsule.isHidden || resultsCapsule.alphaValue < 1

    resultsHeightConstraint.constant = measuredResultsCardHeight()
    resultsTopConstraint.constant = AgentPaletteMetrics.resultsTopSpacing
    anchorErrorLabel()
    onContentSizeChange?()

    resultsCapsule.isHidden = false

    guard isAppearing else { return }
    needsLayout = true
    layoutSubtreeIfNeeded()
    scrollSelectedResultVisible()
    revealSurfaceContent()
  }

  func layoutForPresentation() {
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  private static let targetSwapBlurFilterName = "bolttyTargetSwapBlur"
  private static let targetSwapBlurKey = "targetSwapBlur"

  func setInstallHints(_ agents: [AgentId]) {
    showsNoAgentsState = !agents.isEmpty
  }

  func revealInstallHintsIfNeeded() {
    guard showsNoAgentsState, mode == .prompt, field.isEmptyPrompt else { return }
    isResultsExpanded = true
    refreshResults(keepingSelection: false)
  }

  func setCatalogScanning(_ scanning: Bool) {
    if scanning, agentForNewPrompt == nil, field.isEmptyPrompt, mode == .prompt {
      hintLabel.stringValue = "Looking for agents…"
      hintLabel.isHidden = false
      selectedAgentImage.showMascot(
        conversationID: pendingConversationID,
        emotion: .thinking,
        look: MascotLook.face(for: nil)
      )
    } else if !scanning, agentForNewPrompt == nil, mode == .prompt {
      refreshMascotEmotion()
    }
  }

  private func measuredResultsCardHeight() -> CGFloat {
    max(0, historySurfaceHeight - (mode == .search ? promptCapsuleHeightConstraint.constant : 0))
  }

  private(set) var listedAgents = AgentHistory.tabOrder

  private var listedSessionItems: [BolttyAISessionItem] {
    guard listedAgents != AgentHistory.tabOrder else { return sessionItems }
    let hidden = Set(AgentHistory.tabOrder).subtracting(listedAgents)
    return sessionItems.filter { !hidden.contains($0.agent) }
  }

  func setListedAgents(_ agents: [AgentId]) {
    let listed = agents.isEmpty ? AgentHistory.tabOrder : agents
    guard listed != listedAgents else { return }
    listedAgents = listed
    let stops = AgentHistory.stops(for: listed)
    if !stops.contains(activeHistoryAgent) { activeHistoryAgent = stops.first ?? nil }
    syncHistoryNewChat()
    if isResultsExpanded { refreshResults(keepingSelection: true) }
  }

  private func selectHistoryAgent(_ agent: AgentId?) {
    guard agent != activeHistoryAgent else { return }
    activeHistoryAgent = agent
    resultsScroll.contentView.setBoundsOrigin(.zero)
    resultsScroll.reflectScrolledClipView(resultsScroll.contentView)
    refreshResults(keepingSelection: false)
  }

  private func stepHistoryTab(by delta: Int) {
    let agent = AgentHistory.adjacentTab(to: activeHistoryAgent, by: delta, among: listedAgents)
    guard agent != activeHistoryAgent else { return }
    keyboardSelectionPointerAnchor = pointerLocation
    setResultHoverQuiet(true)
    selectHistoryAgent(agent)
    announce(agent?.shortDisplayName ?? "All")
  }

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

  private func discardResultRows() {
    resultsStack.removeAllArrangedSubviews()
    resultLines = []
    resultLineIndexByRow = []
    rowsByConversation = [:]
    headersByDay = [:]
  }

  private func syncResultRows() {
    isShowingInstallHints = false

    guard !resultItems.isEmpty else {
      discardResultRows()
      resultsStack.addArrangedSubview(
        (showsHistoryChrome ? activeHistoryAgent : nil)
          .map(BolttyAIEmptyResultsView.init(emptyHistoryFor:))
          ?? BolttyAIEmptyResultsView(query: resultsQuery, agent: agentForNewPrompt)
      )
      return
    }

    let live = Set(sessionItems.map(\.id)).union(resultItems.map(\.id))
    for (id, row) in rowsByConversation where !live.contains(id) {
      row.removeFromSuperview()
      rowsByConversation.removeValue(forKey: id)
    }
    let liveDays = Set(resultSections.map(\.id))
    for (day, header) in headersByDay where !liveDays.contains(day) {
      header.removeFromSuperview()
      headersByDay.removeValue(forKey: day)
    }

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
    resultsStack.setLines(lines.map(\.listLine)) { [weak self] index in
      self?.resultLineView(at: index) ?? NSView()
    }

    scrollSelectedResultVisible()
    syncResultRowHover()
  }

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
      row.setShowsFace(showsHistoryChrome && activeHistoryAgent == nil)
      row.setHighlighted(item.id == selectedResultID, animated: false)
      return row
    }
  }

  private var selectedResultID: UUID? {
    resultItems.indices.contains(selectedResultIndex) ? resultItems[selectedResultIndex].id : nil
  }

  private func syncResultRowHover() {
    guard let window else { return }
    resultsScroll.layoutSubtreeIfNeeded()
    let point = window.convertPoint(fromScreen: pointerLocation)
    let uncovered: NSPoint? = isUnderHistoryTabs(point) || isOnHistoryFoot(point) ? nil : point
    for row in rowsByConversation.values {
      row.syncHover(pointerInWindow: uncovered)
    }
  }

  private func isUnderHistoryTabs(_ pointInWindow: NSPoint) -> Bool {
    guard resultsOverlap > 0, !historyTabs.isHidden else { return false }
    return historyTabs.bounds.contains(historyTabs.convert(pointInWindow, from: nil))
  }

  private func isOnHistoryFoot(_ pointInWindow: NSPoint) -> Bool {
    guard showsHistoryFoot else { return false }
    return [historyNewChatButton, historySettingsButton].contains {
      $0.bounds.contains($0.convert(pointInWindow, from: nil))
    }
  }

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

  private func setResultsOverlap(_ overlap: CGFloat) {
    guard overlap != resultsOverlap else { return }
    resultsOverlap = overlap
    resultsScrollTop.constant = -overlap
    var insets = resultsStack.edgeInsets
    insets.top = AgentPaletteMetrics.resultsVerticalInset + overlap
    resultsStack.edgeInsets = insets
    updateResultsTopEdge()
  }

  private func updateResultsTopEdge() {
    let height = resultsScroll.bounds.height
    guard height > 0 else { return }
    let overlap = min(resultsOverlap, height)
    let soft = AgentPaletteMetrics.previewScrollEdgeSoftness
    let flipped = resultsScroll.layer?.isGeometryFlipped ?? resultsScroll.isFlipped
    let gone = overlap * 0.25
    var stops: [(y: CGFloat, alpha: CGFloat)] = overlap > 0
      ? ScrollEdgeBlur.smoothstep.map { (gone + (overlap - gone) * $0.t, $0.s) }
      : [(0, 1)]
    if overlap > 0 { stops.insert((0, 0), at: 0) }
    if showsHistoryFoot {
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
  }

  private func applySelectionHighlight(animated: Bool) {
    let selected = selectedResultID
    for row in rowsByConversation.values {
      row.setHighlighted(row.item.id == selected, animated: animated)
    }
    if mode == .picking {
      renderAddressee()
    }
  }

  private func renderAddressee() {
    guard selectedResultIndex >= 0, selectedResultIndex < resultItems.count else {
      renderPromptMark(animated: false)
      hintLabel.isHidden = !field.isEmptyPrompt
      return
    }
    let item = resultItems[selectedResultIndex]
    render(agent: item.agent, conversationID: item.id, emotion: .focused, animated: false)
    selectedAgentImage.toolTip = "Message \(item.title)"
    hintLabel.stringValue = "Message this chat"
    hintLabel.isHidden = !field.isEmptyPrompt
  }

  private func moveResultSelection(by delta: Int) {
    guard !resultItems.isEmpty else { return }
    highlightResult(at: min(max(selectedResultIndex + delta, 0), resultItems.count - 1))
  }

  private var resultRowsPerPage: Int {
    let foot = showsHistoryFoot ? AgentPaletteMetrics.historyFootHeight : 0
    let clear = resultsScroll.contentView.bounds.height - resultsOverlap - foot
      - 2 * AgentPaletteMetrics.resultsVerticalInset
    return max(1, Int(clear / AgentPaletteMetrics.resultsRowHeight))
  }

  private func highlightResult(at index: Int) {
    guard resultItems.indices.contains(index), index != selectedResultIndex else { return }
    selectedResultIndex = index
    keyboardSelectionPointerAnchor = pointerLocation
    setResultHoverQuiet(true)
    applySelectionHighlight(animated: false)
    scrollSelectedResultVisible()
    announce(resultItems[index].title)
  }

  private func setResultHoverQuiet(_ quiet: Bool) {
    for row in rowsByConversation.values { row.hoverIsQuiet = quiet }
  }

  private func scrollSelectedResultVisible() {
    guard resultLineIndexByRow.indices.contains(selectedResultIndex) else { return }
    let clipView = resultsScroll.contentView
    // A held arrow key repeats ~25 times a second: lay out only the scroll view's
    // subtree.
    resultsScroll.layoutSubtreeIfNeeded()

    let line = resultLineIndexByRow[selectedResultIndex]
    let rowFrame = resultsStack.frameOfLine(at: line)
    var head = rowFrame
    if line > 0, case .heading = resultLines[line - 1] {
      head = resultsStack.frameOfLine(at: line - 1)
    }
    let visible = clipView.bounds
    guard visible.height > 0 else { return }

    let inset = AgentPaletteMetrics.resultsVerticalInset
    let foot = showsHistoryFoot ? AgentPaletteMetrics.historyFootHeight : 0
    let top = max(0, head.minY - inset - resultsOverlap)
    let bottom = rowFrame.maxY + inset + foot - visible.height
    var origin = visible.origin
    if visible.minY > top {
      origin.y = top
    } else if visible.minY < bottom {
      origin.y = min(top, bottom)
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

  func openResult(withID id: UUID) {
    selectResult(withID: id)
  }

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

  private func confirmSelectionOrSubmit() {
    guard !isVoiceProcessing else { return }
    if isVoiceListening {
      onVoiceConfirm?()
      return
    }
    if let addressedPreview {
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

  func confirmCurrentDraft() {
    confirmSelectionOrSubmit()
  }

  // MARK: - Mode

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
      field.setDraft(PromptDraft(field.searchQuery))
    }
    mode = .prompt
    applyModeChrome()
    collapseResults()
  }

  private func applyModeChrome() {
    switch mode {
    case .search:
      selectedAgentImage.showMascot(
        conversationID: pendingConversationID,
        emotion: .focused,
        look: MascotLook.face(for: agentForNewPrompt)
      )
      selectedAgentImage.setAccessibilityLabel("Search chats")
      selectedAgentImage.toolTip = "Searching chats"
      hintLabel.stringValue = "Search chats"
    case .picking:
      renderAddressee()
    case .prompt:
      renderPromptMark(animated: false)
    }
    hintLabel.isHidden = !field.isEmptyPrompt
    applyPromptForegroundAppearance()
    syncTrailingHint()
  }

  // MARK: - The agent a new prompt starts on

  func setAgentChoices(_ agents: [AgentId], planned: AgentId?) {
    guard agents != agentChoices || planned != plannedAgent else { return }
    let changed = agents != agentChoices
    agentChoices = agents
    plannedAgent = planned
    if let chosen = chosenAgent, !agents.contains(chosen) { chosenAgent = nil }
    syncHistoryNewChat()
    if changed, isResultsExpanded { refreshResults(keepingSelection: true) }
    if mode == .prompt, addressedPreview == nil {
      renderPromptMark(animated: false)
    }
    syncTrailingHint()
  }

  func chooseAgent(_ agent: AgentId) {
    guard agentChoices.contains(agent) else { return }
    let chosen = agent == plannedAgent ? nil : agent
    guard chosen != chosenAgent else { return }
    chosenAgent = chosen
    if mode == .prompt, addressedPreview == nil {
      renderPromptMark(animated: true)
    }
    onAgentChoiceChange?()
    syncTrailingHint()
  }

  func resetAgentChoice() {
    guard chosenAgent != nil else { return }
    chosenAgent = nil
    if mode == .prompt, addressedPreview == nil {
      renderPromptMark(animated: false)
    }
    onAgentChoiceChange?()
  }

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

  private func agentChoice(movingFrom agent: AgentId?, by delta: Int) -> AgentId? {
    guard agentChoices.count > 1 else { return nil }
    let count = agentChoices.count
    let current = agent.flatMap(agentChoices.firstIndex(of:)) ?? (delta > 0 ? -1 : 0)
    return agentChoices[((current + delta) % count + count) % count]
  }

  private enum ComposerKeyTarget: Equatable {
    case text
    case folder
    case microphone
  }

  private var composerKeyTarget: ComposerKeyTarget = .text

  private var isFirstScreen: Bool {
    mode == .prompt && addressedPreview == nil && !isResultsExpanded
  }

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

  private func pressComposerChord(_ chord: ComposerChord) -> Bool {
    guard mode == .prompt else { return false }
    let button: NSButton = switch chord {
    case .dictate: micButton
    case .folder: directoryChip
    case .attach: attachRestDisc.button
    case .model: modelChipButton
    }
    let standing = switch chord {
    case .dictate: !micButton.isHidden
    case .folder: !directoryChip.isHidden
    case .attach: !attachRestDisc.isHidden
    case .model: !modelChipButton.isHidden
    }
    guard standing, button.isEnabled else { return false }
    button.performClick(nil)
    return true
  }

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

  var trailingHintForTesting: [String] { field.trailingHint.map { "\($0.words) \($0.key)" } }

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

  private func renderPromptMark(animated: Bool) {
    if animated { beginTargetSwap() }
    defer {
      syncTrailingHint()
      syncSelectionOverlay()
    }

    hintLabel.stringValue = "Describe a task or ask a question"
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
      selectedAgentImage.showMascot(
        conversationID: pendingConversationID,
        emotion: emotion ?? .focused,
        look: MascotLook.face(for: agentForNewPrompt)
      )
    } else {
      selectedAgentImage.showMascot(
        conversationID: pendingConversationID,
        emotion: emotion ?? (isVoiceListening ? .listening : .curious),
        look: MascotLook.face(for: agentForNewPrompt)
      )
    }
    syncVoiceGlowPalette()
  }

  private func beginTargetSwap() {
    guard !MotionPreferences.reduceMotion, let layer = selectedAgentImage.layer else { return }

    let crossfade = CATransition()
    crossfade.type = .fade
    crossfade.duration = AgentPaletteMetrics.targetSwapFadeDuration
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
        guard layer?.animation(forKey: Self.targetSwapBlurKey) == nil else { return }
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
    field.onComposerChord = { [weak self] in self?.pressComposerChord($0) ?? false }
    field.onMouseDown = { [weak self] in self?.setComposerKeyTarget(.text) }
    field.onAttachmentsChange = { [weak self] animated in
      guard let self else { return }
      self.attachmentStrip.show(self.field.attachments, animated: animated)
    }
    attachmentStrip.onRemove = { [weak self] id in
      guard let self else { return }
      self.field.removeAttachment(id: id)
      _ = self.focusField()
    }
    attachmentStrip.onOpen = { attachment in
      guard let url = try? PromptAttachmentStore.shared.fileURL(for: attachment) else { return }
      FileQuickLookStore.shared.show(url: url)
    }
    registerForDraggedTypes([.fileURL, .png, .tiff, .string])
    let agentClick = NSClickGestureRecognizer(
      target: self,
      action: #selector(pokePromptMark)
    )
    selectedAgentImage.addGestureRecognizer(agentClick)
    promptScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
    modelChipSlot.translatesAutoresizingMaskIntoConstraints = false
    modelChipSlot.addSubview(modelChipButton)
    modelChipButton.target = self
    modelChipButton.action = #selector(modelChipPressed)
    modelChipButton.setAccessibilityIdentifier("boltty.ask.model")
    modelChipButton.helpShortcut = ComposerChord.model.display
    modelChipButton.isHidden = true
    NSLayoutConstraint.activate([
      modelChipWidth,
      modelChipSlot.heightAnchor.constraint(equalToConstant: ComposerControlGroup.target),
      modelChipButton.leadingAnchor.constraint(equalTo: modelChipSlot.leadingAnchor),
      modelChipButton.trailingAnchor.constraint(equalTo: modelChipSlot.trailingAnchor),
      modelChipButton.topAnchor.constraint(equalTo: modelChipSlot.topAnchor),
      modelChipButton.bottomAnchor.constraint(equalTo: modelChipSlot.bottomAnchor),
    ])
    trailingControls.setViews([planRing, directorySlot, micButton, sendSlot], in: .leading)
    ComposerControlGroup.style(planRing)
    ComposerControlGroup.style(directoryChip)
    ComposerControlGroup.style(attachRestDisc.button)
    ComposerControlGroup.style(modelChipButton)
    ComposerControlGroup.styleSendDisc(sendButton.button)
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
    leadingControls.orientation = .horizontal
    leadingControls.alignment = .centerY
    leadingControls.spacing = AgentPaletteMetrics.restingControlsSpacing
    leadingControls.translatesAutoresizingMaskIntoConstraints = false
    leadingControls.detachesHiddenViews = false
    leadingControls.setViews([attachRestSlot, modelChipSlot], in: .leading)
    promptForeground.addSubview(leadingControls)
    NSLayoutConstraint.activate([
      leadingControls.leadingAnchor.constraint(
        equalTo: promptForeground.leadingAnchor,
        constant: AgentPaletteMetrics.chatComposerControlsTrailingInset),
      leadingControls.centerYAnchor.constraint(equalTo: trailingControls.centerYAnchor),
    ])
    promptForeground.addSubview(recordingHoverSensor)
    promptForeground.addSubview(recordingControls)

    hintLabel.stringValue = "Describe a task or ask a question"
    hintLabel.font = PromptTextView.promptFont
    hintLabel.textColor = AgentPaletteMetrics.chatComposerPlaceholderInk
    hintLabel.translatesAutoresizingMaskIntoConstraints = false
    hintLabel.wantsLayer = true
    hintLabel.setContentHuggingPriority(.required, for: .horizontal)
    hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    hintLabel.isHidden = false
    promptForeground.addSubview(hintLabel)

    NSLayoutConstraint.activate([
      selectedAgentImage.centerXAnchor.constraint(
        equalTo: promptForeground.leadingAnchor,
        constant: AgentPaletteMetrics.promptLeadingInset + AgentPaletteMetrics.iconSize / 2
      ),
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

      editorLeading,
      promptScrollHeightConstraint,

      micWidth,
      micHeight,

      hintLabel.leadingAnchor.constraint(equalTo: promptScroll.leadingAnchor),
      hintBaseline,
      hintLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingControls.leadingAnchor,
        constant: -AgentPaletteMetrics.promptMicTextSpacing
      ),
      controlsTrailing,
      controlsTop,
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

    inlineControlConstraints = [
      promptScroll.centerYAnchor.constraint(equalTo: promptForeground.centerYAnchor),
    ]
    expandedPromptConstraints = [expandedPromptTop]
    NSLayoutConstraint.activate(inlineControlConstraints + [editorTrailing])

    applyPromptForegroundAppearance()
    applyMicAppearance()
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
    resultsScroll.verticalScroller = PaletteInvisibleScroller()
    resultsScroll.scrollerStyle = .overlay
    resultsScroll.documentView = resultsStack
    resultsScroll.translatesAutoresizingMaskIntoConstraints = false
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
    directoryChip.helpShortcut = ComposerChord.folder.display
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
    previewForeground.layer?.cornerRadius = 0
    previewForeground.layer?.masksToBounds = true
    applyFloatingShadow(
      to: promptCapsule,
      cornerRadius: AgentPaletteMetrics.cornerRadius
    )

    promptCapsule.addSubview(promptHost)
    promptCapsule.addSubview(promptForeground)
    attachmentStrip.translatesAutoresizingMaskIntoConstraints = false
    attachmentStrip.isHidden = true
    promptCapsule.addSubview(attachmentStrip)
    promptHost.layer?.zPosition = 0
    promptForeground.layer?.zPosition = 10
    attachmentStrip.layer?.zPosition = 10
    resultsCapsule.addSubview(resultsForeground)
    resultsForeground.layer?.zPosition = 10
    previewCapsule.addSubview(previewForeground)
    previewForeground.layer?.zPosition = 10
    surface.translatesAutoresizingMaskIntoConstraints = true
    surface.wantsLayer = true
    surfaceContainer.wantsLayer = true
    surfaceContainer.addSubview(surface)
    screenOutlines.frame = bounds
    screenOutlines.autoresizingMask = [.width, .height]
    addSubview(screenOutlines)
    voiceGlow.translatesAutoresizingMaskIntoConstraints = true
    addSubview(voiceGlow)
    addSubview(surfaceContainer)
    addSubview(backdrop)
    listeningWordsHost.translatesAutoresizingMaskIntoConstraints = true
    listeningWordsHost.wantsLayer = true
    listeningWordsHost.layer?.masksToBounds = true
    listeningWordsHost.alphaValue = 0
    listeningWords.translatesAutoresizingMaskIntoConstraints = true
    listeningWords.alphaValue = 0
    listeningFace.emotion = .listening
    listeningFace.isHidden = true
    listeningWordsHost.addSubview(listeningWords)
    listeningWordsHost.addSubview(listeningFace)
    addSubview(listeningWordsHost)
    scrollIndicator.translatesAutoresizingMaskIntoConstraints = true
    scrollIndicator.autoresizingMask = [.width, .height]
    addSubview(previewCapsule)
    addSubview(promptCapsule)
    addSubview(resultsCapsule)
    addSubview(bottomBar)
    addSubview(latestPill)
    NSLayoutConstraint.activate(latestPillConstraints)
    addSubview(notice)
    NSLayoutConstraint.activate([noticeCenterX, noticeTopToPrompt])

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
      promptForegroundTop,
      promptForeground.bottomAnchor.constraint(equalTo: promptCapsule.bottomAnchor),

      attachmentStrip.leadingAnchor.constraint(equalTo: promptCapsule.leadingAnchor),
      attachmentStrip.trailingAnchor.constraint(equalTo: promptCapsule.trailingAnchor),
      attachmentStrip.bottomAnchor.constraint(equalTo: promptForeground.topAnchor),
      attachmentStripHeight,

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

    resizeGrabber.isHidden = true
    addSubview(resizeGrabber, positioned: .below, relativeTo: promptCapsule)
    scrollIndicator.frame = bounds
    addSubview(scrollIndicator)
    addSubview(selectionPointerHint)
  }

  override func setFrameSize(_ newSize: NSSize) {
    let heightChanged = abs(newSize.height - frame.height) > 0.5
    super.setFrameSize(newSize)
    applyPlacement()
    if heightChanged, addressedPreview != nil {
      previewBandHeight = reservedTranscriptHeight
    }
  }

  override func layout() {
    isPerformingLayout = true
    defer { isPerformingLayout = false }
    if !selectsOnDrag { hideSelectionPointerHint() }
    applyPlacement()
    super.layout()
    if window?.frame != outlinedWindowFrame { syncScreenOutlines() }
    updateUnifiedSurface()
    syncPointerWhereItIs()
    for capsule in [promptCapsule, resultsCapsule, previewCapsule] {
      capsule.layer?.shadowOpacity = 0
      // Guarded: `clipsToBounds` invalidates layout on every write, and writing
      // the value it already holds from inside `layout()` spins the run loop —
      // the same trap `syncResultsCardCorner` was written around.
      if capsule.clipsToBounds { capsule.clipsToBounds = false }
    }
  }

  private func applyPlacement() {
    let size = bounds.size
    guard size.width > 1, size.height > 1 else { return }
    let anchor = shellAnchor
    let top = anchor?.top ?? surfaceTopInset
    let offset = anchor?.offset ?? 0
    let chat = addressedPreview != nil
    applyComposerGlyphSize(chat: chat)
    promptHost.apply(surfaceStyle: chat ? .bolttyAIComposer : .bolttyAI)
    applySurfaceStyle(.bolttyAIPrompt)
    errorTopToPromptConstraint.constant = AgentPaletteMetrics.errorTopSpacing
    let height = promptCapsuleHeightConstraint.constant
    let grown = height > AgentPaletteMetrics.chatComposerHeight + 1
    promptHost.cornerRadius = chat
      ? (grown ? AgentPaletteMetrics.chatComposerRestingCornerRadius
        : AgentPaletteMetrics.chatComposerCornerRadius)
      : AgentPaletteMetrics.cornerRadius
    field.setChatComposerStyle(chat)
    selectedAgentImage.isHidden = chat
    hintLabel.font = chat ? PromptTextView.chatComposerFont : PromptTextView.promptFont
    hintLabel.textColor = AgentPaletteMetrics.chatComposerPlaceholderInk
    editorLeading.constant = chat
      ? AgentPaletteMetrics.chatComposerTextLeading
      : AgentPaletteMetrics.promptTextLeading
    bottomBar.edgeInsets = NSEdgeInsets(
      top: 0, left: editorLeading.constant, bottom: 0, right: editorLeading.constant)
    micWidth.constant = isVoiceListening
      ? AgentPaletteMetrics.voiceOrbDiameter
      : composerControlDiameter
    micHeight.constant = micWidth.constant
    micButton.setShowsGlass(isVoiceListening)
    let bottomControls = chat && isPromptExpanded
    let restingInset = usesExpandedControlLayout
      ? AgentPaletteMetrics.promptTrailingInset
      : chat
        ? AgentPaletteMetrics.chatComposerSendDiscInset
        : AgentPaletteMetrics.restingControlsTrailingInset
    controlsTrailing.constant = -restingInset
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
    hintBaseline.constant = field.typedBaselineFromTop
    _ = updatePromptHeights()
    expandedPromptTop.constant = bottomControls ? AgentPaletteMetrics.chatComposerGrownTextTop : 0
    controlsTop.constant = bottomControls
      ? promptCapsuleHeightConstraint.constant - attachmentBand
        - (AgentPaletteMetrics.chatComposerControlsPadding + ComposerControlGroup.glyph / 2)
      : (chat ? AgentPaletteMetrics.chatComposerHeight / 2 : AgentPaletteMetrics.promptSize.height / 2)
    let inset = chat ? AgentPaletteMetrics.shellContentInset : 0
    let width = chat ? chatSurfaceSize.width
      : isHistoryOpen ? historySurfaceWidth : promptSurfaceWidth
    promptWidthConstraint.constant = width - inset * 2
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
    previewTopConstraint.constant = -(promptCapsuleHeightConstraint.constant
      + previewBandHeight
      + (chat ? AgentPaletteMetrics.surfaceStackSpacing : 0))
  }

  private var wantedSurfaceStyle = PaletteSurfaceStyle.bolttyAI
  private var surfaceStyleIsScheduled = false

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

    let width: CGFloat
    if listening {
      width = listeningShellSize().width
    } else {
      width = isOpenChat ? chatSurfaceSize.width
        : isHistoryOpen ? historySurfaceWidth : promptSurfaceWidth
    }
    let unclamped: CGFloat
    if listening {
      unclamped = listeningShellSize().height
    } else if list {
      unclamped = historySurfaceHeight
    } else if chat {
      unclamped = chatSurfaceSize.height
    } else {
      unclamped = promptCapsuleHeightConstraint.constant
    }
    let height = unclamped

    let rect = CGRect(
      x: bounds.midX + (shellAnchor?.offset ?? promptCenterXConstraint.constant) - width / 2,
      y: bounds.height - top - height,
      width: width,
      height: height
    )
    promptHost.isHidden = !chat || listening
    listeningWordsWidth = width
    let saysWords = listening && !listeningWords.text.isEmpty && !isHandingOver
    let fades: [(NSView, Bool)] = [(listeningWordsHost, listening), (listeningWords, saysWords)]
    if listening { listeningFace.isHidden = false }
    for (view, shown) in fades where shown != (view.alphaValue > 0) {
      let hidesFace = view === listeningWordsHost && !shown
      if !MotionPreferences.reduceMotion, window?.isVisible == true {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = shown ? Motion.standard : Motion.quick
          context.timingFunction = Motion.emphasizedCurve
          view.animator().alphaValue = shown ? 1 : 0
        } completionHandler: { [weak self] in
          guard hidesFace, let self, !self.showsCompactListening else { return }
          self.listeningFace.isHidden = true
        }
      } else {
        view.alphaValue = shown ? 1 : 0
        if hidesFace { listeningFace.isHidden = true }
      }
    }
    listeningFace.reduceMotion = MotionPreferences.reduceMotion
    promptCapsule.alphaValue = (list && !searching) || listening ? 0 : 1
    previewCapsule.alphaValue = listening ? 0 : 1
    resultsCapsule.alphaValue = 1
    syncDirectoryChipVisibility()
    let jumps = placedPhase != screenSelectionPhase
    let opensBesideRegion = placedPhase == .drawing && screenSelectionPhase == .editing
    placedPhase = screenSelectionPhase
    let grows = opensBesideRegion && surfaceReady && dripTarget == nil
      && window?.isVisible == true && !MotionPreferences.reduceMotion
    if grows { surfaceMotion.move(to: regionSeed(for: rect), in: self, animated: false) }
    _ = surfaceMotion.move(
      to: dripTarget ?? rect,
      in: self,
      animated: resizeDrag == nil && surfaceReady && (!jumps || grows)
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
    rideAttachmentBand(at: rect)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surfaceContainer.frame = rect
    surface.frame = surfaceContainer.bounds
    voiceGlow.frame = rect
    let isChat = addressedPreview != nil && !showsCompactListening
    let isList = addressedPreview == nil && isResultsExpanded
    surface.cornerRadius = AgentPaletteMetrics.surfaceCornerRadius(
      forHeight: rect.height,
      shape: isChat ? .chat : (isList ? .list : (showsInitialPrompt ? .initial : .pill))
    )
    surface.layoutSubtreeIfNeeded()
    let corner = surface.renderedCornerRadius
    let curve = surface.renderedCornerCurve
    voiceGlow.surfaceCornerRadius = corner
    voiceGlow.surfaceCornerCurve = curve
    let agent = addressedPreview?.agent
    let chosen = isChat ? ChatBackdrop.chosen(for: agent) : .standard
    if !isDrippingIn {
      let skySize = dripTarget != nil ? resizeTarget.size : surfaceMotion.destination.size
      backdrop.morphingTo = surfaceMotion.isMoving ? skySize : nil
      backdrop.show(chosen, palette: chosen == .standard ? .standard : MascotPalette.face(for: agent))
      backdrop.layOut(in: rect, corner: corner, curve: curve)
    }
    layoutListeningWords(in: rect, corner: corner, curve: curve)
    layoutResizeGrabber(in: rect, corner: corner)
    scrollIndicatorShell = (rect, corner)
    syncScrollIndicator()
    applyFloatingShadow(to: surfaceContainer, cornerRadius: corner)
    syncShellShadow()
    let clippedContent = [promptForeground, attachmentStrip, resultsForeground, previewForeground]
    for content in clippedContent {
      let mask = (content.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
      mask.frame = content.bounds
      let local = convert(rect, to: content)
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

  private func layoutListeningWords(in rect: CGRect, corner: CGFloat, curve: CALayerCornerCurve) {
    listeningWordsHost.frame = rect
    listeningWordsHost.layer?.cornerRadius = corner
    listeningWordsHost.layer?.cornerCurve = curve
    let inset = AgentPaletteMetrics.listeningWordsInset
    let blur = AgentPaletteMetrics.listeningWordBlur
    let room = AgentPaletteMetrics.listeningMaxWidth - inset * 2
    let lines = listeningWords.measure(width: room).lines
    let width = max(0, listeningWordsWidth - inset * 2)
    let headroom = AgentPaletteMetrics.listeningFaceTopInset
      + AgentPaletteMetrics.listeningFaceSize + AgentPaletteMetrics.listeningFaceWordsGap - blur
    let height = headroom + CGFloat(max(1, lines)) * listeningWords.lineHeight + blur * 2
    listeningWords.wrapWidth = room
    listeningWords.headroom = headroom
    listeningWords.frame = CGRect(
      x: ((rect.width - width) / 2).rounded(),
      y: (rect.height - height).rounded(),
      width: width,
      height: height
    )
    layoutListeningFace()
  }

  private func layoutListeningFace() {
    let rect = listeningWordsHost.frame
    let face = AgentPaletteMetrics.listeningFaceSize
    let orb = AgentPaletteMetrics.listeningOrbDiameter
    let worded = AgentPaletteMetrics.listeningWordedHeight(lines: 1, lineHeight: listeningWords.lineHeight)
    let grown = max(0, min(1, (rect.height - orb) / (worded - orb)))
    let centred = (rect.height - face) / 2
    let atTop = rect.height - AgentPaletteMetrics.listeningFaceTopInset - face
    var frame = CGRect(
      x: ((rect.width - face) / 2).rounded(),
      y: (centred + (atTop - centred) * grown).rounded(),
      width: face,
      height: face
    )
    if let flight = faceFlight {
      let progress = (Motion.now - flight.start) / AgentPaletteMetrics.listeningFaceFlight
      if progress >= 1 {
        endFaceFlight()
      } else {
        let p = CGFloat(max(0, progress))
        let eased = 1 - pow(1 - p, 3)
        let from = flight.from.offsetBy(dx: -rect.minX, dy: -rect.minY)
        let side = from.width + (face - from.width) * eased
        let midX = from.midX + (frame.midX - from.midX) * eased
        let midY = from.midY + (frame.midY - from.midY) * eased + sin(.pi * p) * 14
        frame = CGRect(x: midX - side / 2, y: midY - side / 2, width: side, height: side)
      }
    }
    listeningFace.frame = frame
    listeningFace.lookAtWindowPoint = listeningWords.newestWordCentre.map {
      listeningWords.convert($0, to: nil)
    }
  }

  private func beginFaceFlight() {
    guard !MotionPreferences.reduceMotion, window?.isVisible == true,
          selectedAgentImage.window != nil, !selectedAgentImage.isHidden
    else { return }
    let mark = selectedAgentImage
    let centre = mark.convert(CGPoint(x: mark.bounds.midX, y: mark.bounds.midY), to: self)
    let side = AgentPaletteMetrics.promptMascotSize
    faceFlight = (CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side), Motion.now)
    if let identity = mark.mascotIdentity, let look = mark.mascotLook {
      listeningFace.reseed(conversationID: identity, look: look)
    }
    faceFlightTimer?.invalidate()
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.layoutListeningFace() }
    }
    RunLoop.main.add(timer, forMode: .common)
    faceFlightTimer = timer
  }

  private func endFaceFlight() {
    faceFlight = nil
    faceFlightTimer?.invalidate()
    faceFlightTimer = nil
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

  private enum ResizableShell { case chat, history }

  private var resizableShell: ResizableShell? {
    if isOpenChat { return .chat }
    if isHistoryOpen { return .history }
    return nil
  }

  private var resizeTarget: CGRect = .zero

  private let resizeGrabber = PaletteResizeGrabberView(frame: .zero)
  private var resizeHoverArea: NSTrackingArea?

  private func resizeEdges(at point: NSPoint) -> SurfaceResizeEdges? {
    guard resizableShell != nil, !resizeTarget.isEmpty else { return nil }
    if isOnHistoryFoot(convert(point, to: nil)) { return nil }
    return SurfaceResizeEdges.at(point, of: resizeTarget)
  }

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
    surfaceMotion.settle()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let drag = resizeDrag else {
      super.mouseDragged(with: event)
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    let dx = point.x - drag.start.x
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

  private func syncPointer(at point: NSPoint?) {
    syncSelectionPointerHint(at: point)
    guard resizeDrag == nil else { return }
    let onGrip = point.flatMap(gripRegion(at:)) != nil
    if onGrip != resizeGrabber.isHovered { resizeGrabber.isHovered = onGrip }
    if let cursor = heldCursor ?? point.flatMap(pointerCursor(at:)) {
      wear(cursor)
    } else {
      releasePointerCursor()
    }
  }

  private func syncPointerWhereItIs() {
    guard let window, window.isVisible else { return }
    let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    syncPointer(at: bounds.contains(point) ? point : nil)
  }

  private func syncSelectionPointerHint(at point: NSPoint?) {
    guard let point, resizeDrag == nil, selectsOnDrag, regionHintIsNeeded,
          isEmptyGlass(point), !isNearShellEdge(point) else {
      hideSelectionPointerHint()
      return
    }
    selectionPointerHint.setText(
      addressedPreview == nil
        ? AgentPaletteMetrics.screenSelectionHintText
        : AgentPaletteMetrics.screenSelectionChatHintText)
    selectionPointerHint.place(at: point, in: bounds)
    if selectionPointerHint.superview === self, subviews.last !== selectionPointerHint {
      addSubview(selectionPointerHint, positioned: .above, relativeTo: nil)
    }
    guard !selectionPointerHint.isShowing else { return }
    selectionPointerHintTimer?.invalidate()
    selectionPointerHintTimer = Timer.scheduledTimer(
      withTimeInterval: AgentPaletteMetrics.screenSelectionHintDelay,
      repeats: false
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.selectionPointerHint.show() }
    }
  }

  private var regionHintIsNeeded: Bool {
    UserDefaults.standard.integer(forKey: AgentPaletteMetrics.regionsDrawnKey)
      < AgentPaletteMetrics.regionHintUses
  }

  private func noteRegionDrawn() {
    guard !AppDelegate.isHostingUnitTests else { return }
    let drawn = UserDefaults.standard.integer(forKey: AgentPaletteMetrics.regionsDrawnKey)
    guard drawn < AgentPaletteMetrics.regionHintUses else { return }
    UserDefaults.standard.set(drawn + 1, forKey: AgentPaletteMetrics.regionsDrawnKey)
  }

  private func hideSelectionPointerHint() {
    selectionPointerHintTimer?.invalidate()
    selectionPointerHintTimer = nil
    selectionPointerHint.hide()
  }

  private var ownsPointer = false
  private var heldCursor: NSCursor?

  func releasePointerCursor() {
    hideSelectionPointerHint()
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

  private let scrollIndicator = PaletteCornerScrollIndicator(frame: .zero)
  private var scrollIndicatorShell: (rect: CGRect, corner: CGFloat)?

  private var indicatedScroll: NSScrollView? {
    if addressedPreview != nil {
      return showsCompactListening ? nil : previewCard.transcriptScroll
    }
    return isResultsExpanded ? resultsScroll : nil
  }

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

  private func layoutResizeGrabber(in rect: CGRect, corner: CGFloat) {
    let shows = resizableShell != nil && rect.width > 1
    resizeGrabber.isHidden = !shows
    guard shows else { return }
    resizeGrabber.frame = bounds
    resizeGrabber.place(in: rect, corner: corner)
  }

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

  private func anchorNotice() {
    let inChat = addressedPreview != nil
    let wanted = inChat ? noticeAboveComposer
      : isResultsExpanded ? noticeTopToResults : noticeTopToPrompt
    guard !wanted.isActive else { return }
    for constraint in [noticeTopToPrompt, noticeTopToResults, noticeAboveComposer]
    where constraint !== wanted {
      constraint.isActive = false
    }
    wanted.isActive = true
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let edges = resizeEdges(at: point), let shell = resizableShell {
      beginResize(edges: edges, shell: shell, at: point)
      return
    }
    if isNearShellEdge(point) { return }
    if isHandingOver { return }
    guard isEmptyGlass(point) else {
      super.mouseDown(with: event)
      return
    }
    hideSelectionPointerHint()
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

  enum ScreenSelectionPhase: Equatable {
    case idle
    case drawing
    case editing
  }

  private(set) var screenSelectionPhase: ScreenSelectionPhase = .idle {
    didSet { if screenSelectionPhase != oldValue { needsLayout = true } }
  }
  private var screenSelectionGlobal: CGRect?
  private var frozenScreenGlobal: (image: CGImage, frame: CGRect)?
  private var placedPhase: ScreenSelectionPhase = .idle

  private var regionAnnounced = false
  private var awaitsRegionVoice = false {
    didSet { if awaitsRegionVoice != oldValue { needsLayout = true } }
  }
  private var regionVoiceWait: DispatchWorkItem?
  private var isHandingOver = false
  private var regionEndedAtLeft = false
  private var regionEndedAtFoot = false

  var screenSelectionFrame: CGRect? {
    screenSelectionPhase == .editing ? screenSelectionGlobal : nil
  }

  private var acceptsScreenSelection: Bool {
    onScreenSelectionBegan != nil && mode == .prompt
      && !isVoiceListening && !showsCompactListening
      && !isResultsExpanded
  }

  private var selectsOnDrag: Bool {
    acceptsScreenSelection && screenSelectionPhase == .idle
  }

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
      if isDrag, screenSelectionPhase == .drawing {
        screenSelectionGlobal = clampedToScreen(Self.region(from: origin, to: here))
        syncSelectionOverlay()
      }
      if event.type == .leftMouseUp { break }
    }
    guard isDrag else {
      if replacing { letGoOfRegion() } else { onCancel?() }
      return
    }
    let release = NSEvent.mouseLocation
    regionEndedAtLeft = release.x < origin.x
    regionEndedAtFoot = release.y < origin.y
    finishScreenDrawing()
  }

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
      noteRegionDrawn()
      onScreenRegionSelected?(region)
      return
    }
    let first = !regionAnnounced
    regionAnnounced = true
    if first { noteRegionDrawn() }
    if first, field.draft.isEffectivelyEmpty {
      setListeningWords("")
      syncVoiceGlowPalette()
      awaitsRegionVoice = true
      let wait = DispatchWorkItem { [weak self] in self?.awaitsRegionVoice = false }
      regionVoiceWait = wait
      DispatchQueue.main.asyncAfter(deadline: .now() + AgentPaletteMetrics.regionVoiceWait, execute: wait)
    }
    screenSelectionPhase = .editing
    screenOutlines.showsHandles = true
    syncSelectionOverlay()
    syncPointerWhereItIs()
    _ = focusField()
    if first { onScreenRegionReady?() }
  }

  private static func region(from start: CGPoint, to end: CGPoint) -> CGRect {
    CGRect(
      x: min(start.x, end.x), y: min(start.y, end.y),
      width: abs(end.x - start.x), height: abs(end.y - start.y)
    )
  }

  private func clampedToScreen(_ rect: CGRect) -> CGRect {
    guard let screen = window?.screen?.frame else { return rect }
    return rect.intersection(screen)
  }

  private func movedOnScreen(_ rect: CGRect) -> CGRect {
    guard let screen = window?.screen?.frame else { return rect }
    var moved = rect
    moved.origin.x = min(max(rect.minX, screen.minX), screen.maxX - rect.width)
    moved.origin.y = min(max(rect.minY, screen.minY), screen.maxY - rect.height)
    return moved
  }

  func showFrozenScreen(_ image: CGImage, frame: CGRect) {
    guard screenSelectionPhase != .idle else { return }
    frozenScreenGlobal = (image, frame)
    syncSelectionOverlay()
  }

  func insertScreenSelection(_ selection: ScreenSelection) {
    let card = PromptAttachment(
      kind: .image,
      payload: .screen(selection),
      label: field.draft.nextGeneratedLabel(for: .image)
    )
    applyIngest(.attachments([card]))
  }

  private func letGoOfRegion() {
    guard let onLetGoOfRegion, screenSelectionPhase == .editing else {
      cancelScreenSelection()
      return
    }
    onLetGoOfRegion()
  }

  func cancelScreenSelection() {
    guard screenSelectionPhase != .idle, !isHandingOver else { return }
    endScreenSelection()
    onScreenSelectionCancelled?()
  }

  var promptFaceOnScreen: CGPoint? {
    guard let window else { return nil }
    let face: NSView = showsCompactListening ? listeningFace : selectedAgentImage
    guard !face.isHidden, face.window != nil else { return nil }
    let centre = CGPoint(x: face.bounds.midX, y: face.bounds.midY)
    return window.convertPoint(toScreen: face.convert(centre, to: nil))
  }

  func endScreenSelection() {
    regionVoiceWait?.cancel()
    regionVoiceWait = nil
    awaitsRegionVoice = false
    isHandingOver = false
    holdsQuestionWords = false
    screenOutlines.alphaValue = 1
    regionAnnounced = false
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

  private var selectionPalette: [NSColor] {
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

  func holdRegion(_ region: CGRect) {
    PaletteHelpPresenter.shared.dismiss()
    hideNotice()
    screenSelectionGlobal = region
    screenSelectionPhase = .drawing
    screenOutlines.showsHandles = false
    screenOutlines.isDimmed = true
    syncSelectionOverlay()
  }

  func finishHeldRegion() {
    finishScreenDrawing()
  }

  private func regionSeed(for rect: CGRect) -> CGRect {
    let side = AgentPaletteMetrics.regionSeedSide
    let orb = AgentPaletteMetrics.listeningOrbDiameter
    var edge = rect.minX
    if let window, let global = screenSelectionGlobal,
       rect.midX < convert(window.convertFromScreen(global), from: nil).midX {
      edge = rect.maxX
    }
    return CGRect(x: edge - side / 2, y: rect.maxY - orb / 2 - side / 2, width: side, height: side)
  }

  func collapseToFace(then done: @escaping () -> Void) {
    guard window?.isVisible == true, !MotionPreferences.reduceMotion else {
      done()
      return
    }
    isHandingOver = true
    holdsQuestionWords = false
    screenOutlines.showsHandles = false
    needsLayout = true
    let duration = Motion.scaled(AgentPaletteMetrics.regionHandOverDuration)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = Motion.standardCurve
      screenOutlines.animator().alphaValue = 0
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: done)
  }

  private var shellAnchor: (top: CGFloat, offset: CGFloat)? {
    switch screenSelectionPhase {
    case .idle:
      return nil
    case .drawing:
      return (top: -bounds.height, offset: 0)
    case .editing:
      guard let window, let global = screenSelectionGlobal else { return nil }
      let region = convert(window.convertFromScreen(global), from: nil)
      let prompt = promptSurfaceWidth
      let listening = showsCompactListening
      let size = listening ? listeningShellSize() : CGSize(width: prompt, height: promptCapsuleHeightConstraint.constant)
      let width = size.width
      let height = size.height
      let gap = AgentPaletteMetrics.screenSelectionShellGap
      let highest = bounds.height - topReserve - gap
      var left: CGFloat
      var shellTop = regionEndedAtFoot ? region.minY + AgentPaletteMetrics.listeningOrbDiameter : region.maxY
      let fitsRight = region.maxX + gap + prompt <= bounds.maxX - gap
      let fitsLeft = region.minX - gap - prompt >= bounds.minX + gap
      if fitsLeft, !fitsRight || regionEndedAtLeft {
        left = region.minX - gap - width
      } else if fitsRight {
        left = region.maxX + gap
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

  private var outlinedWindowFrame: CGRect?

  var screenOutlinesForTesting: [CGRect] { screenOutlines.drawnRectsForTesting }
  var screenGlowRegionsForTesting: [CGRect] { screenOutlines.glowRegionsForTesting }
  var screenSelectionPaletteForTesting: [NSColor] { screenOutlines.palette }
  var screenSelectionHandleCountForTesting: Int { screenOutlines.handleCountForTesting }
  var isScreenFrozenForTesting: Bool { screenOutlines.isFrozenForTesting }
  var shellFrameForTesting: CGRect { surfaceFrame }
  func pointerCursorForTesting(at point: CGPoint) -> NSCursor? { pointerCursor(at: point) }
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

  func beginDrip(from source: CGRect) {
    layoutSubtreeIfNeeded()
    let shell = resizeTarget
    guard !shell.isEmpty, !MotionPreferences.reduceMotion else { return }
    dripRun += 1
    let run = dripRun
    let stations = PaletteDrip.stations(source: source, shell: shell)
    surfaceMotion.response = AgentPaletteMetrics.dripFallResponse
    dripTarget = stations.fallen
    isDrippingIn = true
    _ = surfaceMotion.move(to: stations.seed, in: self, animated: false)
    _ = surfaceMotion.move(to: stations.fallen, in: self, animated: true)
    fadeShellContent(in: true)
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Motion.scaled(AgentPaletteMetrics.dripSpreadAfter)
    ) { [weak self] in
      guard let self, self.dripRun == run else { return }
      self.dripTarget = nil
      self.isDrippingIn = false
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

  func beginDripOut(into source: CGRect) {
    let shell = resizeTarget
    guard !shell.isEmpty, !MotionPreferences.reduceMotion else { return }
    dripRun += 1
    let run = dripRun
    let stations = PaletteDrip.stations(source: source, shell: shell)
    fadeShellContent(in: false)
    isDrippingIn = false
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

  func endDrip() {
    dripRun += 1
    let wasDripping = dripTarget != nil
    dripTarget = nil
    isDrippingIn = false
    surfaceMotion.response = AgentPaletteMetrics.surfaceResponse
    for view in shellContentViews { view.layer?.removeAnimation(forKey: Self.dripFadeKey) }
    if wasDripping { needsLayout = true }
  }

  var isDrippingForTesting: Bool { dripTarget != nil }

  private static let dripFadeKey = "boltty.drip.fade"

  private var shellContentViews: [NSView] { subviews.filter { $0 !== surfaceContainer } }

  private func fadeShellContent(in arriving: Bool) {
    for view in shellContentViews {
      guard let layer = view.layer else { continue }
      layer.removeAnimation(forKey: Self.dripFadeKey)
      let opacity = layer.opacity
      guard !view.isHidden, opacity > 0 else { continue }
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = arriving ? 0 : opacity
      fade.toValue = arriving ? opacity : 0
      fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        + (arriving ? AgentPaletteMetrics.dripContentInAfter : 0)
      fade.duration = arriving ? AgentPaletteMetrics.dripContentInDuration : Motion.quick
      fade.timingFunction = Motion.standardCurve
      fade.fillMode = arriving ? .backwards : .forwards
      fade.isRemovedOnCompletion = arriving
      layer.add(fade, forKey: Self.dripFadeKey)
    }
  }

  private var shadowGeometry: [ObjectIdentifier: (bounds: CGRect, radius: CGFloat)] = [:]

  private func applyFloatingShadow(to view: NSView, cornerRadius: CGFloat) {
    view.wantsLayer = true
    guard let layer = view.layer else { return }

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

  private var shellCastsShadow = true

  private func syncShellShadow() {
    guard let layer = surfaceContainer.layer else { return }
    let casts = !showsCompactListening
    let contact: Float = casts ? PaletteGlassHost.floatingShadowOpacity : 0
    let pool: Float = casts ? 1 : 0
    if casts != shellCastsShadow, window?.isVisible == true, !MotionPreferences.reduceMotion {
      for (target, key, value) in [(layer, "shadowOpacity", contact), (ambientShadow, "opacity", pool)] {
        let fade = CABasicAnimation(keyPath: key)
        fade.fromValue = target.presentation()?.value(forKeyPath: key) ?? target.value(forKeyPath: key)
        fade.toValue = value
        fade.duration = Motion.standard
        fade.timingFunction = Motion.standardCurve
        target.add(fade, forKey: key)
      }
    }
    shellCastsShadow = casts
    layer.shadowOpacity = contact
    ambientShadow.opacity = pool
  }

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
    let reach = PaletteGlassHost.ambientShadowRadius * 3 + abs(PaletteGlassHost.ambientShadowOffset.height)
    let cutout = CGMutablePath()
    cutout.addRect(bounds.insetBy(dx: -reach, dy: -reach))
    cutout.addPath(shape)
    ambientShadowCutout.frame = bounds
    ambientShadowCutout.path = cutout
  }

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

  private func syncPromptExpansion() {
    isDraftExpanded = !field.attachments.isEmpty
      || (!field.isEmptyPrompt && (isDraftExpanded || field.wrapsBeyondOneLine))
    let expanded = isDraftExpanded || isOpenChat
    guard expanded != isPromptExpanded else { return }
    isPromptExpanded = expanded
    needsLayout = true
    NSLayoutConstraint.deactivate(expanded ? inlineControlConstraints : expandedPromptConstraints)
    NSLayoutConstraint.activate(expanded ? expandedPromptConstraints : inlineControlConstraints)
    field.setExpandedStyle(expanded)
    syncPromptHeight()
    layoutSubtreeIfNeeded()
    syncPromptHeight()
    layoutSubtreeIfNeeded()
    field.scrollRangeToVisible(field.selectedRange())
  }

  private func schedulePromptRemeasure() {
    promptRemeasureWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.syncPromptExpansion()
      self?.syncPromptHeight()
    }
    promptRemeasureWorkItem = work
    DispatchQueue.main.async(execute: work)
  }

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
    onContentSizeChange?()
  }

  @discardableResult
  private func updatePromptHeights() -> Bool {
    let band = attachmentBand
    field.maximumViewportHeight = isOpenChat
      ? max(PromptTextView.lineHeight,
          chatSurfaceSize.height - AgentPaletteMetrics.previewMinHeight
            - AgentPaletteMetrics.surfaceStackSpacing - AgentPaletteMetrics.shellContentInset
            - band
            - (isPromptExpanded
                ? AgentPaletteMetrics.chatComposerGrownTextTop
                  + AgentPaletteMetrics.chatComposerGrownControlsBand
                : 0))
      : AgentPaletteMetrics.promptGrownMaximumHeight
    let textHeight = field.clampedContentHeight
    let extra = textHeight - PromptTextView.lineHeight
    let bottomControls = addressedPreview != nil && isPromptExpanded
    let capsuleHeight = band + (!isOpenChat
      ? (isPromptExpanded
          ? max(AgentPaletteMetrics.promptSize.height, textHeight)
          : AgentPaletteMetrics.promptSize.height)
      : isPromptExpanded
        ? (bottomControls
            ? max(AgentPaletteMetrics.chatComposerBoxHeight,
                  AgentPaletteMetrics.chatComposerGrownTextTop + textHeight
                    + AgentPaletteMetrics.chatComposerGrownControlsBand)
            : textHeight)
        : AgentPaletteMetrics.chatComposerHeight + max(0, extra))

    attachmentStrip.placement = addressedPreview == nil
      ? AgentPaletteMetrics.attachmentStripOnFirstScreen : AgentPaletteMetrics.attachmentStripInChat
    placeAttachmentBand(band)

    guard abs(promptScrollHeightConstraint.constant - textHeight) > 0.5
      || abs(promptCapsuleHeightConstraint.constant - capsuleHeight) > 0.5
    else { return false }

    promptScrollHeightConstraint.constant = textHeight
    promptCapsuleHeightConstraint.constant = capsuleHeight
    return true
  }

  private var attachmentBand: CGFloat {
    guard !field.attachments.isEmpty, !isHistoryOpen else { return 0 }
    return (addressedPreview == nil
      ? AgentPaletteMetrics.attachmentStripOnFirstScreen : AgentPaletteMetrics.attachmentStripInChat).band
  }

  private func placeAttachmentBand(_ band: CGFloat) {
    let settled = bandTravel?.to ?? promptForegroundTop.constant
    if abs(band - settled) > 0.5 {
      bandTravel = addressedPreview == nil && surfaceReady && window?.isVisible == true
        ? (promptForegroundTop.constant, band, surfaceFrame.height) : nil
      if bandTravel == nil { promptForegroundTop.constant = band }
    }
    let held = max(band, promptForegroundTop.constant)
    if abs(attachmentStripHeight.constant - held) > 0.5, held > 0 { attachmentStripHeight.constant = held }
    attachmentStrip.isHidden = band == 0 && bandTravel == nil
  }

  private func rideAttachmentBand(at rect: CGRect) {
    guard let travel = bandTravel else { return }
    let span = promptCapsuleHeightConstraint.constant - travel.fromHeight
    let progress = surfaceMotion.isMoving && abs(span) > 1 && addressedPreview == nil
      ? min(max((rect.height - travel.fromHeight) / span, 0), 1)
      : 1
    let shown = travel.from + (travel.to - travel.from) * progress
    if progress >= 1 {
      bandTravel = nil
      attachmentStrip.isHidden = travel.to == 0
      if travel.to > 0 { attachmentStripHeight.constant = travel.to }
    }
    guard abs(promptForegroundTop.constant - shown) > 0.01 else { return }
    promptForegroundTop.constant = shown
    if !isPerformingLayout { promptCapsule.layoutSubtreeIfNeeded() }
  }

  private func configureMicButton() {
    attachRestSlot.translatesAutoresizingMaskIntoConstraints = false
    attachRestSlot.addSubview(attachRestDisc)
    attachRestDisc.button.target = self
    attachRestDisc.button.action = #selector(attachButtonPressed)
    attachRestDisc.button.toolTip = "Attach a file"
    attachRestDisc.button.helpShortcut = ComposerChord.attach.display
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
    micButton.imagePosition = .imageOnly
    micButton.imageScaling = .scaleNone
    micButton.setButtonType(.momentaryChange)
    micButton.setContentHuggingPriority(.required, for: .horizontal)
    micButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    micButton.setAccessibilityIdentifier("boltty.ask.mic")
    micButton.target = self
    micButton.action = #selector(micButtonPressed)
  }

  private func applyMicAppearance() {
    micButton.setListening(isVoiceListening)
    micButton.setShowsGlass(isVoiceListening)
    micButton.isEnabled = !isVoiceProcessing
    micButton.toolTip = isVoiceProcessing ? "Processing recording…" : isVoiceListening
      ? "Listening — hover for controls"
      : "Dictate prompt"
    micButton.helpShortcut = isVoiceProcessing || isVoiceListening ? nil : ComposerChord.dictate.display
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

  func setAcceptsAttachments(_ accepts: Bool) {
    guard acceptsAttachments != accepts else { return }
    acceptsAttachments = accepts
    applyAttachPlacement()
    needsLayout = true
  }

  private func applyAttachPlacement() {
    let showsRest = acceptsAttachments && composerGlyphsAreChat
    attachRestDisc.isHidden = !showsRest
    attachRestDisc.diameter = composerControlDiameter
    attachRestWidth.constant = showsRest ? composerControlDiameter : 0
  }

  private func restingEditorTrailing(chat: Bool) -> CGFloat {
    let inset = chat
      ? AgentPaletteMetrics.chatComposerSendDiscInset
      : AgentPaletteMetrics.restingControlsTrailingInset
    let gap = AgentPaletteMetrics.restingControlsSpacing
    let target = composerControlDiameter
    let folder = chat || directorySlotWidth.constant == 0 ? 0 : directorySlotWidth.constant + gap
    let plan = planRing.hasReading ? target + gap : 0
    let send = composerIsUp && composerGlyphsAreChat
      ? ComposerControlGroup.sendGap + ComposerControlGroup.sendDisc : 0
    let words = chat
      ? AgentPaletteMetrics.chatComposerTextControlsGap
      : AgentPaletteMetrics.promptMicTextSpacing
    return inset + folder + plan + target + send + words
  }

  var voiceControlFrameInPaletteForTesting: CGRect { convert(micButton.bounds, from: micButton) }

  var isAttachVisibleForTesting: Bool { !attachRestDisc.isHidden }
  var isAttachDiscVisibleForTesting: Bool { !attachRestDisc.isHidden }
  func pressAttachForTesting() { attachButtonPressed() }

  @objc private func attachButtonPressed() { onChooseAttachments?() }

  func appendAttachments(_ urls: [URL]) {
    applyIngest(PasteboardIngest.attachments(for: urls, into: field.draft))
  }

  @objc private func micButtonPressed() {
    if isVoiceListening {
      setRecordingControlsRevealed(true, animated: true)
      return
    }
    onVoiceToggle?()
  }

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
    if composerKeyTarget != .text {
      if replacementString == " " {
        activateComposerKeyTarget()
        return false
      }
      setComposerKeyTarget(.text)
    }
    if replacementString == " ", field.isWhollyEmpty, addressedPreview != nil,
       previewCard.toggleFocusedOption() { return false }
    if let typed = replacementString, typed.count == 1, let number = Int(typed), number > 0,
       field.isWhollyEmpty, addressedPreview != nil,
       previewCard.chooseOption(number: number) { return false }
    return true
  }

  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    let isTab = commandSelector == #selector(insertTab(_:))
    let isBacktab = commandSelector == #selector(insertBacktab(_:))
    if !isTab, !isBacktab, composerKeyTarget != .text {
      setComposerKeyTarget(.text)
    }
    if screenSelectionPhase != .idle, isTab
      || commandSelector == #selector(moveDown(_:)) || commandSelector == #selector(moveUp(_:)) {
      return true
    }
    if commandSelector == #selector(moveLeft(_:)) || commandSelector == #selector(moveRight(_:)) {
      guard addressedPreview == nil, isResultsExpanded, mode == .picking,
            !isShowingInstallHints, field.isEmptyPrompt else { return false }
      stepHistoryTab(by: commandSelector == #selector(moveLeft(_:)) ? -1 : 1)
      return true
    }
    if addressedPreview == nil, isResultsExpanded, !isShowingInstallHints {
      switch commandSelector {
      case #selector(moveToBeginningOfDocument(_:)), #selector(scrollToBeginningOfDocument(_:)):
        highlightResult(at: 0)
        return true
      case #selector(moveToEndOfDocument(_:)), #selector(scrollToEndOfDocument(_:)):
        highlightResult(at: resultItems.count - 1)
        return true
      case #selector(scrollPageUp(_:)), #selector(pageUp(_:)):
        moveResultSelection(by: -resultRowsPerPage)
        return true
      case #selector(scrollPageDown(_:)), #selector(pageDown(_:)):
        moveResultSelection(by: resultRowsPerPage)
        return true
      default:
        break
      }
    }
    if commandSelector == #selector(moveDown(_:)) {
      if addressedPreview != nil, previewCard.isAnswering,
         previewCard.moveOptionFocus(by: 1) { return true }
      if addressedPreview != nil { return false }
      if !isResultsExpanded {
        openSwitcher()
      } else {
        moveResultSelection(by: 1)
      }
      return true
    }
    if commandSelector == #selector(moveUp(_:)) {
      if addressedPreview != nil {
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
          if mode != .prompt {
            closeSwitcher()
          } else {
            collapseResults()
          }
        } else {
          moveResultSelection(by: -1)
        }
        return true
      }
      return false
    }
    if isTab || isBacktab, addressedPreview == nil, isResultsExpanded { return true }
    if isTab {
      guard isFirstScreen else { return false }
      if composerIsUp, !isVoiceListening { cycleComposerKey() }
      return true
    }
    if isBacktab {
      guard isFirstScreen else { return false }
      if screenSelectionFrame != nil || (composerIsUp && !isVoiceListening) { cycleAgent(by: 1) }
      return true
    }
    if commandSelector == #selector(deleteBackward(_:)) {
      if mode != .prompt, field.searchQuery.isEmpty {
        closeSwitcher()
        return true
      }
      return field.removeLastAttachmentFromFieldStart()
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
        onVoiceConfirm?()
        return true
      }
      confirmSelectionOrSubmit()
      return true
    }
    if commandSelector == #selector(cancelOperation(_:)) {
      if screenSelectionPhase != .idle {
        letGoOfRegion()
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
      setComposerKeyTarget(.text)
      mode = .search
      applyModeChrome()
    }
    if !isRestoringChatDraft { onDraftChange?() }
    if !isRestoringChatDraft, !isApplyingVoiceTranscript { hideNotice() }
    if !voiceTranscriptWasInterrupted, !isApplyingVoiceTranscript, let expected = voiceExpectedText,
       field.string != expected {
      voiceTranscriptWasInterrupted = true
      onVoiceEditingInterrupted?()
      setVoiceListening(false)
    }
    syncPromptExpansion()
    hintLabel.isHidden = !field.isEmptyPrompt
    if isResultsExpanded {
      refreshResults(keepingSelection: true)
    }
  }

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
      field.insertAttachments(attachments)
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

private final class PassThroughView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

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
  private(set) var mascotIdentity: UUID?
  private(set) var mascotEmotion: MascotEmotion?
  var mascotPaletteID: String? {
    mascot.isHidden ? nil : mascot.paletteID
  }
  var mascotLook: MascotLook? {
    mascot.isHidden ? nil : mascot.look
  }

  override var allowsVibrancy: Bool { false }

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

  func pokeMascot() {
    guard !mascot.isHidden else { return }
    mascot.poke()
  }

  override func layout() {
    super.layout()
    let side = AgentPaletteMetrics.promptMascotSize
    mascot.frame = CGRect(
      x: bounds.midX - side / 2,
      y: bounds.midY - side / 2,
      width: side,
      height: side
    )
  }
}

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
  var response: CGFloat = AgentPaletteMetrics.surfaceResponse
  init(render: @escaping (CGRect) -> Void) { self.render = render }

  var isMoving: Bool { link != nil }

  var destination: CGRect { CGRect(x: target[0], y: target[1], width: target[2], height: target[3]) }

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

struct SurfaceResizeEdges: OptionSet, Equatable {
  let rawValue: Int
  static let left = SurfaceResizeEdges(rawValue: 1 << 0)
  static let right = SurfaceResizeEdges(rawValue: 1 << 1)
  static let bottom = SurfaceResizeEdges(rawValue: 1 << 2)

  static func at(_ point: NSPoint, of frame: CGRect) -> SurfaceResizeEdges? {
    regions(of: frame).first { $0.rect.contains(point) }?.edges
  }

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

private enum ResultLine {
  case heading(AgentHistory.Section, followsRows: Bool)
  case row(BolttyAISessionItem)

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
