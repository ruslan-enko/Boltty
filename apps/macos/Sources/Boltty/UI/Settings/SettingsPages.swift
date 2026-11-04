import AppKit
import Charts
import SwiftUI

// MARK: - General

struct GeneralSettingsPage: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    Form {
      Section {
        Toggle("System-wide hotkey", isOn: Binding(
          get: { model.bolttyAIHotkeyEnabled },
          set: { model.bolttyAIHotkeyEnabled = $0 }
        ))
        .accessibilityIdentifier("boltty.settings.hotkeyEnabled")

        LabeledContent("Shortcut") {
          HotkeyRecorderField(
            binding: model.bolttyAIHotkey,
            isEnabled: model.bolttyAIHotkeyEnabled,
            probe: model.probeHotkey ?? { _ in .free },
            problem: $model.hotkeyProblem,
            onRecord: { model.bolttyAIHotkey = $0 },
            onRestoreDefault: { model.bolttyAIHotkey = .optionSpace }
          )
        }
        .foregroundStyle(model.bolttyAIHotkeyEnabled ? .primary : .secondary)
      } header: {
        SettingsSectionHeader("Boltty AI")
      } footer: {
        hotkeyNote
      }

      Section {
        Toggle("Open Boltty at login", isOn: Binding(
          get: { model.loginItem.isOn },
          set: { model.loginItem.setEnabled($0) }
        ))
        .accessibilityIdentifier("boltty.settings.openAtLogin")
      } header: {
        SettingsSectionHeader("Startup")
      } footer: {
        loginNote
      }

      Section {
        Toggle(isOn: Binding(
          get: { model.attachesFinderSelection },
          set: { model.attachesFinderSelection = $0 }
        )) {
          Text("Use what's open in Finder")
          Text("Opening Boltty AI over Finder starts the chat in that folder, with the files selected there in the prompt.")
        }
        .accessibilityIdentifier("boltty.settings.attachesFinderSelection")

        Toggle(isOn: Binding(
          get: { model.playsSounds },
          set: { model.playsSounds = $0 }
        )) {
          Text("Play sounds")
          Text("When a message is sent, a reply is ready, or an agent needs you.")
        }
        .accessibilityIdentifier("boltty.settings.playsSounds")
      } header: {
        SettingsSectionHeader("Behaviour")
      }

      Section {
        LabeledContent {
          HStack(spacing: 8) {
            Button("Show in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([model.conversationsDirectory])
            }
            .accessibilityIdentifier("boltty.settings.revealConversations")
            Button("Clear History…", role: .destructive) { confirmClearHistory() }
              .disabled(model.conversationCount == 0)
              .accessibilityIdentifier("boltty.settings.clearHistory")
          }
        } label: {
          Text("Conversations")
          Text("Transcripts stay on this Mac. Nothing is re-run when Boltty restarts.")
        }

        LabeledContent {
          Button("Review…") { model.onReviewAccess?() }
            .accessibilityIdentifier("boltty.settings.reviewAccess")
        } label: {
          Text("Permissions")
          Text("The microphone, Screen Recording, notifications and Finder.")
        }
      } header: {
        SettingsSectionHeader("Privacy")
      }

