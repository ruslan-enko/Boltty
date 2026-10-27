import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var model: AppModel?
  private var chat: ChatWorkspaceCoordinator?
  private var palette: AgentPaletteController?
  private var notchMascot: NotchMascotController?
  private var settingsWindowController: SettingsWindowController?
  private var accessWindowController: AccessPermissionsWindowController?
  private var setupWindowController: SetupWindowController?
  private var firstRunShow: FirstRunShowController?
  private var hotkey: GlobalHotkeyService?
  private var statusBar: StatusBarController?
  private var attentionNotifications: SystemAttentionNotificationService?
  private var sounds: InterfaceSounds?
  private var askBoltty: AskBolttyController?
  /// Boltty's voice, made on first use: the synthesizer loads its voices then.
  private lazy var speech = SpeechOutput { [weak self] in
    let settings = self?.model?.settings ?? AppSettings()
    return SpeechOutput.Preferences(
      voiceByLanguage: settings.speechVoiceByLanguage, rate: settings.speechRate)
  }
  private var settingsCancellable: AnyCancellable?
  private var cancellables = Set<AnyCancellable>()
  private var shortcutMonitor: Any?

  private var didPrepareForTermination = false
  private let presence = AppPresence()
  private let backgroundActivity = BackgroundActivityAssertion()
  private let updater = AppUpdater()
  private let loginItem = LoginItem()

  func applicationDidFinishLaunching(_ notification: Notification) {
    LaunchTrace.mark("→ applicationDidFinishLaunching entered")
    #if DEBUG
    NSLog("[Boltty] applicationDidFinishLaunching")
    #endif

    guard !Self.isHostingUnitTests else { return }

    setupModel()
    LaunchTrace.mark("setupModel")

    setupHotkey()
    LaunchTrace.mark("setupHotkey")
    installMenu()
    LaunchTrace.mark("installMenu")
    shortcutMonitor = BolttyShortcutRouter.installMonitor()
    LaunchTrace.mark("installMonitor")

    model?.agentCatalog.scan()
    LaunchTrace.mark("agentCatalog.scan (async)")
    Task.detached(priority: .utility) {
      PromptAttachmentStore.shared.purgeExpired()
    }

    setupStatusBar()
    presence.enterTrayOnly()
    setupSettingsPipeline()
    LaunchTrace.mark("tray + settings pipeline")

    setupChat()
    LaunchTrace.mark("setupChat")
    setupBackgroundActivity()
    setupUpdater()
    warmDeferredWork()
    presentFirstRunIfNeeded()
    DispatchQueue.main.async { LaunchTrace.mark("first run-loop turn") }
    #if DEBUG
    NSLog("[Boltty] workspace ready controllers=%d", chat?.store.conversations.count ?? 0)
    #endif
  }

  private func setupModel() {
    let model = AppModel(settings: AppSettings.load())
    self.model = model
  }

  static var isHostingUnitTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  private func setupChat() {
    let store = ConversationStore()
    let registry = AgentRegistry.live()
    let engine = ConversationEngine(store: store, registry: registry)
    let coordinator = ChatWorkspaceCoordinator(store: store, engine: engine)
    if let appModel = model {
      coordinator.isProviderEnabled = { [weak appModel] id in
        appModel?.settings.isProviderEnabled(id) ?? true
      }
      coordinator.preferredProviderID = { [weak appModel] in
        appModel?.settings.agentPreset?.rawValue
      }
      coordinator.defaultModelID = { [weak appModel] id in
        appModel?.settings.defaultModelByProvider[id]
      }
      coordinator.defaultEffortID = { [weak appModel] id in
        appModel?.settings.defaultEffortByProvider[id]
      }
      coordinator.defaultAutoApprove = { [weak appModel] id in
        appModel?.settings.autoApproveProviderIDs.contains(id) ?? false
      }
    }
    let notifications = SystemAttentionNotificationService()
    notifications.onActivateSession = { [weak self] id in
      self?.requirePalette()?.addressConversation(id)
    }
    notifications.onReplyToSession = { [weak self] id, text in
      guard let self else { return }
      if self.chat?.replyFromNotification(text, to: id) != true {
        self.requirePalette()?.addressConversation(id)
      }
    }
    let sounds = InterfaceSounds { [weak appModel = model] in appModel?.settings.playsSounds ?? true }
    notifications.sound = { [weak sounds] kind in sounds?.notificationSound(for: kind) }
    self.sounds = sounds
    coordinator.notificationDelivery = { [weak notifications] in notifications?.deliver($0) }
    attentionNotifications = notifications
    chat = coordinator

    let askBoltty = AskBolttyController(coordinator: coordinator, speech: speech) { [weak appModel = model] in
      appModel?.settings ?? AppSettings()
    }
    askBoltty.onBegin = { [weak self] in self?.palette?.hide() }
    askBoltty.onSent = { [weak self] in self?.sounds?.playSend() }
    askBoltty.onNeedsYou = { [weak self] id in self?.requirePalette()?.addressConversation(id) }
    self.askBoltty = askBoltty
    model?.$settings
      .sink { [weak askBoltty] in askBoltty?.apply($0) }
      .store(in: &cancellables)

    engine.start()
    statusBar?.attach(coordinator)
    if ProcessInfo.processInfo.arguments.contains(Self.uiTestingFlag) {
      requireSettingsWindow()?.present(activating: false)
    }
  }

  static let uiTestingFlag = "--ui-testing"

  private func applyWindowPresence(hasVisibleWindow: Bool) {
    guard !didPrepareForTermination else { return }
    if hasVisibleWindow || settingsWindowController?.window?.isVisible == true
      || accessWindowController?.window?.isVisible == true
      || setupWindowController?.window?.isVisible == true {
      presence.enterForeground()
    } else {
      presence.enterTrayOnly()
    }
  }

  private func setupBackgroundActivity() {
    guard let chat else { return }
    chat.store.$conversations
      .map { $0.contains { $0.lastKnownState.blocksSending } }
      .removeDuplicates()
      .sink { [weak self] hasSessions in
        self?.backgroundActivity.setNeeded(hasSessions)
      }
      .store(in: &cancellables)
  }

  private func setupUpdater() {
    updater.checksAutomatically = { [weak self] in self?.model?.settings.checksForUpdates ?? true }
    updater.onPresent = { [weak self] in self?.presence.enterForeground() }
    updater.onDismiss = { [weak self] in self?.applyWindowPresence(hasVisibleWindow: false) }
    statusBar?.onCheckForUpdates = { [weak self] in self?.updater.checkForUpdates() }
    updater.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        guard let self else { return }
        self.statusBar?.updateOffer = self.updater.offer
      }
      .store(in: &cancellables)
    updater.start()
    statusBar?.updateOffer = updater.offer
  }

  @objc private func checkForUpdates() {
    updater.checkForUpdates()
  }

  @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard menuItem.action == #selector(checkForUpdates) else { return true }
    return !updater.isInstalling && (updater.available != nil || !updater.isChecking)
  }

  @discardableResult
  private func requirePalette() -> AgentPaletteController? {
    if let palette { return palette }
    guard let model, let chat else { return nil }
    let palette = AgentPaletteController(model: model, conversations: chat)
    let notch = NotchMascotController()
    notch.onOpen = { [weak self] conversationID in
      if let conversationID {
        self?.requirePalette()?.addressConversation(conversationID)
      } else {
        self?.requirePalette()?.show()
      }
    }
    let asks = chat.store.$transcripts
      .map { NotchMascotStatus.asks(in: $0) }
      .removeDuplicates()
    chat.store.$conversations.combineLatest(model.$settings, asks)
      .sink { [weak notch] conversations, settings, waitingOn in
        notch?.update(
          conversations: conversations,
          roster: MascotRoster(selections: settings.mascotSelections, preferred: settings.agentPreset),
          waitingOn: waitingOn
        )
      }
      .store(in: &cancellables)
    palette.onVisibilityChange = { [weak notch] visible, screen, conversationID in
      notch?.setPanelVisible(visible, screen: screen, conversationID: conversationID)
    }
    notchMascot = notch
    palette.onOpenSettings = { [weak self] in self?.showSettings(page: .agents) }
    palette.onPromptSent = { [weak self] in self?.sounds?.playSend() }
    palette.onPromptRefused = { [weak self] in self?.sounds?.playRefused() }
    palette.onSpeakMessage = { [weak self] message in
      self?.speech.toggle(markdown: message.copyableText, id: message.id)
    }
    palette.onHide = { [weak self] in
      guard let speech = self?.speech, speech.speakingID?.hasPrefix("settings-") == false else { return }
      speech.stop()
    }
    speech.$speakingID
      .removeDuplicates()
      .sink { [weak palette] id in palette?.setSpeakingMessage(id) }
      .store(in: &cancellables)
    palette.onSelectSession = { [weak self] conversationID in
      self?.requirePalette()?.addressConversation(conversationID)
    }
    self.palette = palette
    return palette
  }

  @discardableResult
  private func requireSettingsWindow() -> SettingsWindowController? {
    if let settingsWindowController { return settingsWindowController }
    guard let model else { return nil }
    guard let engine = chat?.engine else { return nil }
    let controller = SettingsWindowController(
      model: model,
      engine: engine,
      probeHotkey: { [weak hotkey] binding in hotkey?.probe(binding) ?? .free },
      updater: updater,
      loginItem: loginItem,
      speech: speech
    )
    settingsWindowController = controller
    controller.onReviewAccess = { [weak self] in self?.showAccess() }
    if let window = controller.window {
      NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
        .sink { [weak self] _ in
          DispatchQueue.main.async {
            guard let self else { return }
            self.applyWindowPresence(hasVisibleWindow: false)
          }
        }
        .store(in: &cancellables)
    }
    return controller
  }

  private func warmDeferredWork() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      self?.requirePalette()
      LaunchTrace.mark("deferred panel warmed")
      AgentHistoryFaces.warm()
    }
  }

  private static let hasShownFirstRunKey = "boltty.hasShownFirstRun"

  private func presentFirstRunIfNeeded() {
    guard !ProcessInfo.processInfo.arguments.contains(Self.uiTestingFlag) else { return }
    let defaults = UserDefaults.standard
    var isFirstRun = !defaults.bool(forKey: Self.hasShownFirstRunKey)
    #if DEBUG
    if defaults.bool(forKey: "boltty.replayIntro") { isFirstRun = true }
    #endif
    defaults.set(true, forKey: Self.hasShownFirstRunKey)
    let greet = { [weak self] in
      guard let self else { return }
      self.firstRunShow?.dismissBackdrop()
      self.firstRunShow = nil
      if isFirstRun { self.requirePalette()?.show() }
    }
    // The first run plays Boltty once — the show (*First run*) — then sets
    // it up in one window — agents, faces, keys, access — and opens the
    // panel once that closes.
    if isFirstRun {
      return playFirstRunShow { [weak self] in
        guard let self else { return }
        if !self.showSetup(then: greet) { greet() }
      }
    }
    guard !defaults.bool(forKey: AccessPermissionsWindowController.shownKey) else { return }
    defaults.set(true, forKey: AccessPermissionsWindowController.shownKey)
    let access = requireAccessWindow()
    Task { @MainActor [weak self] in
      await access.model.refresh()
      guard !access.model.allAllowed else { return }
      self?.showAccess()
    }
  }

  private var firstRunScreen: NSScreen? {
    AgentPaletteController.presentationScreen(
      main: NSScreen.main, pointer: NSEvent.mouseLocation, screens: NSScreen.screens
    )
  }

  /// The agents to show: the ones that can take a prompt, in the history
  /// tabs' order, or every adapter while none is ready yet (a first launch
  /// may come before the scan).
  private var firstRunAgents: [AgentId] {
    let launchable = chat?.launchableProviderIDs().compactMap(AgentId.init(rawValue:)) ?? []
    let ready = AgentHistory.tabOrder.filter(launchable.contains)
    return ready.isEmpty ? AgentHistory.tabOrder : ready
  }

  /// The show — the faces gathering under a sunset, then Boltty AI played
  /// on glass of its own — *First run* in AGENTS.md. `then` runs once it
  /// has ended or was skipped.
  private func playFirstRunShow(then: @escaping () -> Void) {
    guard let screen = firstRunScreen, !MotionPreferences.reduceMotion else { return then() }
    #if DEBUG
    if UserDefaults.standard.bool(forKey: "boltty.skipShow") { return then() }
    #endif
    let show = FirstRunShowController(
      agents: firstRunAgents,
      planned: UserDefaults.standard.string(forKey: AppSettings.agentPresetKey).flatMap(AgentId.init(rawValue:))
        ?? chat?.plannedProviderID().flatMap(AgentId.init(rawValue:)),
      on: screen
    )
    show.onSound = { [weak self] sound, index in self?.sounds?.playFace(sound, index) }
    show.onSend = { [weak self] in self?.sounds?.playSend() }
    show.makesBlips = model?.settings.playsSounds ?? true
    show.onMusic = { [weak self] playing in
      if playing { self?.sounds?.startMusic() } else { self?.sounds?.stopMusic(fade: 2.5) }
    }
    firstRunShow = show
    show.play(completion: then)
  }

  /// The setup window, on the same settings model as Settings. `false`
  /// when it cannot be made yet (no engine).
  private func showSetup(then: @escaping () -> Void) -> Bool {
    guard let model, let engine = chat?.engine else { return false }
    let settings = BolttyAISettingsModel(
      appModel: model, engine: engine, updater: updater, loginItem: loginItem, speech: speech
    )
    settings.probeHotkey = { [weak hotkey] binding in hotkey?.probe(binding) ?? .free }
    let setup = SetupWindowController(
      model: settings, access: AccessPermissionsModel(probe: .live)
    )
    setupWindowController = setup
    setup.onFaceHover = { [weak self] index in self?.sounds?.playFace(.hum, index) }
    UserDefaults.standard.set(true, forKey: AccessPermissionsWindowController.shownKey)
    setup.onClose = { [weak self] in
      self?.setupWindowController = nil
      self?.applyWindowPresence(hasVisibleWindow: false)
      then()
    }
    presence.enterForeground { [weak self] in
      setup.show(on: self?.firstRunScreen)
      // The show's daylight stays under the window until it closes.
      if let window = setup.window { self?.firstRunShow?.settle(under: window) }
    }
    return true
  }

  private func requireAccessWindow() -> AccessPermissionsWindowController {
    if let accessWindowController { return accessWindowController }
    let controller = AccessPermissionsWindowController(probe: .live)
    accessWindowController = controller
    return controller
  }

  private func showAccess(then: (() -> Void)? = nil) {
    let access = requireAccessWindow()
    access.onClose = { [weak self] in
      self?.applyWindowPresence(hasVisibleWindow: false)
      then?()
    }
    presence.enterForeground { access.show() }
  }

  private func setupStatusBar() {
    let statusBar = StatusBarController()
    statusBar.onBolttyAI = { [weak self] in self?.requirePalette()?.show() }
    statusBar.onSelectAgent = { [weak self] id in self?.requirePalette()?.addressConversation(id) }
    statusBar.onJumpLatestUnread = { [weak self] in
      if let id = self?.chat?.statusSnapshot.latestUnreadSessionID {
        self?.requirePalette()?.addressConversation(id)
      }
    }
    statusBar.onSettings = { [weak self] in self?.showSettings() }
    statusBar.onQuit = { [weak self] in self?.requestQuit() }
    statusBar.install()
    self.statusBar = statusBar
    refreshHotkeyHint()
  }

  private func setupHotkey() {
    hotkey = GlobalHotkeyService { [weak self] in
      Task { @MainActor in
        self?.requirePalette()?.toggle()
      }
    }
    guard let settings = model?.settings else { return }
    applyHotkey(settings.bolttyAIHotkey, enabled: settings.bolttyAIHotkeyEnabled)
  }

  private func setupSettingsPipeline() {
    guard let model else { return }
    settingsCancellable = model.$settings
      .map { ($0.bolttyAIHotkey, $0.bolttyAIHotkeyEnabled) }
      .removeDuplicates { $0 == $1 }
      .sink { [weak self] binding, enabled in
        self?.applyHotkey(binding, enabled: enabled)
      }
  }

  private var appliedHotkey: HotkeyBinding?
  private var isRevertingHotkey = false
  private var lastHotkeyAttempt: (binding: HotkeyBinding, enabled: Bool)?

  private func applyHotkey(_ binding: HotkeyBinding, enabled: Bool) {
    guard let model, let hotkey else { return }

    if isRevertingHotkey {
      isRevertingHotkey = false
      return
    }

    if lastHotkeyAttempt?.binding == binding, lastHotkeyAttempt?.enabled == enabled {
      refreshHotkeyHint()
      return
    }
    let waitingModifierChoice = inputMonitoringTimer == nil
      ? nil : lastHotkeyAttempt.map(\.binding).flatMap { $0.isModifierOnly ? $0 : nil }
    lastHotkeyAttempt = (binding, enabled)
    model.hotkeyStandIn = nil
    model.hotkeyStandInFailed = false
    stopAwaitingInputMonitoring()

    guard enabled else {
      hotkey.stop()
      appliedHotkey = nil
      model.hotkeyRegistrationFailed = false
      refreshHotkeyHint()
      return
    }

    let availability = hotkey.updateHotkey(binding)
    if availability.isFree {
      appliedHotkey = binding
      model.hotkeyRegistrationFailed = false
      refreshHotkeyHint()
      return
    }

    if binding.isModifierOnly, availability == .needsInputMonitoring {
      let candidates = [appliedHotkey].compactMap { $0 }.filter { !$0.isModifierOnly }
        + [HotkeySuggestions.defaultBinding] + HotkeySuggestions.fallbacks
      appliedHotkey = nil
      for candidate in candidates where HotkeyValidation.reject(candidate) == nil {
        if hotkey.updateHotkey(candidate).isFree {
          appliedHotkey = candidate
          break
        }
      }
      model.hotkeyRegistrationFailed = false
      model.hotkeyStandInFailed = appliedHotkey == nil
      model.hotkeyStandIn = appliedHotkey
      awaitInputMonitoring()
      refreshHotkeyHint()
      return
    }

    #if DEBUG
    NSLog("[Boltty] failed to register Boltty AI hotkey \(binding.displayName): \(availability)")
    #endif
    model.hotkeyRegistrationFailed = true

    if appliedHotkey == nil, binding == HotkeySuggestions.defaultBinding,
       !model.settings.bolttyAIHotkeyIsChosen,
       let fallback = HotkeySuggestions.firstFree(isFree: { hotkey.probe($0).isFree }),
       hotkey.updateHotkey(fallback).isFree {
      appliedHotkey = fallback
      model.hotkeyRegistrationFailed = false
      lastHotkeyAttempt = (fallback, enabled)
      model.updateSettings { $0.bolttyAIHotkey = fallback }
      refreshHotkeyHint()
      return
    }

    if let waiting = waitingModifierChoice, waiting != binding {
      if let standIn = appliedHotkey, !hotkey.updateHotkey(standIn).isFree {
        appliedHotkey = nil
      }
      model.hotkeyStandIn = appliedHotkey
      model.hotkeyStandInFailed = appliedHotkey == nil
      isRevertingHotkey = true
      lastHotkeyAttempt = (waiting, enabled)
      model.updateSettings { $0.bolttyAIHotkey = waiting }
      awaitInputMonitoring()
      refreshHotkeyHint()
      return
    }

    guard let previous = appliedHotkey, previous != binding else {
      refreshHotkeyHint()
      return
    }
    if hotkey.updateHotkey(previous).isFree {
      isRevertingHotkey = true
      lastHotkeyAttempt = (previous, enabled)
      model.updateSettings { $0.bolttyAIHotkey = previous }
    } else if previous.isModifierOnly {
      appliedHotkey = nil
      lastHotkeyAttempt = nil
      model.updateSettings { $0.bolttyAIHotkey = previous }
    } else {
      appliedHotkey = nil
    }
    refreshHotkeyHint()
  }

  private var inputMonitoringTimer: Timer?
  private var inputMonitoringTapTriesLeft = 0
  private static let inputMonitoringTapTries = 15

  private func awaitInputMonitoring() {
    guard inputMonitoringTimer == nil else { return }
    inputMonitoringTapTriesLeft = Self.inputMonitoringTapTries
    inputMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let hotkey = self.hotkey, let settings = self.model?.settings,
              settings.bolttyAIHotkey.isModifierOnly, settings.bolttyAIHotkeyEnabled
        else {
          self?.stopAwaitingInputMonitoring()
          return
        }
        guard ModifierHotkeyMonitor.hasAccess else {
          self.inputMonitoringTapTriesLeft = Self.inputMonitoringTapTries
          return
        }
        guard self.inputMonitoringTapTriesLeft > 0 else { return }
        self.inputMonitoringTapTriesLeft -= 1
        guard hotkey.takeOver(with: settings.bolttyAIHotkey).isFree else { return }
        self.stopAwaitingInputMonitoring()
        self.appliedHotkey = settings.bolttyAIHotkey
        self.model?.hotkeyStandIn = nil
        self.model?.hotkeyStandInFailed = false
        self.refreshHotkeyHint()
      }
    }
  }

  private func stopAwaitingInputMonitoring() {
    inputMonitoringTimer?.invalidate()
    inputMonitoringTimer = nil
  }

  private func refreshHotkeyHint() {
    statusBar?.hotkeyHint = appliedHotkey?.displayName
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // The first run's show is playing: the panel comes after it.
    if firstRunShow?.isPlaying == true { return false }
    if let settings = settingsWindowController?.window,
       settings.isVisible || settings.isMiniaturized {
      presence.enterForeground()
      if settings.isMiniaturized { settings.deminiaturize(nil) }
      settings.makeKeyAndOrderFront(nil)
      return false
    }
    requirePalette()?.show()
    return false
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if didPrepareForTermination {
      return .terminateNow
    }
    finishTermination()
    return .terminateLater
  }

  private func finishTermination() {
    beginApplicationTermination()
    askBoltty?.shutDown()
    guard let chat else {
      NSApp.reply(toApplicationShouldTerminate: true)
      return
    }
    var replied = false
    let reply = {
      guard !replied else { return }
      replied = true
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    Task { @MainActor in
      await chat.prepareForTermination()
      reply()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationDeadline) {
      reply()
    }
  }

  private static let terminationDeadline: TimeInterval = 8

  func applicationWillTerminate(_ notification: Notification) {
    beginApplicationTermination()
    if let shortcutMonitor {
      NSEvent.removeMonitor(shortcutMonitor)
      self.shortcutMonitor = nil
    }
    hotkey?.stop()
    statusBar?.remove()
  }

  @MainActor private func installMenu() {
    let bindings = model?.shortcutBindings
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenuItem.submenu = appMenu
    appMenu.addItem(withTitle: "About Boltty",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    let updatesItem = appMenu.addItem(withTitle: "Check for Updates…",
                                      action: #selector(checkForUpdates),
                                      keyEquivalent: "")
    updatesItem.target = self
    appMenu.addItem(NSMenuItem.separator())
    let settingsItem = appMenu.addItem(withTitle: "Settings…",
                                       action: #selector(openSettings),
                                       keyEquivalent: ",")
    settingsItem.target = self
    bindings?.bind(settingsItem, to: "settings")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
      withTitle: "Hide Boltty",
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )
    let hideOthers = appMenu.addItem(
      withTitle: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h"
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(
      withTitle: "Show All",
      action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(NSMenuItem.separator())
    let closeItem = appMenu.addItem(withTitle: "Close Boltty",
                                    action: #selector(closeBoltty),
                                    keyEquivalent: "q")
    closeItem.target = self
    bindings?.bind(closeItem, to: "closeBoltty")
    let quitItem = appMenu.addItem(withTitle: "Quit Boltty",
                                   action: #selector(requestQuit),
                                   keyEquivalent: "")
    quitItem.target = self

    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenuItem.submenu = editMenu
    bindings?.bind(
      editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
      to: "copy"
    )
    bindings?.bind(
      editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
      to: "paste"
    )
    editMenu.addItem(NSMenuItem.separator())
    bindings?.bind(
      editMenu.addItem(
        withTitle: "Select All",
        action: #selector(NSText.selectAll(_:)),
        keyEquivalent: "a"
      ),
      to: "selectAll"
    )
    editMenu.addItem(NSMenuItem.separator())
    let servicesMenu = NSMenu(title: "Services")
    let servicesItem = editMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
    servicesItem.submenu = servicesMenu
    NSApplication.shared.servicesMenu = servicesMenu

    let windowMenuItem = NSMenuItem()
    mainMenu.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: "Window")
    windowMenuItem.submenu = windowMenu

    bindings?.bind(
      windowMenu.addItem(
        withTitle: "Minimize",
        action: #selector(NSWindow.performMiniaturize(_:)),
        keyEquivalent: "m"
      ),
      to: "minimize"
    )
    windowMenu.addItem(
      withTitle: "Zoom",
      action: #selector(NSWindow.performZoom(_:)),
      keyEquivalent: ""
    )
    windowMenu.addItem(NSMenuItem.separator())

    // No chord: the launch hotkey (General) is the key that opens it, and a
    // second one here was the same thing twice.
    let paletteItem = windowMenu.addItem(
      withTitle: "Boltty AI",
      action: #selector(openPalette),
      keyEquivalent: ""
    )
    paletteItem.target = self

    windowMenu.addItem(NSMenuItem.separator())
    windowMenu.addItem(
      withTitle: "Bring All to Front",
      action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: ""
    )

    NSApplication.shared.mainMenu = mainMenu
    NSApplication.shared.windowsMenu = windowMenu

    #if DEBUG
    bindings?.assertEveryCustomizableIDIsBound()
    #endif
  }

  @objc private func openPalette() {
    requirePalette()?.show()
  }

  @objc private func closeBoltty() {
    settingsWindowController?.window?.performClose(nil)
    palette?.hide()
    presence.enterTrayOnly()
  }

  @objc private func requestQuit() {
    NSApp.terminate(nil)
  }

  @objc private func openSettings() {
    showSettings()
  }

  private func showSettings(page: SettingsPage? = nil) {
    palette?.yieldToAppWindow()
    presence.enterForeground { [weak self] in
      self?.requireSettingsWindow()?.show(page: page)
    }
  }

  private func beginApplicationTermination() {
    guard !didPrepareForTermination else { return }
    didPrepareForTermination = true
    notchMascot?.shutdown()
    palette?.hide()
    backgroundActivity.setNeeded(false)
  }
}
