import AppKit
import SwiftUI

struct ChatBackdropPicker: View {
  @ObservedObject var model: BolttyAISettingsModel
  let agent: AgentId
  @AppStorage private var stored: String

  init(model: BolttyAISettingsModel, agent: AgentId) {
    self.model = model
    self.agent = agent
    _stored = AppStorage(wrappedValue: ChatBackdrop.standard.rawValue, ChatBackdrop.storageKey(for: agent))
  }

  private var chosen: ChatBackdrop { ChatBackdrop(rawValue: stored) ?? .standard }

  var body: some View {
    let palette = model.mascotLook(for: agent).palette
    HStack(spacing: 28) {
      ForEach(ChatBackdrop.allCases) { backdrop in
        RingedChoice(title: backdrop.title, isChosen: backdrop == chosen, diameter: BackdropWindow.diameter) {
          withAnimation(SettingsMotion.quick) { stored = backdrop.rawValue }
        } picture: { _ in
          BackdropWindow(backdrop: backdrop, palette: palette, isLive: backdrop == chosen)
        }
        .accessibilityIdentifier("boltty.settings.chatBackdrop.\(agent.rawValue).\(backdrop.rawValue)")
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
  }
}

private struct BackdropWindow: View {
  let backdrop: ChatBackdrop
  let palette: MascotPalette
  let isLive: Bool
  @Environment(\.displayScale) private var displayScale

  static let diameter: CGFloat = 84
  private static let scene: CGFloat = 260

  var body: some View {
    ZStack {
      if let still = AgentBackdropRenderer.still(
        of: backdrop, palette: palette, scene: Self.scene, pixels: Self.diameter * displayScale
      ) {
        Image(decorative: still, scale: displayScale)
          .resizable()
          .interpolation(.high)
      } else {
        Color.gray.opacity(0.45)
        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
      }
      if isLive, backdrop != .standard, !MotionPreferences.reduceMotion {
        LiveBackdrop(backdrop: backdrop, palette: palette, sceneScale: Self.diameter / Self.scene)
      }
    }
    .clipShape(Circle())
  }
}

private struct LiveBackdrop: NSViewRepresentable {
  let backdrop: ChatBackdrop
  let palette: MascotPalette
  let sceneScale: CGFloat

  func makeNSView(context: Context) -> LiveBackdropHost {
    LiveBackdropHost(sceneScale: sceneScale)
  }

  func updateNSView(_ host: LiveBackdropHost, context: Context) {
    host.view.show(backdrop, palette: palette)
  }
}

private final class LiveBackdropHost: NSView {
  let view = AgentBackdropView(frame: .zero)

  init(sceneScale: CGFloat) {
    super.init(frame: .zero)
    clipsToBounds = true
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
    let scene = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 2)
    view.layOut(in: scene, corner: 0, curve: .continuous)
  }
}