      Section {
        Toggle("Check for updates automatically", isOn: Binding(
          get: { model.checksForUpdates },
          set: { model.checksForUpdates = $0 }
        ))
        .accessibilityIdentifier("boltty.settings.checkForUpdates")

        LabeledContent("Version") {
          HStack(spacing: 8) {
            if let updater = model.updater, updater.isChecking || updater.isInstalling {
              ProgressView().controlSize(.small)
            }
            Text(model.versionDescription)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
            if let updater = model.updater {
              Button(updateButtonTitle(updater)) {
                updater.checkForUpdates()
              }
              .disabled(updater.isChecking || updater.isInstalling)
              .accessibilityIdentifier("boltty.settings.checkNow")
            }
          }
        }
      } header: {
        SettingsSectionHeader("Updates")
      } footer: {
        if let updater = model.updater {
          SettingsNote(updatesNote(updater))
        }
      }
    }
    .settingsGroupedPage()
    .onAppear { model.loginItem.refresh() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      model.loginItem.refresh()
    }
  }

  @ViewBuilder
  private var loginNote: some View {
    if let error = model.loginItem.lastError {
      SettingsNote("macOS refused: \(error)", color: .red)
    } else if model.loginItem.status == .requiresApproval {
      VStack(alignment: .leading, spacing: 8) {
        SettingsNote("macOS is waiting for you to allow Boltty in System Settings › General › Login Items.", color: .orange)
        Button("Open Login Items") { model.loginItem.openSystemSettings() }
      }
    } else if model.bolttyAIHotkeyEnabled {
      SettingsNote("So \(model.bolttyAIHotkey.displayName) works right after a restart, with nothing to open first.")
    } else {
      SettingsNote("Boltty starts in the menu bar, with nothing on screen.")
    }
  }

  private func updateButtonTitle(_ updater: AppUpdater) -> String {
    guard let release = updater.available else { return "Check Now" }
    if updater.isInstalling { return "Installing Boltty \(release.version)…" }
    return release.isInstallable ? "Install Boltty \(release.version)…" : "Download Boltty \(release.version)…"
  }

  private func updatesNote(_ updater: AppUpdater) -> String {
    if let release = updater.available, release.isInstallable {
      return "Boltty \(release.version) is out; you have \(updater.currentVersion). Install puts it in place of this copy and opens it again."
    }
    if let release = updater.available {
      return "Boltty \(release.version) is out; you have \(updater.currentVersion). Download it, quit Boltty from the menu bar, and drag the new one into Applications."
    }
    let telling = "Boltty asks GitHub once a day and tells you; it installs only when you say so."
    guard let checked = updater.lastUpdateCheckDate else { return telling }
    return "Last checked \(AppUpdater.checkedPhrase(checked)). \(telling)"
  }

  @ViewBuilder
  private var hotkeyNote: some View {
    if let problem = model.hotkeyProblem {
      SettingsNote(problem.message, color: .red)
    } else if model.bolttyAIHotkey.isModifierOnly, model.hotkeyStandInFailed {
      SettingsNote("\(model.bolttyAIHotkey.displayName) needs Input Monitoring: allow Boltty in System Settings › Privacy & Security › Input Monitoring. Until then no shortcut opens Boltty — none of the others could be registered.", color: .red)
    } else if model.hotkeyRegistrationFailed {
      SettingsNote("Couldn't register that shortcut — another app took it in the moment.", color: .red)
    } else if model.bolttyAIHotkey.isModifierOnly, let standIn = model.hotkeyStandIn {
      SettingsNote("\(model.bolttyAIHotkey.displayName) needs Input Monitoring: allow Boltty in System Settings › Privacy & Security › Input Monitoring. Until then, \(standIn.displayName) opens Boltty.", color: .red)
    } else if model.bolttyAIHotkey.isModifierOnly {
      SettingsNote("Press \(model.bolttyAIHotkey.displayName) together and let go. Uses Input Monitoring, which only this shortcut needs.")
    } else {
      SettingsNote("Works while Boltty is in the background. No extra permission needed.")
    }
  }

  private func confirmClearHistory() {
    let count = model.conversationCount
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = count == 1
      ? "Move the one saved conversation to the Trash?"
      : "Move all \(count) saved conversations to the Trash?"
    alert.informativeText =
      "Boltty forgets them. Until you empty the Trash, their transcripts are kept there in a “Boltty History” folder."
    alert.addButton(withTitle: "Move to Trash")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    model.clearHistory()
  }
}

// MARK: - Agents

/// Every agent on one short list — its face, what a new chat with it would
/// use, its switch — and a page of its own for its model, permissions and
/// face, so the list stays a list.
struct AgentsSettingsPage: View {
  @ObservedObject var model: BolttyAISettingsModel
  @ObservedObject var navigation: SettingsNavigation

  var body: some View {
    Group {
      if let agent = navigation.agent,
         let row = model.adapterRows.first(where: { $0.agent == agent })
      {
        AgentSettingsDetail(model: model, row: row)
      } else {
        list
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        SettingsRefreshButton(
          title: "Scan for Agents",
          busyTitle: "Scanning for Agents",
          help: "Look for installed agents again",
          busyHelp: "Looking for installed agents…",
          isBusy: model.isLoadingModels,
          identifier: "boltty.settings.scanAgents"
        ) {
          Task { await model.refreshAgents() }
        }
      }
    }
  }

  private var list: some View {
    // Preferred over whom? With one agent on, the words have nothing to say.
    let preferred = model.enabledAdapters.count > 1 ? model.defaultAgent : nil
    return Form {
      Section {
        ForEach(model.adapterRows) { row in
          AgentSettingsListRow(model: model, row: row, isPreferred: row.agent == preferred) {
            navigation.open(agent: row.agent)
          }
        }
      } footer: {
        if model.enabledAdapters.count > 1 {
          SettingsNote("New chats go to the preferred agent, or to the next enabled one while it isn't ready.")
        }
      }
    }
    .settingsGroupedPage()
  }

  /// What Auto Mode lets through, in that agent's terms. New chats take the
  /// choice; a chat already started keeps its own.
  static func autoModeNote(for agent: AgentId) -> String {
    "Auto Mode: \(autoModeReach(for: agent)) Applies to new chats."
  }

  /// What Auto Mode lets through, alone — the composer's switch says it too.
  static func autoModeReach(for agent: AgentId) -> String {
    switch agent {
    case .codex:
      "Codex works inside its workspace sandbox without asking."
    case .claude:
      "Claude Code decides what is safe to run and asks only about the rest."
    default:
      "edits in the chat's folder go through without asking; commands still ask."
    }
  }
}

