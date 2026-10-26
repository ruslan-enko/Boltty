import AppKit
import XCTest

@testable import Boltty

final class ShortcutBindingTests: XCTestCase {
  func testDisplayNameUsesCanonicalModifierOrder() {
    let binding = ShortcutBinding(
      keyEquivalent: "k",
      modifiers: [.command, .shift, .option, .control]
    )
    XCTAssertEqual(binding.displayName, "⌃⌥⇧⌘K")
  }

  func testUnprintableKeysGetNames() {
    XCTAssertEqual(ShortcutBinding.keyLabel(" "), "Space")
    XCTAssertEqual(ShortcutBinding.keyLabel("\r"), "↩")
    XCTAssertEqual(ShortcutBinding.keyLabel("\u{f700}"), "↑")
  }

  func testUnboundReadsAsNone() {
    XCTAssertEqual(ShortcutBinding.unbound.displayName, "None")
    XCTAssertTrue(ShortcutBinding.unbound.isUnbound)
  }

  // MARK: - Validation

  func testBareKeyIsRejected() {
    let binding = ShortcutBinding(keyEquivalent: "k", modifiers: [])
    XCTAssertEqual(ShortcutBindingValidation.reject(binding), .noModifier)
  }

  func testShiftAloneIsNotEnough() {
    let binding = ShortcutBinding(keyEquivalent: "k", modifiers: .shift)
    XCTAssertEqual(ShortcutBindingValidation.reject(binding), .noModifier)
  }

  func testCommandChordIsAccepted() {
    let binding = ShortcutBinding(keyEquivalent: "k", modifiers: .command)
    XCTAssertNil(ShortcutBindingValidation.reject(binding))
  }

  func testSystemReservedChordIsRejected() {
    let binding = ShortcutBinding(keyEquivalent: " ", modifiers: .command)
    XCTAssertEqual(ShortcutBindingValidation.reject(binding), .reservedBySystem)
  }

  func testUnboundNeedsNoModifier() {
    XCTAssertNil(ShortcutBindingValidation.reject(.unbound))
  }
}

@MainActor
final class ShortcutBindingStoreTests: XCTestCase {
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    defaults = isolatedDefaults("com.boltty.tests")
  }

  override func tearDown() async throws {
    try await super.tearDown()
  }

  func testUntouchedIDsFollowTheCatalog() {
    let store = ShortcutBindingStore(defaults: defaults)
    XCTAssertEqual(store.binding(for: "minimize").keyEquivalent, "m")
    XCTAssertEqual(store.binding(for: "minimize").modifiers, .command)
    XCTAssertFalse(store.isCustomized("minimize"))
  }

  func testOverrideRoundTripsThroughDefaults() {
    let store = ShortcutBindingStore(defaults: defaults)
    let recorded = ShortcutBinding(keyEquivalent: "j", modifiers: [.command, .shift])
    store.setBinding(recorded, for: "minimize")

    let reloaded = ShortcutBindingStore(defaults: defaults)
    XCTAssertEqual(reloaded.binding(for: "minimize"), recorded)
    XCTAssertTrue(reloaded.isCustomized("minimize"))
  }

  func testColonKeyEquivalentRoundTrips() {
    let store = ShortcutBindingStore(defaults: defaults)
    let recorded = ShortcutBinding(keyEquivalent: ":", modifiers: .command)
    store.setBinding(recorded, for: "minimize")

    XCTAssertEqual(ShortcutBindingStore(defaults: defaults).binding(for: "minimize"), recorded)
  }

  func testARowThatShipsUnboundCanStillBeGivenAChord() {
    let store = ShortcutBindingStore(defaults: defaults)
    XCTAssertTrue(store.binding(for: "saveScrollback").isUnbound)

    let item = NSMenuItem()
    store.bind(item, to: "saveScrollback")
    XCTAssertEqual(item.keyEquivalent, "", "an unbound row must not invent a chord")

    store.setBinding(ShortcutBinding(keyEquivalent: "s", modifiers: [.command, .shift]), for: "saveScrollback")
    XCTAssertEqual(item.keyEquivalent, "s")
    XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
  }

  func testRecordingTheDefaultClearsTheOverride() {
    let store = ShortcutBindingStore(defaults: defaults)
    store.setBinding(ShortcutBinding(keyEquivalent: "j", modifiers: .command), for: "minimize")
    XCTAssertTrue(store.isCustomized("minimize"))

    store.setBinding(ShortcutBinding(keyEquivalent: "m", modifiers: .command), for: "minimize")
    XCTAssertFalse(store.isCustomized("minimize"))
  }

  func testNilBindingRestoresTheDefault() {
    let store = ShortcutBindingStore(defaults: defaults)
    store.setBinding(ShortcutBinding(keyEquivalent: "j", modifiers: .command), for: "minimize")
    store.setBinding(nil, for: "minimize")

    XCTAssertFalse(store.isCustomized("minimize"))
    XCTAssertEqual(store.binding(for: "minimize").keyEquivalent, "m")
  }

  func testResetAllClearsEveryOverride() {
    let store = ShortcutBindingStore(defaults: defaults)
    store.setBinding(ShortcutBinding(keyEquivalent: "j", modifiers: .command), for: "minimize")
    store.setBinding(ShortcutBinding(keyEquivalent: "y", modifiers: .command), for: "settings")
    store.resetAll()

    XCTAssertTrue(store.overrides.isEmpty)
    XCTAssertNil(defaults.object(forKey: ShortcutBindingStore.overridesKey))
  }

  // MARK: - Menu items

  func testBindingWritesThroughToTheMenuItem() {
    let store = ShortcutBindingStore(defaults: defaults)
    let item = NSMenuItem()
    store.bind(item, to: "minimize")

    XCTAssertEqual(item.keyEquivalent, "m")
    XCTAssertEqual(item.keyEquivalentModifierMask, .command)

    store.setBinding(ShortcutBinding(keyEquivalent: "j", modifiers: [.command, .shift]), for: "minimize")

    XCTAssertEqual(item.keyEquivalent, "j")
    XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
  }

  func testResetAllWritesBackToMenuItems() {
    let store = ShortcutBindingStore(defaults: defaults)
    let item = NSMenuItem()
    store.bind(item, to: "minimize")
    store.setBinding(ShortcutBinding(keyEquivalent: "j", modifiers: .command), for: "minimize")
    store.resetAll()

    XCTAssertEqual(item.keyEquivalent, "m")
  }

  func testRebindingTheSameItemDoesNotRegisterItTwice() {
    let store = ShortcutBindingStore(defaults: defaults)
    let item = NSMenuItem()
    store.bind(item, to: "minimize")
    store.bind(item, to: "settings")

    store.setBinding(ShortcutBinding(keyEquivalent: "j", modifiers: .command), for: "minimize")
    XCTAssertEqual(item.keyEquivalent, ",")
  }

  // MARK: - Conflicts

  func testDefaultsHaveNoConflicts() {
    XCTAssertTrue(
      ShortcutBindingStore(defaults: defaults).conflicts().isEmpty,
      "the shipped shortcut defaults collide with each other"
    )
  }

  func testDuplicateChordIsReported() {
    let store = ShortcutBindingStore(defaults: defaults)
    store.setBinding(ShortcutBinding(keyEquivalent: "c", modifiers: .command), for: "minimize")

    let conflicting = store.conflictingIDs()
    XCTAssertTrue(conflicting.contains("copy"))
    XCTAssertTrue(conflicting.contains("minimize"))
  }

  func testUnboundRowsDoNotConflict() {
    let store = ShortcutBindingStore(defaults: defaults)
    store.setBinding(.unbound, for: "minimize")
    store.setBinding(.unbound, for: "settings")

    XCTAssertTrue(store.conflicts().isEmpty)
  }
}

