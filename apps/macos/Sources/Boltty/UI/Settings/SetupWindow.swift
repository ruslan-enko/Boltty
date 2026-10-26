import AppKit
import SwiftUI

/// **The first run's setup**: one card of steps —
/// which agents, which faces, which keys, what Boltty may reach — after the
/// show, on its sunset. Laid out as Dia's welcome card: which step of how
/// many, a title and two short lines on the left with the buttons under
/// them, and on the right the thing being chosen, drawn rather than
/// described. Every choice is the one Settings holds, made through the same
/// model; nothing here is stored apart.
enum SetupStep: Int, CaseIterable {
  case agents, mascots, keys, access

  var title: String {
    switch self {
    case .agents: "Meet your agents"
    case .mascots: "Give them faces"
    case .keys: "Your keys"
    case .access: "Almost there"
    }
  }

  /// Two lines, each written to fit the column whole — a word left alone
  /// on a line of its own reads as a mistake. The first is said brighter.
  var subtitle: [(String, Bool)] {
    switch self {
    case .agents: [("The agents already on your Mac.", true), ("\nPick the ones Boltty AI may use.", false)]
    case .mascots: [("Every agent wears its own.", true), ("\nClick one to restyle it.", false)]
    case .keys: [("One chord opens Boltty AI.", true), ("\nHold three to ask about the screen.", false)]
    case .access: [("macOS asks for each once.", true), ("\nYou can change them any time.", false)]
    }
  }

  var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
  var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }
}

struct SetupView: View {
  @ObservedObject var model: BolttyAISettingsModel
  @ObservedObject var access: AccessPermissionsModel
  var onFaceHover: (Int) -> Void = { _ in }
  var onFinish: () -> Void
  @State private var step: SetupStep = Self.firstStep
  @State private var forward = true

  static let padding: CGFloat = 40

  /// A Debug build opens on `-boltty.setup.step N`, to photograph a step.
  private static var firstStep: SetupStep {
    #if DEBUG
    return SetupStep(rawValue: UserDefaults.standard.integer(forKey: "boltty.setup.step")) ?? .agents
    #else
    return .agents
    #endif
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
  }

  // MARK: The left: what this is, what next

  private var words: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        // Which step of how many, in words.
        Text("Step \(step.rawValue + 1) of \(SetupStep.allCases.count)")
          .font(.system(size: 13, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .padding(.bottom, -6)
        Text(step.title)
          .font(.system(size: 32, weight: .semibold, design: .rounded))
        step.subtitle.reduce(Text("")) { text, part in
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
      if let next = step.next {
        Button { go(to: next) } label: { SetupButtonLabel(title: "Continue") }
          .buttonStyle(.glassProminent)
          .controlSize(.extraLarge)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("boltty.setup.continue")
      } else if access.hasSomethingToAsk {
        Button { access.allowAll() } label: { SetupButtonLabel(title: "Allow All") }
          .buttonStyle(.glassProminent)
          .controlSize(.extraLarge)
          .keyboardShortcut(.defaultAction)
          .disabled(access.asking != nil)
        Button("Not Now", action: onFinish)
          .buttonStyle(.glass)
          .controlSize(.extraLarge)
      } else {
        Button(action: onFinish) { SetupButtonLabel(title: "Let’s Go") }
          .buttonStyle(.glassProminent)
          .controlSize(.extraLarge)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("boltty.setup.finish")
      }
      if let previous = step.previous {
        Button("Back") { go(to: previous) }
          .buttonStyle(.glass)
          .controlSize(.extraLarge)
          .keyboardShortcut(.cancelAction)
      }
    }
  }

  // MARK: The right: the thing being chosen

  @ViewBuilder
  private func visual(for step: SetupStep) -> some View {
    switch step {
    case .agents: SetupAgentsVisual(model: model, onFaceHover: onFaceHover)
    case .mascots: SetupMascotsVisual(model: model, onFaceHover: onFaceHover)
    case .keys: SetupKeysVisual(model: model)
    case .access: SetupAccessVisual(model: access)
    }
  }

  private func go(to target: SetupStep) {
    forward = target.rawValue > step.rawValue
    withAnimation(SettingsMotion.arrival) { step = target }
  }
}

/// A button's words with the key that presses it, as Dia's "Let's Go ↵".
private struct SetupButtonLabel: View {
  let title: String

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
      Text("↵").opacity(0.7)
    }
    .padding(.horizontal, 6)
  }
}

/// A rounded tile of the card's own glass, lit when chosen.
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
      .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .strokeBorder(.white.opacity(isOn ? 0.18 : 0.06), lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }
}

// MARK: - Agents

private struct SetupAgentsVisual: View {
  @ObservedObject var model: BolttyAISettingsModel
  let onFaceHover: (Int) -> Void

  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
      ForEach(Array(model.adapterRows.enumerated()), id: \.element.id) { index, row in
        SetupAgentTile(model: model, row: row, onHover: { onFaceHover(index) })
          .frame(height: 140)
      }
    }
  }
}

