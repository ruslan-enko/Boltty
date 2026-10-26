import AppKit
import QuartzCore
import Combine

@MainActor
enum PickerPanelPresentation {
  private static var originalHostLevels: [ObjectIdentifier: NSWindow.Level] = [:]

  static func attach(_ picker: NSWindow, above host: NSWindow?) {
    guard let host else { return }
    originalHostLevels[ObjectIdentifier(host)] = host.level
    host.level = .normal
    picker.level = .modalPanel
  }

  static func detach(_ picker: NSWindow, from host: NSWindow?) {
    guard let host else { return }
    let key = ObjectIdentifier(host)
    if let original = originalHostLevels.removeValue(forKey: key) {
      host.level = original
    }
  }
}

@MainActor
final class AgentPaletteController: NSWindowController, NSWindowDelegate {
  private let model: AppModel
  private weak var conversations: BolttyAIConversations?
  private let panelView: AgentPaletteView
  private let voiceDictation: VoiceDictationService
  private let sendAnswer: @MainActor (AgentQuestion, [String]) async throws -> Bool
  private var answerTask: Task<Void, Never>?
  private(set) var isShowing = false
  private var suppressResignHide = false
  private var suppressResignHideWorkItem: DispatchWorkItem?
  private var panelDismissWorkItem: DispatchWorkItem?
  var resumeWindow: TimeInterval = 60
  private var leftChat: (sessionID: UUID, at: Date)?
  var dripsEnabled = !AppDelegate.isHostingUnitTests
  private var previouslyActiveApplication: NSRunningApplication?
  private(set) var applicationPendingRestoreForTesting: NSRunningApplication?
  var activatePreviousApplicationForTesting: ((NSRunningApplication) -> Void)?
  private var visibilityGeneration = 0
  private var isSubmitting = false
  private var cancellables = Set<AnyCancellable>()

  var onOpenSettings: (() -> Void)?
  var onPromptSent: (() -> Void)?
  /// An answer's read-aloud control was pressed.
  var onSpeakMessage: ((ConversationMessage) -> Void)?
  /// The panel went away; what it was reading aloud stops with it.
  var onHide: (() -> Void)?

  func setSpeakingMessage(_ id: String?) { panelView.setSpeakingMessage(id) }
  var onPromptRefused: (() -> Void)?
  var onVisibilityChange: ((_ visible: Bool, _ screen: NSScreen?, _ conversationID: UUID?) -> Void)?
  var onSelectSession: ((UUID) -> Void)?
  private var observingPreviewID: UUID?
  private var newPromptDraft = PromptDraft()
  private var pendingWorkingDirectory: String?
  var directoryPicker: (@MainActor (_ current: String) -> String?)?
  var attachmentPicker: (@MainActor (_ current: String) -> [URL])?
  var finderSelection = FinderSelectionService()
  var frontmostBundleIDForTesting: String?

