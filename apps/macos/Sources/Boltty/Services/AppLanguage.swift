import AppKit

/// Boltty's own language: the `AppleLanguages` macOS keeps for this app alone,
/// the value System Settings › Language & Region › Applications writes too, so
/// the two never disagree. Read at launch, so a change shows after a relaunch.
@MainActor
final class AppLanguage: ObservableObject {
  static let key = "AppleLanguages"
  static let order = ["en", "uk", "de", "fr", "es", "pt-BR", "ja", "zh-Hans", "ko"]

  private let defaults: UserDefaults
  private let domain: String
  let running: String?
  @Published private(set) var chosen: String?

  init(defaults: UserDefaults = .standard, domain: String = Bundle.main.bundleIdentifier ?? "com.boltty.app") {
    self.defaults = defaults
    self.domain = domain
    let stored = (defaults.persistentDomain(forName: domain)?[Self.key] as? [String])?.first
    chosen = stored
    running = stored
  }

  var available: [String] {
    let shipped = Set(Bundle.main.localizations)
    return Self.order.filter(shipped.contains)
  }

  var needsRelaunch: Bool { chosen != running }

  func choose(_ code: String?) {
    if let code {
      defaults.set([code], forKey: Self.key)
    } else {
      defaults.removeObject(forKey: Self.key)
    }
    chosen = code
  }

  /// Each language named in itself, as macOS lists them.
  static func name(of code: String) -> String {
    let locale = Locale(identifier: code)
    guard let name = locale.localizedString(forIdentifier: code) else { return code }
    return name.prefix(1).uppercased(with: locale) + name.dropFirst()
  }

  func relaunch() {
    Task { @MainActor in
      try? await UpdateInstaller.relaunch(Bundle.main.bundleURL)
      RunLoop.main.perform { NSApp.terminate(nil) }
    }
  }
}
