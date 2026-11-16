import AppKit
import SwiftUI

struct ChatBackdropPicker: View {
  @ObservedObject var model: BolttyAISettingsModel
  @AppStorage(ChatBackdrop.storageKey) private var stored = ChatBackdrop.standard.rawValue

  private var chosen: ChatBackdrop { ChatBackdrop(rawValue: stored) ?? .standard }

  var body: some View {
    let look = model.mascotLook(for: model.mascotRoster.restingAgent)
    VStack(alignment: .leading, spacing: 12) {
      LabeledContent {
        Picker("Backdrop", selection: Binding(get: { chosen }, set: { stored = $0.rawValue })) {
          ForEach(ChatBackdrop.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("boltty.settings.backdrop")
      } label: {
        Text("Backdrop")
        Text("Behind the chat list and open chats, for every agent, in the colours of the face shown. The list's All tab wears it in greys.")
      }
      SettingsStage(width: nil, height: 320, corner: SettingsStageMetrics.fillingCorner) {
        ChatBackdropSample(backdrop: chosen, look: look, clearGlass: model.panelClearGlass)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(ChatBackdropSampleView.margin)
      }
    }
    .padding(.vertical, 6)
  }
}
