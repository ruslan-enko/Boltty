import AppKit
import SwiftUI

/// Boltty's accent, off the app icon's fill (`AppIcon.icon`: #FFEB01 to #FFA500
/// in Display P3). BRAND.md says where each one goes.
///
/// Written out rather than `controlAccentColor` or an `NSAccentColorName`: the
/// system honours an app's accent only while the person's own is Multicolor, so
/// on a Mac set to blue the app would stay blue.
enum BolttyBrand {
  /// Always a fill: a switch, a meter, a chart's bars, a chosen ring, whatever is
  /// selected. Never words: yellow on white is 1.6:1, and darkened until it reads
  /// it was brown, no colour of ours. A selection is this under `onAccent`.
  /// Deeper on a light surface, where the icon's middle all but vanishes into white.
  static let accent = dynamic(
    light: NSColor(displayP3Red: 1, green: 0.75, blue: 0, alpha: 1),
    dark: accentOnGlass
  )

  /// Words and glyphs on an accent fill. Black at 11:1 or better; white was 1.5:1.
  static let onAccent = NSColor.black

  /// The accent on the panel's glass, which is always dark. Fixed, since it ends
  /// up as a `CGColor` and a layer resolves nothing (see `PaletteInk`). The icon
  /// gradient's middle.
  static let accentOnGlass = NSColor(displayP3Red: 1, green: 0.784, blue: 0.002, alpha: 1)

  private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
  }
}

extension Color {
  static let bolttyAccent = Color(nsColor: BolttyBrand.accent)
  static let bolttyOnAccent = Color(nsColor: BolttyBrand.onAccent)
}

/// A switch that is on wears the accent. The tint goes on the switch alone: on
/// the whole page it reached every button's and menu's words, yellow on white.
/// The brighter value in both themes: the system dulls a switch's tint, and the
/// light theme's own accent came out ochre beside a meter.
struct BolttySwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Toggle(configuration)
      .toggleStyle(.switch)
      .tint(Color(nsColor: BolttyBrand.accentOnGlass))
  }
}

extension View {
  /// The one prominent button of a window: the accent's fill under black words.
  func bolttyProminentButton() -> some View {
    buttonStyle(.glassProminent)
      .tint(Color.bolttyAccent)
      .foregroundStyle(Color.bolttyOnAccent)
  }
}
