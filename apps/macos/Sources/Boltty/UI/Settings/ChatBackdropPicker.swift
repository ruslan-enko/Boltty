import AppKit
import SwiftUI

struct ChatBackdropPicker: View {
  @ObservedObject var model: BolttyAISettingsModel
  @AppStorage(ChatBackdrop.storageKey) private var stored = ChatBackdrop.standard.rawValue

  private var chosen: ChatBackdrop { ChatBackdrop(rawValue: stored) ?? .standard }

  var body: some View {
    let look = model.mascotLook(for: model.mascotRoster.restingAgent)
    VStack(alignment: .leading, spacing: 12) {
      LabeledContent {
        SettingsSegments(
          title: "Backdrop",
          options: ChatBackdrop.allCases.map { ($0, $0.title) },
          selection: Binding(get: { chosen }, set: { stored = $0.rawValue }),
          icon: { AnyView(BackdropSwatch(backdrop: $0, palette: look.palette)) }
        )
        .accessibilityIdentifier("boltty.settings.backdrop")
      } label: {
        Text("Backdrop")
        Text("Behind the chat list and open chats, for every agent, in the colours of the face shown. The list's All tab wears it in greys.")
      }
      SettingsStage(width: nil, height: 320, corner: SettingsStageMetrics.fillingCorner) {
        ChatBackdropSample(backdrop: chosen, look: look, clearGlass: model.panelClearGlass)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(ChatBackdropSampleView.margin)
      }
    }
    .padding(.vertical, 6)
  }
}

/// The backdrop's own still in a dot, as a segment's icon.
private struct BackdropSwatch: View {
  let backdrop: ChatBackdrop
  let palette: MascotPalette
  @Environment(\.displayScale) private var displayScale

  private static let diameter: CGFloat = 14
  private static let scene: CGFloat = 260

  var body: some View {
    Group {
      if let still = AgentBackdropRenderer.still(
        of: backdrop, palette: palette, scene: Self.scene, pixels: Self.diameter * displayScale
      ) {
        Image(decorative: still, scale: displayScale)
          .resizable()
          .interpolation(.high)
      } else {
        Color.primary.opacity(0.18)
      }
    }
    .frame(width: Self.diameter, height: Self.diameter)
    .clipShape(Circle())
  }
}