extension AgentSettingsRow {
  /// One line for the list: what a new chat with this agent would use, or why
  /// there would be none.
  var summary: String {
    guard isReady else { return status }
    guard enabled else { return "Off" }
    var parts: [String] = []
    if let model = currentModel { parts.append(model.selection.displayName) }
    if let selectedEffort, let effort = effortOptions.first(where: { $0.value == selectedEffort }) {
      parts.append(effort.label)
    }
    if offersAutoApproval, autoApprove { parts.append("Auto Mode") }
    return parts.isEmpty ? "Ready" : parts.joined(separator: " · ")
  }

  /// The chosen model, else the one the agent itself starts with.
  var currentModel: AgentModelOption? {
    models.first { $0.selection.modelID == selectedModelID } ?? models.first { $0.isDefault }
  }
}

/// A row that opens the agent's page. The switch stays its own control, so
/// an agent goes on or off without leaving the list.
private struct AgentSettingsListRow: View {
  @ObservedObject var model: BolttyAISettingsModel
  let row: AgentSettingsRow
  let isPreferred: Bool
  let open: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 12) {
      Button(action: open) {
        HStack(spacing: 12) {
          MascotStill(look: model.mascotLook(for: row.agent), size: 30)
            .opacity(row.isReady ? 1 : 0.45)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(row.agent.displayName)
              if isPreferred { SettingsTag("Preferred") }
            }
            // A status can carry a command in backticks.
            Text((try? AttributedString(markdown: row.summary)) ?? AttributedString(row.summary))
              .font(BolttyInterfaceTypography.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(SettingsRowPressStyle())
      .accessibilityLabel(row.agent.displayName)
      .accessibilityValue(isPreferred ? "Preferred, \(row.summary)" : row.summary)
      .accessibilityHint("Opens its model, permissions and face")
      .accessibilityIdentifier("boltty.settings.agent.\(row.agent.rawValue).open")

      AgentEnabledSwitch(model: model, row: row)
        .controlSize(.small)

      Button(action: open) {
        BolttyIconView(icon: .chevronRight, size: 16)
          .foregroundStyle(isHovered ? .secondary : .tertiary)
          .frame(width: 16, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(SettingsRowPressStyle())
      .accessibilityHidden(true)
    }
    .onHover { isHovered = $0 }
    .animation(SettingsMotion.quick, value: isHovered)
    .contextMenu {
      Button("Open \(row.agent.shortDisplayName) Settings", action: open)
      Button("Make Preferred") { model.defaultAgent = row.agent }
        .disabled(!row.enabled || isPreferred)
    }
  }
}

/// One agent's own page: the agent and its switch, what its new chats use,
/// and its face.
private struct AgentSettingsDetail: View {
  @ObservedObject var model: BolttyAISettingsModel
  let row: AgentSettingsRow

  var body: some View {
    Form {
      Section { header }

      if row.enabled {
        Section {
          if model.enabledAdapters.count > 1 { preferred }
          if row.isReady, row.offersModels { modelRows }
          if row.isReady, row.offersAutoApproval { permissions }
        } footer: {
          if row.isReady, row.offersAutoApproval {
            SettingsNote(AgentsSettingsPage.autoModeNote(for: row.agent))
          }
        }
      }

      Section {
        MascotChoiceRows(model: model, agent: row.agent)
      } header: {
        SettingsSectionHeader("Face")
      } footer: {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          SettingsNote("\(row.agent.shortDisplayName) wears it on its tab, above the prompt and in the notch. No two agents share one.")
          Spacer(minLength: 0)
          Button("Restore Default") { model.restoreDefaultMascot(for: row.agent) }
            .disabled(!model.canRestoreDefaultMascot(for: row.agent))
            .accessibilityIdentifier("boltty.settings.mascot.\(row.agent.rawValue).reset")
        }
      }

      Section {
        ChatBackdropPicker(model: model, agent: row.agent)
      } header: {
        SettingsSectionHeader("Chat")
      } footer: {
        SettingsNote("Drawn behind \(row.agent.shortDisplayName)'s open chats, in its face's colours: a new face recolours it.")
      }
    }
    .settingsGroupedPage()
  }

  private var header: some View {
    HStack(spacing: 10) {
      MascotFace(look: model.mascotLook(for: row.agent))
        .frame(width: 52, height: 52)
        .opacity(row.isReady ? 1 : 0.45)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.agent.displayName)
          .font(BolttyInterfaceTypography.headline)
        Text((try? AttributedString(markdown: row.status)) ?? AttributedString(row.status))
          .font(BolttyInterfaceTypography.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer(minLength: 12)
      AgentEnabledSwitch(model: model, row: row)
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var preferred: some View {
    LabeledContent("Preferred agent") {
      if model.defaultAgent == row.agent {
        Text("New chats start here")
          .foregroundStyle(.secondary)
      } else {
        Button("Make Preferred") { model.defaultAgent = row.agent }
          .accessibilityIdentifier("boltty.settings.makePreferred.\(row.agent.rawValue)")
      }
    }
  }

  @ViewBuilder
  private var modelRows: some View {
    if row.models.isEmpty {
      if model.isLoadingModels {
        LabeledContent("Model") {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Loading models")
        }
      } else {
        LabeledContent {
          Text("Agent default")
            .foregroundStyle(.secondary)
        } label: {
          Text("Model")
          Text("\(row.agent.shortDisplayName) did not list its models. Scan for Agents asks again.")
        }
        .accessibilityIdentifier("boltty.settings.model.\(row.agent.rawValue).unlisted")
      }
    } else {
      Picker(
        selection: Binding(
          get: { row.shownModelID },
          set: { model.setDefaultModel($0.isEmpty ? nil : $0, for: row.agent) }
        )
      ) {
        Text(row.models.first(where: \.isDefault).map { "Default (\($0.selection.displayName))" } ?? "Agent default")
          .tag("")
        ForEach(row.models) { option in
          Text(option.selection.displayName).tag(option.selection.modelID)
        }
      } label: {
        Text("Model")
        if let gone = row.modelNoLongerOffered {
          Text("\(gone) is no longer offered, so new chats use the default.")
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("boltty.settings.model.\(row.agent.rawValue)")

      if !row.effortOptions.isEmpty {
        Picker(
          "Reasoning",
          selection: Binding(
            get: { row.selectedEffort ?? "" },
            set: { model.setDefaultEffort($0.isEmpty ? nil : $0, for: row.agent) }
          )
        ) {
          Text("Model default").tag("")
          ForEach(row.effortOptions) { option in
            Text(option.label).tag(option.value)
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("boltty.settings.effort.\(row.agent.rawValue)")
      }
    }
  }

  private var permissions: some View {
    Picker(
      "Permissions",
      selection: Binding(
        get: { row.autoApprove },
        set: { model.setAutoApprove($0, for: row.agent) }
      )
    ) {
      Text("Ask").tag(false)
      Text("Auto Mode").tag(true)
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier("boltty.settings.permissions.\(row.agent.rawValue)")
  }
}

private struct AgentEnabledSwitch: View {
  @ObservedObject var model: BolttyAISettingsModel
  let row: AgentSettingsRow

  var body: some View {
    Toggle(row.agent.displayName, isOn: Binding(
      get: { row.enabled },
      set: { enabled in
        withAnimation(enabled ? SettingsMotion.arrival : SettingsMotion.departure) {
          model.setEnabled(enabled, for: row.agent)
        }
      }
    ))
    .labelsHidden()
    .toggleStyle(.switch)
    .accessibilityIdentifier("boltty.settings.agent.\(row.agent.rawValue)")
  }
}

/// A row that is a button presses like one, without a bezel.
private struct SettingsRowPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.55 : 1)
      .animation(configuration.isPressed ? nil : SettingsMotion.quick, value: configuration.isPressed)
  }
}

/// A word beside a name that marks it, quieter than the name.
private struct SettingsTag: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(BolttyInterfaceTypography.fixed(size: 11, weight: .medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 1.5)
      .background(Capsule().fill(Color.primary.opacity(0.08)))
  }
}

// MARK: - Usage

struct UsageSettingsPage: View {
  @ObservedObject var model: BolttyAISettingsModel
  @Environment(\.controlActiveState) private var activeState

  var body: some View {
    let rows = model.usageRows
    Group {
      if rows.isEmpty, model.statistics?.sessions.isEmpty == true {
        ContentUnavailableView {
          Label {
            Text("No usage yet")
          } icon: {
            BolttyIconView(icon: SettingsPage.usage.icon, size: 40)
          }
        } description: {
          Text("Nothing any agent wrote down yet. Plan limits show here where an agent reports them, and every chat is counted.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Form {
          UsageOverviewSection(model: model)
          ForEach(rows) { row in
            Section {
              usageRow(row)
            } footer: {
              if row.id == rows.last?.id {
                SettingsNote("Read from each agent's own account. Codex counts tokens a day, OpenCode counts steps. OpenCode reports no plan limit.")
              }
            }
          }
        }
        .settingsGroupedPage()
      }
    }
    .task { await model.refreshUsageIfStale() }
    .onChange(of: activeState) { _, state in
      guard state == .key else { return }
      Task { await model.refreshUsageIfStale() }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        SettingsRefreshButton(
          title: "Refresh",
          busyTitle: "Refreshing",
          help: "Check every agent's sign-in and read its usage again",
          busyHelp: "Reading every agent's sign-in and usage…",
          isBusy: model.isRefreshingUsage,
          identifier: "boltty.settings.refreshUsage"
        ) {
          Task { await model.refreshUsage() }
        }
      }
    }
  }

  private func usageRow(_ row: BolttyAISettingsModel.UsageRow) -> some View {
    return VStack(alignment: .leading, spacing: 20) {
      if row.isSignedOut {
        signedOutTitle(row.agent)
      } else {
        SettingsAgentTitle(model: model, agent: row.agent)
      }
      if let usage = row.usage {
        ForEach(usage.windows, id: \.title) { window in
          UsageLimitCard(window: window)
        }
      }
      if let history = row.history {
        UsageHistoryChart(history: history)
      }
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("boltty.settings.usage.\(row.agent.rawValue)")
  }

  private func signedOutTitle(_ agent: AgentId) -> some View {
    let command = agent.signInCommand ?? agent.program
    return HStack(alignment: .center) {
      SettingsAgentTitle(
        model: model, agent: agent,
        subtitle: "Signed out. Run `\(command)` in a terminal, then refresh."
      )
      Spacer()
      Button("Copy Command") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
      }
      .help("Copy “\(command)”")
      .accessibilityIdentifier("boltty.settings.usage.\(agent.rawValue).copySignIn")
    }
  }

}

/// One plan window, said the way plan pages say it: what is left, and when
/// it comes back. The bar is what remains.
private struct UsageLimitCard: View {
  let window: AgentUsageWindow

  private var remaining: Int { max(0, 100 - window.usedPercent) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(BolttyInterfaceTypography.headline)
      HStack(alignment: .firstTextBaseline) {
        if let reset = window.resetsAt, reset > Date() {
          Text("Resets in \(AgentUsageWindow.countdown(to: reset))")
            .foregroundStyle(.secondary)
            .help("Resets \(AgentUsageWindow.resetPhrase(reset))")
        }
        Spacer(minLength: 8)
        Text("\(remaining)% remaining")
          .foregroundStyle(.secondary)
      }
      .font(BolttyInterfaceTypography.callout)
      .monospacedDigit()
      UsageMeter(fraction: Double(remaining) / 100)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue("\(remaining) percent remaining")
  }

  private var title: String {
    let limit = "\(window.kind.title) usage limit"
    return window.label.map { "\($0) · \(limit)" } ?? limit
  }
}

/// A capsule track, the filled part in the accent colour, as the system's
/// own meters are. The faces' colours made every agent's bar a scale of its own.
struct UsageMeter: View {
  let fraction: Double
  var height: CGFloat = 8

  var body: some View {
    GeometryReader { proxy in
      let filled = proxy.size.width * min(max(fraction, 0), 1)
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.08))
        if filled > 0 {
          Capsule()
            .fill(Color.accentColor)
            .frame(width: max(filled, height))
        }
      }
    }
    .frame(height: height)
  }
}

private struct UsageHistoryChart: View {
  let history: AgentActivityHistory

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      headline
      Chart(history.days) { day in
        BarMark(
          x: .value("Day", day.date, unit: .day),
          y: .value(history.unit.title.capitalized, day.value),
          width: .ratio(0.62)
        )
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous))
        .foregroundStyle(Color.accentColor)
      }
      .chartYAxis {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            .foregroundStyle(Color.primary.opacity(0.15))
          AxisValueLabel {
            if let number = value.as(Double.self) {
              Text(AgentActivityHistory.compact(number))
            }
          }
        }
      }
      .chartXAxis {
        AxisMarks(values: .stride(by: .day, count: 7)) { value in
          AxisValueLabel {
            if let date = value.as(Date.self) { Text(Self.dayFormatter.string(from: date)) }
          }
        }
      }
      .frame(height: 96)
      .accessibilityLabel("\(history.unit.title.capitalized) per day, last \(AgentActivityHistory.window) days")

      if let caption {
        Text(caption)
          .font(BolttyInterfaceTypography.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// Said like a limit card's title: what is counted, and the fortnight's sum.
  private var headline: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Last \(AgentActivityHistory.window) days")
        .font(BolttyInterfaceTypography.headline)
      Spacer(minLength: 8)
      Text("\(AgentActivityHistory.compact(history.days.reduce(0) { $0 + $1.value })) \(history.unit.title)")
        .font(BolttyInterfaceTypography.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("d MMM")
    return formatter
  }()

  private var caption: String? {
    var parts: [String] = []
    if let streak = history.streakDays, streak > 0 {
      parts.append(streak == 1 ? "1-day streak" : "\(streak)-day streak")
    }
    if let summary = history.summary { parts.append(summary) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

// MARK: - Voice

struct VoiceSettingsPage: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    Form {
      dictation
      if let speech = model.speech {
        reading(speech)
      }
    }
    .settingsGroupedPage()
  }

  // MARK: Dictation

  private var dictation: some View {
    Section {
      if model.localModels != nil {
        Picker("Engine", selection: Binding(
          get: { model.usesLocalDictation }, set: { model.chooseLocalDictation($0) }
        )) {
          Text("Apple Dictation").tag(false)
          Text(modelTitle("Parakeet", .parakeetUltra)).tag(true)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("boltty.settings.dictationEngine")
        LocalModelProgress(model: model, id: .parakeetUltra, chosen: model.usesLocalDictation)
      }

      if !model.usesLocalDictation {
        Picker(
          "Language",
          selection: Binding(
            get: { model.dictationLocaleIdentifier },
            set: { identifier in
              Task { await model.selectDictationLanguage(identifier) }
            }
          )
        ) {
          Text("Follow System").tag(DictationLanguageCatalog.followSystemIdentifier)
          Divider()
          ForEach(model.dictationLanguages) { language in
            Text(language.isInstalled ? language.displayName : "\(language.displayName) (download)")
              .tag(language.identifier)
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("boltty.settings.dictationLocale")
        .disabled(model.dictationLanguages.isEmpty)

        Picker(
          "Second language",
          selection: Binding(
            get: { model.dictationSecondLocaleIdentifier },
            set: { identifier in
              Task { await model.selectSecondDictationLanguage(identifier) }
            }
          )
        ) {
          Text("None").tag(DictationLanguageCatalog.noSecondLanguageIdentifier)
          Divider()
          ForEach(model.secondDictationLanguages) { language in
            Text(language.isInstalled ? language.displayName : "\(language.displayName) (download)")
              .tag(language.identifier)
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("boltty.settings.dictationSecondLocale")
        .disabled(model.dictationLanguages.isEmpty)

        download
      }
    } header: {
      SettingsSectionHeader("Dictation")
    } footer: {
      if model.usesLocalDictation {
        SettingsNote("Hears 25 languages and tells them apart itself.")
      } else if model.dictationSecondLocaleIdentifier != DictationLanguageCatalog.noSecondLanguageIdentifier {
        SettingsNote("Both listen at once; each phrase is written in the one that heard it.")
      }
    }
  }

  // MARK: Reading aloud

  /// Supertonic reads aloud, or nothing does: until it is downloaded the
  /// page offers only the download.
  @ViewBuilder
  private func reading(_ speech: SpeechOutput) -> some View {
    if model.localModels != nil {
      Section {
        if model.supertonicState == .ready {
          VoicePicker(model: model)

          Picker("Read answers", selection: $model.readAnswers) {
            Text("Never").tag(AnswerReading.off)
            Text("When I Asked by Voice").tag(AnswerReading.askedByVoice)
            Text("Always").tag(AnswerReading.always)
          }
          .pickerStyle(.menu)
          .accessibilityIdentifier("boltty.settings.readAnswers")
        } else {
          LabeledContent {
            LocalModelProgress(model: model, id: .supertonic3, chosen: true)
          } label: {
            Text("Supertonic")
            Text("Reads answers aloud in 31 languages, on this Mac.")
          }
        }
      } header: {
        SettingsSectionHeader("Reading aloud")
      }
    }
  }

  /// A model's name in a menu, with what choosing it downloads until it is here.
  private func modelTitle(_ name: String, _ id: LocalVoiceModel.ID) -> String {
    switch model.modelState(id) {
    case .notInstalled, .failed: "\(name) (\(model.modelSize(id)) download)"
    case .downloading, .preparing, .ready: name
    }
  }

  @ViewBuilder
  private var download: some View {
    switch model.dictationDownload {
    case .idle:
      EmptyView()
    case let .downloading(language, fraction):
      ProgressView(value: fraction) {
        Text("Downloading \(language)…")
          .font(BolttyInterfaceTypography.callout)
      }
      .accessibilityIdentifier("boltty.settings.dictationDownload")
    case let .failed(message):
      SettingsNote(message, color: .red)
    }
  }
}

/// Settings › Ask Boltty. Voice is dictation; a region asked about is Ask
/// Boltty's.
struct AskBolttySettingsPage: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    Form {
      AskBolttySettingsSection(model: model)
    }
    .settingsGroupedPage()
  }
}

// MARK: - Shortcuts

struct ShortcutsSettingsPage: View {
  @ObservedObject var model: BolttyAISettingsModel
  @State private var hoveredID: String?

  var body: some View {
    let sections = model.shortcutSections
    let builtIn = model.builtInKeySections
    Form {
      ForEach(sections) { section in
        Section {
          ForEach(section.shortcuts) { shortcut in
            row(shortcut)
          }
        } header: {
          SettingsSectionHeader(section.title)
        } footer: {
          if section.id == sections.last?.id {
            footer
          }
        }
      }
      ForEach(builtIn) { section in
        Section {
          ForEach(section.keys) { key in
            builtInRow(key)
          }
        } header: {
          SettingsSectionHeader(section.title)
        } footer: {
          if section.id == builtIn.last?.id {
            SettingsNote("The keys above, from Boltty AI down, are built in and cannot be changed.")
          }
        }
      }
    }
    .settingsGroupedPage()
  }

  private var footer: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      SettingsNote("Click a shortcut, then type the new one — Delete removes it, Esc cancels.")
      Spacer(minLength: 0)
      if model.hasCustomizedShortcuts {
        Button("Restore Defaults") { model.restoreAllDefaultShortcuts() }
          .accessibilityIdentifier("boltty.settings.shortcuts.reset")
      }
    }
  }

  /// A key that is not a menu command: plain, and not a control.
  private func builtInRow(_ key: BuiltInKey) -> some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 2) {
        Text(key.title)
        if let detail = key.detail {
          Text(detail)
            .font(BolttyInterfaceTypography.callout)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 12)
      Text(key.keys)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("boltty.settings.builtInKey.\(key.id)")
  }

  private func row(_ shortcut: KeyboardShortcut) -> some View {
    let isHovered = hoveredID == shortcut.id
    let conflict = model.shortcutConflictCaption(for: shortcut.id)
    return HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 2) {
        Text(shortcut.title)
        if let conflict {
          Text(conflict)
            .font(BolttyInterfaceTypography.callout)
            .foregroundStyle(.orange)
        }
      }
      Spacer(minLength: 0)
      MenuShortcutRecorderField(
        id: shortcut.id,
        binding: model.shortcutBinding(for: shortcut.id),
        isConflicting: conflict != nil,
        isRowHovered: isHovered,
        canRestore: model.isShortcutCustomized(shortcut.id),
        onRecord: { model.setShortcutBinding($0, for: shortcut.id) },
        onRestoreDefault: { model.restoreDefaultShortcut(shortcut.id) }
      )
      .accessibilityIdentifier("boltty.settings.shortcut.\(shortcut.id)")
    }
    .onHover { hoveredID = $0 ? shortcut.id : (hoveredID == shortcut.id ? nil : hoveredID) }
  }
}

