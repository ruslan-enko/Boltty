import Foundation
import Speech

@MainActor
enum DictationCatalog {
  static func languages() async -> [DictationLanguage] {
    async let speechSupported = SpeechTranscriber.supportedLocales
    async let speechInstalled = SpeechTranscriber.installedLocales
    async let dictationSupported = DictationTranscriber.supportedLocales
    async let dictationInstalled = DictationTranscriber.installedLocales
    return await DictationLanguageCatalog.languages(
      speechTranscriberSupported: identifiers(speechSupported),
      speechTranscriberInstalled: identifiers(speechInstalled),
      dictationSupported: identifiers(dictationSupported),
      dictationInstalled: identifiers(dictationInstalled),
      legacySupported: [],
      isModern: true
    )
  }

  static func engine(for tier: DictationTier) -> DictationEngine {
    if tier != .legacy {
      return SpeechAnalyzerDictationEngine(tier: tier)
    }
    return LegacyDictationEngine()
  }

  /// The engine for one language, or for two when a second is chosen: both
  /// listen to the same audio and the words of whichever heard it are kept.
  static func engine(for primary: DictationLanguage, second: DictationLanguage?) -> DictationEngine {
    guard let second, primary.tier != .legacy, second.tier != .legacy else {
      return engine(for: primary.tier)
    }
    return BilingualDictationEngine(primaryTier: primary.tier, secondary: second)
  }

  static func install(
    _ language: DictationLanguage,
    onProgress: @escaping @MainActor (Progress) -> Void
  ) async throws {
    let locale = language.locale
    let reserved = await AssetInventory.reservedLocales
    if reserved.count >= AssetInventory.maximumReservedLocales,
       let oldest = reserved.first {
      _ = await AssetInventory.release(reservedLocale: oldest)
    }
    _ = try await AssetInventory.reserve(locale: locale)

    let module: any SpeechModule
    switch language.tier {
    case .speechTranscriber:
      module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    case .dictationTranscriber, .legacy:
      module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
    }

    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
    else {
      return
    }
    onProgress(request.progress)
    try await request.downloadAndInstall()
  }

  private static func identifiers(_ locales: [Locale]) -> [String] {
    locales.map(\.identifier)
  }
}
