import AppKit
import Combine

@MainActor
final class BolttyAISettingsModel: ObservableObject {
  let appModel: AppModel
  let engine: ConversationEngine
  let updater: AppUpdater?
  let loginItem: LoginItem

  @Published private(set) var dictationLanguages: [DictationLanguage] = []
  @Published var dictationDownload: DictationDownloadState = .idle
  @Published var hotkeyProblem: HotkeyProblem?
  @Published private(set) var modelsByProvider: [String: [AgentModelOption]] = [:]
  @Published private(set) var isLoadingModels = false
  @Published private(set) var isRefreshingUsage = false
  @Published private(set) var statistics: AgentStatistics?
  var statisticsReader = AgentStatisticsReader()

  var probeHotkey: ((HotkeyBinding) -> HotkeyAvailability)?
  var onReviewAccess: (() -> Void)?
  /// Says the samples on the Voice page; `nil` where nothing can speak.
  let speech: SpeechOutput?

  private var cancellables = Set<AnyCancellable>()

  enum DictationDownloadState: Equatable {
    case idle
    case downloading(language: String, fraction: Double)
    case failed(String)
  }

  init(
    appModel: AppModel,
    engine: ConversationEngine,
    updater: AppUpdater? = nil,
    loginItem: LoginItem = LoginItem(),
    speech: SpeechOutput? = nil
  ) {
    self.speech = speech
    self.appModel = appModel
    self.engine = engine
    self.updater = updater
    self.loginItem = loginItem
    updater?.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    loginItem.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    speech?.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    appModel.$settings
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    appModel.$hotkeyRegistrationFailed
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    appModel.$hotkeyStandIn
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    appModel.$hotkeyStandInFailed
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    engine.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    engine.$modelsByProvider
      .receive(on: RunLoop.main)
      .sink { [weak self] models in self?.modelsByProvider = models }
      .store(in: &cancellables)
  }

  // MARK: - Usage

  struct UsageRow: Identifiable, Equatable {
    let agent: AgentId
    let usage: AgentUsage?
    let history: AgentActivityHistory?
    /// The CLI says it is signed out; its limits come back after a sign-in
    /// and a refresh.
    var isSignedOut = false
    var id: AgentId { agent }
  }

  var usageRows: [UsageRow] {
    AgentHistory.tabOrder.compactMap { agent in
      let usage = engine.usageByProvider[agent.rawValue]
      let history = engine.historyByProvider[agent.rawValue]
      let isSignedOut = appModel.settings.isProviderEnabled(agent.rawValue)
        && engine.registry.installation(for: agent)?.availability.isSignedOut == true
      guard usage != nil || history != nil || isSignedOut else { return nil }
      return UsageRow(agent: agent, usage: usage, history: history, isSignedOut: isSignedOut)
    }
  }

  func usageTint(for agent: AgentId) -> NSColor {
    mascotLook(for: agent).palette.colors.first ?? .controlAccentColor
  }

  // MARK: - Mascots

  var mascotRoster: MascotRoster {
    MascotRoster(selections: appModel.settings.mascotSelections, preferred: appModel.settings.agentPreset)
  }

  func mascotLook(for agent: AgentId) -> MascotLook {
    mascotRoster.look(for: agent)
  }

  func mascotOwner(of look: MascotLook, besides agent: AgentId) -> AgentId? {
    mascotRoster.owner(of: look, besides: agent)
  }

  func name(of owner: AgentId) -> String {
    owner.shortDisplayName
  }

  func chooseMascot(_ look: MascotLook, for agent: AgentId) {
    appModel.updateSettings { settings in
      var roster = MascotRoster(selections: settings.mascotSelections)
      guard roster.choose(look, for: agent) else { return }
      settings.mascotSelections = roster.selections
    }
  }

  /// Asks every CLI again whether it is signed in, then reads limits,
  /// activity and the statistics. Signing in happens in a terminal, so
  /// nothing here may trust an earlier answer.
  func refreshUsage() async {
    guard !isRefreshingUsage else { return }
    isRefreshingUsage = true
    defer {
      isRefreshingUsage = false
      usageReadAt = Date()
    }
    async let statistics: Void = refreshStatistics()
    await refreshAgents()
    await engine.refreshActivityHistory()
    await statistics
  }

  /// The page re-reads on its own when it is shown or its window comes
  /// forward, but not on every switch between windows.
  func refreshUsageIfStale() async {
    if let usageReadAt, Date().timeIntervalSince(usageReadAt) < Self.usageStaleAfter { return }
    await refreshUsage()
  }

  private var usageReadAt: Date?
  private var agentsRefresh: Task<Void, Never>?
  static let usageStaleAfter: TimeInterval = 30

  func refreshStatistics() async {
    let reader = statisticsReader
    let read = await Task.detached(priority: .utility) { reader.read() }.value
    if read != statistics { statistics = read }
  }

  var bolttyAIHotkey: HotkeyBinding {
    get { appModel.settings.bolttyAIHotkey }
    set {
      hotkeyProblem = nil
      appModel.updateSettings {
        $0.bolttyAIHotkey = newValue
        $0.bolttyAIHotkeyIsChosen = true
      }
    }
  }