/// A local model's line on the Voice page, only when there is something to
/// say: its download while chosen, or what it takes once it is no longer used.
struct LocalModelProgress: View {
  @ObservedObject var model: BolttyAISettingsModel
  let id: LocalVoiceModel.ID
  let chosen: Bool
  @State private var confirmsRemoval = false

  private var name: String { id == .parakeetUltra ? "Parakeet" : "Supertonic" }

  var body: some View {
    switch model.modelState(id) {
    case .notInstalled:
      // Chosen, yet gone from the disk: removed by hand.
      if chosen {
        Button("Download (\(model.modelSize(id)))") { model.download(id) }
      }
    case let .downloading(fraction):
      HStack(spacing: 8) {
        ProgressView(value: fraction)
          .frame(width: 140)
          .accessibilityIdentifier("boltty.settings.\(id.rawValue).progress")
        Text("\(Int(fraction * 100)) % of \(model.modelSize(id))")
          .font(BolttyInterfaceTypography.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Button("Stop") { model.stopDownload(id) }
          .controlSize(.small)
      }
    case .preparing:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Getting ready, about a minute…")
          .font(BolttyInterfaceTypography.callout)
          .foregroundStyle(.secondary)
      }
    case .ready:
      if !chosen {
        HStack(spacing: 4) {
          Text("\(name) takes \(model.modelSize(id)) on this Mac.")
            .font(BolttyInterfaceTypography.callout)
            .foregroundStyle(.secondary)
          Button("Remove…") { confirmsRemoval = true }
            .buttonStyle(.link)
            .font(BolttyInterfaceTypography.callout)
            .accessibilityIdentifier("boltty.settings.\(id.rawValue).remove")
        }
        .confirmationDialog("Remove \(name) from this Mac?", isPresented: $confirmsRemoval) {
          Button("Remove", role: .destructive) { model.remove(id) }
        } message: {
          Text("Choosing it again downloads it again.")
        }
      }
    case let .failed(message):
      if chosen {
        VStack(alignment: .leading, spacing: 6) {
          SettingsNote(message, color: .red)
          Button("Try Again") { model.download(id) }
        }
      }
    }
  }
}

