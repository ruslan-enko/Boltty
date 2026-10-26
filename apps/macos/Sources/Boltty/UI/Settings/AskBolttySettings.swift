import AppKit
import SwiftUI

// MARK: - Ask Boltty

extension BolttyAISettingsModel {
  var askBolttyEnabled: Bool {
    get { appModel.settings.askBolttyEnabled }
    set { appModel.updateSettings { $0.askBolttyEnabled = newValue } }
  }

  var askBolttyReadOnly: Bool {
    get { appModel.settings.askBolttyReadOnly }
    set { appModel.updateSettings { $0.askBolttyReadOnly = newValue } }
  }

  /// Ready, switched-on agents that take a picture: Ask Boltty sends the screen.
  var askBolttyAgents: [AgentId] {
    AgentHistory.tabOrder.filter { agent in
      guard appModel.settings.isProviderEnabled(agent.rawValue),
            let installation = engine.registry.installation(for: agent), installation.isReady
      else { return false }
      return AskBolttyConfiguration.canAnswer(installation.capabilities)
    }
  }

  /// What Ask Boltty would use right now, with the settings as they are.
  var askBolttyTarget: AskBolttyTarget? {
    AskBolttyConfiguration.resolve(
      settings: appModel.settings, candidates: askBolttyAgents.map(\.rawValue), models: modelsByProvider)
  }

  /// What Automatic would pick, whatever is chosen now. The row that names it
  /// is the widest in the Answers menu, so a title that followed the choice
  /// (the model picked below it) widened the whole pop-up with every pick.
  var askBolttyAutomaticTarget: AskBolttyTarget? {
    var settings = appModel.settings
    settings.askBolttyProviderID = nil
    settings.askBolttyModelID = nil
    settings.askBolttyEffort = nil
    return AskBolttyConfiguration.resolve(
      settings: settings, candidates: askBolttyAgents.map(\.rawValue), models: modelsByProvider)
  }

  /// `""` is Automatic.
  var askBolttyProviderID: String {
    get { appModel.settings.askBolttyProviderID ?? "" }
    set {
      appModel.updateSettings { settings in
        settings.askBolttyProviderID = newValue.isEmpty ? nil : newValue
        settings.askBolttyModelID = nil
        settings.askBolttyEffort = nil
      }
    }
  }

  var askBolttyModels: [AgentModelOption] {
    guard let id = appModel.settings.askBolttyProviderID,
          engine.registry.capabilities(forProviderID: id).contains(.modelSelection)
    else { return [] }
    return modelsByProvider[id] ?? []
  }

  /// `""` is the agent's own default.
  var askBolttyModelID: String {
    get { appModel.settings.askBolttyModelID ?? "" }
    set {
      appModel.updateSettings { settings in
        settings.askBolttyModelID = newValue.isEmpty ? nil : newValue
        settings.askBolttyEffort = nil
      }
    }
  }

  var askBolttyNeedsInputMonitoring: Bool {
    appModel.settings.askBolttyEnabled && !ModifierHotkeyMonitor.hasAccess
  }

  static let inputMonitoringPane =
    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
}

/// Settings › Voice › Ask Boltty: the chord, who answers, what they may do.
struct AskBolttySettingsSection: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    LabeledContent("Ask Boltty:") {
      VStack(alignment: .leading, spacing: 6) {
        Toggle(
          "Hold \(AskBolttyController.chordName) to ask about the screen",
          isOn: Binding(get: { model.askBolttyEnabled }, set: { model.askBolttyEnabled = $0 })
        )
        .accessibilityIdentifier("boltty.settings.talkEnabled")
        SettingsNote("Hold the keys, ask out loud, let go. The agent sees your screen and answers beside the pointer, in words and blips.")
        if model.askBolttyNeedsInputMonitoring {
          SettingsNote("Boltty needs Input Monitoring to notice the keys being held. Allow it in System Settings › Privacy & Security.", color: .orange)
          if let pane = BolttyAISettingsModel.inputMonitoringPane {
            Button("Open Privacy Settings…") { NSWorkspace.shared.open(pane) }
          }
        }
      }
      .frame(maxWidth: 320, alignment: .leading)
    }
    .padding(.bottom, 14)

    if model.askBolttyEnabled {
      Picker("Answers:", selection: Binding(
        get: { model.askBolttyProviderID }, set: { model.askBolttyProviderID = $0 }
      )) {
        Text(automaticAgentTitle).tag("")
        Divider()
        ForEach(model.askBolttyAgents, id: \.rawValue) { agent in
          Text(agent.displayName).tag(agent.rawValue)
        }
      }
      .pickerStyle(.menu)
      .fixedSize()
      .accessibilityIdentifier("boltty.settings.talkAgent")

      if !model.askBolttyModels.isEmpty {
        Picker("Model:", selection: Binding(
          get: { model.askBolttyModelID }, set: { model.askBolttyModelID = $0 }
        )) {
          Text("Agent default").tag("")
          Divider()
          ForEach(model.askBolttyModels) { option in
            Text(option.selection.displayName).tag(option.selection.modelID)
          }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityIdentifier("boltty.settings.talkModel")
      }

      LabeledContent("Access:") {
        VStack(alignment: .leading, spacing: 6) {
          Picker("", selection: Binding(
            get: { model.askBolttyReadOnly }, set: { model.askBolttyReadOnly = $0 }
          )) {
            Text("Read only").tag(true)
            Text("Can make changes").tag(false)
          }
          .labelsHidden()
          .pickerStyle(.radioGroup)
          .accessibilityIdentifier("boltty.settings.talkAccess")
          SettingsNote(model.askBolttyReadOnly
            ? "Ask Boltty looks and answers. Whatever it asks to change or run is refused."
            : "Ask Boltty can edit files and run commands, asking you first as a chat does.")
        }
        .frame(maxWidth: 320, alignment: .leading)
      }
    }
  }

  private var automaticAgentTitle: String {
    guard let target = model.askBolttyAutomaticTarget,
          let agent = AgentId(rawValue: target.providerID)
    else { return "Automatic" }
    let modelName = target.model.map { " · \($0.displayName)" } ?? ""
    return "Automatic (\(agent.displayName)\(modelName))"
  }
}
