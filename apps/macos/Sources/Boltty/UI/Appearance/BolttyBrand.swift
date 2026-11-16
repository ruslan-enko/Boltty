import AppKit
import SwiftUI

enum BolttyBrand {
  static let accent = dynamic(
    light: NSColor(oklch: 0.845, 0.2, 82.7),
    dark: accentOnGlass
  )

  static let onAccent = NSColor.black

  static let accentOnGlass = NSColor(oklch: 0.86, 0.203, 87.2)

  static let accentOnGlassHover = NSColor(oklch: 0.9, 0.17, 87.2)

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

struct BolttySwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Toggle(configuration)
      .toggleStyle(.switch)
      .tint(Color(nsColor: BolttyBrand.accentOnGlass))
  }
}

extension View {
  func bolttyProminentButton() -> some View {
    buttonStyle(.glassProminent)
      .tint(Color.bolttyAccent)
      .foregroundStyle(Color.bolttyOnAccent)
  }
}