  var bolttyAIHotkeyEnabled: Bool {
    get { appModel.settings.bolttyAIHotkeyEnabled }
    set { appModel.updateSettings { $0.bolttyAIHotkeyEnabled = newValue } }
  }

  var playsSounds: Bool {
    get { appModel.settings.playsSounds }
    set { appModel.updateSettings { $0.playsSounds = newValue } }
  }

  var checksForUpdates: Bool {
    get { appModel.settings.checksForUpdates }
    set { appModel.updateSettings { $0.checksForUpdates = newValue } }
  }

  var hotkeyRegistrationFailed: Bool { appModel.hotkeyRegistrationFailed }
  var hotkeyStandIn: HotkeyBinding? { appModel.hotkeyStandIn }
  var hotkeyStandInFailed: Bool { appModel.hotkeyStandInFailed }

  var defaultAgent: AgentId {
    get {
      if let preset = appModel.settings.agentPreset,
         preset != .custom,
         AgentId.adapterCases.contains(preset),
         appModel.settings.isProviderEnabled(preset.rawValue)
      {
        return preset
      }
      return AgentId.adapterCases.first {
        appModel.settings.isProviderEnabled($0.rawValue)
      } ?? .opencode
    }
    set { appModel.updateSettings { $0.agentPreset = newValue } }
  }

  var enabledAdapters: [AgentId] {
    AgentHistory.tabOrder.filter { appModel.settings.isProviderEnabled($0.rawValue) }
  }

  var adapterRows: [AgentSettingsRow] {
    AgentHistory.tabOrder.map { agent in
      let installation = engine.registry.installation(for: agent)
      let models = modelsByProvider[agent.rawValue] ?? []
      let selectedModelID = appModel.settings.defaultModelByProvider[agent.rawValue]
      let selectedModel = models.first { $0.selection.modelID == selectedModelID }
        ?? models.first { $0.isDefault }
        ?? models.first
      return AgentSettingsRow(
        agent: agent,
        enabled: appModel.settings.isProviderEnabled(agent.rawValue),
        status: installation?.statusText ?? "Not installed",
        isReady: installation?.isReady == true,
        offersModels: installation?.capabilities.contains(.modelSelection) == true,
        models: models,
        selectedModelID: selectedModelID,
        effortOptions: selectedModel?.effortOptions ?? [],
        selectedEffort: appModel.settings.defaultEffortByProvider[agent.rawValue],
        offersAutoApproval: installation?.capabilities.contains(.autoApproval) == true,
        autoApprove: appModel.settings.autoApproveProviderIDs.contains(agent.rawValue)
      )
    }
  }

  func setEnabled(_ enabled: Bool, for agent: AgentId) {
    appModel.updateSettings { $0.setProvider(agent.rawValue, enabled: enabled) }
  }

  func setDefaultModel(_ modelID: String?, for agent: AgentId) {
    appModel.updateSettings { settings in
      if let modelID, !modelID.isEmpty {
        settings.defaultModelByProvider[agent.rawValue] = modelID
      } else {
        settings.defaultModelByProvider.removeValue(forKey: agent.rawValue)
      }
      let models = modelsByProvider[agent.rawValue] ?? []
      let match = models.first { $0.selection.modelID == modelID }
        ?? models.first { $0.isDefault }
        ?? models.first
      let allowed = Set((match?.effortOptions ?? []).map(\.value))
      if let current = settings.defaultEffortByProvider[agent.rawValue],
         !allowed.contains(current)
      {
        settings.defaultEffortByProvider.removeValue(forKey: agent.rawValue)
      }
    }
  }

  func setAutoApprove(_ enabled: Bool, for agent: AgentId) {
    appModel.updateSettings { settings in
      if enabled {
        settings.autoApproveProviderIDs.insert(agent.rawValue)
      } else {
        settings.autoApproveProviderIDs.remove(agent.rawValue)
      }
    }
  }

  func setDefaultEffort(_ effort: String?, for agent: AgentId) {
    appModel.updateSettings { settings in
      if let effort, !effort.isEmpty {
        settings.defaultEffortByProvider[agent.rawValue] = effort
      } else {
        settings.defaultEffortByProvider.removeValue(forKey: agent.rawValue)
      }
    }
  }

  // MARK: - Menu shortcuts

  var shortcutSections: [KeyboardShortcutSection] {
    KeyboardShortcutCatalog.sections
  }

  /// Every key that is not a menu command, with the launch chord as it is set
  /// now.
  var builtInKeySections: [BuiltInKeySection] {
    let settings = appModel.settings
    return BuiltInKeyCatalog.sections(
      launchChord: settings.bolttyAIHotkeyEnabled ? settings.bolttyAIHotkey.displayName : nil,
      askBolttyChord: AskBolttyController.chordName,
      askBolttyIsOn: settings.askBolttyEnabled
    )
  }

  func shortcutBinding(for id: String) -> ShortcutBinding {
    appModel.shortcutBindings.binding(for: id)
  }

  func isShortcutCustomized(_ id: String) -> Bool {
    appModel.shortcutBindings.isCustomized(id)
  }

