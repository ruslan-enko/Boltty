import AppKit
import SwiftUI

enum SettingsSurfacePalette {
  static let background = NSColor.windowBackgroundColor
  static let separator = NSColor.separatorColor

  static func background(for appearance: NSAppearance?) -> NSColor {
    resolved(background, for: appearance)
  }

  static func resolved(_ color: NSColor, for appearance: NSAppearance?) -> NSColor {
    guard let appearance else { return color }
    var result = color
    appearance.performAsCurrentDrawingAppearance {
      result = color.usingColorSpace(.sRGB) ?? color
    }
    return result
  }
}

extension View {
  func bolttyInterfaceTypography() -> some View {
    font(BolttyInterfaceTypography.body)
      .fontDesign(.rounded)
  }
}

enum SettingsMotion {
  static let quick = Animation.easeOut(duration: Motion.quick)

  static var arrival: Animation? {
    MotionPreferences.reduceMotion ? nil : .easeOut(duration: Motion.standard)
  }

  static var departure: Animation? {
    MotionPreferences.reduceMotion ? nil : .easeOut(duration: Motion.quick)
  }

  static var press: Animation? {
    MotionPreferences.reduceMotion
      ? nil
      : .spring(duration: Motion.pressSpring.duration, bounce: Motion.pressSpring.bounce)
  }
}

extension EnvironmentValues {
  @Entry var settingsControlIsPressed = false
}

struct SettingsPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .environment(\.settingsControlIsPressed, configuration.isPressed)
  }
}

struct SettingsRefreshButton: View {
  let title: String
  let busyTitle: String
  let help: String
  let busyHelp: String
  let isBusy: Bool
  let identifier: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(isBusy ? busyTitle : title, systemImage: "arrow.clockwise")
        .symbolEffect(
          .rotate, options: .speed(1.5), isActive: isBusy && !MotionPreferences.reduceMotion
        )
    }
    .help(isBusy ? busyHelp : help)
    .accessibilityIdentifier(identifier)
  }
}
