import AppKit
import SwiftUI

struct AgentInstallButton: View {
  @ObservedObject var model: BolttyAISettingsModel
  let agent: AgentId
  let install: AgentSettingsRow.Install

  var body: some View {
    if install.isRunning {
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Installing…")
          .font(BolttyInterfaceTypography.callout)
          .foregroundStyle(.secondary)
      }
    } else {
      Button(install.failure == nil ? String(localized: "Install") : String(localized: "Try Again")) {
        model.install(agent)
      }
      .help(install.command)
      .accessibilityLabel("Install \(agent.displayName)")
      .accessibilityIdentifier("boltty.agent.\(agent.rawValue).install")
    }
  }
}

struct CopyCommandButton: View {
  let command: String

  var body: some View {
    Button("Copy Command") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(command, forType: .string)
    }
  }
}
