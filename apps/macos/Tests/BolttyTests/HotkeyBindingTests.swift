import AppKit
import Carbon
import XCTest

@testable import Boltty

final class HotkeyBindingTests: XCTestCase {
  func testDefaultIsOptionSpace() {
    XCTAssertEqual(HotkeyBinding.optionSpace.displayName, "⌥Space")
  }

  func testModifierSymbolsUseCanonicalOrder() {
    let all = UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey) | UInt32(controlKey)
    XCTAssertEqual(HotkeyBinding.modifierSymbols(all), "⌃⌥⇧⌘")
  }

  func testNoModifiersRenderAsBareKey() {
    XCTAssertEqual(HotkeyBinding.modifierSymbols(0), "")
  }

  func testNamedKeysUseTheirFunctionNotTheirCharacter() {
    XCTAssertEqual(HotkeyBinding.keyLabel(for: UInt32(kVK_Space)), "Space")
    XCTAssertEqual(HotkeyBinding.keyLabel(for: UInt32(kVK_Return)), "Return")
    XCTAssertEqual(HotkeyBinding.keyLabel(for: UInt32(kVK_Escape)), "Esc")
    XCTAssertEqual(HotkeyBinding.keyLabel(for: UInt32(kVK_Tab)), "Tab")
    XCTAssertEqual(HotkeyBinding.keyLabel(for: UInt32(kVK_LeftArrow)), "←")
    XCTAssertEqual(HotkeyBinding.keyLabel(for: UInt32(kVK_F5)), "F5")
  }

  func testCharacterKeysProduceAShortUppercaseLabel() {
    let label = HotkeyBinding.keyLabel(for: UInt32(kVK_ANSI_A))
    XCTAssertFalse(label.isEmpty)
    XCTAssertFalse(label.hasPrefix("Key "), "layout translation failed for kVK_ANSI_A")
    XCTAssertEqual(label, label.uppercased())
  }

  func testUnknownKeyFallsBackToItsCode() {
    XCTAssertEqual(HotkeyBinding.keyLabel(for: 9999), "Key 9999")
  }

  func testDisplayNameJoinsModifiersAndKey() {
    let binding = HotkeyBinding(
      keyCode: UInt32(kVK_Space),
      carbonModifiers: UInt32(controlKey) | UInt32(optionKey)
    )
    XCTAssertEqual(binding.displayName, "⌃⌥Space")
  }

  // MARK: - Latin key equivalents

  private func keyEvent(
    characters: String,
    keyCode: Int,
    modifiers: NSEvent.ModifierFlags = .command
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: UInt16(keyCode)
    )!
  }

  func testANonLatinKeyResolvesThroughTheAsciiLayout() throws {
    let event = keyEvent(characters: "в", keyCode: kVK_ANSI_V)
    let resolved = try XCTUnwrap(event.latinCharactersIgnoringModifiers)

    XCTAssertTrue(resolved.allSatisfy(\.isASCII), "got \(resolved), which is not Latin")
    XCTAssertEqual(resolved, KeyboardLayoutCharacter.ascii(for: UInt32(kVK_ANSI_V)))
  }

  func testATypedLatinCharacterIsUsedAsIs() {
    XCTAssertEqual(
      keyEvent(characters: "v", keyCode: kVK_ANSI_V).latinCharactersIgnoringModifiers,
      "v"
    )
    XCTAssertEqual(
      keyEvent(characters: ";", keyCode: kVK_ANSI_S).latinCharactersIgnoringModifiers,
      ";"
    )
  }

  func testTheResolvedCharacterIsLowercased() {
    let event = keyEvent(characters: "V", keyCode: kVK_ANSI_V, modifiers: [.command, .shift])
    XCTAssertEqual(event.latinCharactersIgnoringModifiers, "v")
  }

  // MARK: - Validation

  func testChordWithOptionOrControlIsAccepted() {
    for modifier in [optionKey, controlKey] {
      let binding = HotkeyBinding(
        keyCode: UInt32(kVK_ANSI_K),
        carbonModifiers: UInt32(modifier)
      )
      XCTAssertNil(HotkeyValidation.reject(binding), "rejected \(binding.displayName)")
    }
  }

  func testBareLetterIsRejected() {
    let binding = HotkeyBinding(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: 0)
    XCTAssertEqual(HotkeyValidation.reject(binding), .noModifier)
  }

  func testShiftAloneIsNotEnough() {
    let binding = HotkeyBinding(
      keyCode: UInt32(kVK_ANSI_K),
      carbonModifiers: UInt32(shiftKey)
    )
    XCTAssertEqual(HotkeyValidation.reject(binding), .noModifier)
  }

  func testFunctionKeysAndEscapeMayBeTakenBare() {
    for keyCode in [kVK_Escape, kVK_F1, kVK_F5, kVK_F20] {
      let binding = HotkeyBinding(keyCode: UInt32(keyCode), carbonModifiers: 0)
      XCTAssertNil(
        HotkeyValidation.reject(binding),
        "rejected bare \(binding.displayName)"
      )
    }
  }

  func testBareTypingKeyIsStillRefused() {
    for keyCode in [kVK_ANSI_A, kVK_ANSI_Z, kVK_Return, kVK_Space] {
      let binding = HotkeyBinding(keyCode: UInt32(keyCode), carbonModifiers: 0)
      XCTAssertEqual(HotkeyValidation.reject(binding), .noModifier)
    }
  }

  func testBareCommandIsRefusedAsSystemOwned() {
    for keyCode in [kVK_ANSI_K, kVK_ANSI_M, kVK_ANSI_Q, kVK_ANSI_W] {
      let binding = HotkeyBinding(keyCode: UInt32(keyCode), carbonModifiers: UInt32(cmdKey))
      XCTAssertEqual(
        HotkeyValidation.reject(binding), .reservedBySystem,
        "accepted \(binding.displayName)"
      )
    }
  }

  func testBareCommandOnEscapeOrAFunctionKeyIsAllowed() {
    for keyCode in [kVK_Escape, kVK_F5, kVK_F17] {
      let binding = HotkeyBinding(
        keyCode: UInt32(keyCode),
        carbonModifiers: UInt32(cmdKey)
      )
      XCTAssertNil(HotkeyValidation.reject(binding), "rejected \(binding.displayName)")
    }
  }

  func testCommandWithASecondModifierIsAccepted() {
    for modifiers in [
      UInt32(cmdKey) | UInt32(shiftKey),
      UInt32(cmdKey) | UInt32(optionKey),
      UInt32(cmdKey) | UInt32(controlKey)
    ] {
      let binding = HotkeyBinding(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: modifiers)
      XCTAssertNil(HotkeyValidation.reject(binding), "rejected \(binding.displayName)")
    }
  }

  func testChordsMacOSItselfHoldsAreRefusedAsReserved() {
    let onSpace: [Int] = [
      cmdKey,
      controlKey,
      controlKey | shiftKey,
      cmdKey | optionKey,
      cmdKey | controlKey | shiftKey,
    ]
    let onEscape: [Int] = [
      cmdKey | optionKey,
      cmdKey | controlKey,
    ]
    for modifiers in onSpace {
      let binding = HotkeyBinding(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(modifiers))
      XCTAssertEqual(
        HotkeyValidation.reject(binding), .reservedBySystem,
        "accepted \(binding.displayName)"
      )
    }
    for modifiers in onEscape {
      let binding = HotkeyBinding(keyCode: UInt32(kVK_Escape), carbonModifiers: UInt32(modifiers))
      XCTAssertEqual(
        HotkeyValidation.reject(binding), .reservedBySystem,
        "accepted \(binding.displayName)"
      )
    }
  }

  func testTheDefaultIsNotOnItsOwnReservedList() {
    XCTAssertNil(HotkeyValidation.reject(.optionSpace))
  }

  // MARK: - Problem

  func testARejectionCarriesNoChordAndSaysWhy() {
    let problem = HotkeyProblem.rejected(.noModifier)
    XCTAssertNil(problem.attempted)
    XCTAssertFalse(problem.isConflict)
    XCTAssertEqual(problem.message, KeyChordSymbols.noModifierMessage)
  }

  func testATakenChordIsCarriedAndNamed() {
    let binding = HotkeyBinding(
      keyCode: UInt32(kVK_ANSI_J),
      carbonModifiers: UInt32(controlKey)
    )
    let problem = HotkeyProblem.unavailable(binding, .taken)
    XCTAssertEqual(problem.attempted, binding)
    XCTAssertTrue(problem.isConflict)
    XCTAssertTrue(problem.message.contains(binding.displayName), problem.message)
  }

  func testAnUnrelatedFailureStillTints() {
    let binding = HotkeyBinding(
      keyCode: UInt32(kVK_ANSI_J),
      carbonModifiers: UInt32(controlKey)
    )
    XCTAssertTrue(HotkeyProblem.unavailable(binding, .failed(status: -1)).isConflict)
  }

  // MARK: - AppKit bridge

  func testModifierFlagsConvertToCarbonMasks() {
    XCTAssertEqual(HotkeyBinding.carbonModifiers(from: [.command]), UInt32(cmdKey))
    XCTAssertEqual(HotkeyBinding.carbonModifiers(from: [.option]), UInt32(optionKey))
    XCTAssertEqual(HotkeyBinding.carbonModifiers(from: [.control]), UInt32(controlKey))
    XCTAssertEqual(HotkeyBinding.carbonModifiers(from: [.shift]), UInt32(shiftKey))
    XCTAssertEqual(
      HotkeyBinding.carbonModifiers(from: [.command, .shift]),
      UInt32(cmdKey) | UInt32(shiftKey)
    )
  }

  func testNonHotkeyFlagsAreDropped() {
    XCTAssertEqual(
      HotkeyBinding.carbonModifiers(from: [.option, .capsLock, .function, .numericPad]),
      UInt32(optionKey)
    )
  }
}

