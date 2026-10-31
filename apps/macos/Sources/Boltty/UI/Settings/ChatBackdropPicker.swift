import AppKit
import SwiftUI

/// Settings › Agents › one agent: what its open chats wear behind the
/// transcript. A live preview of the choice over a mock chat, and the choices
/// as round stills under it, the way Messages offers its backgrounds. Both are
/// drawn in the agent's face colours, so changing the face recolours them.
/// Read back by the panel each time it lays out a chat.
struct ChatBackdropPicker: View {
  @ObservedObject var model: BolttyAISettingsModel
  let agent: AgentId
  @AppStorage private var stored: String
  /// Each pick pokes the face on the preview, so choosing feels answered.
  @State private var pokes = 0

  init(model: BolttyAISettingsModel, agent: AgentId) {
    self.model = model
    self.agent = agent
    _stored = AppStorage(wrappedValue: ChatBackdrop.standard.rawValue, ChatBackdrop.storageKey(for: agent))
  }

  private var chosen: ChatBackdrop { ChatBackdrop(rawValue: stored) ?? .standard }

  var body: some View {
    let look = model.mascotLook(for: agent)
    VStack(spacing: 16) {
      ChatBackdropPreview(backdrop: chosen, look: look, agentName: agent.shortDisplayName, pokes: pokes)
        .frame(height: 340)
        .accessibilityHidden(true)
      HStack(spacing: 18) {
        ForEach(ChatBackdrop.allCases) { backdrop in
          ChatBackdropChoice(backdrop: backdrop, palette: look.palette, isChosen: backdrop == chosen) {
            guard backdrop != chosen else { return }
            withAnimation(SettingsMotion.quick) { stored = backdrop.rawValue }
            pokes += 1
          }
          .accessibilityIdentifier("boltty.settings.chatBackdrop.\(agent.rawValue).\(backdrop.rawValue)")
        }
      }
      .frame(maxWidth: .infinity)
    }
    .padding(.vertical, 6)
  }
}

/// The chosen backdrop, moving, as the agent's own chat: its face and name at
/// the top, a question, and its answer — what an open chat will look like.
/// Scenes dissolve into one another rather than cut.
private struct ChatBackdropPreview: View {
  let backdrop: ChatBackdrop
  let look: MascotLook
  let agentName: String
  let pokes: Int

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
    ZStack {
      StandardBackdropFill()
      // One live view per scene, so the old one can fade out over the new
      // one fading in.
      ForEach([backdrop]) { scene in
        LiveBackdrop(backdrop: scene, palette: look.palette, corner: Self.corner)
          .transition(.opacity.animation(.easeInOut(duration: 0.6)))
      }
      chat.padding(.horizontal, 18).padding(.vertical, 14)
    }
    .clipShape(shape)
    .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    .overlay(alignment: .bottomLeading) { caption.padding(12) }
  }

  static let corner: CGFloat = 18

  private var exchange: (question: String, answer: String) {
    switch backdrop {
    case .standard:
      ("What's in this folder?",
       "Three Swift targets and a README. The app itself lives in Sources/Boltty.")
    case .sky:
      ("Is the release ready?",
       "Almost: two flaky tests and a changelog a day behind. Clear skies after that.")
    case .space:
      ("How big is this repo?",
       "About 1,900 files in 140 folders. Plenty of room out here.")
    case .matrix:
      ("Why does the build fail?",
       "A missing import in AgentBackdropView.swift. Follow the white rabbit to line 12.")
    }
  }

  /// The face takes a mood from its scene.
  private var emotion: MascotEmotion {
    switch backdrop {
    case .standard: .curious
    case .sky: .listening
    case .space: .thinking
    case .matrix: .focused
    }
  }

  private var chat: some View {
    VStack(spacing: 14) {
      VStack(spacing: 4) {
        MascotFace(look: look, emotion: emotion, pokes: pokes)
          .frame(width: 34, height: 34)
        Text(agentName)
          .font(BolttyInterfaceTypography.fixed(size: 11, weight: .semibold))
          .foregroundStyle(Color.white)
          .padding(.horizontal, 9)
          .padding(.vertical, 3)
          .background(Capsule().fill(Color.white.opacity(0.16)))
      }
      HStack {
        Spacer(minLength: 60)
        Text(exchange.question)
          .font(BolttyInterfaceTypography.fixed(size: 13))
          .foregroundStyle(Color.black)
          .padding(.horizontal, 12)
          .padding(.vertical, 7)
          .background(Capsule().fill(Color.white))
      }
      Text(exchange.answer)
        .font(BolttyInterfaceTypography.fixed(size: 13))
        .foregroundStyle(Color.white.opacity(0.92))
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 40)
      Spacer(minLength: 0)
    }
    .id(backdrop)
    .transition(.opacity)
  }

  /// Says where the colour comes from: the scene, in the face's gradient.
  private var caption: some View {
    Text(backdrop == .standard ? "Standard" : "\(backdrop.title) in \(look.palette.displayName)")
      .font(BolttyInterfaceTypography.fixed(size: 11, weight: .medium))
      .foregroundStyle(Color.white.opacity(0.85))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Capsule().fill(Color.black.opacity(0.35)))
      .contentTransition(.opacity)
  }
}

