import Carbon
import XCTest

@testable import Boltty

final class AppSettingsTests: XCTestCase {
  private func defaults(_ name: String = #function) -> UserDefaults {
    isolatedDefaults(named: "boltty.tests.settings.\(name)")
  }

  // MARK: - Defaults

  func testAFreshDomainLoadsTheShippedDefaults() {
    let loaded = AppSettings.load(defaults: defaults())

    XCTAssertEqual(loaded.bolttyAIHotkey, .optionSpace)
    XCTAssertFalse(loaded.bolttyAIHotkeyIsChosen, "the default is nobody's choice")
    XCTAssertTrue(loaded.bolttyAIHotkeyEnabled)
    XCTAssertEqual(loaded.enabledProviderIDs, AppSettings.allAdapterProviderIDs)
    XCTAssertEqual(loaded.defaultModelByProvider, [:])
    XCTAssertEqual(loaded.defaultEffortByProvider, [:])
    XCTAssertEqual(loaded.dictationLocaleIdentifier, DictationLanguageCatalog.followSystemIdentifier)
    XCTAssertEqual(
      loaded.dictationSecondLocaleIdentifier,
      DictationLanguageCatalog.noSecondLanguageIdentifier,
      "dictation listens for one language until a second is chosen"
    )
    XCTAssertNil(loaded.agentPreset)
    XCTAssertTrue(loaded.playsSounds, "sounds are on until somebody turns them off")
    XCTAssertTrue(loaded.checksForUpdates, "the daily check is on until somebody turns it off")
  }

  // MARK: - "Absent" is not "false"

  func testAnUnsetHotkeyEnabledIsOnAndAnExplicitOffIsOff() {
    let suite = defaults()
    XCTAssertTrue(AppSettings.load(defaults: suite).bolttyAIHotkeyEnabled)

    suite.set(false, forKey: "boltty.askBolttyHotkey.enabled")
    XCTAssertFalse(AppSettings.load(defaults: suite).bolttyAIHotkeyEnabled)

    suite.set(true, forKey: "boltty.askBolttyHotkey.enabled")
    XCTAssertTrue(AppSettings.load(defaults: suite).bolttyAIHotkeyEnabled)
  }

  func testUnsetSoundsAreOnAndAnExplicitOffIsOff() {
    let suite = defaults()
    XCTAssertTrue(AppSettings.load(defaults: suite).playsSounds)

    suite.set(false, forKey: "boltty.sounds.enabled")
    XCTAssertFalse(AppSettings.load(defaults: suite).playsSounds)
  }

  func testSpeechStartsAtTheSystemPaceWithNoVoiceChosenAndKeepsAChoice() {
    let suite = defaults()
    let fresh = AppSettings.load(defaults: suite)
    XCTAssertEqual(fresh.speechRate, 1)
    XCTAssertEqual(fresh.speechVoiceByLanguage, [:])

    var settings = fresh
    settings.speechRate = 1.25
    settings.speechVoiceByLanguage = ["uk": "com.apple.voice.compact.uk-UA.Lesya"]
    settings.save(defaults: suite)
    let loaded = AppSettings.load(defaults: suite)
    XCTAssertEqual(loaded.speechRate, 1.25)
    XCTAssertEqual(loaded.speechVoiceByLanguage, ["uk": "com.apple.voice.compact.uk-UA.Lesya"])
  }

  func testAskBolttyIsOffReadOnlyAndAutomaticUntilChosen() {
    let suite = defaults()
    let fresh = AppSettings.load(defaults: suite)
    XCTAssertFalse(fresh.askBolttyEnabled)
    XCTAssertTrue(fresh.askBolttyReadOnly)
    XCTAssertNil(fresh.askBolttyProviderID)

    var settings = fresh
    settings.askBolttyEnabled = true
    settings.askBolttyReadOnly = false
    settings.askBolttyProviderID = "codex"
    settings.askBolttyModelID = "gpt-6-luna"
    settings.askBolttyEffort = "low"
    settings.save(defaults: suite)
    let loaded = AppSettings.load(defaults: suite)
    XCTAssertTrue(loaded.askBolttyEnabled)
    XCTAssertFalse(loaded.askBolttyReadOnly)
    XCTAssertEqual(loaded.askBolttyProviderID, "codex")
    XCTAssertEqual(loaded.askBolttyModelID, "gpt-6-luna")
    XCTAssertEqual(loaded.askBolttyEffort, "low")
  }

