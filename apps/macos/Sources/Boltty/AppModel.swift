import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {
  @Published var settings: AppSettings
  @Published var hotkeyRegistrationFailed = false
  @Published var hotkeyStandIn: HotkeyBinding?
  @Published var hotkeyStandInFailed = false
  private let settingsDefaults: UserDefaults

  private(set) lazy var agentCatalog = AgentCatalogService(model: self)

  private(set) lazy var shortcutBindings = ShortcutBindingStore(defaults: settingsDefaults)

  init(settings: AppSettings? = nil, defaults: UserDefaults = .standard) {
    settingsDefaults = defaults
    self.settings = settings ?? .load(defaults: defaults)
  }

  var persistsSettings: Bool {
    !(Self.isRunningTests && settingsDefaults == .standard)
  }

  private static let isRunningTests = NSClassFromString("XCTestCase") != nil

  func updateSettings(_ transform: (inout AppSettings) -> Void) {
    var newSettings = settings
    transform(&newSettings)
    settings = newSettings
    if persistsSettings {
      newSettings.save(defaults: settingsDefaults)
    }
  }
}
