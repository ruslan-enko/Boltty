import AppKit
import SwiftUI

enum SetupStep: Int, CaseIterable {
  case agents, mascots, keys, voice, access

  var title: String {
    switch self {
    case .agents: String(localized: "Meet your agents")
    case .mascots: String(localized: "Give them faces")
    case .keys: String(localized: "Your keys")
    case .voice: String(localized: "Your voice")
    case .access: String(localized: "Almost there")
    }
  }

  var subtitle: [(String, Bool)] {
    switch self {
    case .agents: [(String(localized: "The agents already on your Mac."), true), (String(localized: "\nPick the ones Boltty AI may use."), false)]
    case .mascots: [(String(localized: "Every agent wears its own."), true), (String(localized: "\nClick one to restyle it."), false)]
    case .keys: [(String(localized: "One chord opens Boltty AI."), true), (String(localized: "\nThen drag across the screen to ask about it."), false)]
    case .voice: [(String(localized: "Boltty listens with Apple’s dictation."), true), (String(localized: "\nAdd natural voices that run on this Mac."), false)]
    case .access: [(String(localized: "macOS asks for each once."), true), (String(localized: "\nYou can change them any time."), false)]
    }
  }

  static func steps(hasNoAgents: Bool) -> [SetupStep] {
    hasNoAgents ? allCases.filter { $0 != .mascots } : allCases
  }
}

struct SetupView: View {
  @ObservedObject var model: BolttyAISettingsModel
  @ObservedObject var access: AccessPermissionsModel
  var onFaceHover: (Int) -> Void = { _ in }
  var onFinish: () -> Void
  @State private var step: SetupStep = Self.firstStep
  @State private var forward = true
  @FocusState private var primaryFocused: Bool

  static let padding: CGFloat = 40

  private static var firstStep: SetupStep {
    #if DEBUG
    return SetupStep(rawValue: UserDefaults.standard.integer(forKey: "boltty.setup.step")) ?? .agents
    #else
    return .agents
    #endif
  }

  private var steps: [SetupStep] { SetupStep.steps(hasNoAgents: model.hasNoAgents) }
  private var index: Int { steps.firstIndex(of: step) ?? 0 }
  private var next: SetupStep? { steps.indices.contains(index + 1) ? steps[index + 1] : nil }
  private var previous: SetupStep? { index > 0 ? steps[index - 1] : nil }
  private var asksForAgent: Bool { step == .agents && model.hasNoAgents }
  private var title: String {
    asksForAgent ? String(localized: "Boltty needs an agent") : step.title
  }
  private var subtitle: [(String, Bool)] {
    guard asksForAgent else { return step.subtitle }
    return [
      (String(localized: "None of these is on your Mac yet."), true),
      (String(localized: "\nInstall one and sign in to it, and Boltty has someone to ask."), false),
    ]
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 36) {
        words.frame(width: 290, alignment: .leading)

        ZStack {
          visual(for: step)
            .id(step)
            .transition(.asymmetric(
              insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
              removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
    }
    .padding(Self.padding)
    .frame(width: SetupWindowController.contentSize.width, height: SetupWindowController.contentSize.height)
    .bolttyInterfaceTypography()
    .task { await model.refreshAgents() }
    .onAppear { primaryFocused = true }
    .onChange(of: step) { primaryFocused = true }
    .onChange(of: access.hasSomethingToAsk) { DispatchQueue.main.async { primaryFocused = true } }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      guard step == .agents, model.adapterRows.contains(where: { !$0.isReady }) else { return }
      Task { await model.refreshAgents() }
    }
  }

  private var words: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        Text("Step \(index + 1) of \(steps.count)")
          .font(.system(size: 13, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .padding(.bottom, -6)
        Text(title)
          .font(.system(size: 32, weight: .semibold, design: .rounded))
        subtitle.reduce(Text(verbatim: "")) { text, part in
          text + Text(part.0).foregroundStyle(part.1 ? .primary : .secondary)
        }
        .font(.system(size: 15, design: .rounded))
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
      }
      .id(step)
      .transition(.opacity)

      Spacer(minLength: 20)

      buttons
    }
    .frame(maxHeight: .infinity)
  }