/// Standard is the shell's own glass under its black ramp; this stands in
/// for it here, and sits under every scene while one fades in.
private struct StandardBackdropFill: View {
  var body: some View {
    ZStack {
      Color.gray.opacity(0.45)
      LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
    }
  }
}

private struct ChatBackdropChoice: View {
  let backdrop: ChatBackdrop
  let palette: MascotPalette
  let isChosen: Bool
  let action: () -> Void
  @State private var isHovered = false
  @Environment(\.displayScale) private var displayScale

  private static let diameter: CGFloat = 56

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        thumbnail
          .frame(width: Self.diameter, height: Self.diameter)
          .clipShape(Circle())
          .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
          // The ring stands off the picture, as Messages' does.
          .padding(4)
          .overlay(
            Circle().strokeBorder(Color.accentColor, lineWidth: isChosen ? 2.5 : 0)
          )
          .scaleEffect(isHovered && !MotionPreferences.reduceMotion ? 1.06 : 1)
          .animation(.spring(duration: 0.3, bounce: 0.4), value: isHovered)
          .overlay(alignment: .bottomTrailing) {
            if isChosen {
              Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.accentColor)
                .font(BolttyInterfaceTypography.headline)
                .transition(.scale(scale: 0.4).combined(with: .opacity).animation(.spring(duration: 0.35, bounce: 0.5)))
            }
          }
        Text(backdrop.title)
          .font(BolttyInterfaceTypography.callout)
          .foregroundStyle(isChosen ? .primary : .secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(ChatBackdropChoiceStyle(isHovered: isHovered))
    .onHover { isHovered = $0 }
    .accessibilityLabel(backdrop.title)
    .accessibilityValue(isChosen ? "Selected" : "")
  }

  /// Still until the pointer is on it; then the scene moves, as a preview of
  /// the preview.
  @ViewBuilder
  private var thumbnail: some View {
    ZStack {
      still
      if isHovered, backdrop != .standard, !MotionPreferences.reduceMotion {
        LiveBackdrop(backdrop: backdrop, palette: palette, corner: 0, sceneScale: 0.215)
          // Twice as tall and pinned to the foot, so it moves the same lower
          // half the still shows.
          .frame(width: Self.diameter, height: Self.diameter * 2)
          .frame(width: Self.diameter, height: Self.diameter, alignment: .bottom)
          .transition(.opacity)
      }
    }
    .animation(SettingsMotion.quick, value: isHovered)
  }

  @ViewBuilder
  private var still: some View {
    if let image = AgentBackdropRenderer.still(
      of: backdrop, palette: palette, scene: 260, pixels: Self.diameter * displayScale
    ) {
      Image(decorative: image, scale: displayScale)
        .resizable()
        .interpolation(.high)
    } else {
      StandardBackdropFill()
    }
  }
}

private struct ChatBackdropChoiceStyle: ButtonStyle {
  let isHovered: Bool

  func makeBody(configuration: Configuration) -> some View {
    let isPressed = configuration.isPressed
    configuration.label
      .scaleEffect(
        isPressed && !MotionPreferences.reduceMotion ? AgentPaletteMetrics.controlPressedScale : 1
      )
      .brightness(isHovered && !isPressed ? 0.04 : 0)
      .animation(SettingsMotion.press, value: isPressed)
  }
}

/// `AgentBackdropView` outside the panel: laid out at its host's bounds, with
/// its own corner.
private struct LiveBackdrop: NSViewRepresentable {
  let backdrop: ChatBackdrop
  let palette: MascotPalette
  let corner: CGFloat
  /// Below 1, a small view shows more of the scene: the thumbnails.
  var sceneScale: CGFloat = 1

  func makeNSView(context: Context) -> LiveBackdropHost {
    LiveBackdropHost(corner: corner, sceneScale: sceneScale)
  }

  func updateNSView(_ host: LiveBackdropHost, context: Context) {
    host.view.show(backdrop, palette: palette)
    host.needsLayout = true
  }
}

final class LiveBackdropHost: NSView {
  let view = AgentBackdropView(frame: .zero)
  private let corner: CGFloat

  init(corner: CGFloat, sceneScale: CGFloat) {
    self.corner = corner
    super.init(frame: .zero)
    view.sceneScale = sceneScale
    addSubview(view)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    view.layOut(in: bounds, corner: corner, curve: .continuous)
  }
}
