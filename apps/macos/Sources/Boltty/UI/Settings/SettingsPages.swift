import AppKit
import Charts
import SwiftUI

// MARK: - General

struct GeneralSettingsPage: View {
  @ObservedObject var model: BolttyAISettingsModel
  @State private var hoveredHotkey = false

  var body: some View {
    SettingsColumnsPage {
      LabeledContent("Boltty AI:") {
        VStack(alignment: .leading, spacing: 10) {
          Toggle("Enable system-wide hotkey", isOn: Binding(
            get: { model.bolttyAIHotkeyEnabled },
            set: { model.bolttyAIHotkeyEnabled = $0 }
          ))
          .accessibilityIdentifier("boltty.settings.hotkeyEnabled")

          HotkeyRecorderField(
            binding: model.bolttyAIHotkey,
            isEnabled: model.bolttyAIHotkeyEnabled,
            isRowHovered: hoveredHotkey,
            probe: model.probeHotkey ?? { _ in .free },
            problem: $model.hotkeyProblem,
            onRecord: { model.bolttyAIHotkey = $0 },
            onRestoreDefault: { model.bolttyAIHotkey = .optionSpace }
          )
          .onHover { hoveredHotkey = $0 }

          hotkeyNote
            .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(.bottom, 14)
      }

      LabeledContent("Startup:") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Open Boltty at login", isOn: Binding(
            get: { model.loginItem.isOn },
            set: { model.loginItem.setEnabled($0) }
          ))
          .accessibilityIdentifier("boltty.settings.openAtLogin")
          loginNote
            .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(.bottom, 14)
      }