  private var buttons: some View {
    HStack(spacing: 10) {
      if asksForAgent, let next {
        Button("Not Now") { go(to: next) }
          .buttonStyle(.glass)
          .controlSize(.extraLarge)
          .accessibilityIdentifier("boltty.setup.continue")
      } else if let next {
        Button { go(to: next) } label: { SetupButtonLabel(title: String(localized: "Continue")) }
          .bolttyProminentButton()
          .controlSize(.extraLarge)
          .keyboardShortcut(.defaultAction)
          .focused($primaryFocused)
          .focusEffectDisabled()
          .accessibilityIdentifier("boltty.setup.continue")
      } else if access.hasSomethingToAsk {
        Button { access.allowAll() } label: { SetupButtonLabel(title: String(localized: "Allow All")) }
          .bolttyProminentButton()
          .controlSize(.extraLarge)
          .keyboardShortcut(.defaultAction)
          .focused($primaryFocused)
          .focusEffectDisabled()
          .disabled(access.asking != nil)
        Button("Not Now", action: finish)
          .buttonStyle(.glass)
          .controlSize(.extraLarge)
      } else {
        Button(action: finish) { SetupButtonLabel(title: String(localized: "Let’s Go")) }
          .bolttyProminentButton()
          .controlSize(.extraLarge)
          .keyboardShortcut(.defaultAction)
          .focused($primaryFocused)
          .focusEffectDisabled()
          .accessibilityIdentifier("boltty.setup.finish")
      }
      if let previous {
        Button("Back") { go(to: previous) }
          .buttonStyle(.glass)
          .controlSize(.extraLarge)
          .keyboardShortcut(.cancelAction)
      }
    }
  }

  @ViewBuilder
  private func visual(for step: SetupStep) -> some View {
    switch step {
    case .agents: SetupAgentsVisual(model: model, onFaceHover: onFaceHover)
    case .mascots: SetupMascotsVisual(model: model, onFaceHover: onFaceHover)
    case .keys: SetupKeysVisual(model: model)
    case .voice: SetupVoiceVisual(model: model)
    case .access: SetupAccessVisual(model: access)
    }
  }

  private func finish() {
    model.installSetupVoices()
    onFinish()
  }

  private func go(to target: SetupStep) {
    forward = target.rawValue > step.rawValue
    withAnimation(SettingsMotion.arrival) { step = target }
  }
}

private struct SetupButtonLabel: View {
  let title: String

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
      Text(verbatim: "↵").opacity(0.7)
    }
    .padding(.horizontal, 6)
  }
}

private struct SetupTile<Content: View>: View {
  var isOn = true
  var isHovered = false
  @ViewBuilder var content: Content

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(.white.opacity(isOn ? (isHovered ? 0.17 : 0.12) : (isHovered ? 0.07 : 0.04)))
      )
      .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }
}

private struct SetupAgentsVisual: View {
  @ObservedObject var model: BolttyAISettingsModel
  let onFaceHover: (Int) -> Void
  @State private var hovered: AgentId?

  private var installable: [AgentSettingsRow] { model.adapterRows.filter { $0.install != nil } }

  private var note: String {
    let row = installable.first { $0.agent == hovered }
      ?? installable.first { $0.install?.failure != nil }
    if let failure = row?.install?.failure {
      return String(localized: "\(row?.agent.displayName ?? "") was not installed: \(failure)")
    }
    return String(localized: "Install runs the agent’s own installer. You sign in to it afterwards.")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      grid
      if !installable.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text(note)
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(2)
          if let install = installable.first(where: { $0.agent == hovered })?.install {
            Text(verbatim: install.command)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
        .padding(.horizontal, 6)
      }
    }
  }

  private var grid: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
      ForEach(Array(model.adapterRows.enumerated()), id: \.element.id) { index, row in
        SetupAgentTile(model: model, row: row, onHover: { onFaceHover(index) })
          .onHover { inside in
            if inside { hovered = row.agent } else if hovered == row.agent { hovered = nil }
          }
          .frame(height: 140)
      }
    }
  }
}

private struct SetupAgentTile: View {
  @ObservedObject var model: BolttyAISettingsModel
  let row: AgentSettingsRow
  let onHover: () -> Void
  @State private var isHovered = false
  @State private var pokes = 0
  @State private var identity = UUID()

  private var isOn: Bool { row.enabled && row.isReady }
  private var isDefault: Bool { isOn && offersDefault && !model.routesAutomatically && model.defaultAgent == row.agent }
  private var offersDefault: Bool { model.adapterRows.filter { $0.enabled && $0.isReady }.count > 1 }