  init(
    model: AppModel,
    conversations: BolttyAIConversations? = nil,
    voiceDictation: VoiceDictationService = VoiceDictationService(),
    sendAnswer: (@MainActor (AgentQuestion, [String]) async throws -> Bool)? = nil
  ) {
    self.model = model
    self.conversations = conversations
    self.sendAnswer = sendAnswer ?? { [weak conversations] (question: AgentQuestion, values: [String]) in
      guard let conversations else { return false }
      return try await conversations.answer(question, with: values)
    }
    self.voiceDictation = voiceDictation
    self.panelView = AgentPaletteView()
    panelView.setAccessibilityElement(false)
    panelView.setAccessibilityIdentifier("boltty.ask.panel")

    let panel = KeyablePanel(
      contentRect: NSRect(origin: .zero, size: AgentPaletteMetrics.panelSize()),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // Without this a press on transparent pixels falls through to the app below.
    panel.ignoresMouseEvents = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.worksWhenModal = true
    panel.isMovableByWindowBackground = false
    panel.animationBehavior = .none
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.identifier = NSUserInterfaceItemIdentifier("boltty.ask.panel")
    panel.setAccessibilityElement(false)
    panel.setAccessibilityIdentifier("boltty.ask.panel")

    super.init(window: panel)

    panel.delegate = self
    panel.contentView = panelView
    Motion.applyTimeScale(to: panel)
    BackgroundCursor.enable()

    panelView.onAgentChoiceChange = { [weak self] in
      self?.syncWorkingDirectoryToPanel()
      self?.syncUsageToPanel()
    }
    panelView.onSubmit = { [weak self] prompt in
      self?.submit(prompt)
    }
    panelView.onSubmitSteering = { [weak self] prompt in
      self?.submit(prompt, steering: true)
    }
    panelView.onCancel = { [weak self] in
      self?.hide()
    }
    panelView.onAnswerQuestion = { [weak self] sessionID, question, answers in
      self?.answer(question, with: answers, in: sessionID)
    }
    panelView.onCancelQueuedPrompt = { [weak self] sessionID in
      guard let self else { return }
      self.conversations?.cancelQueuedFollowUp(for: sessionID)
      self.refreshAddressedPreview(sessionID)
    }
    panelView.onRetryPrompt = { [weak self] sessionID, prompt in
      guard let self, self.isShowing, !self.isSubmitting else { return }
      self.sendFollowUp(prompt, to: sessionID)
    }
    panelView.onSelectSession = { [weak self] sessionID in
      self?.selectExistingSession(sessionID)
    }
    panelView.onOpenSettings = { [weak self] in
      self?.yieldToAppWindow()
      self?.onOpenSettings?()
    }
    panelView.onConfirmSession = { [weak self] sessionID in
      self?.confirmSession(sessionID)
    }
    panelView.onSessionContextMenu = { [weak self] sessionID, event, row in
      self?.showSessionMenu(for: sessionID, with: event, from: row)
    }
    panelView.onContentSizeChange = { [weak self] in
      self?.panelView.layoutSubtreeIfNeeded()
    }
    panelView.onVoiceToggle = { [weak self] in
      self?.cancelPendingVoiceSubmit()
      self?.voiceDictation.toggle()
    }
    panelView.onVoiceCancel = { [weak self] in
      guard let self else { return }
      self.cancelPendingVoiceSubmit()
      self.silenceWatcher.reset()
      self.voiceDictation.cancel()
      self.panelView.setVoiceListening(false, ending: .cancelled)
      self.panelView.discardVoiceTranscript()
    }
    panelView.onVoiceConfirm = { [weak self] in
      self?.confirmDictation()
    }
    panelView.onVoiceEditingInterrupted = { [weak self] in
      self?.cancelPendingVoiceSubmit()
      self?.voiceDictation.cancel()
      self?.panelView.setVoiceGlowPhase(.cancelled)
    }
    panelView.onDraftChange = { [weak self] in self?.saveCurrentDraft() }
    panelView.onSpeakMessage = { [weak self] in self?.onSpeakMessage?($0) }
    panelView.onStop = { [weak self] in
      guard let self, let id = self.panelView.addressedSessionID else { return }
      Task { await self.conversations?.stopConversation(id: id) }
    }
    panelView.onLeaveAddressing = { [weak self] left in
      if let self { self.conversations?.saveDraft(self.panelView.currentDraft, for: left) }
      self?.panelView.setChatDraft(self?.newPromptDraft ?? PromptDraft())
      self?.conversations?.setAddressedConversation(nil)
      self?.stopObservingPreview()
      self?.answerTask?.cancel()
      self?.answerTask = nil
      self?.isSubmitting = false
      self?.syncWorkingDirectoryToPanel()
    }
    panelView.onSetAutoMode = { [weak self] id, enabled in
      self?.conversations?.setAutoApprove(enabled, for: id)
    }
    panelView.onCompact = { [weak self] in
      guard let self, let id = self.panelView.addressedSessionID else { return }
      self.conversations?.compact(id)
    }
    panelView.onChooseWorkingDirectory = { [weak self] in
      self?.chooseWorkingDirectory()
    }
    panelView.onWorkingDirectoryMenu = { [weak self] in
      self?.showWorkingDirectoryMenu()
    }
    panelView.onChooseAttachments = { [weak self] in
      self?.chooseAttachments()
    }
    panelView.onScreenSelectionBegan = { [weak self] in
      self?.beginScreenSelection()
    }
    panelView.onScreenRegionSelected = { [weak self] region in
      self?.putScreenRegionInChat(region)
    }
    panelView.onScreenSelectionCancelled = { [weak self] in
      self?.finishScreenSelection()
    }
    panelView.onSurfaceSizesChange = { sizes in
      sizes.save()
    }
    panelView.surfaceSizes = BolttyAISurfaceSizes.load()
    voiceDictation.onFinalTranscript = { [weak self] in
      self?.submitDictatedPromptIfPending()
    }

    voiceDictation.onAudioLevel = { [weak self] level in
      guard let self else { return }
      self.panelView.applyVoiceLevel(level)
      guard self.silenceWatcher.accept(level: level, now: CACurrentMediaTime()) else { return }
      guard !self.panelView.currentDraft.isEffectivelyEmpty else { return }
      self.silenceWatcher.reset()
      self.confirmDictation()
    }
    voiceDictation.onTranscript = { [weak self] transcript in
      self?.panelView.applyVoiceTranscript(transcript)
    }
    voiceDictation.onStateChange = { [weak self] state in
      guard let self else { return }
      if state != .requestingPermission, self.isShowing, self.window?.isKeyWindow == false {
        self.window?.makeKeyAndOrderFront(nil)
      }
      guard state != .listening else {
        self.silenceWatcher.reset()
        self.panelView.setVoiceListening(true)
        return
      }
      self.panelView.setVoiceListening(
        false,
        ending: self.pendingVoiceSubmit == nil ? .completed : .processing
      )
    }
    voiceDictation.onError = { [weak self] message in
      self?.cancelPendingVoiceSubmit()
      self?.panelView.setVoiceListening(false, ending: .failed)
      self?.panelView.showError(message)
    }

    applyDictationLanguage()
    syncAgentChoicesToPanel()
    panelView.onWillShowSessions = { [weak self] in self?.syncSessionsToPanel() }

    model.$settings
      .sink { [weak self] settings in
        self?.applyDictationLanguage(settings)
      }
      .store(in: &cancellables)

    conversations?.conversationsChanged
      .sink { [weak self] in self?.scheduleConversationsSync() }
      .store(in: &cancellables)

    conversations?.usageChanged
      .sink { [weak self] in
        guard let self, self.isShowing else { return }
        self.syncUsageToPanel()
        self.syncContextToPanel()
      }
      .store(in: &cancellables)

    model.agentCatalog.$installedAgents
      .combineLatest(model.agentCatalog.$isScanning)
      .receive(on: RunLoop.main)
      .sink { [weak self] _, _ in
        guard let self else { return }
        self.syncCatalogStateToPanel()
        guard self.isShowing else { return }
        self.panelView.revealInstallHintsIfNeeded()
        self.panelView.layoutSubtreeIfNeeded()
      }
      .store(in: &cancellables)
  }

  private func confirmDictation() {
    guard isShowing, pendingVoiceSubmit == nil, !isSubmitting else { return }
    let generation = visibilityGeneration
    let work = DispatchWorkItem { [weak self] in
      guard self?.visibilityGeneration == generation else { return }
      self?.submitDictatedPromptIfPending()
    }
    pendingVoiceSubmit = work
    voiceDictation.stop()
    panelView.setVoiceListening(false, ending: .processing)
    DispatchQueue.main.asyncAfter(
      deadline: .now() + AgentPaletteMetrics.voiceConfirmGraceInterval,
      execute: work
    )
  }

  private func submitDictatedPromptIfPending() {
    guard let work = pendingVoiceSubmit else { return }
    work.cancel()
    pendingVoiceSubmit = nil
    panelView.setVoiceGlowPhase(.completed)
    guard isShowing else { return }
    voiceDictation.cancel()
    let draft = panelView.currentDraft
    guard !draft.isEffectivelyEmpty else { return }
    panelView.confirmCurrentDraft()
  }

  private func cancelPendingVoiceSubmit() {
    pendingVoiceSubmit?.cancel()
    pendingVoiceSubmit = nil
    silenceWatcher.reset()
  }

  private func applyDictationLanguage(_ settings: AppSettings? = nil) {
    let settings = settings ?? model.settings
    voiceDictation.localeIdentifier = settings.dictationLocaleIdentifier
    voiceDictation.secondLocaleIdentifier = settings.dictationSecondLocaleIdentifier
    voiceDictation.invalidateLanguageCache()
  }

  private func syncAgentChoicesToPanel() {
    let launchable = conversations?.launchableProviderIDs().compactMap(AgentId.init(rawValue:)) ?? []
    let planned = conversations?.plannedProviderID().flatMap(AgentId.init(rawValue:))
    panelView.setAgentChoices(launchable, planned: planned)
  }

  private func syncSessionsToPanel() {
    panelView.setSessions(
      conversations?.switcherItems() ?? [],
      transcripts: conversations?.sessionTranscripts() ?? [:]
    )
  }

  private var isConversationsSyncScheduled = false

  private func scheduleConversationsSync() {
    guard isShowing, !isConversationsSyncScheduled else { return }
    isConversationsSyncScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isConversationsSyncScheduled = false
        guard self.isShowing else { return }
        self.syncAgentChoicesToPanel()
        if self.panelView.isShowingSessions { self.syncSessionsToPanel() }
      }
    }
  }

  private func syncCatalogStateToPanel() {
    let catalog = model.agentCatalog
    syncAgentChoicesToPanel()
    let availability = conversations?.providerAvailability
    let showHints = availability.map { !$0.isAvailable } ?? false
    let enabledAdapters = AgentId.adapterCases.filter {
      model.settings.isProviderEnabled($0.rawValue)
    }
    panelView.setInstallHints(showHints ? enabledAdapters : [])
    panelView.setCatalogScanning(catalog.isScanning && catalog.launchableAgents.isEmpty)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func toggle() {
    if isShowing { hide() } else { show() }
  }

  static let voiceScreenshotFlag = "--ui-testing-voice"
  static let voiceProcessingScreenshotFlag = "--ui-testing-voice-processing"
  static let voiceTranscriptScreenshotFlag = "--ui-testing-voice-transcript"

  private var silenceWatcher = VoiceSilenceWatcher()
  private var voiceScreenshotTimer: Timer?
  private var pendingVoiceSubmit: DispatchWorkItem?
  private var voiceScreenshotPhase: CGFloat = 0

  private func startVoiceScreenshotPreviewIfRequested() {
    guard ProcessInfo.processInfo.arguments.contains(Self.voiceScreenshotFlag),
          voiceScreenshotTimer == nil
    else { return }
    if ProcessInfo.processInfo.arguments.contains("--ui-testing-voice-long") {
      panelView.field.setDraft(
        PromptDraft(
          String(repeating: "Review the voice input in Boltty AI. Keep the recording controls "
            + "at the top right while this long draft scrolls underneath. ", count: 3)
        )
      )
    }
    panelView.setVoiceListening(true)
    if ProcessInfo.processInfo.arguments.contains(Self.voiceTranscriptScreenshotFlag) {
      panelView.applyVoiceTranscript("polish the listening capsule")
    }
    if ProcessInfo.processInfo.arguments.contains(Self.voiceProcessingScreenshotFlag) {
      panelView.setVoiceListening(false, ending: .processing)
      return
    }
    voiceScreenshotTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.voiceScreenshotPhase += 0.2
        self.panelView.applyVoiceLevel(0.55 + 0.35 * sin(self.voiceScreenshotPhase))
      }
    }
  }

  func show() {
    guard !isShowing else { return }
    visibilityGeneration += 1
    let generation = visibilityGeneration
    panelDismissWorkItem?.cancel()
    panelDismissWorkItem = nil
    isSubmitting = false

    let frontmost = NSWorkspace.shared.frontmostApplication
    previouslyActiveApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
      ? nil
      : frontmost

    isShowing = true
    suppressResignHide = true

    guard let window else { return }

    panelView.cancelAllAnimationsAndSettle()

    syncCatalogStateToPanel()
    syncWorkingDirectoryToPanel()
    syncUsageToPanel()
    conversations?.refreshUsage()
    panelView.hideRoutingFallback()
    startVoiceScreenshotPreviewIfRequested()
    let resumed = resumableChat()
    panelView.prepareForPresentation(resumingChat: resumed != nil)
    if let resumed { resumeAddressing(resumed) }
    adoptFinderSelectionIfAppropriate(generation: generation)
    panelView.revealInstallHintsIfNeeded()
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
       ProcessInfo.processInfo.arguments.contains("--ui-testing-reply") {
      let question = AgentQuestion(
        kind: .question, requestID: "screenshot",
        header: "Approach", prompt: "Which approach should I use?",
        options: [
          .init(label: "Keep the native interface", detail: "Polish spacing, keyboard access and transitions."),
          .init(label: "Review the changes first", detail: nil),
          .init(label: "Show more detail", detail: nil),
        ], allowsMultiple: false, allowsCustom: true
      )
      panelView.enterAddressing(.init(
        id: UUID(), title: "Review Boltty AI", agent: .opencode, state: .blocked,
        body: "I reviewed the prompt, voice input and reply card.\n\nThe changes preserve your draft, keep the reply readable while it updates, and make each confirmation send once.\n\nWhich approach should I use?",
        question: question
      ))
    }
    if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
       ProcessInfo.processInfo.arguments.contains("--ui-testing-chat") {
      let working = ProcessInfo.processInfo.arguments.contains("--ui-testing-thinking")
      let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
      func message(
        _ id: String, _ role: ConversationMessage.Role, _ text: String,
        _ tools: [AgentActivity] = []
      ) -> ConversationMessage {
        ConversationMessage(
          id: id, role: role, createdAt: Date(),
          completedAt: role == .agent ? Date() : nil,
          parts: [.text(TextPart(id: id + "-text", kind: .text, text: text))]
            + tools.map { ConversationPart.activity($0) }
        )
      }
      let tools = [
        AgentActivity(id: "t1", name: "read", summary: "Upscayl.app/Contents/MacOS",
                      state: .completed, files: ["/Applications/Upscayl.app"]),
        AgentActivity(id: "t2", name: "bash", summary: "upscayl-bin --help",
                      state: .completed,
                      detail: "Usage: upscayl-bin -i infile -o outfile [options]...\n\n  -s scale\n  -m model-path\n  -n model-name"),
        AgentActivity(id: "t3", name: "bash", summary: "sips -g pixelWidth shot.png",
                      state: .failed, detail: "sips: shot.png: No such file or directory"),
      ]
      let initial = message("user-1", .user, "Which image upscaler works well on a Mac?")
      let history = [initial,
        message("agent-1", .agent, "For a CLI-comfortable developer on Apple Silicon, the free CLI route covers most needs. Upscayl offers a free GUI and an underlying CLI, and Real-ESRGAN runs well enough on the neural engine to batch a folder without heating the machine."),
        message("user-2", .user, "Can I use the CLI for a folder of images?"),
        message("agent-2", .agent, "Yes. Start with one image to check the output, then process the folder. Keep the originals and write the results into a separate directory.", tools),
        message("user-3", .user, "А українською теж розбереш?"),
        message("agent-3", .agent, "Звісно. Перевірю диски, SMART і знос SSD — зараз зберу системні дані. Диск живий і в хорошому стані, це внутрішній Apple SSD, не зовнішній."),
        message("user-4", .user, "Which one would you pick?"),
        message("agent-4", .agent, "Upscayl, unless the batch is large. Its defaults are the ones you would have chosen by hand, and the CLI underneath it is the same binary, so nothing is lost by starting in the window and moving to the terminal later.")]
      panelView.enterAddressing(.init(id: id, title: "Image upscaling", agent: .opencode,
        state: working ? .running : .finished, body: "", messages: working ? [initial] : history))
    }
    if ProcessInfo.processInfo.arguments.contains("--ui-testing-service-cards") {
      let permission = AgentQuestion(
        kind: .permission, requestID: "visual-fixture", header: "Approval",
        prompt: "May I update the files in this project?",
        detail: "swift build --configuration debug",
        options: [.init(label: "Allow once", detail: nil, value: "once"),
                  .init(label: "Always allow", detail: "For this conversation.", value: "always"),
                  .init(label: "Reject", detail: nil, value: "reject")],
        allowsMultiple: false, allowsCustom: false)
      let queued = ProcessInfo.processInfo.arguments.contains("--ui-testing-queue")
      let failed = ProcessInfo.processInfo.arguments.contains("--ui-testing-error")
      var preview = BolttyAISessionPreview(
        id: UUID(), title: "Service cards", agent: .codex,
        state: failed ? .failed : queued ? .running : .blocked,
        body: failed ? "Connection refused by the local agent process." : queued ? "Working" : permission.prompt,
        question: queued || failed ? nil : permission)
      if queued {
        preview.queuedPrompt = "Then review the changes and check that the long queued message stays readable inside its card."
      }
      if failed {
        preview.notice = preview.body
        preview.retryPrompt = "Review the changes"
      }
      panelView.enterAddressing(preview)
      panelView.setUsage(AgentUsage(windows: [
        .init(kind: .session, usedPercent: 18, resetsAt: Date().addingTimeInterval(3600)),
        .init(kind: .weekly, usedPercent: 52, resetsAt: Date().addingTimeInterval(86400))]), agent: .codex)
      panelView.setContext(.init(usedTokens: 160_000, limitTokens: 200_000), canCompact: false)
    }
    #endif
    panelView.surfaceSizes = BolttyAISurfaceSizes.load()
    coverActiveScreen()
    onVisibilityChange?(true, window.screen, panelView.addressedSessionID)

    guard let layer = panelView.preparePresentationLayer() else { return }
    layer.removeAllAnimations()
    panelView.prepareCapsuleForEntrance()
    let drips = willDrip
    if drips { setOpacity(of: layer, to: 0) }

    window.orderFrontRegardless()
    window.makeKeyAndOrderFront(nil)

    coverActiveScreen()

    panelView.layoutForPresentation()
    _ = panelView.focusField()
    if drips { dripIn(layer: layer, generation: generation) }

    DispatchQueue.main.async { [weak self] in
      guard let self,
            self.visibilityGeneration == generation,
            self.isShowing,
            let window = self.window else { return }

      window.orderFrontRegardless()
      window.makeKeyAndOrderFront(nil)
      _ = self.panelView.focusField()

      DispatchQueue.main.async {
        guard self.visibilityGeneration == generation, self.isShowing else { return }
        _ = self.panelView.focusField()
      }

      self.suppressResignHideWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self] in
        guard let self, self.visibilityGeneration == generation else { return }
        self.suppressResignHide = false
      }
      self.suppressResignHideWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }
  }

  func yieldToAppWindow() {
    previouslyActiveApplication = nil
    hide()
  }

  func setPreviousApplicationForTesting(_ application: NSRunningApplication?) {
    previouslyActiveApplication = application
  }

  func hide() {
    PaletteHelpPresenter.shared.dismiss()
    guard isShowing else { return }
    onHide?()
    panelView.releasePointerCursor()
    if panelView.screenSelectionPhase != .idle {
      panelView.endScreenSelection()
      finishScreenSelection()
    }
    leftChat = panelView.addressedSessionID.map { (sessionID: $0, at: Date()) }
    saveCurrentDraft()
    panelView.suspendChatAnimations()
    conversations?.setAddressedConversation(nil)
    stopObservingPreview()
    cancelPendingVoiceSubmit()
    answerTask?.cancel()
    answerTask = nil
    isSubmitting = false
    voiceScreenshotTimer?.invalidate()
    voiceScreenshotTimer = nil

    visibilityGeneration += 1
    let generation = visibilityGeneration
    isShowing = false
    onVisibilityChange?(false, window?.screen, panelView.addressedSessionID)
    suppressResignHide = true
    suppressResignHideWorkItem?.cancel()
    voiceDictation.cancel()
    panelView.setVoiceListening(false, ending: .cancelled)

    let appToRestore = previouslyActiveApplication
    previouslyActiveApplication = nil
    applicationPendingRestoreForTesting = appToRestore

    guard let layer = panelView.presentationLayer else {
      panelView.cancelAllAnimationsAndSettle()
      window?.orderOut(nil)
      DispatchQueue.main.async { [weak self] in
        self?.handBack(appToRestore)
      }
      return
    }

    layer.removeAllAnimations()

    panelDismissWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self,
            self.visibilityGeneration == generation,
            let layer = self.panelView.presentationLayer else { return }

      let finish: @MainActor @Sendable () -> Void = { [weak self] in
        guard let self, self.visibilityGeneration == generation else { return }
        self.window?.orderOut(nil)
        self.panelView.cancelAllAnimationsAndSettle()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        layer.removeAllAnimations()

        self.handBack(appToRestore)
      }
      if self.dripOut() {
        DispatchQueue.main.asyncAfter(
          deadline: .now() + Motion.scaled(AgentPaletteMetrics.dripOutDuration)
        ) { MainActor.assumeIsolated { finish() } }
      } else {
        self.animatePanelDismissal(on: layer, generation: generation, completion: finish)
      }
    }
    panelDismissWorkItem = workItem
    DispatchQueue.main.async(execute: workItem)
  }

  private func handBack(_ application: NSRunningApplication?) {
    guard let application else { return }
    if let activatePreviousApplicationForTesting {
      activatePreviousApplicationForTesting(application)
    } else {
      application.activate()
    }
  }

  private func animatePanelDismissal(
    on layer: CALayer,
    generation: Int,
    completion: @escaping @MainActor @Sendable () -> Void
  ) {
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = layer.presentation()?.opacity ?? layer.opacity
    opacity.toValue = 0

    let group = CAAnimationGroup()
    group.animations = [opacity]
    group.duration = AgentPaletteMetrics.panelFadeOutDuration
    group.timingFunction = Motion.emphasizedCurve
    group.preferringHighFrameRate()

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = 0
    layer.transform = CATransform3DIdentity

    CATransaction.setCompletionBlock {
      Task { @MainActor in
        guard self.visibilityGeneration == generation else { return }
        completion()
      }
    }
    layer.add(group, forKey: "boltty.panel.dismiss")
    CATransaction.commit()
  }

  // MARK: - The drip

  private func dripSource() -> CGRect? {
    guard let window, let screen = window.screen else { return nil }
    let shell = panelView.surfaceFrameInView
    guard !shell.isEmpty else { return nil }
    let midX = window.convertToScreen(panelView.convert(shell, to: nil)).midX
    let source = PaletteDrip.source(on: screen, around: midX)
    return panelView.convert(window.convertFromScreen(source), from: nil)
  }

  private var willDrip: Bool {
    dripsEnabled && !MotionPreferences.reduceMotion
  }

  private func setOpacity(of layer: CALayer, to opacity: Float) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = opacity
    CATransaction.commit()
  }

  private func dripIn(layer: CALayer, generation: Int) {
    if let source = dripSource() {
      panelView.beginDrip(from: source)
    }
    setOpacity(of: layer, to: 1)
  }

  private func dripOut() -> Bool {
    guard willDrip, window?.isVisible == true, let source = dripSource() else { return false }
    panelView.beginDripOut(into: source)
    return panelView.isDrippingForTesting
  }

  // MARK: - Working directory

  private func currentWorkingDirectory() -> String {
    if let id = panelView.addressedSessionID,
       let conversation = conversations?.conversation(id: id) {
      return conversation.workingDirectory
    }
    return pendingWorkingDirectory
      ?? conversations?.defaultWorkingDirectory()
      ?? WorkingDirectoryResolver.homeDirectoryPath
  }

  private func syncContextToPanel() {
    guard let id = panelView.addressedSessionID, let conversations else {
      panelView.setContext(nil, canCompact: false)
      return
    }
    let conversation = conversations.conversation(id: id)
    let cacheIsCold = conversation.map {
      $0.providerID == AgentId.claude.rawValue && !$0.lastKnownState.blocksSending
        && Date().timeIntervalSince($0.updatedAt) > AgentContextUsage.promptCacheLifetime
    } ?? false
    panelView.setContext(
      conversations.contextUsage(for: id), canCompact: conversations.canCompact(id), cacheIsCold: cacheIsCold)
  }

  private func syncWorkingDirectoryToPanel() {
    syncContextToPanel()
    syncUsageToPanel()
    guard let conversations else {
      panelView.setWorkingDirectory(nil)
      panelView.setAcceptsAttachments(false)
      return
    }
    let routedProviderID = routedProviderID(in: conversations)
    panelView.setAcceptsAttachments(
      routedProviderID.map(conversations.acceptsAttachments) ?? false
    )
    if let id = panelView.addressedSessionID,
       let conversation = conversations.conversation(id: id) {
      panelView.setWorkingDirectory(
        WorkingDirectoryChip.forConversation(
          conversation,
          honoursWorkingDirectory: conversations.honoursWorkingDirectory(
            providerID: conversation.providerID
          )
        ).withBranch(GitRepository.read(at: conversation.workingDirectory)?.branch)
      )
      return
    }
    let providerID = panelView.agentForNewPrompt?.rawValue ?? conversations.plannedProviderID()
    let path = currentWorkingDirectory()
    panelView.setWorkingDirectory(
      WorkingDirectoryChip.forNewPrompt(
        path: path,
        honoursWorkingDirectory: providerID
          .map(conversations.honoursWorkingDirectory) ?? true
      ).withBranch(GitRepository.read(at: path)?.branch)
    )
  }

  private func adoptFinderSelectionIfAppropriate(generation: Int) {
    let frontmost = frontmostBundleIDForTesting
      ?? previouslyActiveApplication?.bundleIdentifier
    guard frontmost == FinderSelectionService.finderBundleID else { return }
    guard panelView.addressedSessionID == nil,
          panelView.currentDraft.isEffectivelyEmpty
    else { return }
    let service = finderSelection
    Task { @MainActor [weak self] in
      let urls = await service.selection()
      guard let self, !urls.isEmpty,
            self.visibilityGeneration == generation,
            self.isShowing,
            self.panelView.addressedSessionID == nil,
            self.panelView.currentDraft.isEffectivelyEmpty
      else { return }
      self.panelView.appendAttachments(urls)
    }
  }

  private func routedProviderID(in conversations: BolttyAIConversations) -> String? {
    panelView.addressedSessionID
      .flatMap { conversations.conversation(id: $0)?.providerID }
      ?? panelView.agentForNewPrompt?.rawValue
      ?? conversations.plannedProviderID()
  }

  private func beginScreenSelection() {
    guard screenRecordingAccess() else {
      panelView.cancelScreenSelection()
      panelView.showError(Self.screenRecordingNeeded)
      return
    }
    guard let window, let screen = window.screen ?? NSScreen.main, let displayID = screen.displayID else {
      panelView.cancelScreenSelection()
      return
    }
    isProgrammaticMove = true
    window.setFrame(screen.frame, display: true)
    isProgrammaticMove = false
    panelView.layoutSubtreeIfNeeded()

    frozenScreen = nil
    freezeTask?.cancel()
    let freeze = screenFreeze
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    freezeTask = Task { [weak self] in
      do {
        let frozen = try await freeze(displayID)
        guard let self, !Task.isCancelled else { return }
        self.frozenScreen = frozen
        self.panelView.showFrozenScreen(
          frozen.image, frame: frozen.displayFrameInAppKit(primaryScreenHeight: primaryHeight))
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.panelView.cancelScreenSelection()
        self.panelView.showError(
          error as? ScreenRegionCapture.Failure == .notAllowed
            ? Self.screenRecordingNeeded
            : "Could not capture the screen.")
      }
    }
  }

  private func cutScreenSelection(_ region: CGRect) async -> ScreenSelection? {
    guard let frozenScreen else { return nil }
    let primaryHeight = NSScreen.screens.first?.frame.height ?? region.maxY
    return await Task.detached(priority: .userInitiated) {
      try? ScreenRegionCapture.selection(region, in: frozenScreen, primaryScreenHeight: primaryHeight)
    }.value
  }

  private func putScreenRegionInChat(_ region: CGRect) {
    Task { [weak self] in
      _ = await self?.freezeTask?.value
      guard let self, self.isShowing else { return }
      if let selection = await self.cutScreenSelection(region) {
        guard self.isShowing else { return }
        self.panelView.insertScreenSelection(selection)
      } else {
        self.panelView.showError("Could not capture that part of the screen.")
      }
      self.panelView.endScreenSelection()
      self.finishScreenSelection()
    }
  }

  private func finishScreenSelection() {
    freezeTask?.cancel()
    freezeTask = nil
    frozenScreen = nil
    guard isShowing else { return }
    coverActiveScreen()
  }

  static let screenRecordingNeeded =
    "Boltty needs Screen Recording to see the screen. Allow it in System Settings › Privacy & Security, then quit Boltty and open it again."

  var attachmentStore: PromptAttachmentStoring = PromptAttachmentStore.shared
  private var freezeTask: Task<Void, Never>?
  private var frozenScreen: FrozenScreen?
  var screenRecordingAccess: () -> Bool = { ScreenRegionCapture.ensureAccess() }
  var screenFreeze: (CGDirectDisplayID) async throws -> FrozenScreen = {
    try await ScreenRegionCapture.freeze(displayID: $0)
  }

  private func chooseAttachments() {
    let pick = attachmentPicker ?? { [weak self] current in
      self?.runAttachmentPanel(startingAt: current) ?? []
    }
    let chosen = pick(currentWorkingDirectory())
    guard !chosen.isEmpty else { return }
    panelView.appendAttachments(chosen)
    _ = panelView.focusField()
  }

  private func runAttachmentPanel(startingAt current: String) -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Attach"
    panel.message = "Choose files to send with this prompt"
    panel.directoryURL = URL(fileURLWithPath: current)

    suppressResignHideWorkItem?.cancel()
    suppressResignHide = true
    NSApp.activate(ignoringOtherApps: true)
    PickerPanelPresentation.attach(panel, above: window)
    let response = panel.runModal()
    PickerPanelPresentation.detach(panel, from: window)
    suppressResignHide = false
    window?.makeKeyAndOrderFront(nil)
    guard response == .OK else { return [] }
    return panel.urls
  }

  private func chooseWorkingDirectory() {
    guard let conversations else { return }
    if let id = panelView.addressedSessionID {
      guard conversations.conversation(id: id)?.canChangeWorkingDirectory == true else { return }
    }
    let pick = directoryPicker ?? { [weak self] current in
      self?.runOpenPanel(startingAt: current)
    }
    guard let chosen = pick(currentWorkingDirectory()) else { return }
    useWorkingDirectory(chosen)
  }

  private func useWorkingDirectory(_ path: String) {
    guard let conversations else { return }
    if let id = panelView.addressedSessionID {
      guard conversations.conversation(id: id)?.canChangeWorkingDirectory == true else { return }
      conversations.setWorkingDirectory(path, for: id)
    } else {
      pendingWorkingDirectory = path
    }
    syncWorkingDirectoryToPanel()
    _ = panelView.focusField()
  }

  // MARK: - A history row's menu

  static let openChatTitle = "Open Chat"
  static let deleteChatTitle = "Delete Chat…"

  private func showSessionMenu(for id: UUID, with event: NSEvent, from row: NSView) {
    guard let menu = sessionMenu(for: id) else { return }
    PaletteHelpPresenter.shared.dismiss()
    suppressResignHideWorkItem?.cancel()
    suppressResignHide = true
    panelView.showSessionMenu(menu, with: event, for: row)
    suppressResignHide = false
  }

  func sessionMenu(for id: UUID) -> NSMenu? {
    guard let conversations else { return nil }
    let menu = NSMenu(title: "Chat")
    menu.autoenablesItems = false
    menu.addItem(WorkingDirectoryMenuItem(title: Self.openChatTitle) { [weak self] in
      self?.panelView.openResult(withID: id)
    })
    if let location = conversations.finderLocation(forRow: id) {
      let finder = WorkingDirectoryMenuItem(title: WorkingDirectoryMenu.showInFinderTitle) {
        NSWorkspace.shared.activateFileViewerSelecting([location])
      }
      finder.toolTip = location.path
      menu.addItem(finder)
    }
    if conversations.canDeleteChat(id) {
      menu.addItem(.separator())
      menu.addItem(WorkingDirectoryMenuItem(title: Self.deleteChatTitle) { [weak self] in
        self?.confirmDeleteChat(id)
      })
    }
    return menu
  }

  private func confirmDeleteChat(_ id: UUID) {
    guard let conversations, let conversation = conversations.conversation(id: id) else { return }
    let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let agent = AgentId(rawValue: conversation.providerID)?.displayName
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title.isEmpty ? "Move this chat to the Trash?" : "Move “\(title)” to the Trash?"
    alert.informativeText = conversation.remoteSessionID != nil && agent != nil
      ? "Boltty forgets it, and keeps its transcript in the Trash until you empty it. The session in \(agent!) is not deleted."
      : "Boltty forgets it, and keeps its transcript in the Trash until you empty it."
    alert.addButton(withTitle: "Move to Trash")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true

    suppressResignHideWorkItem?.cancel()
    suppressResignHide = true
    NSApp.activate(ignoringOtherApps: true)
    PickerPanelPresentation.attach(alert.window, above: window)
    let response = alert.runModal()
    PickerPanelPresentation.detach(alert.window, from: window)
    suppressResignHide = false
    window?.makeKeyAndOrderFront(nil)
    guard response == .alertFirstButtonReturn else { return }
    Task { [weak conversations] in await conversations?.deleteChat(id: id) }
  }

  private func showWorkingDirectoryMenu() {
    guard let menu = workingDirectoryMenu() else { return }
    PaletteHelpPresenter.shared.dismiss()
    suppressResignHideWorkItem?.cancel()
    suppressResignHide = true
    panelView.showWorkingDirectoryMenu(menu)
    suppressResignHide = false
  }

  func workingDirectoryMenu() -> NSMenu? {
    guard let conversations else { return nil }
    let chatID = panelView.addressedSessionID
    let conversation = chatID.flatMap(conversations.conversation(id:))
    let canChoose = conversation.map(\.canChangeWorkingDirectory) ?? true
    let home = conversations.defaultWorkingDirectory()
    let current = currentWorkingDirectory()
    return WorkingDirectoryMenu.make(
      current: current,
      home: home,
      recent: RecentFolders.offered(
        recent: conversations.recentWorkingDirectories(), current: current, home: home),
      canChoose: canChoose,
      actions: folderActions(for: current),
      choose: { [weak self] path in self?.useWorkingDirectory(path) },
      openFolder: { [weak self] in self?.chooseWorkingDirectory() }
    )
  }

  private func folderActions(for folder: String) -> WorkingDirectoryMenu.FolderActions {
    let gitHub = GitRepository.read(at: folder)?.gitHubURL
    let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
    return WorkingDirectoryMenu.FolderActions(
      gitHubURL: gitHub,
      showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([folderURL]) },
      copyPath: {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(folder, forType: .string)
      },
      openGitHub: { if let gitHub { NSWorkspace.shared.open(gitHub) } }
    )
  }

  // MARK: - Plan usage

  private func syncUsageToPanel() {
    guard let conversations else {
      panelView.setUsage(nil, agent: nil)
      return
    }
    let providerID = panelView.addressedSessionID
      .flatMap { conversations.conversation(id: $0)?.providerID }
      ?? panelView.agentForNewPrompt?.rawValue
      ?? conversations.plannedProviderID()
    let agent = providerID.flatMap(AgentId.init(rawValue:))
    panelView.setUsage(providerID.flatMap(conversations.usage(providerID:)), agent: agent)
  }

  private func runOpenPanel(startingAt current: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.message = "Choose the folder this chat works in"
    panel.directoryURL = URL(fileURLWithPath: current)

    suppressResignHideWorkItem?.cancel()
    suppressResignHide = true
    NSApp.activate(ignoringOtherApps: true)
    PickerPanelPresentation.attach(panel, above: window)
    let response = panel.runModal()
    PickerPanelPresentation.detach(panel, from: window)
    suppressResignHide = false
    window?.makeKeyAndOrderFront(nil)
    guard response == .OK, let url = panel.url else { return nil }
    return url.path
  }

  private func submit(_ draft: PromptDraft, steering: Bool = false) {
    guard isShowing, !isSubmitting else { return }
    guard panelView.addressedSessionID == nil, let region = panelView.screenSelectionFrame else {
      send(draft, endingScreenSelection: false, steering: steering)
      return
    }
    isSubmitting = true
    Task { [weak self] in
      _ = await self?.freezeTask?.value
      let selection = await self?.cutScreenSelection(region)
      guard let self else { return }
      self.isSubmitting = false
      guard self.isShowing, self.panelView.screenSelectionFrame == region else { return }
      guard let selection else {
        self.panelView.showError("Could not capture that part of the screen.")
        return
      }
      var draft = draft
      draft.append(PromptAttachment(
        kind: .image, payload: .screen(selection), label: draft.nextGeneratedLabel(for: .image)))
      self.send(draft, endingScreenSelection: true)
    }
  }

  private func send(_ draft: PromptDraft, endingScreenSelection: Bool, steering: Bool = false) {
    guard isShowing, !isSubmitting else { return }
    do {
      isSubmitting = true
      var sendingDraft = draft
      if let id = panelView.addressedSessionID {
        conversations?.saveDraft(draft, for: id)
        sendingDraft = conversations?.conversation(id: id)?.panelDraft ?? draft
      }
      let chat = panelView.addressedSessionID
      let names = draft.attachments.reduce(into: [UUID: String]()) { names, attachment in
        guard case let .file(url) = attachment.payload else { return }
        names[attachment.id] = chat.map { ConversationStore.attachedName(of: url, in: $0) }
          ?? url.lastPathComponent
      }
      let (prompt, files) = try PromptExpansion.expandRecordingFiles(
        sendingDraft, names: names, store: attachmentStore)
      var addressed: Conversation?
      if let addressedID = panelView.addressedSessionID {
        guard let conversation = conversations?.conversation(id: addressedID) else {
          isSubmitting = false
          panelView.showError("This chat is gone. Choose another one.")
          return
        }
        addressed = conversation
      }
      switch BolttyAIFollowUp.confirmPrompt(
        promptIsEmpty: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        addressedConversation: addressed
      ) {
      case .open:
        isSubmitting = false
        return
      case .nothing:
        isSubmitting = false
        onPromptRefused?()
        return
      case let .send(addressedID):
        sendFollowUp(prompt, files: files, to: addressedID, steering: steering)
        return
      case .launchNew:
        break
      }
      guard let conversations else {
        isSubmitting = false
        return
      }
      let chosen = panelView.chosenAgent
      let fallback = chosen == nil ? conversations.routingFallback() : nil
      guard let conversationID = conversations.startConversation(
        prompt: prompt,
        id: panelView.pendingConversationID,
        workingDirectory: currentWorkingDirectory(),
        providerID: chosen?.rawValue,
        pictures: files.compactMap(\.file.picture)
      ) else {
        isSubmitting = false
        panelView.showError(chosen.map {
          "\($0.displayName) is not ready. Press Shift-Tab for another agent."
        } ?? "No enabled agent is available. Check Agents in Settings.")
        _ = panelView.focusField()
        return
      }
      conversations.recordSentFiles(files.map(\.file), in: conversationID)
      onPromptSent?()
      newPromptDraft = PromptDraft()
      panelView.setChatDraft(PromptDraft())
      isSubmitting = false
      if endingScreenSelection {
        panelView.endScreenSelection()
        finishScreenSelection()
      }
      if let fallback {
        panelView.showRoutingFallback(fallback)
      } else {
        panelView.hideRoutingFallback()
      }
      pendingWorkingDirectory = nil
      beginAddressing(conversationID)

    } catch {
      isSubmitting = false
      panelView.showError(error.localizedDescription)
      panelView.layoutSubtreeIfNeeded()
      _ = panelView.focusField()
    }
  }

  func addressConversation(_ sessionID: UUID) {
    guard conversations?.conversation(id: sessionID) != nil else { return }
    if !isShowing { show() }
    beginAddressing(sessionID)
  }

  private func confirmSession(_ sessionID: UUID) {
    guard isShowing, !isSubmitting else { return }
    guard let conversation = conversations?.conversation(id: sessionID) else { return }
    beginAddressing(conversation.id)
  }

  private func beginAddressing(_ sessionID: UUID) {
    saveCurrentDraft()
    guard let preview = conversations?.preview(for: sessionID) else { return }
    if panelView.addressedSessionID == nil { newPromptDraft = panelView.currentDraft }
    conversations?.setAddressedConversation(sessionID)
    panelView.setChatDraft(conversations?.conversation(id: sessionID)?.panelDraft ?? PromptDraft())
    stopObservingPreview()
    observingPreviewID = sessionID
    panelView.enterAddressing(preview)
    syncWorkingDirectoryToPanel()
    conversations?.refreshContext(for: sessionID)
    observePreviewChanges(of: sessionID)
    _ = panelView.focusField()
  }

  private func resumableChat() -> UUID? {
    defer { leftChat = nil }
    guard let left = leftChat else { return nil }
    let elapsed = Date().timeIntervalSince(left.at)
    guard elapsed >= 0, elapsed < resumeWindow,
          panelView.addressedSessionID == left.sessionID,
          conversations?.conversation(id: left.sessionID) != nil
    else { return nil }
    return left.sessionID
  }

  private func resumeAddressing(_ sessionID: UUID) {
    guard let preview = conversations?.preview(for: sessionID) else {
      panelView.leaveAddressing(animated: false)
      return
    }
    conversations?.setAddressedConversation(sessionID)
    stopObservingPreview()
    observingPreviewID = sessionID
    panelView.updateAddressing(preview)
    panelView.resumeChatAnimations()
    syncWorkingDirectoryToPanel()
    conversations?.refreshContext(for: sessionID)
    observePreviewChanges(of: sessionID)
  }

  private func observePreviewChanges(of sessionID: UUID) {
    conversations?.observePreview(of: sessionID) { [weak self] in
      Task { @MainActor in
        guard let self, self.isShowing, self.observingPreviewID == sessionID else { return }
        guard let updated = self.conversations?.preview(for: sessionID) else {
          self.panelView.leaveAddressing(animated: false)
          self.panelView.showError("This chat is gone. Choose another one.")
          return
        }
        self.panelView.updateAddressing(updated)
        self.syncWorkingDirectoryToPanel()
      }
    }
  }

  private func sendFollowUp(
    _ prompt: String, files: [(chip: UUID, file: SentFile)] = [], to sessionID: UUID,
    steering: Bool = false
  ) {
    let preview = conversations?.preview(for: sessionID)
    if let preview, preview.question != nil {
      isSubmitting = false
      panelView.showError(BolttyAIFollowUp.busyMessage(agent: preview.agent))
      panelView.layoutSubtreeIfNeeded()
      _ = panelView.focusField()
      return
    }
    if !files.isEmpty { conversations?.recordSentFiles(files.map(\.file), in: sessionID) }
    if let preview, preview.isBusy, let conversations {
      isSubmitting = false
      let outcome = steering
        ? conversations.steerFollowUp(prompt, to: sessionID)
        : conversations.queueFollowUp(prompt, to: sessionID)
      onPromptSent?()
      conversations.saveDraft(PromptDraft(), for: sessionID)
      panelView.setChatDraft(PromptDraft())
      panelView.announceQueued(
        BolttyAIFollowUp.queuedMessage(outcome, agent: preview.agent)
      )
      refreshAddressedPreview(sessionID)
      _ = panelView.focusField()
      return
    }
    panelView.prepareFileFlights(files)
    guard conversations?.sendFollowUp(
      prompt, pictures: files.compactMap(\.file.picture), to: sessionID) == true else {
      isSubmitting = false
      panelView.showError("Could not send to this chat. Your message is still here.")
      return
    }
    onPromptSent?()
    conversations?.saveDraft(PromptDraft(), for: sessionID)
    panelView.setChatDraft(PromptDraft())
    isSubmitting = false
    beginAddressing(sessionID)
  }

  private func refreshAddressedPreview(_ sessionID: UUID) {
    guard panelView.addressedSessionID == sessionID,
          let updated = conversations?.preview(for: sessionID)
    else { return }
    panelView.updateAddressing(updated)
  }

  private func saveCurrentDraft() {
    if let id = panelView.addressedSessionID {
      conversations?.saveDraft(panelView.currentDraft, for: id)
    } else {
      newPromptDraft = panelView.currentDraft
    }
  }

  private func stopObservingPreview() {
    if let id = observingPreviewID {
      conversations?.observePreview(of: id, nil)
      observingPreviewID = nil
    }
  }

  private func answer(_ question: AgentQuestion, with answers: [String], in sessionID: UUID) {
    guard isShowing, !isSubmitting, panelView.addressedSessionID == sessionID else { return }
    guard let current = conversations?.preview(for: sessionID), current.question == question, !current.isBusy else {
      panelView.showError("This question is no longer waiting for an answer.")
      return
    }
    isSubmitting = true
    let generation = visibilityGeneration
    let send = sendAnswer
    let submittedDraft = panelView.currentDraft
    answerTask = Task { @MainActor [weak self] in
      do {
        let shown = self?.conversations?.preview(for: sessionID)
        var delivered = false
        if shown == nil || shown?.question == question {
          delivered = try await send(question, answers)
        }
        guard let self, !Task.isCancelled, self.isShowing,
              self.visibilityGeneration == generation else { return }
        self.isSubmitting = false
        self.answerTask = nil
        guard self.panelView.addressedSessionID == sessionID else { return }
        if let preview = self.conversations?.preview(for: sessionID) {
          if preview.question == question, let notice = preview.notice {
            self.panelView.showError(notice)
          } else if !delivered {
            self.panelView.showError(
              preview.question == question
                ? "That reply was not delivered. Try again."
                : "This question is no longer waiting for an answer."
            )
          } else if self.panelView.currentDraft == submittedDraft,
                    AgentQuestion.answer(answers, carries: submittedDraft.typedText) {
            self.panelView.setChatDraft(PromptDraft())
            self.conversations?.saveDraft(PromptDraft(), for: sessionID)
          }
          self.panelView.updateAddressing(preview)
        }
      } catch {
        guard let self, !Task.isCancelled, self.isShowing,
              self.visibilityGeneration == generation else { return }
        self.isSubmitting = false
        self.answerTask = nil
        guard self.panelView.addressedSessionID == sessionID,
              self.panelView.addressedQuestion == question else { return }
        self.panelView.showError("Could not reach the agent")
      }
    }
  }

  private func selectExistingSession(_ sessionID: UUID) {
    guard isShowing else { return }
    previouslyActiveApplication = nil
    panelView.reset()
    hide()
    onSelectSession?(sessionID)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func coverActiveScreen() {
    guard let window else { return }
    let screen = Self.presentationScreen(
      main: NSScreen.main,
      pointer: NSEvent.mouseLocation,
      screens: NSScreen.screens
    )
    guard let screen else { return }
    let visible = screen.visibleFrame
    let frame = CGRect(x: visible.minX, y: visible.minY, width: visible.width,
                       height: screen.frame.maxY - visible.minY)
    isProgrammaticMove = true
    window.setFrame(frame, display: true)
    isProgrammaticMove = false
    panelView.topReserve = frame.maxY - visible.maxY
    panelView.layoutSubtreeIfNeeded()
  }

  static func presentationScreen(
    main: NSScreen?,
    pointer: NSPoint,
    screens: [NSScreen]
  ) -> NSScreen? {
    if let main, screens.contains(where: { $0 === main }) { return main }
    return screens.first { $0.frame.contains(pointer) } ?? screens.first
  }

  private var isProgrammaticMove = false

  func windowDidMove(_ notification: Notification) {
    guard isShowing, !isProgrammaticMove else { return }
    coverActiveScreen()
  }

  func windowDidResignKey(_ notification: Notification) {
    guard isShowing, !suppressResignHide,
          voiceDictation.state != .requestingPermission else { return }

    DispatchQueue.main.async { [weak self] in
      guard let self, self.isShowing, !self.suppressResignHide,
            self.voiceDictation.state != .requestingPermission else { return }
      guard self.window?.isKeyWindow != true else { return }
      self.hide()
    }
  }
}
