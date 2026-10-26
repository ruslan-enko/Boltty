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
  /// The voice chosen per language code (`en`, `uk`); a language not in it
  /// speaks in the best voice the Mac has for it.
  var speechVoiceByLanguage: [String: String]
  /// A multiple of the system's speaking rate.
  var speechRate: Double
  /// Ask Boltty: hold the chord, ask about the screen out loud, hear the answer.
  var askBolttyEnabled: Bool
  /// `nil` is automatic: Claude Code where it is ready (the fastest measured).
  var askBolttyProviderID: String?
  var askBolttyModelID: String?
  var askBolttyEffort: String?
  /// Ask Boltty looks and answers; it changes nothing unless the person allows it.
  var askBolttyReadOnly: Bool
  var playsSounds: Bool
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
  /// What Settings › Voice stored for "Automatic" while Whisper could hear the
  /// language. Apple's engine cannot, and it was the system's language there.
  private static let retiredAutomaticLocale = "automatic"
  private static let speechVoiceByLanguageKey = "boltty.speech.voiceByLanguage"
  private static let speechRateKey = "boltty.speech.rate"
  private static let askBolttyEnabledKey = "boltty.talk.enabled"
  private static let askBolttyProviderIDKey = "boltty.talk.agent"
  private static let askBolttyModelIDKey = "boltty.talk.model"
  private static let askBolttyEffortKey = "boltty.talk.effort"
  private static let askBolttyReadOnlyKey = "boltty.talk.readOnly"
  private static let playsSoundsKey = "boltty.sounds.enabled"
  private static let checksForUpdatesKey = "boltty.updates.automaticChecks"

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
    speechVoiceByLanguage: [String: String] = [:],
    speechRate: Double = 1,
    askBolttyEnabled: Bool = false,
    askBolttyProviderID: String? = nil,
    askBolttyModelID: String? = nil,
    askBolttyEffort: String? = nil,
    askBolttyReadOnly: Bool = true,
    playsSounds: Bool = true,
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
    self.speechVoiceByLanguage = speechVoiceByLanguage
    self.speechRate = speechRate
    self.askBolttyEnabled = askBolttyEnabled
    self.askBolttyProviderID = askBolttyProviderID
    self.askBolttyModelID = askBolttyModelID
    self.askBolttyEffort = askBolttyEffort
    self.askBolttyReadOnly = askBolttyReadOnly
    self.playsSounds = playsSounds
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
    let speechVoiceByLanguage = defaults.dictionary(forKey: Self.speechVoiceByLanguageKey)
      as? [String: String] ?? [:]
    let speechRate = defaults.object(forKey: Self.speechRateKey)
      .map { _ in defaults.double(forKey: Self.speechRateKey) } ?? 1
    let askBolttyReadOnly = defaults.object(forKey: Self.askBolttyReadOnlyKey)
      .map { _ in defaults.bool(forKey: Self.askBolttyReadOnlyKey) } ?? true
    let playsSounds = defaults.object(forKey: Self.playsSoundsKey)
      .map { _ in defaults.bool(forKey: Self.playsSoundsKey) } ?? true
    let checksForUpdates = defaults.object(forKey: Self.checksForUpdatesKey)
      .map { _ in defaults.bool(forKey: Self.checksForUpdatesKey) } ?? true

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
      speechVoiceByLanguage: speechVoiceByLanguage,
      speechRate: speechRate,
      askBolttyEnabled: defaults.bool(forKey: Self.askBolttyEnabledKey),
      askBolttyProviderID: defaults.string(forKey: Self.askBolttyProviderIDKey),
      askBolttyModelID: defaults.string(forKey: Self.askBolttyModelIDKey),
      askBolttyEffort: defaults.string(forKey: Self.askBolttyEffortKey),
      askBolttyReadOnly: askBolttyReadOnly,
      playsSounds: playsSounds,
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
    defaults.set(speechVoiceByLanguage, forKey: Self.speechVoiceByLanguageKey)
    defaults.set(speechRate, forKey: Self.speechRateKey)
    defaults.set(askBolttyEnabled, forKey: Self.askBolttyEnabledKey)
    defaults.set(askBolttyProviderID, forKey: Self.askBolttyProviderIDKey)
    defaults.set(askBolttyModelID, forKey: Self.askBolttyModelIDKey)
    defaults.set(askBolttyEffort, forKey: Self.askBolttyEffortKey)
    defaults.set(askBolttyReadOnly, forKey: Self.askBolttyReadOnlyKey)
    defaults.set(playsSounds, forKey: Self.playsSoundsKey)
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