final class KeyboardShortcutCatalogTests: XCTestCase {
  func testTheStoredIDsAreFrozen() {
    XCTAssertEqual(
      Set(KeyboardShortcutCatalog.customizableIDs),
      Set([
        "copy", "paste", "selectAll",
        "minimize",
        "settings", "closeBoltty"
      ])
    )
  }

  func testCatalogIDsAreUnique() {
    let ids = KeyboardShortcutCatalog.allShortcuts.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count)
  }

  func testEveryRowShipsWithADefaultChord() {
    for shortcut in KeyboardShortcutCatalog.allShortcuts {
      XCTAssertNotNil(
        shortcut.keyEquivalent,
        "\(shortcut.id) is rebindable but has no default chord"
      )
    }
  }

  func testConversationChordsAreGoneFromTheCatalog() {
    for retired in [
      "newWindow", "newTab", "selectTab1", "selectTab6", "toggleSidebar",
      "showBoltty", "jumpUnread", "fullScreen"
    ] {
      XCTAssertNil(KeyboardShortcutCatalog.entry(for: retired))
    }
  }

  func testCustomizableIDsCoverEveryRow() {
    XCTAssertEqual(
      Set(KeyboardShortcutCatalog.customizableIDs),
      Set(KeyboardShortcutCatalog.allShortcuts.map(\.id))
    )
  }

  func testUnknownIDResolvesToNilRatherThanTrapping() {
    XCTAssertNil(KeyboardShortcutCatalog.entry(for: "notARealCommand"))
  }
}

final class BuiltInKeyCatalogTests: XCTestCase {
  private func sections(launch: String? = "⌥Space", askIsOn: Bool = true) -> [BuiltInKeySection] {
    BuiltInKeyCatalog.sections(launchChord: launch, askBolttyChord: "⌃⌥⌘", askBolttyIsOn: askIsOn)
  }

  func testEveryKeyHasANameAndKeysAndAUniqueID() {
    let keys = sections().flatMap(\.keys)
    XCTAssertEqual(Set(keys.map(\.id)).count, keys.count)
    for key in keys {
      XCTAssertFalse(key.title.isEmpty, key.id)
      XCTAssertFalse(key.keys.isEmpty, key.id)
    }
  }

  func testTheLaunchChordIsTheOneSetNowAndOffWhenSwitchedOff() {
    func open(_ sections: [BuiltInKeySection]) -> BuiltInKey? {
      sections.flatMap(\.keys).first { $0.id == "open" }
    }
    XCTAssertEqual(open(sections(launch: "⌃⌥K"))?.keys, "⌃⌥K")
    XCTAssertEqual(open(sections(launch: nil))?.keys, "Off")
  }

  func testAskBolttySaysWhetherItIsOn() {
    func ask(_ sections: [BuiltInKeySection]) -> BuiltInKey? {
      sections.flatMap(\.keys).first { $0.id == "ask" }
    }
    XCTAssertEqual(ask(sections(askIsOn: true))?.keys, "Hold ⌃⌥⌘")
    XCTAssertEqual(ask(sections(askIsOn: true))?.detail, "Speak, then let go")
    XCTAssertTrue(ask(sections(askIsOn: false))?.detail?.hasPrefix("Off") == true)
  }

  func testNoBuiltInKeyRepeatsAMenuCommandsTitle() {
    let menu = Set(KeyboardShortcutCatalog.allShortcuts.map(\.title))
    for key in sections().flatMap(\.keys) {
      XCTAssertFalse(menu.contains(key.title), "\(key.title) is a menu command, listed above")
    }
  }
}
