import AppKit
import SwiftUI

/// The panel's glass and the chats' backdrop, side by side as tiles: each one
/// the real thing in small, over the person's own desktop.
struct AppearancePicker: View {
  @ObservedObject var model: BolttyAISettingsModel
  @AppStorage(ChatBackdrop.storageKey) private var stored = ChatBackdrop.standard.rawValue

  static let tile = (size: CGSize(width: 76, height: 52), corner: CGFloat(12))
  private static var gap: CGFloat { 8 }

  private var chosen: ChatBackdrop { ChatBackdrop(rawValue: stored) ?? .standard }
  private var look: MascotLook { model.mascotLook(for: model.mascotRoster.restingAgent) }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 12) {
        glass
        Rectangle()
          .fill(Color.primary.opacity(0.1))
          .frame(width: 1)
          .padding(.vertical, 2)
        backdrop
      }
      .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 16) {
        glass
        backdrop
      }
    }
    .padding(.vertical, 4)
  }

  private var glass: some View {
    cluster(String(localized: "Panel glass")) {
      ForEach([true, false], id: \.self) { clear in
        RingedChoice(
          title: clear ? String(localized: "Clear") : String(localized: "Frosted"), isChosen: model.panelClearGlass == clear, tile: Self.tile
        ) {
          withAnimation(SettingsMotion.quick) { model.panelClearGlass = clear }
        } picture: { _ in
          SettingsStage(width: Self.tile.size.width, height: Self.tile.size.height, corner: Self.tile.corner) {
            GlassSwatch(clearGlass: clear, look: look)
          }
        }
        .accessibilityIdentifier("boltty.settings.panelGlass.\(clear ? "clear" : "frosted")")
      }
    }
    .accessibilityIdentifier("boltty.settings.panelGlass")
  }

  private var backdrop: some View {
    cluster(String(localized: "Backdrop")) {
      ForEach(ChatBackdrop.allCases, id: \.self) { backdrop in
        RingedChoice(title: backdrop.title, isChosen: chosen == backdrop, tile: Self.tile) {
          withAnimation(SettingsMotion.quick) { stored = backdrop.rawValue }
        } picture: { _ in
          SettingsStage(width: Self.tile.size.width, height: Self.tile.size.height, corner: Self.tile.corner) {
            BackdropSwatch(
              backdrop: backdrop, palette: look.palette, clearGlass: model.panelClearGlass,
              corner: Self.tile.corner)
          }
        }
        .accessibilityIdentifier("boltty.settings.backdrop.\(backdrop.rawValue)")
      }
    }
    .accessibilityIdentifier("boltty.settings.backdrop")
  }

  private func cluster<Choices: View>(
    _ title: String, @ViewBuilder choices: () -> Choices
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(BolttyInterfaceTypography.callout)
        .foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: Self.gap) {
        choices()
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}
