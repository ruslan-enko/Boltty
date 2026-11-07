import AppKit

enum ModelMenu {
  private static let flatLimit = 14

  static func make(
    _ content: BolttyAIModelMenu,
    chooseModel: @escaping (AgentModelOption) -> Void,
    chooseEffort: @escaping (String?) -> Void,
    setAutoMode: @escaping (Bool) -> Void
  ) -> NSMenu {
    let menu = NSMenu(title: "Model")
    menu.autoenablesItems = false

    if let gone = content.goneName {
      let item = NSMenuItem(title: gone, action: nil, keyEquivalent: "")
      item.subtitle = "No longer offered"
      item.state = .on
      item.isEnabled = false
      menu.addItem(item)
    }
    addModels(content, to: menu, choose: chooseModel)

    if !content.efforts.isEmpty {
      menu.addItem(.sectionHeader(title: "Effort"))
      if content.canResetEffort || content.effort == nil {
        menu.addItem(item(title: "Default", isOn: content.effort == nil) { chooseEffort(nil) })
      }
      for effort in content.efforts {
        menu.addItem(item(title: effort.label, isOn: content.effort == effort.value) {
          chooseEffort(effort.value)
        })
      }
    }

    if let on = content.autoMode {
      if menu.numberOfItems > 0 { menu.addItem(.separator()) }
      let auto = item(title: "Auto Mode", isOn: on) { setAutoMode(!on) }
      let reach = AgentsSettingsPage.autoModeReach(for: content.agent)
      auto.subtitle = reach.prefix(1).uppercased() + reach.dropFirst()
      auto.setAccessibilityIdentifier("boltty.ask.autoMode")
      menu.addItem(auto)
    }
    return menu
  }

  private static func addModels(
    _ content: BolttyAIModelMenu,
    to menu: NSMenu,
    choose: @escaping (AgentModelOption) -> Void
  ) {
    var providers: [String] = []
    for option in content.models where !providers.contains(option.selection.providerID) {
      providers.append(option.selection.providerID)
    }
    func row(_ option: AgentModelOption) -> NSMenuItem {
      let row = item(title: option.selection.displayName, isOn: option == content.current) { choose(option) }
      if option.isDefault { row.subtitle = "Default" }
      return row
    }
    guard providers.count > 1 else {
      content.models.forEach { menu.addItem(row($0)) }
      return
    }
    let nests = content.models.count > flatLimit
    for provider in providers {
      let models = content.models.filter { $0.selection.providerID == provider }
      if nests {
        let parent = NSMenuItem(title: provider, action: nil, keyEquivalent: "")
        parent.state = models.contains { $0 == content.current } ? .on : .off
        let submenu = NSMenu(title: provider)
        submenu.autoenablesItems = false
        submenu.appearance = NSAppearance(named: .darkAqua)
        models.forEach { submenu.addItem(row($0)) }
        parent.submenu = submenu
        menu.addItem(parent)
      } else {
        menu.addItem(.sectionHeader(title: provider))
        models.forEach { menu.addItem(row($0)) }
      }
    }
  }

  private static func item(title: String, isOn: Bool, handler: @escaping () -> Void) -> NSMenuItem {
    let item = WorkingDirectoryMenuItem(title: title, handler: handler)
    item.state = isOn ? .on : .off
    return item
  }
}
