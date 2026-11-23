import AppKit
import SwiftUI

enum BolttyBrand {
  static var accent: NSColor { dynamic(light: accentOnPage, dark: accentOnGlass) }

  static var accentOnPage: NSColor { live(NSColor(oklch: 0.845, 0.2, 82.7)) }

  static let onAccent = NSColor.black

  static var accentOnGlass: NSColor { live(NSColor(oklch: 0.86, 0.203, 87.2)) }

  static var accentOnGlassHover: NSColor { live(NSColor(oklch: 0.9, 0.17, 87.2)) }

  private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
  }
}

extension Color {
  static var bolttyAccent: Color { Color(nsColor: BolttyBrand.accent) }
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