// MARK: - Suggestions

final class HotkeySuggestionTests: XCTestCase {
  func testEverySuggestionPassesValidation() {
    for suggestion in HotkeySuggestions.all {
      XCTAssertNil(
        HotkeyValidation.reject(suggestion.binding),
        "suggestion \(suggestion.binding.displayName) would be refused"
      )
    }
  }

  func testSuggestionsAreDistinctAndIdentifiable() {
    let ids = HotkeySuggestions.all.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count, "duplicate suggestion: \(ids)")
  }

  func testTheDefaultIsTheFirstSuggestion() {
    XCTAssertEqual(HotkeySuggestions.all.first?.binding, HotkeySuggestions.defaultBinding)
  }

  func testTheFallbacksSkipTheDefaultAndOptionWithOneKey() {
    let fallbacks = HotkeySuggestions.fallbacks
    XCTAssertFalse(fallbacks.isEmpty)
    XCTAssertFalse(fallbacks.contains(HotkeySuggestions.defaultBinding))
    for binding in fallbacks {
      XCTAssertNotEqual(binding.carbonModifiers, UInt32(optionKey), binding.displayName)
    }
  }

  func testTheFirstFreeFallbackIsTakenInOrder() {
    let fallbacks = HotkeySuggestions.fallbacks
    XCTAssertEqual(HotkeySuggestions.firstFree { _ in true }, fallbacks.first)
    let held = Set(fallbacks.dropLast())
    XCTAssertEqual(HotkeySuggestions.firstFree { !held.contains($0) }, fallbacks.last)
    XCTAssertNil(HotkeySuggestions.firstFree { _ in false }, "all taken: nothing to move to")
  }
}