  var body: some View {
    SetupTile(isOn: isOn, isHovered: isHovered) {
      VStack(spacing: 8) {
        MascotFace(look: model.mascotLook(for: row.agent), identity: identity, ownsDisplayLink: true, pokes: pokes,
                   renderScale: 1.5)
          .frame(width: 62, height: 62)
          .saturation(isOn ? 1 : 0)
          .opacity(isOn ? 1 : 0.45)
        Text(row.agent.shortDisplayName)
          .font(.system(size: 15, weight: .semibold, design: .rounded))
          .foregroundStyle(isOn ? .primary : .secondary)
        ZStack { footnote }.frame(height: 22)
      }
    }
    .onTapGesture {
      guard row.isReady else { return }
      withAnimation(SettingsMotion.quick) { model.setEnabled(!row.enabled, for: row.agent) }
    }
    .onHover { hovering in
      withAnimation(SettingsMotion.quick) { isHovered = hovering }
      guard hovering, isOn else { return }
      pokes += 1
      onHover()
    }
    .animation(SettingsMotion.quick, value: isOn)
    .contextMenu {
      if let install = row.install { CopyCommandButton(command: install.command) }
    }
    .accessibilityElement(children: row.install == nil ? .combine : .contain)
    .accessibilityAddTraits(row.install == nil ? .isButton : [])
    .accessibilityLabel(row.agent.displayName)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityIdentifier("boltty.setup.agent.\(row.agent.rawValue)")
  }

  @ViewBuilder
  private var footnote: some View {
    if let install = row.install {
      AgentInstallButton(model: model, agent: row.agent, install: install)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    } else if !row.isReady {
      Text(row.needsLogin ? String(localized: "Signed out") : row.status)
        .font(.system(size: 12, design: .rounded))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .help(row.status)
    } else if isDefault {
      Button("Starts here") { model.sendNewChats(to: nil) }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(.white.opacity(0.2), in: Capsule())
    } else if isOn && isHovered && offersDefault {
      Button("Start here") { model.sendNewChats(to: row.agent) }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(.white.opacity(0.08), in: Capsule())
        .transition(.opacity)
    }
  }
}

private struct SetupMascotsVisual: View {
  @ObservedObject var model: BolttyAISettingsModel
  let onFaceHover: (Int) -> Void

  private var agents: [AgentId] {
    let here = model.adapterRows.filter { $0.enabled && $0.isInstalled }.map(\.agent)
    return here.isEmpty ? AgentHistory.tabOrder : here
  }

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      let spots = FirstRunShowController.pileFrames(
        count: agents.count, center: CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2),
        side: side * 0.82
      )
      ZStack {
        ForEach(Array(zip(agents, spots).enumerated()), id: \.element.0) { index, pair in
          let (agent, spot) = pair
          SetupMascotFace(model: model, agent: agent, side: spot.frame.width * 0.8,
                          onHover: { onFaceHover(index) })
            .rotationEffect(.radians(-spot.tilt))
            .position(x: spot.frame.midX, y: proxy.size.height - spot.frame.midY)
            .zIndex(spot.frame.width)
        }
      }
    }
  }
}

private struct SetupMascotFace: View {
  @ObservedObject var model: BolttyAISettingsModel
  let agent: AgentId
  let side: CGFloat
  let onHover: () -> Void
  @State private var isOpen = false
  @State private var isHovered = false
  @State private var pokes = 0
  @State private var identity = UUID()