// MARK: - Voice picker

/// Settings › Voice › Reading aloud: Supertonic's ten voices as a strip of
/// gradients, scrolled sideways. A press chooses the voice and says a line in
/// it; a press on the chosen one says it again, so there is no Play button.
struct VoicePicker: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    ChoiceStrip(title: "Voice", identifier: "boltty.settings.localVoice") {
      ForEach(BolttyAISettingsModel.localVoices, id: \.id) { voice in
        let chosen = voice.id == model.localVoice
        RingedChoice(
          title: voice.title, isChosen: chosen,
          help: chosen ? "Hear this voice again" : "Use this voice"
        ) {
          if chosen {
            model.previewLocalVoice()
          } else {
            withAnimation(SettingsMotion.quick) { model.localVoice = voice.id }
          }
        } picture: { _ in
          VoiceSwatch(id: voice.id)
        }
        .accessibilityIdentifier("boltty.settings.localVoice.\(voice.id)")
      }
    }
  }
}

/// A voice's circle: one of the mascots' gradients and nothing else. Ten
/// voices, six gradients: a gradient worn twice runs the other way.
private struct VoiceSwatch: View {
  let id: String

  private static let looks: [String: (palette: String, start: UnitPoint, end: UnitPoint)] = [
    "F1": ("ember", .topLeading, .bottomTrailing),
    "F2": ("candy", .top, .bottom),
    "F3": ("citrus", .topLeading, .bottomTrailing),
    "F4": ("daybreak", .top, .bottom),
    "F5": ("slate", .topTrailing, .bottomLeading),
    "M1": ("lagoon", .top, .bottom),
    "M2": ("citrus", .bottomTrailing, .topLeading),
    "M3": ("slate", .bottomLeading, .topTrailing),
    "M4": ("daybreak", .bottomLeading, .topTrailing),
    "M5": ("candy", .bottomTrailing, .topLeading),
  ]

