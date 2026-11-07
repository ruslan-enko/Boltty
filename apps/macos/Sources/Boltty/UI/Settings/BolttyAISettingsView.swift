import AppKit
import SwiftUI

struct BolttyAISettingsView: View {
  @ObservedObject var model: BolttyAISettingsModel
  @ObservedObject var navigation: SettingsNavigation
  @FocusState private var sidebarHasFocus: Bool

  var body: some View {
    NavigationSplitView(columnVisibility: .constant(.all)) {
      sidebar
    } detail: {
      page
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: SettingsSurfacePalette.background).ignoresSafeArea())
        .navigationTitle(navigation.title)
        .toolbar { history }
    }
    .bolttyInterfaceTypography()
    .toggleStyle(BolttySwitchStyle())
    .writingToolsBehavior(.disabled)
    .task {
      await model.loadDictationLanguages()
      await model.refreshAgents()
    }
  }

  private var sidebar: some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(SettingsPage.allCases) { page in
          SettingsSidebarRow(page: page, isSelected: navigation.current == page) {
            select(page)
          }
        }
      }
      .padding(.horizontal, 10)
    }
    .scrollIndicators(.never)
    .focusable()
    .focused($sidebarHasFocus)
    .focusEffectDisabled()
    .onAppear { sidebarHasFocus = true }
    .onMoveCommand { direction in
      let pages = SettingsPage.allCases
      guard let index = pages.firstIndex(of: navigation.current) else { return }
      switch direction {
      case .up where index > pages.startIndex:
        select(pages[pages.index(before: index)])
      case .down where pages.index(after: index) < pages.endIndex:
        select(pages[pages.index(after: index)])
      default:
        break
      }
    }
    .toolbar(removing: .sidebarToggle)
    .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
  }

  private func select(_ page: SettingsPage) {
    if page != navigation.current { navigation.open(page) }
  }

  @ViewBuilder
  private var page: some View {
    switch navigation.current {
    case .general: GeneralSettingsPage(model: model)
    case .agents: AgentsSettingsPage(model: model, navigation: navigation)
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
        Label {
          Text("Back")
        } icon: {
          BolttyIconView(icon: .chevronLeft, size: 18)
        }
      }
      .disabled(!navigation.canGoBack)
      .keyboardShortcut("[", modifiers: .command)
      .help("Back")
      .accessibilityIdentifier("boltty.settings.back")

      Button {
        navigation.goForward()
      } label: {
        Label {
          Text("Forward")
        } icon: {
          BolttyIconView(icon: .chevronRight, size: 18)
        }
      }
      .disabled(!navigation.canGoForward)
      .keyboardShortcut("]", modifiers: .command)
      .help("Forward")
      .accessibilityIdentifier("boltty.settings.forward")
    }
  }
}

// MARK: - Pages

extension View {
  func settingsGroupedPage() -> some View {
    formStyle(.grouped)
      .scrollContentBackground(.hidden)
  }
}

private struct SettingsSidebarRow: View {
  let page: SettingsPage
  let isSelected: Bool
  let action: () -> Void
  @Environment(\.controlActiveState) private var activeState
  @State private var isHovered = false

  var body: some View {
    let selection = SettingsSelection(isSelected: isSelected, activeState: activeState)
    Button(action: action) {
      HStack(spacing: 8) {
        BolttyIconView(icon: page.icon, size: 17)
          .foregroundStyle(isSelected ? selection.ink : Color.secondary)
          .frame(width: 24)
        Text(page.title)
          .fontWeight(isSelected ? .semibold : .regular)
          .foregroundStyle(selection.ink)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .frame(height: 32)
      .background(
        selection.fill ?? Color.primary.opacity(isHovered ? 0.06 : 0),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(SettingsMotion.quick, value: isHovered)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("boltty.settings.page.\(page.rawValue)")
  }
}

struct SettingsSelection {
  let isSelected: Bool
  let activeState: ControlActiveState

  private var isLit: Bool { activeState == .key || activeState == .active }

  var fill: Color? {
    guard isSelected else { return nil }
    return isLit ? Color.bolttyAccent : Color.primary.opacity(0.12)
  }

  var ink: Color {
    isSelected && isLit ? Color.bolttyOnAccent : Color.primary
  }
}

struct SettingsSegments<Value: Hashable>: View {
  let title: String
  let options: [(value: Value, title: String)]
  @Binding var selection: Value
  @Environment(\.controlActiveState) private var activeState
  @Namespace private var thumb

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.value) { option in
        segment(option.value, title: option.title)
      }
    }
    .padding(2)
    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }

  private func segment(_ value: Value, title: String) -> some View {
    let chosen = SettingsSelection(isSelected: value == selection, activeState: activeState)
    return Button {
      withAnimation(SettingsMotion.arrival) { selection = value }
    } label: {
      Text(title)
        .fontWeight(chosen.isSelected ? .medium : .regular)
        .foregroundStyle(chosen.ink)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background {
          if let fill = chosen.fill {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(fill)
              .matchedGeometryEffect(id: "thumb", in: thumb)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(chosen.isSelected ? .isSelected : [])
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
  var icon = BolttyIcon.chevronsUpDown
  var isHovered = false
  @Environment(\.settingsControlIsPressed) private var isPressed

  var body: some View {
    BolttyIconView(icon: icon, size: 13)
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