  var body: some View {
    let look = model.mascotLook(for: agent)
    Button { isOpen.toggle() } label: {
      VStack(spacing: 4) {
        MascotFace(look: look, identity: identity, ownsDisplayLink: true, pokes: pokes, renderScale: 1.25)
          .frame(width: side, height: side)
          .scaleEffect(isHovered || isOpen ? 1.06 : 1)
        Text(agent.shortDisplayName)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(.black.opacity(0.28), in: Capsule())
          .opacity(isHovered || isOpen ? 1 : 0.85)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(SettingsPressStyle())
    .focusEffectDisabled()
    .onHover { hovering in
      isHovered = hovering
      guard hovering else { return }
      pokes += 1
      onHover()
    }
    .animation(SettingsMotion.quick, value: isHovered)
    .popover(isPresented: $isOpen, arrowEdge: .bottom) {
      MascotPickerView(model: model, agent: agent)
    }
    .accessibilityLabel("Mascot for \(agent.displayName)")
    .accessibilityValue(look.displayName)
    .accessibilityIdentifier("boltty.setup.mascot.\(agent.rawValue)")
  }
}

private struct SetupKeysVisual: View {
  @ObservedObject var model: BolttyAISettingsModel

  private var hotkeyCaps: [String] {
    let binding = model.bolttyAIHotkey
    let modifiers = HotkeyBinding.modifierSymbols(binding.carbonModifiers).map(String.init)
    return binding.isModifierOnly ? modifiers : modifiers + [HotkeyBinding.keyLabel(for: binding.keyCode)]
  }

  var body: some View {
    VStack(spacing: 12) {
      SetupKeysTile(caps: hotkeyCaps, isOn: true) {
        Text("Opens Boltty AI").font(.system(size: 14, weight: .semibold, design: .rounded))
        Spacer(minLength: 8)
        HotkeyRecorderField(
          binding: model.bolttyAIHotkey,
          isEnabled: model.bolttyAIHotkeyEnabled,
          probe: model.probeHotkey ?? { _ in .free },
          problem: $model.hotkeyProblem,
          onRecord: { model.bolttyAIHotkey = $0 },
          onRestoreDefault: { model.bolttyAIHotkey = .optionSpace }
        )
      } note: {
        if let problem = model.hotkeyProblem { SettingsNote(problem.message, color: .orange) }
      }
    }
  }
}

private struct SetupKeysTile<Row: View, Note: View>: View {
  let caps: [String]
  let isOn: Bool
  @ViewBuilder var row: Row
  @ViewBuilder var note: Note

  var body: some View {
    SetupTile(isOn: isOn) {
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        SetupKeycaps(caps: caps).opacity(isOn ? 1 : 0.5)
        Spacer(minLength: 0)
        HStack(spacing: 10) { row }
        note
      }
      .padding(18)
    }
  }
}

private struct SetupKeycaps: View {
  let caps: [String]

  var body: some View {
    HStack(spacing: 10) {
      ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
        Text(cap)
          .font(.system(size: cap.count > 1 ? 17 : 24, weight: .medium, design: .rounded))
          .frame(minWidth: 54, minHeight: 54)
          .padding(.horizontal, cap.count > 1 ? 14 : 0)
          .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          .contentTransition(.opacity)
      }
    }
    .animation(SettingsMotion.quick, value: caps)
  }
}

private struct SetupAccessVisual: View {
  @ObservedObject var model: AccessPermissionsModel

  var body: some View {
    VStack(spacing: 12) {
      Grid(horizontalSpacing: 12, verticalSpacing: 12) {
        ForEach(0..<2, id: \.self) { line in
          GridRow {
            ForEach(Array(model.kinds.dropFirst(line * 2).prefix(2)), id: \.self) { kind in
              SetupAccessTile(kind: kind, status: model.statuses[kind], isAsking: model.asking == kind) {
                model.act(on: kind)
              }
            }
          }
        }
      }
      if model.statuses[.screen] == .refused {
        SettingsNote(String(localized: "Screen Recording takes effect once Boltty is opened again."))
      }
    }
  }
}

private struct SetupAccessTile: View {
  let kind: AccessKind
  let status: AccessStatus?
  let isAsking: Bool
  let action: () -> Void

  var body: some View {
    SetupTile(isOn: status == .allowed) {
      VStack(spacing: 10) {
        BolttyIconView(icon: kind.icon, size: 28)
          .foregroundStyle(.white)
          .frame(width: 48, height: 48)
          .background(kind.tint.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        Text(kind.title)
          .font(.system(size: 15, weight: .semibold, design: .rounded))
          .frame(height: 20)
        trailing.frame(height: 26)
      }
    }
    .help(kind.purpose)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("boltty.access.\(kind.rawValue)")
  }

  @ViewBuilder
  private var trailing: some View {
    if isAsking || status == nil {
      ProgressView().controlSize(.small)
    } else {
      switch status {
      case .allowed:
        Text("Allowed")
          .font(.system(size: 12, design: .rounded))
          .foregroundStyle(.secondary)
          .transition(.opacity)
      case .refused:
        Button("Open Settings…", action: action)
          .buttonStyle(.glass)
          .controlSize(.small)
      default:
        Button("Allow", action: action)
          .buttonStyle(.glass)
          .controlSize(.small)
      }
    }
  }
}

private final class SetupCardWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
  static let contentSize = NSSize(width: 880, height: 540)
  static let cornerRadius: CGFloat = 34

