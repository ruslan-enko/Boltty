import XCTest
@testable import Boltty

final class DictationLanguageCatalogTests: XCTestCase {
  private let speechOnly = ["en-US", "de-DE", "ja-JP"]
  private let dictationOnly = ["en-US", "de-DE", "uk-UA", "pl-PL", "ru-RU"]

  private func catalog(
    speechInstalled: [String] = [],
    dictationInstalled: [String] = []
  ) -> [DictationLanguage] {
    DictationLanguageCatalog.languages(
      speechTranscriberSupported: speechOnly,
      speechTranscriberInstalled: speechInstalled,
      dictationSupported: dictationOnly,
      dictationInstalled: dictationInstalled,
      legacySupported: [],
      isModern: true
    )
  }

  func testUkrainianComesFromTheDictationEngineNotTheNewOne() {
    let languages = catalog()
    XCTAssertEqual(
      DictationLanguageCatalog.tier(for: "uk-UA", in: languages),
      .dictationTranscriber
    )
    XCTAssertEqual(
      DictationLanguageCatalog.tier(for: "ja-JP", in: languages),
      .speechTranscriber
    )
  }

  func testALanguageInBothEnginesIsListedOnceAndPrefersTheNewer() {
    let languages = catalog()
    let english = languages.filter { $0.identifier.hasPrefix("en") }

    XCTAssertEqual(english.count, 1)
    XCTAssertEqual(english.first?.tier, .speechTranscriber)
  }

  func testInstallationIsReportedPerEngine() {
    let languages = catalog(speechInstalled: ["en-US"], dictationInstalled: ["uk-UA"])

    XCTAssertEqual(languages.first { $0.identifier == "en-US" }?.isInstalled, true)
    XCTAssertEqual(languages.first { $0.identifier == "uk-UA" }?.isInstalled, true)
    XCTAssertEqual(languages.first { $0.identifier == "pl-PL" }?.isInstalled, false)
  }

  func testIdentifiersMatchAcrossTheFrameworksSpellings() {
    let languages = catalog()
    XCTAssertEqual(
      DictationLanguageCatalog.tier(for: "uk_UA", in: languages),
      .dictationTranscriber
    )
  }

  // MARK: - Resolving the setting

  func testFollowSystemUsesTheSystemLocale() {
    let languages = catalog()
    let resolved = DictationLanguageCatalog.resolve(
      identifier: DictationLanguageCatalog.followSystemIdentifier,
      systemIdentifier: "uk_UA",
      in: languages
    )
    XCTAssertEqual(resolved?.identifier, "uk-UA")
  }

  func testASecondLanguageIsAnotherLanguageNotAnotherRegion() {
    let languages = catalog()
    let primary = DictationLanguageCatalog.resolve(
      identifier: "uk-UA", systemIdentifier: "en_US", in: languages
    )!

    XCTAssertEqual(
      DictationLanguageCatalog.resolveSecond(
        identifier: "en-US", primary: primary, systemIdentifier: "en_US", in: languages
      )?.identifier,
      "en-US"
    )
    XCTAssertNil(
      DictationLanguageCatalog.resolveSecond(
        identifier: "uk-UA", primary: primary, systemIdentifier: "en_US", in: languages
      ),
      "two recognizers of one language would only agree"
    )
    XCTAssertNil(
      DictationLanguageCatalog.resolveSecond(
        identifier: DictationLanguageCatalog.noSecondLanguageIdentifier,
        primary: primary, systemIdentifier: "en_US", in: languages
      )
    )
    XCTAssertNil(
      DictationLanguageCatalog.resolveSecond(
        identifier: "sw-KE", primary: primary, systemIdentifier: "en_US", in: languages
      ),
      "a language this Mac does not offer is no second language"
    )
  }

  func testAnUnknownRegionFallsBackToTheSameLanguage() {
    let resolved = DictationLanguageCatalog.resolve(
      identifier: "de-AT",
      systemIdentifier: "en_US",
      in: catalog()
    )
    XCTAssertEqual(resolved?.identifier, "de-DE")
  }

  func testTheFallbackPrefersAnInstalledRegion() {
    let languages = DictationLanguageCatalog.languages(
      speechTranscriberSupported: ["en-GB", "en-US"],
      speechTranscriberInstalled: ["en-US"],
      dictationSupported: [],
      dictationInstalled: [],
      legacySupported: [],
      isModern: true
    )
    let resolved = DictationLanguageCatalog.resolve(
      identifier: "en-AU",
      systemIdentifier: "en_AU",
      in: languages
    )
    XCTAssertEqual(resolved?.identifier, "en-US")
  }

  func testAnUnsupportedLanguageResolvesToNothing() {
    XCTAssertNil(
      DictationLanguageCatalog.resolve(
        identifier: "sw-KE",
        systemIdentifier: "en_US",
        in: catalog()
      )
    )
  }

  func testBeforeMacOS26TheMenuComesFromTheLegacyList() {
    let languages = DictationLanguageCatalog.languages(
      speechTranscriberSupported: speechOnly,
      speechTranscriberInstalled: [],
      dictationSupported: dictationOnly,
      dictationInstalled: [],
      legacySupported: ["uk_UA", "en_US"],
      isModern: false
    )
    XCTAssertEqual(languages.map(\.tier), [.legacy, .legacy])
    XCTAssertEqual(Set(languages.map(\.identifier)), ["uk-UA", "en-US"])
  }

  func testTheMenuIsSortedByWhatTheUserReads() {
    let names = catalog().map(\.displayName)
    XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
  }
}