  private var gradient: LinearGradient {
    let look = Self.looks[id] ?? ("ember", .top, .bottom)
    let palette = MascotPalette.palette(withID: look.palette) ?? .standard
    let stops = zip(palette.colors, palette.stopPlaces).map {
      Gradient.Stop(color: Color(nsColor: $0), location: $1)
    }
    return LinearGradient(stops: stops, startPoint: look.start, endPoint: look.end)
  }

  var body: some View {
    Circle().fill(gradient)
  }
}

/// A titled row of round choices that scrolls sideways when it runs out of
/// room: voices on the Voice page, agents on Ask Boltty's.
struct ChoiceStrip<Choices: View>: View {
  let title: String
  let identifier: String
  @ViewBuilder let choices: () -> Choices

  /// The form's row inset, which `listRowInsets` does not remove on macOS:
  /// the strip reaches past it to the card's edges, so a choice scrolls out
  /// under the edge rather than being cut short of it.
  private static var rowInset: CGFloat { 10 }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 14) {
          choices()
        }
        .padding(.horizontal, Self.rowInset)
        .padding(.vertical, 6)
      }
      .scrollIndicators(.never)
      .padding(.horizontal, -Self.rowInset)
      .accessibilityIdentifier(identifier)
    }
    .padding(.vertical, 8)
  }
}

