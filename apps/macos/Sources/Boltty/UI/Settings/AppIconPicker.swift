import SwiftUI

/// Settings › General: which icon Boltty wears, as a strip of the icons
/// themselves, the chosen one told by its name.
struct AppIconPicker: View {
  @AppStorage(AppIconChoice.storageKey) private var stored = AppIconChoice.standard.rawValue

  private var chosen: AppIconChoice { AppIconChoice(rawValue: stored) ?? .standard }

  var body: some View {
    HStack(spacing: 28) {
      ForEach(AppIconChoice.allCases) { choice in
        RingedChoice(title: choice.title, isChosen: choice == chosen, diameter: 64, isRinged: false) {
          stored = choice.rawValue
          choice.apply()
        } picture: { _ in
          if let picture = choice.picture {
            Image(nsImage: picture)
              .resizable()
              .interpolation(.high)
          }
        }
        .accessibilityIdentifier("boltty.settings.appIcon.\(choice.rawValue)")
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
  }
}
