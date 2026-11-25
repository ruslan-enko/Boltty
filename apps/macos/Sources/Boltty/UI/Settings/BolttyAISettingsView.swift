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
        .clipped()
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
      VStack(spacing: 2) {
        ForEach(SettingsPage.allCases) { page in
          SettingsSidebarRow(page: page, isSelected: navigation.current == page) {
            select(page)
          }
        }
      }
      .padding(.horizontal, 10)
    }
    .scrollIndicators(.never)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color(nsColor: SettingsSurfacePalette.background).ignoresSafeArea())
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
    .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
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
  @State private var isHovered = false

  private static let tile: CGFloat = 24
  private static let inset: CGFloat = 4

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        SettingsPageTile(page: page, side: Self.tile)
        Text(page.title)
          .fontWeight(isSelected ? .semibold : .regular)
          .foregroundStyle(.primary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Self.inset)
      .frame(height: Self.tile + 2 * Self.inset)
      .background(
        Color.primary.opacity(isSelected ? 0.08 : (isHovered ? 0.04 : 0)),
        in: RoundedRectangle(cornerRadius: SettingsPageTile.corner(Self.tile) + Self.inset, style: .continuous)
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

struct SettingsPageTile: View {
  let page: SettingsPage
  var side: CGFloat = 24

  static func corner(_ side: CGFloat) -> CGFloat { side * 0.26 }

  @MainActor private static var images: [SettingsPage: NSImage] = [:]

  @MainActor private var image: NSImage? {
    if let kept = Self.images[page] { return kept }
    guard let url = Bundle.main.url(forResource: page.rawValue, withExtension: "png", subdirectory: "Icons/Settings"),
          let made = NSImage(contentsOf: url)
    else {
      assertionFailure("No tile \(page.rawValue) in Resources/Icons/Settings")
      return nil
    }
    Self.images[page] = made
    return made
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().interpolation(.high)
      } else {
        Color.clear
      }
    }
    .frame(width: side, height: side)
    .clipShape(RoundedRectangle(cornerRadius: Self.corner(side), style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Self.corner(side), style: .continuous)
        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
    )
    .accessibilityHidden(true)
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

struct GlassSegments<Value: Hashable>: View {
  let title: String
  let options: [(value: Value, title: String)]
  @Binding var selection: Value

  @State private var frames: [Int: CGRect] = [:]
  @State private var lead: CGFloat = 0
  @State private var trail: CGFloat = 0
  @State private var hovered: Int?
  @State private var pressed = false
  @State private var placed = false

  private static var height: CGFloat { 28 }
  private static var inset: CGFloat { 2 }
  private static var front: Animation { Animation.spring(duration: 0.28, bounce: 0.18) }
  private static var back: Animation { Animation.spring(duration: 0.46, bounce: 0.12) }

  private var chosenIndex: Int { options.firstIndex { $0.value == selection } ?? 0 }

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(options.enumerated()), id: \.offset) { index, option in
        Text(option.title)
          .fontWeight(.regular)
          .foregroundStyle(.primary.opacity(index == chosenIndex ? 1 : (hovered == index ? 0.85 : 0.7)))
          .padding(.horizontal, 14)
          .frame(height: Self.height - 2 * Self.inset)
          .contentShape(Rectangle())
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
            frames[index] = $0
            if index == chosenIndex, !placed { place(on: index, animated: false) }
          }
          .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
          .accessibilityElement()
          .accessibilityLabel(option.title)
          .accessibilityAddTraits(index == chosenIndex ? [.isButton, .isSelected] : .isButton)
          .accessibilityAction { selection = option.value }
      }
    }
    .padding(Self.inset)
    .coordinateSpace(.named(Self.space))
    .background(alignment: .leading) { thumb }
    .background(Color.primary.opacity(0.08), in: Capsule())
    .textSelection(.disabled)
    .highPriorityGesture(press)
    .onChange(of: selection) { place(on: chosenIndex, animated: true) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }

  private var thumb: some View {
    Capsule()
      .fill(.clear)
      .glassEffect(.regular, in: Capsule())
      .frame(width: max(0, trail - lead), height: Self.height - 2 * Self.inset)
      .scaleEffect(pressed ? 1.08 : 1)
      .offset(x: lead)
      .opacity(placed ? 1 : 0)
      .allowsHitTesting(false)
  }

  private var press: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
      .onChanged { drag in
        if !pressed { withAnimation(.spring(duration: 0.22, bounce: 0.3)) { pressed = true } }
        if let index = index(at: drag.location.x), index != shownIndex { place(on: index, animated: true) }
      }
      .onEnded { drag in
        withAnimation(.spring(duration: 0.3, bounce: 0.25)) { pressed = false }
        if let index = index(at: drag.location.x) {
          selection = options[index].value
        }
        place(on: chosenIndex, animated: true)
      }
  }

  @State private var shownIndex: Int?

  private func index(at x: CGFloat) -> Int? {
    frames.min { abs($0.value.midX - x) < abs($1.value.midX - x) }?.key
  }

  private func place(on index: Int, animated: Bool) {
    guard let frame = frames[index] else { return }
    shownIndex = index
    guard animated, placed else {
      lead = frame.minX
      trail = frame.maxX
      placed = true
      return
    }
    let rightward = frame.midX > (lead + trail) / 2
    withAnimation(rightward ? Self.front : Self.back) { trail = frame.maxX }
    withAnimation(rightward ? Self.back : Self.front) { lead = frame.minX }
  }

  private static var space: String { "glassSegments" }
}