  func testAnUnsetUpdateCheckIsOnAndAnExplicitOffIsOff() {
    let suite = defaults()
    XCTAssertTrue(AppSettings.load(defaults: suite).checksForUpdates)

    suite.set(false, forKey: "boltty.updates.automaticChecks")
    XCTAssertFalse(AppSettings.load(defaults: suite).checksForUpdates)
  }

  func testAutoModeIsAskByDefaultAndRemembersEachAgent() {
    let suite = defaults()
    XCTAssertEqual(AppSettings.load(defaults: suite).autoApproveProviderIDs, [], "every agent asks")

    var settings = AppSettings.load(defaults: suite)
    settings.autoApproveProviderIDs = ["claude", "agy"]
    settings.save(defaults: suite)
    XCTAssertEqual(AppSettings.load(defaults: suite).autoApproveProviderIDs, ["claude", "agy"])
  }

  // MARK: - The pre-recorder hotkey

  func testTheLegacyHotkeyStringStillResolves() {
    let suite = defaults()
    suite.set("controlOptionSpace", forKey: "boltty.askBolttyHotkey")

    let loaded = AppSettings.load(defaults: suite)
    XCTAssertEqual(loaded.bolttyAIHotkey.keyCode, UInt32(kVK_Space))
    XCTAssertEqual(
      loaded.bolttyAIHotkey.carbonModifiers,
      UInt32(controlKey) | UInt32(optionKey)
    )
  }

  func testEveryOtherLegacyValueFallsBackToTheDefault() {
    for value in ["optionSpace", "somethingElse", "", "controlSpace"] {
      let suite = defaults()
      suite.set(value, forKey: "boltty.askBolttyHotkey")
      XCTAssertEqual(
        AppSettings.load(defaults: suite).bolttyAIHotkey, .optionSpace,
        "legacy value \(value.debugDescription)"
      )
    }
  }

  func testTheRecordedPairOutranksTheLegacyString() {
    let suite = defaults()
    suite.set("controlOptionSpace", forKey: "boltty.askBolttyHotkey")
    suite.set(Int(kVK_ANSI_J), forKey: "boltty.askBolttyHotkey.keyCode")
    suite.set(Int(optionKey), forKey: "boltty.askBolttyHotkey.modifiers")

    XCTAssertEqual(AppSettings.load(defaults: suite).bolttyAIHotkey.displayName, "⌥J")
  }

  func testSavingLeavesTheLegacyKeyAlone() {
    let suite = defaults()
    suite.set("controlOptionSpace", forKey: "boltty.askBolttyHotkey")

    AppSettings(bolttyAIHotkey: .optionSpace).save(defaults: suite)

    XCTAssertEqual(suite.string(forKey: "boltty.askBolttyHotkey"), "controlOptionSpace")
  }

  // MARK: - Removed values stay on disk