      LabeledContent("Sounds:") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Play sounds", isOn: Binding(
            get: { model.playsSounds },
            set: { model.playsSounds = $0 }
          ))
          .accessibilityIdentifier("boltty.settings.playsSounds")
          SettingsNote("When a message is sent, a reply is ready, or an agent needs you. Boltty's own, made for it.")
            .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(.bottom, 14)
      }

      LabeledContent("Conversations:") {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Button("Show in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([model.conversationsDirectory])
            }
            .accessibilityIdentifier("boltty.settings.revealConversations")
            Button("Clear History…", role: .destructive) { confirmClearHistory() }
              .disabled(model.conversationCount == 0)
              .accessibilityIdentifier("boltty.settings.clearHistory")
          }
          SettingsNote("Transcripts stay on this Mac. Nothing is re-run when Boltty restarts.")
            .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(.bottom, 14)
      }

      LabeledContent("Permissions:") {
        VStack(alignment: .leading, spacing: 8) {
          Button("Review…") { model.onReviewAccess?() }
            .accessibilityIdentifier("boltty.settings.reviewAccess")
          SettingsNote("The microphone, Screen Recording, notifications and Finder — what each is for, and where it stands.")
            .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(.bottom, 14)
      }

      LabeledContent("Updates:") {
        updates
          .frame(maxWidth: 320, alignment: .leading)
          .padding(.bottom, 14)
      }

      LabeledContent("Version:") {
        Text(model.versionDescription)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
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

  @ViewBuilder
  private var updates: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("Check for updates automatically", isOn: Binding(
        get: { model.checksForUpdates },
        set: { model.checksForUpdates = $0 }
      ))
      .accessibilityIdentifier("boltty.settings.checkForUpdates")
      if let updater = model.updater {
        HStack(spacing: 8) {
          Button(updateButtonTitle(updater)) {
            updater.checkForUpdates()
          }
          .disabled(updater.isChecking || updater.isInstalling)
          .accessibilityIdentifier("boltty.settings.checkNow")
          if updater.isChecking || updater.isInstalling {
            ProgressView().controlSize(.small)
          }
        }
        SettingsNote(updatesNote(updater))
      }
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

struct AgentsSettingsPage: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    Form {
      Section {
        Picker(
          "Preferred agent",
          selection: Binding(
            get: { model.defaultAgent },
            set: { model.defaultAgent = $0 }
          )
        ) {
          ForEach(model.enabledAdapters, id: \.self) { agent in
            Text(agent.displayName).tag(agent)
          }
        }
        .pickerStyle(.menu)
        .disabled(model.enabledAdapters.isEmpty)
        .accessibilityIdentifier("boltty.settings.defaultAgent")
      } footer: {
        SettingsNote("Boltty AI uses the preferred agent when it is ready, then falls back to another enabled one. Each agent uses its selected model and reasoning.")
      }

      ForEach(model.adapterRows) { row in
        Section {
          agentRows(row)
        }
      }
    }
    .settingsGroupedPage()
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

  @ViewBuilder
  private func agentRows(_ row: AgentSettingsRow) -> some View {
    HStack(alignment: .center, spacing: 12) {
      SettingsAgentTitle(model: model, agent: row.agent, subtitle: row.status)
      Spacer(minLength: 0)
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

    if row.enabled, row.isReady, row.offersModels {
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
          "Model",
          selection: Binding(
            get: { row.selectedModelID ?? "" },
            set: { model.setDefaultModel($0.isEmpty ? nil : $0, for: row.agent) }
          )
        ) {
          Text("Agent default").tag("")
          ForEach(row.models) { option in
            Text(option.selection.displayName).tag(option.selection.modelID)
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

    if row.enabled, row.isReady, row.offersAutoApproval {
      Picker(
        selection: Binding(
          get: { row.autoApprove },
          set: { model.setAutoApprove($0, for: row.agent) }
        )
      ) {
        Text("Ask").tag(false)
        Text("Auto Mode").tag(true)
      } label: {
        Text("Permissions")
        Text(Self.autoModeNote(for: row.agent))
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("boltty.settings.permissions.\(row.agent.rawValue)")
    }

    MascotPickerButton(model: model, agent: row.agent)
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
    default:
      "edits in the chat's folder go through without asking; commands still ask."
    }
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
          Label("No usage yet", systemImage: SettingsPage.usage.symbol)
        } description: {
          Text("Nothing any agent wrote down yet. Claude Code, Codex and Grok report their plan limits here, and every chat with any of them is counted.")
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
                SettingsNote("Read from each agent's own account. Codex counts tokens a day, OpenCode counts steps.")
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
    let tint = Color(nsColor: model.usageTint(for: row.agent))
    return VStack(alignment: .leading, spacing: 12) {
      if row.isSignedOut {
        signedOutTitle(row.agent)
      } else {
        SettingsAgentTitle(model: model, agent: row.agent)
      }
      if let usage = row.usage {
        ForEach(usage.windows, id: \.title) { window in
          usageWindow(window)
        }
      }
      if let history = row.history {
        UsageHistoryChart(history: history, tint: tint)
      }
    }
    .padding(.vertical, 4)
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

  private func usageWindow(_ window: AgentUsageWindow) -> some View {
    let tint = Color(nsColor: PlanUsageRingReading.color(for: window.usedPercent))
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(window.title)
          .font(BolttyInterfaceTypography.callout)
        Spacer()
        Text(usageCaption(window))
          .font(BolttyInterfaceTypography.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      ProgressView(value: Double(min(window.usedPercent, 100)), total: 100)
        .tint(tint)
        .accessibilityLabel("\(window.title) limit")
        .accessibilityValue("\(window.usedPercent) percent used")
    }
  }

  private func usageCaption(_ window: AgentUsageWindow) -> String {
    var caption = "\(window.usedPercent)% used"
    if let reset = window.resetsAt, reset > Date() {
      caption += " · resets \(AgentUsageWindow.resetPhrase(reset))"
    }
    return caption
  }
}

private struct UsageHistoryChart: View {
  let history: AgentActivityHistory
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Chart(history.days) { day in
        BarMark(
          x: .value("Day", day.date, unit: .day),
          y: .value(history.unit.title.capitalized, day.value)
        )
        .foregroundStyle(tint)
      }
      .chartYAxis {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
          AxisGridLine()
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
      .frame(height: 72)
      .accessibilityLabel("\(history.unit.title.capitalized) per day, last \(AgentActivityHistory.window) days")

      Text(caption)
        .font(BolttyInterfaceTypography.callout)
        .foregroundStyle(.secondary)
    }
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("d MMM")
    return formatter
  }()

  private var caption: String {
    var parts = ["Last \(AgentActivityHistory.window) days, \(history.unit.title)"]
    if let streak = history.streakDays, streak > 0 {
      parts.append(streak == 1 ? "1-day streak" : "\(streak)-day streak")
    }
    if let summary = history.summary { parts.append(summary) }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Voice

struct VoiceSettingsPage: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    SettingsColumnsPage {
      Picker(
        "Dictation language:",
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
      .fixedSize()
      .accessibilityIdentifier("boltty.settings.dictationLocale")
      .disabled(model.dictationLanguages.isEmpty)

      Picker(
        "Second language:",
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
      .fixedSize()
      .accessibilityIdentifier("boltty.settings.dictationSecondLocale")
      .disabled(model.dictationLanguages.isEmpty)

      LabeledContent {
        VStack(alignment: .leading, spacing: 8) {
          download
          if model.dictationSecondLocaleIdentifier != DictationLanguageCatalog.noSecondLanguageIdentifier {
            SettingsNote("Both languages listen at once and each phrase is written in the one that heard it. A sentence that changes language halfway stays in one of them.")
          }
          SettingsNote("Dictation runs entirely on this Mac — nothing is sent to Apple.")
        }
        .frame(maxWidth: 320, alignment: .leading)
      } label: {
        EmptyView()
      }
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

/// Settings › Ask Boltty. Voice is dictation; holding ⌃⌥⌘ to ask is Ask
/// Boltty's.
struct AskBolttySettingsPage: View {
  @ObservedObject var model: BolttyAISettingsModel

  var body: some View {
    SettingsColumnsPage {
      AskBolttySettingsSection(model: model)
    }
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