  func shortcutConflictCaption(for id: String) -> String? {
    let others = appModel.shortcutBindings.conflicts()
      .filter { $0.key == appModel.shortcutBindings.binding(for: id) }
      .flatMap(\.value)
      .filter { $0 != id }
      .compactMap { KeyboardShortcutCatalog.entry(for: $0)?.title }
      .sorted()
    guard !others.isEmpty else { return nil }
    return others.count == 1
      ? "Also \(others[0])"
      : "Also \(others.joined(separator: ", "))"
  }

  func setShortcutBinding(_ binding: ShortcutBinding?, for id: String) {
    appModel.shortcutBindings.setBinding(binding, for: id)
  }

  func restoreDefaultShortcut(_ id: String) {
    appModel.shortcutBindings.setBinding(nil, for: id)
  }

  func restoreAllDefaultShortcuts() {
    appModel.shortcutBindings.resetAll()
  }

  var hasCustomizedShortcuts: Bool {
    !appModel.shortcutBindings.overrides.isEmpty
  }

  var conversationCount: Int { engine.store.conversations.count }

  @discardableResult
  func clearHistory() -> Int {
    engine.store.deleteAllConversations()
  }

  var conversationsDirectory: URL { ConversationPersistence.defaultRoot() }

  var versionDescription: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "—"
    let build = info?["CFBundleVersion"] as? String
    return build.map { "\(short) (\($0))" } ?? short
  }

  func refreshAgents() async {
    // Published before it suspends, so the Usage page joins this probe
    // instead of starting a second one.
    if let agentsRefresh { return await agentsRefresh.value }
    let refresh = Task { @MainActor [engine] in
      isLoadingModels = true
      await engine.refreshAvailability()
      modelsByProvider = engine.modelsByProvider
      isLoadingModels = false
    }
    agentsRefresh = refresh
    await refresh.value
    agentsRefresh = nil
  }

  var dictationLocaleIdentifier: String {
    get { appModel.settings.dictationLocaleIdentifier }
    set { appModel.updateSettings { $0.dictationLocaleIdentifier = newValue } }
  }

  var dictationSecondLocaleIdentifier: String {
    get { appModel.settings.dictationSecondLocaleIdentifier }
    set { appModel.updateSettings { $0.dictationSecondLocaleIdentifier = newValue } }
  }

  /// What "Follow System" resolves to among the languages this Mac offers.
  private var primaryDictationLanguage: DictationLanguage? {
    DictationLanguageCatalog.resolve(
      identifier: dictationLocaleIdentifier,
      systemIdentifier: Locale.current.identifier,
      in: dictationLanguages
    )
  }

  /// The second picker offers every language but the first's own: two
  /// recognizers of one language, in two regions, would only agree.
  var secondDictationLanguages: [DictationLanguage] {
    let taken = primaryDictationLanguage?.languageCode
    return dictationLanguages.filter { $0.languageCode != taken }
  }

  func loadDictationLanguages() async {
    dictationLanguages = await DictationCatalog.languages()
  }

  func selectDictationLanguage(_ identifier: String) async {
    dictationLocaleIdentifier = identifier
    if let second = dictationLanguages.first(where: { $0.identifier == dictationSecondLocaleIdentifier }),
       second.languageCode == primaryDictationLanguage?.languageCode
    {
      dictationSecondLocaleIdentifier = DictationLanguageCatalog.noSecondLanguageIdentifier
    }
    await installDictationLanguage(identifier)
  }

  func selectSecondDictationLanguage(_ identifier: String) async {
    dictationSecondLocaleIdentifier = identifier
    await installDictationLanguage(identifier)
  }

  /// Downloads a language's model when this Mac has not got it yet.
  private func installDictationLanguage(_ identifier: String) async {
    dictationDownload = .idle
    guard
      identifier != DictationLanguageCatalog.followSystemIdentifier,
      let language = dictationLanguages.first(where: { $0.identifier == identifier }),
      !language.isInstalled
    else { return }

    dictationDownload = .downloading(language: language.displayName, fraction: 0)
    var observation: NSKeyValueObservation?
    do {
      try await DictationCatalog.install(language) { [weak self] progress in
        observation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
          let fraction = progress.fractionCompleted
          Task { @MainActor [weak self] in
            self?.dictationDownload = .downloading(
              language: language.displayName,
              fraction: fraction
            )
          }
        }
      }
      observation?.invalidate()
      dictationDownload = .idle
      await loadDictationLanguages()
    } catch {
      observation?.invalidate()
      dictationDownload = .failed(
        DictationEngineError.modelDownloadFailed(language.displayName).localizedDescription
      )
    }
  }
}

struct AgentSettingsRow: Identifiable, Equatable {
  var id: AgentId { agent }
  let agent: AgentId
  let enabled: Bool
  let status: String
  let isReady: Bool
  let offersModels: Bool
  let models: [AgentModelOption]
  let selectedModelID: String?
  let effortOptions: [AgentEffortOption]
  let selectedEffort: String?
  var offersAutoApproval = false
  var autoApprove = false
}
