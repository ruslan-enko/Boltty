import AppKit
import SwiftUI

// MARK: - Ask Boltty

extension BolttyAISettingsModel {
  var askBolttyReadOnly: Bool {
    get { appModel.settings.askBolttyReadOnly }
    set { appModel.updateSettings { $0.askBolttyReadOnly = newValue } }
  }

  var askBolttyAgents: [AgentId] {
    AgentHistory.tabOrder.filter { agent in
      guard appModel.settings.isProviderEnabled(agent.rawValue),
            let installation = engine.registry.installation(for: agent), installation.isReady
      else { return false }
      return AskBolttyConfiguration.canAnswer(installation.capabilities)
    }
  }

  var askBolttyAgent: AgentId? {
    AskBolttyConfiguration.resolve(
      settings: appModel.settings, candidates: askBolttyAgents.map(\.rawValue), models: modelsByProvider
    ).flatMap { AgentId(rawValue: $0.providerID) }
  }

  func chooseAskBolttyAgent(_ agent: AgentId) {
    appModel.updateSettings { settings in
      settings.askBolttyProviderID = agent.rawValue
      settings.askBolttyModelID = nil
    }
  }

  var askBolttyModels: [AgentModelOption] {
    guard let agent = askBolttyAgent,
          engine.registry.capabilities(forProviderID: agent.rawValue).contains(.modelSelection)
    else { return [] }
    return modelsByProvider[agent.rawValue] ?? []
  }

  var askBolttyModelID: String {
    get {
      askBolttyModels.option(stored: appModel.settings.askBolttyModelID)?.id ?? ""
    }
    set {
      let agent = askBolttyAgent?.rawValue
      appModel.updateSettings { settings in
        settings.askBolttyProviderID = agent
        settings.askBolttyModelID = newValue.isEmpty ? nil : newValue
      }
    }
  }

  var askBolttyModelNoLongerOffered: String? {
    guard let stored = appModel.settings.askBolttyModelID, !askBolttyModels.isEmpty,
          askBolttyModels.option(stored: stored) == nil
    else { return nil }
    return stored
  }
}

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
      SettingsNote("Open Boltty AI, drag across what you mean, and ask out loud. The agent answers beside the pointer. It is sent the window under that area and the menu bar; the rest of the screen is hidden from it unless you select all of it.")
    }
  }

  private var modelPicker: some View {
    Picker(selection: Binding(
      get: { model.askBolttyModelID }, set: { model.askBolttyModelID = $0 }
    )) {
      Text(agentDefaultTitle).tag("")
      Divider()
      ForEach(model.askBolttyModels) { option in
        Text(option.selection.displayName).tag(option.id)
      }
    } label: {
      Text("Model")
      if let gone = model.askBolttyModelNoLongerOffered {
        Text("\(gone) is no longer offered, so the default answers.")
      }
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier("boltty.settings.talkModel")
  }

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

  private var agentDefaultTitle: String {
    guard let agent = model.askBolttyAgent,
          let name = model.adapterRows.first(where: { $0.agent == agent })?
            .currentModel?.selection.displayName
    else { return "Agent default" }
    return "Agent default (\(name))"
  }

  private var answererNote: String {
    let quick = "Every model thinks as little as it can, so answers come quickly."
    return model.askBolttyAgents.count > 1 ? "Until you choose, the preferred agent answers. \(quick)" : quick
  }
}

private struct AskBolttyAgentPicker: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    let chosen = model.askBolttyAgent
    if model.askBolttyAgents.isEmpty {
      LabeledContent("Agent") {
        Text("None ready that can see the screen")
          .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("boltty.settings.talkAgent")
    } else {
      ChoiceStrip(title: "Agent", identifier: "boltty.settings.talkAgent") {
      ForEach(model.askBolttyAgents, id: \.rawValue) { agent in
        RingedChoice(title: agent.shortDisplayName, isChosen: chosen == agent, isRinged: false) {
          guard agent != chosen || model.appModel.settings.askBolttyProviderID == nil else { return }
          withAnimation(SettingsMotion.quick) { model.chooseAskBolttyAgent(agent) }
        } picture: { _ in
          MascotStill(look: model.mascotLook(for: agent), size: 52)
        }
        .accessibilityIdentifier("boltty.settings.talkAgent.\(agent.rawValue)")
      }
      }
    }
  }
}
