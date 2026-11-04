import Carbon
import Foundation

struct AppSettings: Equatable, Sendable {
  var bolttyAIHotkey: HotkeyBinding
  var bolttyAIHotkeyIsChosen: Bool
  var bolttyAIHotkeyEnabled: Bool
  var agentPreset: AgentId?
  var enabledProviderIDs: Set<String>
  var defaultModelByProvider: [String: String]
  var mascotSelections: [String: MascotSelection]
  var defaultEffortByProvider: [String: String]
  /// Agents whose new chats start in Auto Mode. Each chat keeps its own copy.
  var autoApproveProviderIDs: Set<String>
  var dictationLocaleIdentifier: String
  /// A second language dictation listens for beside the first; empty is none.
  var dictationSecondLocaleIdentifier: String
  /// Who dictates: empty is Apple's recognizers, `parakeet` the local model
  /// where it hears the dictation language (Apple's elsewhere).
  var dictationEngine: String
  /// A multiple of the voice's own pace.
  var speechRate: Double
  /// Supertonic's preset (`F1`…`M5`); empty is `SpeechOutput.defaultLocalVoice`.
  var speechLocalVoice: String
  /// When a finished turn's reply is read aloud (`AnswerReading`); empty is never.
  var speechReadAnswers: String
  /// Ask Boltty: hold the chord, ask about the screen out loud, hear the answer.
  /// `nil` is automatic: Claude Code where it is ready (the fastest measured).
  var askBolttyProviderID: String?
  var askBolttyModelID: String?
  /// Ask Boltty looks and answers; it changes nothing unless the person allows it.
  var askBolttyReadOnly: Bool
  /// Ask Boltty says its answer aloud as well as typing it out.
  var askBolttySpeaksAloud: Bool
  var playsSounds: Bool
  /// Opening the panel over Finder attaches the files selected there.
  var attachesFinderSelection: Bool
  var checksForUpdates: Bool

  static let agentPresetKey = "boltty.agentPreset"
  private static let enabledProviderIDsKey = "boltty.enabledProviderIDs"
  private static let defaultModelByProviderKey = "boltty.defaultModelByProvider"
  private static let defaultEffortByProviderKey = "boltty.defaultEffortByProvider"
  private static let autoApproveProviderIDsKey = "boltty.autoApproveByProvider"
  private static let bolttyAIHotkeyKeyCodeKey = "boltty.askBolttyHotkey.keyCode"
  private static let bolttyAIHotkeyModifiersKey = "boltty.askBolttyHotkey.modifiers"
  private static let bolttyAIHotkeyEnabledKey = "boltty.askBolttyHotkey.enabled"
  private static let bolttyAIHotkeyChosenKey = "boltty.askBolttyHotkey.chosen"
  private static let legacyBolttyAIHotkeyKey = "boltty.askBolttyHotkey"
  private static let dictationLocaleKey = "boltty.dictationLocale"
  private static let dictationSecondLocaleKey = "boltty.dictationSecondLocale"
  private static let dictationEngineKey = "boltty.dictation.engine"
  /// What Settings › Voice stored for "Automatic" while Whisper could hear the
  /// language. Apple's engine cannot, and it was the system's language there.
  private static let retiredAutomaticLocale = "automatic"
  private static let speechRateKey = "boltty.speech.rate"
  private static let speechLocalVoiceKey = "boltty.speech.localVoice"
  private static let speechReadAnswersKey = "boltty.speech.readAnswers"
  private static let askBolttyProviderIDKey = "boltty.talk.agent"
  private static let askBolttyModelIDKey = "boltty.talk.model"
  private static let askBolttyReadOnlyKey = "boltty.talk.readOnly"
  private static let askBolttySpeaksAloudKey = "boltty.talk.speaksAloud"
  private static let playsSoundsKey = "boltty.sounds.enabled"
  private static let checksForUpdatesKey = "boltty.updates.automaticChecks"
  private static let attachesFinderSelectionKey = "boltty.finderSelection.enabled"

  static var allAdapterProviderIDs: Set<String> {
    Set(AgentId.adapterCases.map(\.rawValue))
  }