  func testRemovedKeysAreNeitherReadNorRewrittenNorDeleted() {
    let suite = defaults()
    let shortcuts = Data(#"[{"title":"Mine","prompt":"Do mine."}]"#.utf8)
    suite.set("dark", forKey: "boltty.appearanceTheme")
    suite.set("echo <prompt>", forKey: "boltty.customCommandTemplate")
    suite.set(shortcuts, forKey: "boltty.promptShortcuts")

    let loaded = AppSettings.load(defaults: suite)
    loaded.save(defaults: suite)

    XCTAssertEqual(suite.string(forKey: "boltty.appearanceTheme"), "dark")
    XCTAssertEqual(suite.string(forKey: "boltty.customCommandTemplate"), "echo <prompt>")
    XCTAssertEqual(suite.data(forKey: "boltty.promptShortcuts"), shortcuts)
  }

  func testTheEngineAndWhisperKeysStayOnDiskAndAreNotRead() {
    let suite = defaults()
    suite.set("whisper", forKey: "boltty.dictationEngine")
    suite.set("small", forKey: "boltty.dictationWhisperModel")

    AppSettings.load(defaults: suite).save(defaults: suite)

    XCTAssertEqual(suite.string(forKey: "boltty.dictationEngine"), "whisper")
    XCTAssertEqual(suite.string(forKey: "boltty.dictationWhisperModel"), "small")
  }

  func testAutomaticDictationLanguageBecomesFollowSystem() {
    let suite = defaults()
    suite.set("automatic", forKey: "boltty.dictationLocale")

    XCTAssertEqual(
      AppSettings.load(defaults: suite).dictationLocaleIdentifier,
      DictationLanguageCatalog.followSystemIdentifier,
      "Automatic was Whisper's; Apple's engine cannot hear which language is spoken"
    )
  }

  func testSavingNeverWritesTheRemovedPromptShortcuts() {
    let suite = defaults()

    AppSettings.load(defaults: suite).save(defaults: suite)

    XCTAssertNil(suite.object(forKey: "boltty.promptShortcuts"))
  }

  // MARK: - Round trip

  func testEveryFieldSurvivesASaveAndLoad() {
    let suite = defaults()
    let settings = AppSettings(
      agentPreset: .codex,
      enabledProviderIDs: ["codex", "grok"],
      defaultModelByProvider: ["codex": "gpt-5"],
      defaultEffortByProvider: ["codex": "high"],
      mascotSelections: [
        "codex": MascotSelection(
          MascotLook(shape: .bloom, palette: MascotPalette.palette(withID: "slate")!)
        )
      ],
      bolttyAIHotkey: HotkeyBinding(
        keyCode: UInt32(kVK_ANSI_K),
        carbonModifiers: UInt32(controlKey) | UInt32(optionKey)
      ),
      bolttyAIHotkeyIsChosen: true,
      bolttyAIHotkeyEnabled: false,
      dictationLocaleIdentifier: "uk-UA",
      dictationSecondLocaleIdentifier: "en-US",
      playsSounds: false,
      checksForUpdates: false
    )

    settings.save(defaults: suite)
    let loaded = AppSettings.load(defaults: suite)

    XCTAssertEqual(loaded.agentPreset, .codex)
    XCTAssertEqual(loaded.enabledProviderIDs, ["codex", "grok"])
    XCTAssertEqual(loaded.defaultModelByProvider, ["codex": "gpt-5"])
    XCTAssertEqual(loaded.defaultEffortByProvider, ["codex": "high"])
    XCTAssertEqual(loaded.bolttyAIHotkey, settings.bolttyAIHotkey)
    XCTAssertTrue(loaded.bolttyAIHotkeyIsChosen)
    XCTAssertFalse(loaded.bolttyAIHotkeyEnabled)
    XCTAssertEqual(loaded.dictationLocaleIdentifier, "uk-UA")
    XCTAssertEqual(loaded.dictationSecondLocaleIdentifier, "en-US")
    XCTAssertFalse(loaded.playsSounds)
    XCTAssertFalse(loaded.checksForUpdates)
  }

  func testSavingSomethingElseDoesNotMakeTheDefaultChordChosen() {
    let suite = defaults()
    var settings = AppSettings.load(defaults: suite)
    settings.agentPreset = .codex
    settings.save(defaults: suite)

    let loaded = AppSettings.load(defaults: suite)
    XCTAssertEqual(loaded.bolttyAIHotkey, .optionSpace)
    XCTAssertFalse(loaded.bolttyAIHotkeyIsChosen)
  }

  func testCorruptDictionariesFallBackRatherThanFail() {
    let suite = defaults()
    suite.set(Data("{not json".utf8), forKey: "boltty.defaultModelByProvider")
    suite.set(Data("nonsense".utf8), forKey: "boltty.defaultEffortByProvider")

    let loaded = AppSettings.load(defaults: suite)
    XCTAssertEqual(loaded.defaultModelByProvider, [:])
    XCTAssertEqual(loaded.defaultEffortByProvider, [:])
  }

  func testAnUnknownAgentIdIsNotAdoptedAsThePreset() {
    let suite = defaults()
    suite.set("some-agent-from-the-future", forKey: "boltty.agentPreset")
    XCTAssertNil(AppSettings.load(defaults: suite).agentPreset)
  }

  // MARK: - The preset

  func testDisablingThePresetAgentMovesThePresetToAnotherEnabledOne() {
    var settings = AppSettings(agentPreset: .codex, enabledProviderIDs: ["codex", "grok"])
    settings.setProvider("codex", enabled: false)
    XCTAssertEqual(settings.agentPreset, .grok)
  }
}
