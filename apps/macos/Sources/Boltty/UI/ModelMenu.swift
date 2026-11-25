import AppKit

enum ModelMenu {
  private static let flatLimit = 14

  static func make(
    _ content: BolttyAIModelMenu,
    chooseModel: @escaping (AgentModelOption) -> Void,
    chooseEffort: @escaping (String?) -> Void,
    setAutoMode: @escaping (Bool) -> Void,
    setPlanMode: @escaping (Bool) -> Void = { _ in }
  ) -> NSMenu {
    let menu = NSMenu(title: "Model")
    menu.autoenablesItems = false

    if let gone = content.goneName {
      let item = NSMenuItem(title: gone, action: nil, keyEquivalent: "")
      item.subtitle = String(localized: "No longer offered")
      item.state = .on
      item.isEnabled = false
      menu.addItem(item)
    }
    addModels(content, to: menu, choose: chooseModel)

    if !content.efforts.isEmpty {
      menu.addItem(.sectionHeader(title: String(localized: "Effort")))
      if content.canResetEffort || content.effort == nil {
        menu.addItem(item(title: String(localized: "Default"), isOn: content.effort == nil) { chooseEffort(nil) })
      }
      for effort in content.efforts {
        menu.addItem(item(title: effort.label, isOn: content.effort == effort.value) {
          chooseEffort(effort.value)
        })
      }
    }

    if let on = content.planMode {
      if menu.numberOfItems > 0 { menu.addItem(.separator()) }
      let plan = item(title: String(localized: "Plan First"), isOn: on) { setPlanMode(!on) }
      plan.subtitle = String(localized: "Changes nothing until you approve its plan")
      plan.setAccessibilityIdentifier("boltty.ask.planMode")
      menu.addItem(plan)
    }

    if let on = content.autoMode {
      if menu.numberOfItems > 0, content.planMode == nil { menu.addItem(.separator()) }
      let auto = item(title: String(localized: "Auto Mode"), isOn: on) { setAutoMode(!on) }
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
      if option.isDefault { row.subtitle = String(localized: "Default") }
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

final class ModelChipButton: PaletteIconButton {
  private let nameLabel = NSTextField(labelWithString: "")
  private let effortLabel = NSTextField(labelWithString: "")
  private static var chipFont: NSFont { roundedAppFont(size: AgentPaletteMetrics.folderChipFontSize(chat: true)) }

  var titleForTesting: String { nameLabel.stringValue + effortLabel.stringValue }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    isBordered = false
    bezelStyle = .regularSquare
    imagePosition = .noImage
    title = ""
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for label in [nameLabel, effortLabel] {
      label.font = Self.chipFont
      label.maximumNumberOfLines = 1
      label.isSelectable = false
      addSubview(label)
    }
    nameLabel.lineBreakMode = .byTruncatingTail
    effortLabel.lineBreakMode = .byClipping
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ chip: BolttyAIModelChip) {
    nameLabel.stringValue = chip.name
    effortLabel.stringValue = Self.effortWords(chip)
    needsLayout = true
  }

  static func width(of chip: BolttyAIModelChip) -> CGFloat {
    min(width(chip.name) + width(effortWords(chip)) + AgentPaletteMetrics.modelChipPadding * 2,
        AgentPaletteMetrics.modelChipMaxWidth)
  }

  private static func effortWords(_ chip: BolttyAIModelChip) -> String {
    chip.effort.map { " · " + $0 } ?? ""
  }

  private static func width(_ words: String) -> CGFloat {
    ceil(NSAttributedString(string: words, attributes: [.font: chipFont]).size().width)
  }

  override func applyTint() {
    super.applyTint()
    nameLabel.textColor = contentTintColor
    effortLabel.textColor = contentTintColor
  }

  override func layout() {
    super.layout()
    let padding = AgentPaletteMetrics.modelChipPadding
    let room = max(0, bounds.width - padding * 2)
    let effort = min(Self.width(effortLabel.stringValue), room)
    let name = min(Self.width(nameLabel.stringValue), room - effort)
    let height = ceil(nameLabel.fittingSize.height)
    let y = (bounds.height - height) / 2
    let inset = max(0, (ceil(nameLabel.fittingSize.width) - Self.width(nameLabel.stringValue)) / 2)
    nameLabel.frame = NSRect(x: padding - inset, y: y, width: name + inset * 2, height: height)
    effortLabel.frame = NSRect(x: padding + name - inset, y: y, width: effort + inset * 2, height: height)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, frame.contains(point) else { return nil }
    return self
  }
}