/// An agent: its face in colour while it is on, grey while it is off, and
/// which one a new prompt starts on said under its name — the others offer
/// it under the pointer.
private struct SetupAgentTile: View {
  @ObservedObject var model: BolttyAISettingsModel
  let row: AgentSettingsRow
  let onHover: () -> Void
  @State private var isHovered = false
  @State private var pokes = 0
  @State private var identity = UUID()

  private var isOn: Bool { row.enabled && row.isReady }
  private var isDefault: Bool { isOn && model.defaultAgent == row.agent }

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
        ZStack { footnote }.frame(height: 20)
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
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(row.agent.displayName)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityIdentifier("boltty.setup.agent.\(row.agent.rawValue)")
  }

  @ViewBuilder
  private var footnote: some View {
    if !row.isReady {
      Text("Not installed")
        .font(.system(size: 12, design: .rounded))
        .foregroundStyle(.tertiary)
    } else if isDefault {
      Text("Starts here")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(.white.opacity(0.2), in: Capsule())
    } else if isOn && isHovered {
      Button("Start here") { model.defaultAgent = row.agent }
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

// MARK: - Mascots

/// The faces in a pile, as the show had them, each its own picker.
private struct SetupMascotsVisual: View {
  @ObservedObject var model: BolttyAISettingsModel
  let onFaceHover: (Int) -> Void

  private var agents: [AgentId] {
    model.enabledAdapters.isEmpty ? AgentHistory.tabOrder : model.enabledAdapters
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
            // The pile's y runs up; SwiftUI's runs down.
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

// MARK: - Keys

private struct SetupKeysVisual: View {
  @ObservedObject var model: BolttyAISettingsModel
  @State private var hoveredHotkey = false

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
          isRowHovered: hoveredHotkey,
          probe: model.probeHotkey ?? { _ in .free },
          problem: $model.hotkeyProblem,
          onRecord: { model.bolttyAIHotkey = $0 },
          onRestoreDefault: { model.bolttyAIHotkey = .optionSpace }
        )
      } note: {
        if let problem = model.hotkeyProblem { SettingsNote(problem.message, color: .orange) }
      }
      .onHover { hoveredHotkey = $0 }

      SetupKeysTile(caps: ["⌃", "⌥", "⌘"], isOn: model.askBolttyEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Ask Boltty").font(.system(size: 14, weight: .semibold, design: .rounded))
          Text("Hold, ask about the screen, let go.")
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Toggle("Ask Boltty", isOn: Binding(
          get: { model.askBolttyEnabled }, set: { model.askBolttyEnabled = $0 }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityIdentifier("boltty.setup.askBoltty")
      } note: {
        if model.askBolttyNeedsInputMonitoring {
          SettingsNote("It needs Input Monitoring — macOS asks for it now.", color: .orange)
        }
      }
    }
  }
}

/// The keys in the middle of the tile, what they do along its foot.
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

/// Keys drawn as keys, on glass.
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

// MARK: - Access

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
        SettingsNote("Screen Recording takes effect once Boltty is opened again.")
      }
    }
  }
}

/// A permission: its icon, its name and where it stands, each on a line of
/// its own height, so the four tiles line up.
private struct SetupAccessTile: View {
  let kind: AccessKind
  let status: AccessStatus?
  let isAsking: Bool
  let action: () -> Void

  var body: some View {
    SetupTile(isOn: status == .allowed) {
      VStack(spacing: 10) {
        Image(systemName: kind.symbol)
          .font(.system(size: 22, weight: .semibold))
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

// MARK: - Window

/// A borderless window can take the keys only if it says so.
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
  /// The pointer came onto agent `index`'s face.
  var onFaceHover: ((Int) -> Void)?

  init(model: BolttyAISettingsModel, access: AccessPermissionsModel) {
    self.access = access
    let window = SetupCardWindow(
      contentRect: NSRect(origin: .zero, size: Self.contentSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.title = "Set Up Boltty AI"
    window.identifier = NSUserInterfaceItemIdentifier("boltty.setup.window")
    window.isMovableByWindowBackground = true
    window.tabbingMode = .disallowed
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    // The system's shadow of a borderless window is cut from its
    // rectangle and drew a hard edge round the glass's corners.
    window.hasShadow = false
    // White words on glass over the sunset, whatever the system says.
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
    // The panel's own glass host, the card's words beside the glass rather
    // than in it: an `NSGlassEffectView` holding the SwiftUI view, as the
    // window's content or inside it, showed a faint square-cornered
    // rectangle round the rounded glass; the panel's host does not.
    let container = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
    container.wantsLayer = true
    container.layer?.cornerRadius = Self.cornerRadius
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    let glass = PaletteGlassHost(content: hosting, cornerRadius: Self.cornerRadius, style: .bolttyAI)
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

  /// In the middle of `screen` — the one the show played on — exactly.
  func show(on screen: NSScreen? = nil) {
    access.startWatching()
    if let window, let screen = screen ?? NSScreen.main {
      let frame = screen.frame
      window.setFrameOrigin(NSPoint(x: (frame.midX - window.frame.width / 2).rounded(),
                                    y: (frame.midY - window.frame.height / 2).rounded()))
    }
    NSApp.activate(ignoringOtherApps: true)
    // Only the sunset and the card, as a setup assistant: the menu bar and
    // the Dock come back when the card closes.
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
