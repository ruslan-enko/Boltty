import AppKit
import SwiftUI

extension BolttyAISettingsModel {
  var askBolttyReadOnly: Bool {
    get { appModel.settings.askBolttyReadOnly }
    set { appModel.updateSettings { $0.askBolttyReadOnly = newValue } }
  }

  var askBolttyTakesTyping: Bool {
    get { appModel.settings.askBolttyTakesTyping }
    set { appModel.updateSettings { $0.askBolttyTakesTyping = newValue } }
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

  var askBolttyIsAutomatic: Bool {
    guard let stored = appModel.settings.askBolttyProviderID else { return true }
    return !askBolttyAgents.contains { $0.rawValue == stored }
  }

  func chooseAskBolttyAgent(_ agent: AgentId?) {
    appModel.updateSettings { settings in
      settings.askBolttyProviderID = agent?.rawValue
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
      if !model.askBolttyIsAutomatic, !model.askBolttyModels.isEmpty { modelPicker }
    } header: {
      SettingsSectionHeader(String(localized: "Who answers"))
    }

    Section {
      Toggle(isOn: Binding(
        get: { model.askBolttyTakesTyping }, set: { model.askBolttyTakesTyping = $0 }
      )) {
        Text("Questions can be typed")
      }
      .accessibilityIdentifier("boltty.settings.talkTakesTyping")
    } header: {
      SettingsSectionHeader(String(localized: "Questions"))
    }

    Section {
      SettingsPreview(height: AskAnswerSampleView.size.height + 28) {
        AskAnswerSample(
          canMakeChanges: !model.askBolttyReadOnly,
          look: model.mascotLook(
            for: model.askBolttyAgent ?? model.nextChatAgent ?? model.mascotRoster.restingAgent))
        .frame(width: AskAnswerSampleView.size.width, height: AskAnswerSampleView.size.height)
      }
      speaking
      Toggle(isOn: Binding(
        get: { !model.askBolttyReadOnly }, set: { model.askBolttyReadOnly = !$0 }
      )) {
        Text("Can make changes")
        Text("Edits files and runs commands when you ask, asking first as a chat does. Off, it only looks and answers.")
      }
      .accessibilityIdentifier("boltty.settings.talkAccess")
    } header: {
      SettingsSectionHeader(String(localized: "Answers"))
    } footer: {
      SettingsNote(String(localized: "Only the windows in the area and the menu bar are sent."))
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
    else { return String(localized: "Agent default") }
    return String(localized: "Agent default (\(name))")
  }
}

private struct AskBolttyAgentPicker: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    let automatic = model.askBolttyIsAutomatic
    let chosen = automatic ? nil : model.askBolttyAgent
    if model.askBolttyAgents.isEmpty {
      LabeledContent("Agent") {
        Text("None ready that can see the screen")
          .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("boltty.settings.talkAgent")
    } else {
      AgentChoiceStrip(
        model: model, identifier: "boltty.settings.talkAgent", agents: model.askBolttyAgents,
        offersAutomatic: model.askBolttyAgents.count > 1, isAutomatic: automatic, chosen: chosen
      ) { model.chooseAskBolttyAgent($0) }
    }
  }
}
