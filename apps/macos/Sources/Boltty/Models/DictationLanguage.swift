import Foundation

enum DictationTier: String, Sendable, Equatable, CaseIterable {
  case speechTranscriber
  case dictationTranscriber
  case legacy
}

struct DictationLanguage: Sendable, Equatable, Identifiable {
  let identifier: String
  let tier: DictationTier
  let isInstalled: Bool

  var id: String { identifier }

  var locale: Locale { Locale(identifier: identifier) }

  var displayName: String {
    Locale.current.localizedString(forIdentifier: identifier) ?? identifier
  }

  var languageCode: String { DictationLanguageCatalog.languageCode(of: identifier) }
}

enum DictationLanguageCatalog {
  static let followSystemIdentifier = ""
  static let noSecondLanguageIdentifier = ""

  static func normalize(_ identifier: String) -> String {
    Locale(identifier: identifier).identifier(.bcp47).lowercased()
  }

  static func languages(
    speechTranscriberSupported: [String],
    speechTranscriberInstalled: [String],
    dictationSupported: [String],
    dictationInstalled: [String],
    legacySupported: [String],
    isModern: Bool
  ) -> [DictationLanguage] {
    guard isModern else {
      return sorted(
        legacySupported.map {
          DictationLanguage(identifier: canonical($0), tier: .legacy, isInstalled: false)
        }
      )
    }

    let speechInstalled = Set(speechTranscriberInstalled.map(normalize))
    let dictationInstalledSet = Set(dictationInstalled.map(normalize))

    var byIdentifier: [String: DictationLanguage] = [:]

    for identifier in dictationSupported {
      let key = normalize(identifier)
      byIdentifier[key] = DictationLanguage(
        identifier: canonical(identifier),
        tier: .dictationTranscriber,
        isInstalled: dictationInstalledSet.contains(key)
      )
    }
    for identifier in speechTranscriberSupported {
      let key = normalize(identifier)
      byIdentifier[key] = DictationLanguage(
        identifier: canonical(identifier),
        tier: .speechTranscriber,
        isInstalled: speechInstalled.contains(key)
      )
    }

    return sorted(Array(byIdentifier.values))
  }

  static func tier(for identifier: String, in languages: [DictationLanguage]) -> DictationTier? {
    let key = normalize(identifier)
    return languages.first { normalize($0.identifier) == key }?.tier
  }

  static func resolve(
    identifier: String,
    systemIdentifier: String,
    in languages: [DictationLanguage]
  ) -> DictationLanguage? {
    let wanted = identifier == followSystemIdentifier ? systemIdentifier : identifier
    let key = normalize(wanted)
    if let exact = languages.first(where: { normalize($0.identifier) == key }) {
      return exact
    }
    let language = String(key.prefix(while: { $0 != "-" }))
    guard !language.isEmpty else { return nil }
    let sameLanguage = languages.filter { normalize($0.identifier).hasPrefix(language + "-") }
    return sameLanguage.first { $0.isInstalled } ?? sameLanguage.first
  }

  static func resolveSecond(
    identifier: String,
    primary: DictationLanguage,
    systemIdentifier: String,
    in languages: [DictationLanguage]
  ) -> DictationLanguage? {
    guard identifier != noSecondLanguageIdentifier,
          let second = resolve(identifier: identifier, systemIdentifier: systemIdentifier, in: languages),
          second.languageCode != primary.languageCode
    else { return nil }
    return second
  }

  static func languageCode(of identifier: String) -> String {
    Locale(identifier: identifier).language.languageCode?.identifier
      ?? String(normalize(identifier).prefix(while: { $0 != "-" }))
  }

  private static func canonical(_ identifier: String) -> String {
    Locale(identifier: identifier).identifier(.bcp47)
  }

  private static func sorted(_ languages: [DictationLanguage]) -> [DictationLanguage] {
    languages.sorted {
      let left = $0.displayName
      let right = $1.displayName
      if left == right { return $0.identifier < $1.identifier }
      return left.localizedStandardCompare(right) == .orderedAscending
    }
  }
}
