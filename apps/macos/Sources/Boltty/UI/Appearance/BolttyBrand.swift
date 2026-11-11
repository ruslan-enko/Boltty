import AppKit
import SwiftUI

enum BolttyBrand {
  static let accent = dynamic(
    light: NSColor(displayP3Red: 1, green: 0.75, blue: 0, alpha: 1),
    dark: accentOnGlass
  )

  static let onAccent = NSColor.black

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
