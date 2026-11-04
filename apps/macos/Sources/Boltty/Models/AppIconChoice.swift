import AppKit

/// The icon Boltty wears while it runs, chosen in Settings › General. macOS has
/// no alternate icons for an app: the bundle's stays what Finder and banners
/// show, since writing another onto the bundle breaks its signature, and this
/// is set on the running app. Pictures, because an `.icon` compiled beside the
/// main one cannot be loaded by name (scripts/render-app-icons.sh).
enum AppIconChoice: String, CaseIterable, Identifiable {
  case standard = "default"
  case citrus
  case pastel
  case sunset

  static let storageKey = "boltty.appIcon"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: "Default"
    case .citrus: "Citrus"
    case .pastel: "Pastel"
    case .sunset: "Sunset"
    }
  }

  var picture: NSImage? {
    Bundle.main.url(forResource: rawValue, withExtension: "png", subdirectory: "AppIcons")
      .flatMap(NSImage.init(contentsOf:))
  }

  static func stored(defaults: UserDefaults = .standard) -> AppIconChoice {
    defaults.string(forKey: storageKey).flatMap(AppIconChoice.init(rawValue:)) ?? .standard
  }

  /// `nil` gives the running app the bundle's own icon back.
  @MainActor func apply() {
    NSApp.applicationIconImage = self == .standard ? nil : picture
  }
}