// MARK: - ⌥⌘, with no key

final class ModifierOnlyHotkeyTests: XCTestCase {
  func testItIsWrittenAsItsModifiersAlone() {
    XCTAssertEqual(HotkeyBinding.optionCommand.displayName, "⌥⌘")
    XCTAssertTrue(HotkeyBinding.optionCommand.isModifierOnly)
    XCTAssertFalse(HotkeyBinding.optionSpace.isModifierOnly)
  }

  func testOnlyTheOfferedPairPassesValidation() {
    XCTAssertNil(HotkeyValidation.reject(.optionCommand))
    let controlOption = HotkeyBinding(
      keyCode: HotkeyBinding.modifiersOnlyKeyCode,
      carbonModifiers: UInt32(controlKey) | UInt32(optionKey))
    XCTAssertEqual(HotkeyValidation.reject(controlOption), .noModifier)
  }

  func testItIsNeverAFallback() {
    XCTAssertFalse(HotkeySuggestions.all.map(\.binding).contains(.optionCommand))
    XCTAssertFalse(HotkeySuggestions.fallbacks.contains { $0.isModifierOnly })
    XCTAssertEqual(HotkeySuggestions.modifierOnly.map(\.binding), [.optionCommand])
  }

  func testItIsStoredAndReadBack() throws {
    let defaults = isolatedDefaults("boltty.tests.modifierOnlyHotkey")
    var settings = AppSettings.load(defaults: defaults)
    settings.bolttyAIHotkey = .optionCommand
    settings.save(defaults: defaults)
    XCTAssertEqual(AppSettings.load(defaults: defaults).bolttyAIHotkey, .optionCommand)
  }
}

