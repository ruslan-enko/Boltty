import AppKit
import SwiftUI

// MARK: - Ask Boltty

extension BolttyAISettingsModel {
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

  /// What Automatic would pick, whatever is chosen now. The row that names it
  /// is the widest in the Answers menu, so a title that followed the choice
  /// (the model picked below it) widened the whole pop-up with every pick.
  var askBolttyAutomaticTarget: AskBolttyTarget? {
    var settings = appModel.settings
    settings.askBolttyProviderID = nil
    settings.askBolttyModelID = nil
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
      }
    }
  }

}

/// Settings › Ask Boltty: who answers, what they may do. The way in is the
/// panel's: there is nothing to switch on.
struct AskBolttySettingsSection: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    Section {
      AskBolttyAgentPicker(model: model)
      if !model.askBolttyModels.isEmpty { modelPicker }
    } header: {
      SettingsSectionHeader("Who answers")
    } footer: {
      SettingsNote(answererNote)
    }

    Section {
      speaking
      Toggle(isOn: Binding(
        get: { !model.askBolttyReadOnly }, set: { model.askBolttyReadOnly = !$0 }
      )) {
        Text("Can make changes")
        Text("Edits files and runs commands when you ask, asking first as a chat does. Off, it only looks and answers.")
      }
      .accessibilityIdentifier("boltty.settings.talkAccess")
    } header: {
      SettingsSectionHeader("Answers")
    } footer: {
      SettingsNote("Open Boltty AI, drag across what you mean, and ask out loud. The agent answers beside the pointer.")
    }
  }

  private var modelPicker: some View {
    Picker("Model", selection: Binding(
      get: { model.askBolttyModelID }, set: { model.askBolttyModelID = $0 }
    )) {
      Text(agentDefaultTitle).tag("")
      Divider()
      ForEach(model.askBolttyModels) { option in
        Text(option.selection.displayName).tag(option.selection.modelID)
      }
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier("boltty.settings.talkModel")
  }

  /// Saying it needs Supertonic: until it is here, its download stands in
  /// the switch's place, as on the Voice page.
  @ViewBuilder
  private var speaking: some View {
    if model.supertonicState == .ready {
      Toggle(isOn: Binding(
        get: { model.askBolttySpeaksAloud }, set: { model.askBolttySpeaksAloud = $0 }
      )) {
        Text("Say answers aloud")
        Text("In the voice chosen under Voice. Off, the face answers in blips.")
      }
      .accessibilityIdentifier("boltty.settings.talkSpeaksAloud")
    } else {
      LabeledContent {
        LocalModelProgress(model: model, id: .supertonic3, chosen: true)
      } label: {
        Text("Say answers aloud")
        Text("Needs Supertonic, a voice that runs on this Mac. Until then the face answers in blips.")
      }
      .accessibilityIdentifier("boltty.settings.talkSpeaksAloud")
    }
  }

  /// The model a chat with the chosen agent starts in, named.
  private var agentDefaultTitle: String {
    guard let id = model.appModel.settings.askBolttyProviderID,
          let name = model.adapterRows.first(where: { $0.agent.rawValue == id })?
            .currentModel?.selection.displayName
    else { return "Agent default" }
    return "Agent default (\(name))"
  }

  private var answererNote: String {
    let quick = "Every model thinks as little as it can, so answers come quickly."
    guard model.askBolttyProviderID.isEmpty,
          let target = model.askBolttyAutomaticTarget,
          let agent = AgentId(rawValue: target.providerID)
    else { return quick }
    let modelName = target.model.map { " on \($0.displayName)" } ?? ""
    return "Automatic is \(agent.displayName)\(modelName), the quickest to answer. \(quick)"
  }
}

/// Who answers, as their faces: the face that will answer beside the
/// pointer is the one chosen here. Automatic wears the face it would pick.
private struct AskBolttyAgentPicker: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    let chosen = model.askBolttyProviderID
    ChoiceStrip(title: "Agent", identifier: "boltty.settings.talkAgent") {
      RingedChoice(title: "Automatic", isChosen: chosen.isEmpty, isRinged: false) {
        choose("")
      } picture: { _ in
        face(model.askBolttyAutomaticTarget.flatMap { AgentId(rawValue: $0.providerID) })
      }
      .accessibilityIdentifier("boltty.settings.talkAgent.automatic")
      ForEach(model.askBolttyAgents, id: \.rawValue) { agent in
        RingedChoice(title: agent.shortDisplayName, isChosen: chosen == agent.rawValue, isRinged: false) {
          choose(agent.rawValue)
        } picture: { _ in
          face(agent)
        }
        .accessibilityIdentifier("boltty.settings.talkAgent.\(agent.rawValue)")
      }
    }
  }

  private func choose(_ id: String) {
    guard id != model.askBolttyProviderID else { return }
    withAnimation(SettingsMotion.quick) { model.askBolttyProviderID = id }
  }

  @ViewBuilder
  private func face(_ agent: AgentId?) -> some View {
    if let agent {
      MascotStill(look: model.mascotLook(for: agent), size: 52)
    }
  }
}
