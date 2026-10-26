import AppKit
import Combine
import SwiftUI

@MainActor
final class AccessPermissionsModel: ObservableObject {
  static let refreshInterval: TimeInterval = 1.5

  @Published private(set) var statuses: [AccessKind: AccessStatus] = [:]
  @Published private(set) var asking: AccessKind?

  let kinds = AccessKind.allCases
  private let probe: AccessProbe
  private var timer: Timer?
  private var activation: AnyCancellable?

  init(probe: AccessProbe) {
    self.probe = probe
  }

  var allAllowed: Bool { kinds.allSatisfy { statuses[$0] == .allowed } }

  func refresh() async {
    for kind in kinds {
      let status = await probe.status(kind)
      if statuses[kind] != status { statuses[kind] = status }
    }
  }

  func act(on kind: AccessKind) {
    guard asking == nil else { return }
    if statuses[kind] == .refused {
      if let pane = kind.settingsPane { NSWorkspace.shared.open(pane) }
      return
    }
    asking = kind
    Task {
      let status = await probe.request(kind)
      statuses[kind] = status
      asking = nil
    }
  }

  static let allowAllOrder: [AccessKind] = [.dictation, .notifications, .finder, .screen]

  var hasSomethingToAsk: Bool { kinds.contains { statuses[$0] == .notAsked } }

  func allowAll() {
    guard asking == nil else { return }
    Task {
      for kind in Self.allowAllOrder where statuses[kind] == .notAsked {
        asking = kind
        statuses[kind] = await probe.request(kind)
      }
      asking = nil
    }
  }

  func startWatching() {
    Task { await refresh() }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.refresh() }
    }
    activation = NotificationCenter.default
      .publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in Task { await self?.refresh() } }
  }

  func stopWatching() {
    timer?.invalidate()
    timer = nil
    activation = nil
  }
}

struct AccessPermissionsView: View {
  @ObservedObject var model: AccessPermissionsModel
  var onDone: () -> Void

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 6) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 64, height: 64)
        Text("Give Boltty AI access")
          .font(.title2.weight(.semibold))
        Text("macOS asks for each once. You can change any of them later in System Settings.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      AccessPermissionList(model: model)

      HStack {
        Spacer()
        if model.hasSomethingToAsk {
          Button("Not Now", action: onDone)
            .buttonStyle(.glass)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("boltty.access.done")
          Button("Allow All") { model.allowAll() }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.asking != nil)
            .accessibilityIdentifier("boltty.access.allowAll")
        } else {
          Button(model.allAllowed ? "Done" : "Not Now", action: onDone)
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("boltty.access.done")
        }
      }
    }
    .padding(.horizontal, 24)
    .padding(.top, 36)
    .padding(.bottom, 20)
    .frame(width: AccessPermissionsWindowController.contentWidth)
    .bolttyInterfaceTypography()
    .animation(SettingsMotion.arrival, value: model.statuses)
  }
}

/// The four rows and the note under them — the permissions window's, and
/// the first run's setup step's.
struct AccessPermissionList: View {
  @ObservedObject var model: AccessPermissionsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      GroupBox {
        VStack(spacing: 0) {
          ForEach(Array(model.kinds.enumerated()), id: \.element) { index, kind in
            if index > 0 { Divider().padding(.leading, 44) }
            AccessPermissionRow(
              kind: kind,
              status: model.statuses[kind],
              isAsking: model.asking == kind,
              action: { model.act(on: kind) }
            )
          }
        }
        .padding(.vertical, 2)
      }

      if model.statuses[.screen] == .refused {
        SettingsNote("Screen Recording takes effect once Boltty is quit and opened again.")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

private struct AccessPermissionRow: View {
  let kind: AccessKind
  let status: AccessStatus?
  let isAsking: Bool
  let action: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: kind.symbol)
        .font(.body.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(kind.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(kind.title)
        Text(kind.purpose)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      trailing
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("boltty.access.\(kind.rawValue)")
  }

  @ViewBuilder
  private var trailing: some View {
    if isAsking {
      ProgressView().controlSize(.small)
    } else {
      switch status {
      case .allowed:
        Image(systemName: "checkmark.circle.fill")
          .font(.title2)
          .foregroundStyle(.green)
          .help("Allowed")
          .transition(.scale.combined(with: .opacity))
      case .refused:
        Button("Open Settings…", action: action)
          .buttonStyle(.glass)
          .help("macOS asks only once — this opens the pane where it is changed")
      case .notAsked:
        Button("Allow", action: action)
          .buttonStyle(.glass)
      case nil:
        ProgressView().controlSize(.small)
      }
    }
  }
}

extension AccessKind {
  var symbol: String {
    switch self {
    case .dictation: "mic.fill"
    case .screen: "rectangle.dashed"
    case .notifications: "bell.badge.fill"
    case .finder: "folder.fill"
    }
  }

  var tint: Color {
    switch self {
    case .dictation: .orange
    case .screen: .purple
    case .notifications: .red
    case .finder: .blue
    }
  }
}

@MainActor
final class AccessPermissionsWindowController: NSWindowController, NSWindowDelegate {
  static let contentWidth: CGFloat = 440
  static let shownKey = "boltty.access.shown"

  let model: AccessPermissionsModel
  var onClose: (() -> Void)?

  init(probe: AccessProbe) {
    let model = AccessPermissionsModel(probe: probe)
    self.model = model
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: Self.contentWidth, height: 480)),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Boltty AI Access"
    window.identifier = NSUserInterfaceItemIdentifier("boltty.access.window")
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.tabbingMode = .disallowed
    window.isReleasedWhenClosed = false
    window.backgroundColor = SettingsSurfacePalette.background
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    super.init(window: window)
    window.delegate = self

    let hosting = NSHostingController(
      rootView: AccessPermissionsView(model: model, onDone: { [weak self] in self?.close() })
    )
    hosting.sizingOptions = [.preferredContentSize]
    window.contentViewController = hosting
    window.setContentSize(hosting.view.fittingSize)
    window.center()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show() {
    model.startWatching()
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    model.stopWatching()
    DispatchQueue.main.async { [weak self] in self?.onClose?() }
  }
}