  let access: AccessPermissionsModel
  var onClose: (() -> Void)?
  var onFaceHover: ((Int) -> Void)?

  init(model: BolttyAISettingsModel, access: AccessPermissionsModel) {
    self.access = access
    let window = SetupCardWindow(
      contentRect: NSRect(origin: .zero, size: Self.contentSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.title = String(localized: "Set Up Boltty AI")
    window.identifier = NSUserInterfaceItemIdentifier("boltty.setup.window")
    window.isMovableByWindowBackground = true
    window.tabbingMode = .disallowed
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.appearance = NSAppearance(named: .darkAqua)
    super.init(window: window)
    window.delegate = self

    let hosting = NSHostingView(
      rootView: SetupView(
        model: model, access: access,
        onFaceHover: { [weak self] index in self?.onFaceHover?(index) },
        onFinish: { [weak self] in self?.close() }
      )
    )
    hosting.sizingOptions = []
    let container = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
    container.wantsLayer = true
    container.layer?.cornerRadius = Self.cornerRadius
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    let glass = PaletteGlassHost(content: hosting, cornerRadius: Self.cornerRadius, style: .bolttyAIPrompt)
    glass.translatesAutoresizingMaskIntoConstraints = true
    glass.frame = container.bounds
    glass.autoresizingMask = [.width, .height]
    container.addSubview(glass)
    window.contentView = container
    window.setContentSize(Self.contentSize)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show(on screen: NSScreen? = nil) {
    access.startWatching()
    if let window, let screen = screen ?? NSScreen.main {
      let frame = screen.frame
      window.setFrameOrigin(NSPoint(x: (frame.midX - window.frame.width / 2).rounded(),
                                    y: (frame.midY - window.frame.height / 2).rounded()))
    }
    NSApp.activate(ignoringOtherApps: true)
    NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.presentationOptions = []
    access.stopWatching()
    DispatchQueue.main.async { [weak self] in self?.onClose?() }
  }
}

private struct SetupVoiceVisual: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    VStack(spacing: 12) {
      SetupVoiceTile(
        model: model, id: .parakeetUltra, icon: .mic, title: String(localized: "Natural dictation"),
        detail: String(localized: "Parakeet hears Ukrainian, English and 23 more, even mixed in one sentence."))
      SetupVoiceTile(
        model: model, id: .supertonic3, icon: .speaker, title: String(localized: "Natural voice"),
        detail: String(localized: "Supertonic reads answers aloud in 31 languages."))
      Text(summary)
        .font(.system(size: 12, design: .rounded))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
  }

  private var summary: String {
    let chosen = LocalVoiceCatalog.all.filter { model.setupVoices.contains($0.id) }
    guard !chosen.isEmpty else { return String(localized: "Nothing is downloaded. Both can be added later in Settings › Voice.") }
    let bytes = chosen.reduce(Int64(0)) { $0 + $1.size }
    let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    return String(localized: "\(size) downloads from Hugging Face after setup.")
  }
}

private struct SetupVoiceTile: View {
  @ObservedObject var model: BolttyAISettingsModel
  let id: LocalVoiceModel.ID
  let icon: BolttyIcon
  let title: String
  let detail: String
  @State private var isHovered = false

  private var isOn: Bool { model.setupVoices.contains(id) }
  private var isHere: Bool { model.modelState(id) == .ready }

  var body: some View {
    SetupTile(isOn: isOn || isHere, isHovered: isHovered) {
      HStack(spacing: 14) {
        BolttyIconView(icon: icon, size: 28)
          .frame(width: 36)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
          Text(detail)
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(isHere ? String(localized: "On this Mac") : model.modelSize(id))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 8)
        BolttyIconView(icon: isOn || isHere ? .checkCircle : .circle, size: 24)
          .foregroundStyle(isOn || isHere ? .primary : .tertiary)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)
    }
    .fixedSize(horizontal: false, vertical: true)
    .onTapGesture {
      guard !isHere else { return }
      withAnimation(SettingsMotion.quick) { model.toggleSetupVoice(id) }
    }
    .onHover { hovering in withAnimation(SettingsMotion.quick) { isHovered = hovering } }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(title)
    .accessibilityValue(isOn || isHere ? "On" : "Off")
    .accessibilityIdentifier("boltty.setup.voice.\(id.rawValue)")
  }
}
