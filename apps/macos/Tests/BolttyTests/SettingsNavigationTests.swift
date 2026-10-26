@testable import Boltty
import XCTest

@MainActor
final class SettingsNavigationTests: XCTestCase {
  private func makeDefaults() -> UserDefaults {
    isolatedDefaults("boltty.tests.settings-navigation")
  }

  func testAFreshInstallOpensOnGeneralWithNowhereToGo() {
    let navigation = SettingsNavigation(defaults: makeDefaults())
    XCTAssertEqual(navigation.current, .general)
    XCTAssertFalse(navigation.canGoBack)
    XCTAssertFalse(navigation.canGoForward)
  }

  func testItOpensOnThePageLastShown() {
    let defaults = makeDefaults()
    SettingsNavigation(defaults: defaults).open(.voice)
    XCTAssertEqual(SettingsNavigation(defaults: defaults).current, .voice)
  }

  func testAnUnknownStoredPageFallsBackToGeneral() {
    let defaults = makeDefaults()
    for retired in ["appearance", "prompts"] {
      defaults.set(retired, forKey: SettingsNavigation.lastPageKey)
      XCTAssertEqual(SettingsNavigation(defaults: defaults).current, .general)
    }
  }

  func testBackAndForwardWalkWhatWasOpened() {
    let navigation = SettingsNavigation(defaults: makeDefaults())
    navigation.open(.agents)
    navigation.open(.usage)

    navigation.goBack()
    XCTAssertEqual(navigation.current, .agents)
    XCTAssertTrue(navigation.canGoBack)
    XCTAssertTrue(navigation.canGoForward)

    navigation.goBack()
    XCTAssertEqual(navigation.current, .general)
    XCTAssertFalse(navigation.canGoBack)

    navigation.goForward()
    navigation.goForward()
    XCTAssertEqual(navigation.current, .usage)
    XCTAssertFalse(navigation.canGoForward)
  }

  func testOpeningAPageAfterGoingBackDropsTheForwardHistory() {
    let navigation = SettingsNavigation(defaults: makeDefaults())
    navigation.open(.agents)
    navigation.open(.usage)
    navigation.goBack()

    navigation.open(.voice)
    XCTAssertEqual(navigation.current, .voice)
    XCTAssertFalse(navigation.canGoForward)
    navigation.goBack()
    XCTAssertEqual(navigation.current, .agents)
  }

  func testOpeningTheCurrentPageAddsNoStep() {
    let navigation = SettingsNavigation(defaults: makeDefaults())
    navigation.open(.agents)
    navigation.open(.agents)
    navigation.goBack()
    XCTAssertEqual(navigation.current, .general)
  }

  func testGoingBackIsRememberedToo() {
    let defaults = makeDefaults()
    let navigation = SettingsNavigation(defaults: defaults)
    navigation.open(.shortcuts)
    navigation.goBack()
    XCTAssertEqual(SettingsNavigation(defaults: defaults).current, .general)
  }

  func testEveryPageHasATitleAndASymbolThatExists() {
    for page in SettingsPage.allCases {
      XCTAssertFalse(page.title.isEmpty, "\(page)")
      XCTAssertNotNil(
        NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil),
        "\(page) names a symbol this system does not have: \(page.symbol)"
      )
    }
  }
}
