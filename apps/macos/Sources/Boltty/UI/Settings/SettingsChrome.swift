import AppKit
import SwiftUI

enum SettingsSurfacePalette {
  static let background = NSColor.windowBackgroundColor
}

extension View {
  func bolttyInterfaceTypography() -> some View {
    font(BolttyInterfaceTypography.body)
      .fontDesign(.rounded)
  }
}

enum SettingsMotion {
  static var quick: Animation { Animation.easeOut(duration: Motion.quick) }

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

  @State private var wasPressed = false

  var body: some View {
    Button {
      wasPressed = true
      action()
    } label: {
      Label {
        Text(isBusy ? busyTitle : title)
      } icon: {
        if isBusy, wasPressed {
          ProgressView().controlSize(.small)
        } else {
          BolttyIconView(icon: .reload, size: 16)
        }
      }
    }
    .onChange(of: isBusy) { _, busy in
      if !busy { wasPressed = false }
    }
    .help(isBusy ? busyHelp : help)
    .accessibilityIdentifier(identifier)
  }
}

struct SettingsFilterField: View {
  let prompt: String
  @Binding var text: String

  var body: some View {
    HStack(spacing: 6) {
      BolttyIconView(icon: .magnifier, size: 14)
        .foregroundStyle(.secondary)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .onExitCommand { text = "" }
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          BolttyIconView(icon: .xmark, size: 10)
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Clear the filter")
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(Color.primary.opacity(0.06), in: Capsule())
    .animation(SettingsMotion.quick, value: text.isEmpty)
    .accessibilityIdentifier("boltty.settings.filter")
  }
}