  init(
    agentPreset: AgentId? = .custom,
    enabledProviderIDs: Set<String> = AppSettings.allAdapterProviderIDs,
    defaultModelByProvider: [String: String] = [:],
    defaultEffortByProvider: [String: String] = [:],
    autoApproveProviderIDs: Set<String> = [],
    mascotSelections: [String: MascotSelection] = [:],
    bolttyAIHotkey: HotkeyBinding = .optionSpace,
    bolttyAIHotkeyIsChosen: Bool = false,
    bolttyAIHotkeyEnabled: Bool = true,
    dictationLocaleIdentifier: String = DictationLanguageCatalog.followSystemIdentifier,
    dictationSecondLocaleIdentifier: String = DictationLanguageCatalog.noSecondLanguageIdentifier,
    dictationEngine: String = "",
    speechRate: Double = 1,
    speechLocalVoice: String = "",
    speechReadAnswers: String = "",
    askBolttyProviderID: String? = nil,
    askBolttyModelID: String? = nil,
    askBolttyReadOnly: Bool = true,
    askBolttySpeaksAloud: Bool = false,
    playsSounds: Bool = true,
    attachesFinderSelection: Bool = true,
    checksForUpdates: Bool = true
  ) {
    self.bolttyAIHotkey = bolttyAIHotkey
    self.bolttyAIHotkeyIsChosen = bolttyAIHotkeyIsChosen
    self.bolttyAIHotkeyEnabled = bolttyAIHotkeyEnabled
    self.agentPreset = agentPreset
    self.enabledProviderIDs = enabledProviderIDs
    self.defaultModelByProvider = defaultModelByProvider
    self.defaultEffortByProvider = defaultEffortByProvider
    self.autoApproveProviderIDs = autoApproveProviderIDs
    self.mascotSelections = mascotSelections
    self.dictationLocaleIdentifier = dictationLocaleIdentifier
    self.dictationSecondLocaleIdentifier = dictationSecondLocaleIdentifier
    self.dictationEngine = dictationEngine
    self.speechRate = speechRate
    self.speechLocalVoice = speechLocalVoice
    self.speechReadAnswers = speechReadAnswers
    self.askBolttyProviderID = askBolttyProviderID
    self.askBolttyModelID = askBolttyModelID
    self.askBolttyReadOnly = askBolttyReadOnly
    self.askBolttySpeaksAloud = askBolttySpeaksAloud
    self.playsSounds = playsSounds
    self.attachesFinderSelection = attachesFinderSelection
    self.checksForUpdates = checksForUpdates
  }

  static func load(defaults: UserDefaults = .standard) -> AppSettings {
    let hotkey = loadHotkey(defaults: defaults)

    let hotkeyEnabled = defaults.object(forKey: Self.bolttyAIHotkeyEnabledKey)
      .map { _ in defaults.bool(forKey: Self.bolttyAIHotkeyEnabledKey) } ?? true

    let storedLocale = defaults.string(forKey: Self.dictationLocaleKey)
    let dictationLocaleIdentifier = storedLocale == nil || storedLocale == Self.retiredAutomaticLocale
      ? DictationLanguageCatalog.followSystemIdentifier : storedLocale!
    let dictationSecondLocaleIdentifier = defaults.string(forKey: Self.dictationSecondLocaleKey)
      ?? DictationLanguageCatalog.noSecondLanguageIdentifier
    let speechRate = defaults.object(forKey: Self.speechRateKey)
      .map { _ in defaults.double(forKey: Self.speechRateKey) } ?? 1
    let askBolttyReadOnly = defaults.object(forKey: Self.askBolttyReadOnlyKey)
      .map { _ in defaults.bool(forKey: Self.askBolttyReadOnlyKey) } ?? true
    let playsSounds = defaults.object(forKey: Self.playsSoundsKey)
      .map { _ in defaults.bool(forKey: Self.playsSoundsKey) } ?? true
    let checksForUpdates = defaults.object(forKey: Self.checksForUpdatesKey)
      .map { _ in defaults.bool(forKey: Self.checksForUpdatesKey) } ?? true
    let attachesFinderSelection = defaults.object(forKey: Self.attachesFinderSelectionKey)
      .map { _ in defaults.bool(forKey: Self.attachesFinderSelectionKey) } ?? true

    let preset = defaults.string(forKey: Self.agentPresetKey)
      .flatMap { AgentId(rawValue: $0) }

    let enabledProviderIDs: Set<String>
    if let stored = defaults.array(forKey: enabledProviderIDsKey) as? [String] {
      enabledProviderIDs = Set(stored)
    } else {
      enabledProviderIDs = Self.allAdapterProviderIDs
    }
    let defaultModelByProvider: [String: String]
    if let data = defaults.data(forKey: defaultModelByProviderKey),
       let decoded = try? JSONDecoder().decode([String: String].self, from: data)
    {
      defaultModelByProvider = decoded
    } else {
      defaultModelByProvider = [:]
    }
    let defaultEffortByProvider: [String: String]
    if let data = defaults.data(forKey: defaultEffortByProviderKey),
       let decoded = try? JSONDecoder().decode([String: String].self, from: data)
    {
      defaultEffortByProvider = decoded
    } else {
      defaultEffortByProvider = [:]
    }
    return AppSettings(
      agentPreset: preset,
      enabledProviderIDs: enabledProviderIDs,
      defaultModelByProvider: defaultModelByProvider,
      defaultEffortByProvider: defaultEffortByProvider,
      autoApproveProviderIDs: Set(defaults.stringArray(forKey: autoApproveProviderIDsKey) ?? []),
      mascotSelections: MascotRoster.load(defaults: defaults).selections,
      bolttyAIHotkey: hotkey,
      bolttyAIHotkeyIsChosen: defaults.bool(forKey: Self.bolttyAIHotkeyChosenKey),
      bolttyAIHotkeyEnabled: hotkeyEnabled,
      dictationLocaleIdentifier: dictationLocaleIdentifier,
      dictationSecondLocaleIdentifier: dictationSecondLocaleIdentifier,
      dictationEngine: defaults.string(forKey: Self.dictationEngineKey) ?? "",
      speechRate: speechRate,
      speechLocalVoice: defaults.string(forKey: Self.speechLocalVoiceKey) ?? "",
      speechReadAnswers: defaults.string(forKey: Self.speechReadAnswersKey) ?? "",
      askBolttyProviderID: defaults.string(forKey: Self.askBolttyProviderIDKey),
      askBolttyModelID: defaults.string(forKey: Self.askBolttyModelIDKey),
      askBolttyReadOnly: askBolttyReadOnly,
      askBolttySpeaksAloud: defaults.bool(forKey: Self.askBolttySpeaksAloudKey),
      playsSounds: playsSounds,
      attachesFinderSelection: attachesFinderSelection,
      checksForUpdates: checksForUpdates
    )
  }