/// One round choice: its picture in a circle, its name under it, and an
/// accent ring standing off the chosen one, as a chat backdrop is chosen.
/// `picture` is told how many times it was pressed, to answer each press.
struct RingedChoice<Picture: View>: View {
  let title: String
  let isChosen: Bool
  var help: String?
  var diameter: CGFloat = 52
  /// False for a picture that stands on its own: no circle, no ring, no
  /// shadow, and the chosen one is told by its name.
  var isRinged = true
  let action: () -> Void
  @ViewBuilder let picture: (_ presses: Int) -> Picture
  @State private var isHovered = false
  @State private var presses = 0

  private static var ringGap: CGFloat { 3 }
  private static var ringWidth: CGFloat { 2.5 }

  var body: some View {
    Button {
      presses += 1
      action()
    } label: {
      VStack(spacing: 7) {
        picture(presses)
          .frame(width: diameter, height: diameter)
          .overlay(Circle().strokeBorder(Color.primary.opacity(isRinged ? 0.1 : 0), lineWidth: 1))
          .padding(Self.ringGap + Self.ringWidth)
          .overlay(
            Circle()
              .strokeBorder(Color.accentColor, lineWidth: Self.ringWidth)
              .opacity(isRinged && isChosen ? 1 : 0)
              .scaleEffect(isChosen ? 1 : 0.9)
          )
          .shadow(
            color: .black.opacity(isRinged ? (isChosen ? 0.22 : 0.1) : 0),
            radius: isChosen ? 8 : 3, y: isChosen ? 3 : 1
          )
          .scaleEffect(scale)
          .animation(.spring(duration: 0.35, bounce: 0.35), value: isChosen)
          .animation(.spring(duration: 0.3, bounce: 0.4), value: isHovered)
        Text(title)
          .font(BolttyInterfaceTypography.callout.weight(isChosen ? .semibold : .regular))
          .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
          .fixedSize()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(RingedChoiceStyle())
    .onHover { isHovered = $0 }
    .help(help ?? "")
    .accessibilityLabel(title)
    .accessibilityValue(isChosen ? "Selected" : "")
  }

  private var scale: CGFloat {
    guard !MotionPreferences.reduceMotion else { return 1 }
    return isHovered && !isChosen ? 1.06 : 1
  }
}

private struct RingedChoiceStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !MotionPreferences.reduceMotion ? 0.94 : 1)
      .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
  }
}
