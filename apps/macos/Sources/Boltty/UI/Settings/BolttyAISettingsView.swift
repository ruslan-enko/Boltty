import AppKit
import SwiftUI

struct BolttyAISettingsView: View {
  @ObservedObject var model: BolttyAISettingsModel
  @ObservedObject var navigation: SettingsNavigation
  @State private var selection: SettingsPage?

  var body: some View {
    NavigationSplitView(columnVisibility: .constant(.all)) {
      sidebar
    } detail: {
      page
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: SettingsSurfacePalette.background).ignoresSafeArea())
        .navigationTitle(navigation.current.title)
        .toolbar { history }
    }
    .bolttyInterfaceTypography()
    .writingToolsBehavior(.disabled)
    .task {
      await model.loadDictationLanguages()
      await model.refreshAgents()
    }
  }

  private var sidebar: some View {
    List(selection: $selection) {
      ForEach(SettingsPage.allCases) { page in
        Label {
          Text(page.title)
        } icon: {
          Image(systemName: page.symbol)
            .resizable()
            .scaledToFit()
            .frame(width: 17, height: 17)
            .foregroundStyle(.secondary)
        }
          .tag(page)
          .accessibilityIdentifier("boltty.settings.page.\(page.rawValue)")
      }
    }
    .listStyle(.sidebar)
    .listItemTint(.monochrome)
    .toolbar(removing: .sidebarToggle)
    .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
    .onAppear { selection = navigation.current }
    .onChange(of: selection) { _, page in
      if let page { navigation.open(page) }
    }
    .onChange(of: navigation.current) { _, page in
      if selection != page { selection = page }
    }
  }

  @ViewBuilder
  private var page: some View {
    switch navigation.current {
    case .general: GeneralSettingsPage(model: model)
    case .agents: AgentsSettingsPage(model: model)
    case .usage: UsageSettingsPage(model: model)
    case .voice: VoiceSettingsPage(model: model)
    case .askBoltty: AskBolttySettingsPage(model: model)
    case .shortcuts: ShortcutsSettingsPage(model: model)
    }
  }

  @ToolbarContentBuilder
  private var history: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        navigation.goBack()
      } label: {
        Label("Back", systemImage: "chevron.backward")
      }
      .disabled(!navigation.canGoBack)
      .keyboardShortcut("[", modifiers: .command)
      .help("Back")
      .accessibilityIdentifier("boltty.settings.back")

      Button {
        navigation.goForward()
      } label: {
        Label("Forward", systemImage: "chevron.forward")
      }
      .disabled(!navigation.canGoForward)
      .keyboardShortcut("]", modifiers: .command)
      .help("Forward")
      .accessibilityIdentifier("boltty.settings.forward")
    }
  }
}

// MARK: - The two kinds of page

struct SettingsColumnsPage<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      Form { content }
        .formStyle(.columns)
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }
  }
}

extension View {
  func settingsGroupedPage() -> some View {
    formStyle(.grouped)
      .scrollContentBackground(.hidden)
  }
}

struct SettingsSectionHeader: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .font(BolttyInterfaceTypography.headline)
      .foregroundStyle(.primary)
  }
}

struct SettingsNote: View {
  let text: String
  var color: Color = .secondary

  init(_ text: String, color: Color = .secondary) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text)
      .font(BolttyInterfaceTypography.callout)
      .foregroundStyle(color)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct SettingsPopUpIndicator: View {
  var symbol = "chevron.up.chevron.down"
  var isHovered = false
  @Environment(\.settingsControlIsPressed) private var isPressed

  var body: some View {
    Image(systemName: symbol)
      .font(BolttyInterfaceTypography.fixed(size: 9, weight: .bold))
      .foregroundStyle(isHovered || isPressed ? .primary : .secondary)
      .frame(width: 20, height: 20)
      .background(Circle().fill(Color.primary.opacity(fill)))
      .animation(SettingsMotion.quick, value: isHovered)
      .animation(isPressed ? nil : SettingsMotion.quick, value: isPressed)
  }

  private var fill: Double {
    if isPressed { return 0.24 }
    return isHovered ? 0.16 : 0.08
  }
}

struct SettingsAgentTitle: View {
  @ObservedObject var model: BolttyAISettingsModel
  let agent: AgentId
  var subtitle: String?

  var body: some View {
    HStack(spacing: 12) {
      MascotStill(look: model.mascotLook(for: agent), size: 30)
      VStack(alignment: .leading, spacing: 2) {
        Text(agent.displayName)
        if let subtitle {
          Text((try? AttributedString(markdown: subtitle)) ?? AttributedString(subtitle))
            .font(BolttyInterfaceTypography.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
