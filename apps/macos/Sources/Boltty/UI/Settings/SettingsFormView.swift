import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
  static let defaultContentSize = NSSize(width: 780, height: 560)
  static let minimumContentSize = NSSize(width: 660, height: 420)
  static let defaultFrameAutosaveName = "BolttySettingsSidebarWindow"

  private let formModel: BolttyAISettingsModel
  private let navigation: SettingsNavigation
  private let hostingController: NSHostingController<BolttyAISettingsView>

  init(
    model: AppModel,
    engine: ConversationEngine,
    frameAutosaveName: String = SettingsWindowController.defaultFrameAutosaveName,
    probeHotkey: @escaping (HotkeyBinding) -> HotkeyAvailability = { _ in .free },
    updater: AppUpdater? = nil,
    loginItem: LoginItem = LoginItem(),
    speech: SpeechOutput? = nil
  ) {
    let formModel = BolttyAISettingsModel(
      appModel: model, engine: engine, updater: updater, loginItem: loginItem, speech: speech
    )
    formModel.probeHotkey = probeHotkey
    let navigation = SettingsNavigation()
    let hostingController = NSHostingController(
      rootView: BolttyAISettingsView(model: formModel, navigation: navigation)
    )
    hostingController.sizingOptions = []
    hostingController.sceneBridgingOptions = [.toolbars, .title]
    hostingController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    hostingController.view.setContentHuggingPriority(.defaultLow, for: .vertical)
    hostingController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    hostingController.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Settings"
    window.identifier = NSUserInterfaceItemIdentifier("boltty.settings.window")
    window.tabbingMode = .disallowed
    window.contentMinSize = Self.minimumContentSize
    window.contentViewController = hostingController
    window.setContentSize(Self.defaultContentSize)
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .unified
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.isOpaque = true
    window.backgroundColor = SettingsSurfacePalette.background

    let restoredFrame = window.setFrameUsingName(frameAutosaveName)
    _ = window.setFrameAutosaveName(frameAutosaveName)
    if !restoredFrame {
      window.center()
    }

    self.formModel = formModel
    self.navigation = navigation
    self.hostingController = hostingController
    super.init(window: window)

    applyAppearance()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show(page: SettingsPage? = nil) {
    if let page { navigation.open(page) }
    present(activating: true)
  }

  func present(activating: Bool) {
    guard let window else { return }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    if activating {
      NSApp.activate(ignoringOtherApps: true)
    }
    showWindow(nil)
    window.makeKeyAndOrderFront(nil)
  }

  var isKeyWindow: Bool {
    window?.isKeyWindow == true
  }

  var onReviewAccess: (() -> Void)? {
    get { formModel.onReviewAccess }
    set { formModel.onReviewAccess = newValue }
  }

  private func applyAppearance() {
    guard let window else { return }
    window.backgroundColor = SettingsSurfacePalette.background
    window.isOpaque = true
  }
}