final class ModifierHotkeyMonitorTests: XCTestCase {
  private final class Count: @unchecked Sendable { var value = 0 }

  private var clock: TimeInterval = 100
  private let count = Count()
  private lazy var monitor: ModifierHotkeyMonitor = {
    let count = count
    let monitor = ModifierHotkeyMonitor(onToggle: { count.value += 1 })
    monitor.now = { [unowned self] in self.clock }
    monitor.listenForTesting(.optionCommand)
    return monitor
  }()

  private func flags(_ flags: CGEventFlags) {
    let event = CGEvent(source: nil)!
    event.type = .flagsChanged
    event.flags = flags
    monitor.handle(.flagsChanged, event)
  }

  private func key() {
    monitor.handle(.keyDown, CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true)!)
  }

  private func pressAndRelease(_ between: () -> Void = {}) -> Bool {
    flags(.maskCommand)
    flags([.maskCommand, .maskAlternate])
    between()
    flags(.maskCommand)
    flags([])
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    return count.value == 1
  }

  func testPressingTheTwoAndLettingGoFires() {
    XCTAssertTrue(pressAndRelease())
  }

  func testAKeyWhileTheyAreHeldIsSomeOtherChord() {
    XCTAssertFalse(pressAndRelease { key() }, "⌥⌘Esc must not open Boltty")
  }

  func testAThirdModifierIsSomeOtherChord() {
    XCTAssertFalse(pressAndRelease { flags([.maskCommand, .maskAlternate, .maskShift]) })
  }

  func testHeldTooLongIsNotAPress() {
    XCTAssertFalse(pressAndRelease { clock += ModifierHotkeyMonitor.maximumHold + 0.1 })
  }

  func testOneModifierAloneDoesNothing() {
    flags(.maskCommand)
    flags([])
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(count.value, 0)
  }

  func testPasteAndMatchStyleWithShiftLetGoFirstIsSomeOtherChord() {
    XCTAssertFalse(pressAndRelease {
      flags([.maskCommand, .maskAlternate, .maskShift])
      key()
      flags([.maskCommand, .maskAlternate])
    })
  }

  func testAChordThatComesBackToThePairIsStillSomeOtherChord() {
    XCTAssertFalse(pressAndRelease {
      flags([.maskCommand, .maskAlternate, .maskControl])
      key()
      flags([.maskCommand, .maskAlternate])
    })
  }

  func testAThirdModifierLetGoOfAgainIsStillSomeOtherChord() {
    XCTAssertFalse(pressAndRelease {
      flags([.maskCommand, .maskAlternate, .maskShift])
      flags([.maskCommand, .maskAlternate])
    })
  }

  func testHeldTooLongStaysSpentWhenThePairIsPressedAgain() {
    XCTAssertFalse(pressAndRelease {
      clock += ModifierHotkeyMonitor.maximumHold + 0.1
      flags(.maskCommand)
      flags([.maskCommand, .maskAlternate])
    })
  }

  func testAKeyBeforeThePairSpoilsTheHold() {
    flags(.maskCommand)
    key()
    XCTAssertFalse(pressAndRelease())
  }

  func testAFreshPressAfterEverythingIsUpFiresAgain() {
    XCTAssertFalse(pressAndRelease { key() })
    XCTAssertTrue(pressAndRelease())
  }

  func testAKeyWithNothingHeldDoesNotSpoilTheNextPress() {
    key()
    XCTAssertTrue(pressAndRelease())
  }

  func testATapTurnedOffMidPressDoesNotFire() {
    XCTAssertFalse(pressAndRelease {
      monitor.handle(.tapDisabledByTimeout, CGEvent(source: nil)!)
    })
    XCTAssertTrue(pressAndRelease())
  }
}
