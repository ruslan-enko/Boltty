import SwiftUI

struct DesignSettingsSamples: View {
  @State private var isOn = true
  @State private var segment = 0
  @State private var filter = ""
  @State private var tile = 0

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $isOn) { Text(verbatim: "Switch") }
          .toggleStyle(BolttySwitchStyle())
        LabeledContent {
          GlassSegments(
            title: "Segments", options: [(value: 0, title: "Day"), (value: 1, title: "Week"), (value: 2, title: "Month")],
            selection: $segment)
            .fixedSize()
        } label: { Text(verbatim: "GlassSegments") }
        LabeledContent {
          ShortcutRecorderCapsule(
            display: "⌥Space", isEnabled: true, accessibilityName: "Shortcut", onEvent: { _ in true })
        } label: { Text(verbatim: "ShortcutRecorderCapsule") }
        LabeledContent {
          UsageMeter(fraction: 0.62).frame(width: 160)
        } label: { Text(verbatim: "UsageMeter") }
        LabeledContent {
          SettingsFilterField(prompt: "Filter", text: $filter).frame(width: 200)
        } label: { Text(verbatim: "SettingsFilterField") }
        LabeledContent {
          Button {} label: { Text(verbatim: "Download") }.bolttyProminentButton()
        } label: { Text(verbatim: "bolttyProminentButton") }
      }
      Section {
        HStack(spacing: 20) {
          ForEach(0..<3, id: \.self) { index in
            RingedChoice(title: "Choice", isChosen: tile == index, action: { tile = index }) { _ in
              MascotStill(
                look: MascotLook(shape: .hex, palette: MascotPalette.catalog[index]), size: 44)
            }
          }
        }
        .frame(maxWidth: .infinity)
      }
    }
    .formStyle(.grouped)
  }
}
