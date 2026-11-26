import AppKit
import SwiftUI

struct AppearancePicker: View {
  @ObservedObject var model: BolttyAISettingsModel
  @AppStorage(ChatBackdrop.storageKey) private var stored = ChatBackdrop.standard.rawValue

  static let tile = (size: CGSize(width: 96, height: 60), corner: CGFloat(14))
  private static var gap: CGFloat { 10 }

  private var chosen: ChatBackdrop { ChatBackdrop(rawValue: stored) ?? .standard }
  private var look: MascotLook { model.mascotLook(for: model.mascotRoster.restingAgent) }

  var body: some View {
    Group {
      glass.padding(.vertical, 4)
      backdrop.padding(.vertical, 4)
    }
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