  private static func loadHotkey(defaults: UserDefaults) -> HotkeyBinding {
    if defaults.object(forKey: bolttyAIHotkeyKeyCodeKey) != nil {
      return HotkeyBinding(
        keyCode: UInt32(bitPattern: Int32(defaults.integer(forKey: bolttyAIHotkeyKeyCodeKey))),
        carbonModifiers: UInt32(
          bitPattern: Int32(defaults.integer(forKey: bolttyAIHotkeyModifiersKey))
        )
      )
    }

    switch defaults.string(forKey: legacyBolttyAIHotkeyKey) {
    case "controlOptionSpace":
      return HotkeyBinding(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(controlKey) | UInt32(optionKey)
      )
    default:
      return .optionSpace
    }
  }

  /// Writes every key: removed keys stay on disk, untouched, for a downgrade.
  func save(defaults: UserDefaults = .standard) {
    defaults.set(agentPreset?.rawValue, forKey: Self.agentPresetKey)
    defaults.set(Array(enabledProviderIDs).sorted(), forKey: Self.enabledProviderIDsKey)
    if let data = try? JSONEncoder().encode(defaultModelByProvider) {
      defaults.set(data, forKey: Self.defaultModelByProviderKey)
    }
    if let data = try? JSONEncoder().encode(defaultEffortByProvider) {
      defaults.set(data, forKey: Self.defaultEffortByProviderKey)
    }
    defaults.set(Array(autoApproveProviderIDs).sorted(), forKey: Self.autoApproveProviderIDsKey)
    if let data = try? JSONEncoder().encode(mascotSelections) {
      defaults.set(data, forKey: MascotRoster.storageKey)
    }
    defaults.set(Int(bolttyAIHotkey.keyCode), forKey: Self.bolttyAIHotkeyKeyCodeKey)
    defaults.set(Int(bolttyAIHotkey.carbonModifiers), forKey: Self.bolttyAIHotkeyModifiersKey)
    defaults.set(bolttyAIHotkeyEnabled, forKey: Self.bolttyAIHotkeyEnabledKey)
    defaults.set(bolttyAIHotkeyIsChosen, forKey: Self.bolttyAIHotkeyChosenKey)
    defaults.set(dictationLocaleIdentifier, forKey: Self.dictationLocaleKey)
    defaults.set(dictationSecondLocaleIdentifier, forKey: Self.dictationSecondLocaleKey)
    defaults.set(dictationEngine, forKey: Self.dictationEngineKey)
    defaults.set(speechRate, forKey: Self.speechRateKey)
    defaults.set(speechLocalVoice, forKey: Self.speechLocalVoiceKey)
    defaults.set(speechReadAnswers, forKey: Self.speechReadAnswersKey)
    defaults.set(askBolttyProviderID, forKey: Self.askBolttyProviderIDKey)
    defaults.set(askBolttyModelID, forKey: Self.askBolttyModelIDKey)
    defaults.set(askBolttyReadOnly, forKey: Self.askBolttyReadOnlyKey)
    defaults.set(askBolttySpeaksAloud, forKey: Self.askBolttySpeaksAloudKey)
    defaults.set(playsSounds, forKey: Self.playsSoundsKey)
    defaults.set(attachesFinderSelection, forKey: Self.attachesFinderSelectionKey)
    defaults.set(checksForUpdates, forKey: Self.checksForUpdatesKey)
  }

  func isProviderEnabled(_ providerID: String) -> Bool {
    enabledProviderIDs.contains(providerID)
  }

  mutating func setProvider(_ providerID: String, enabled: Bool) {
    if enabled {
      enabledProviderIDs.insert(providerID)
    } else {
      enabledProviderIDs.remove(providerID)
      if agentPreset?.rawValue == providerID {
        agentPreset = AgentId.adapterCases.first { enabledProviderIDs.contains($0.rawValue) }
      }
    }
  }
}
