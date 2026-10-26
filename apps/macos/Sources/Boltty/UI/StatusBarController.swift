import AppKit

@MainActor
final class StatusBarController {
  private var item: NSStatusItem?
  private(set) var snapshot = StatusBarSnapshot.idle

  var onBolttyAI: (() -> Void)?
  var onSelectAgent: ((UUID) -> Void)?
  var onJumpLatestUnread: (() -> Void)?
  var onSettings: (() -> Void)?
  var onCheckForUpdates: (() -> Void)?
  var onQuit: (() -> Void)?

  var updateOffer: AppUpdater.Offer? {
    didSet {
      guard updateOffer != oldValue else { return }
      redraw()
    }
  }

  var menuTitlesForTesting: [String] {
    item?.menu?.items.map(\.title) ?? []
  }

  var menuItemsForTesting: [NSMenuItem] {
    item?.menu?.items ?? []
  }

  func install() {
    guard item == nil else { return }
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.setAccessibilityIdentifier("boltty.statusItem")
    item = statusItem
    redraw()
  }

  func attach(_ chat: ChatWorkspaceCoordinator) {
    chat.onStatusSnapshotChange = { [weak self] snapshot in
      self?.apply(snapshot: snapshot)
    }
    isStoreReadOnly = chat.store.isReadOnly
    snapshot = chat.statusSnapshot
    redraw()
  }

  private(set) var isStoreReadOnly = false

  var hotkeyHint: String? {
    didSet {
      guard hotkeyHint != oldValue else { return }
      redraw()
    }
  }

  func apply(snapshot: StatusBarSnapshot) {
    guard snapshot != self.snapshot else { return }
    self.snapshot = snapshot
    redraw()
  }

  private func redraw() {
    guard let item else { return }
    updateIcon()
    item.menu = buildMenu(snapshot: snapshot)
  }

  func remove() {
    if let item {
      NSStatusBar.system.removeStatusItem(item)
    }
    item = nil
  }

  private func updateIcon() {
    guard let item else { return }
    if let button = item.button {
      button.image = StatusBarIconRenderer.image(state: snapshot.iconState)
      button.alphaValue = 1
      button.toolTip = snapshot.accessibilityLabel
      button.setAccessibilityLabel(snapshot.accessibilityLabel)
    }
  }

  private func buildMenu(snapshot: StatusBarSnapshot) -> NSMenu {
    let menu = NSMenu(title: "Boltty")
    menu.autoenablesItems = false
    let ask = addItem(
      to: menu, title: "Boltty AI", action: #selector(bolttyAI), symbolName: "sparkles"
    )
    if let hotkeyHint {
      let title = NSMutableAttributedString(
        string: "Boltty AI",
        attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor]
      )
      title.append(NSAttributedString(
        string: "   \(hotkeyHint)",
        attributes: [
          .font: NSFont.menuFont(ofSize: 0),
          .foregroundColor: NSColor.secondaryLabelColor,
        ]
      ))
      ask.attributedTitle = title
    }

    if !snapshot.agentRows.isEmpty {
      menu.addItem(.separator())
      for row in snapshot.agentRows {
        let title = row.prompt
        let item = NSMenuItem(
          title: title,
          action: #selector(selectAgent(_:)),
          keyEquivalent: ""
        )
        item.target = self
        item.representedObject = row.id as NSUUID
        if let agentImage = AgentIconProvider.image(for: row.agent).copy() as? NSImage {
          agentImage.size = NSSize(width: 14, height: 14)
          item.image = agentImage
        }
        menu.addItem(item)
      }
      menu.addItem(.separator())
    }

    let jump = addItem(
      to: menu,
      title: "Jump to Latest Unread",
      action: #selector(jumpLatestUnread),
      symbolName: "bell.badge"
    )
    jump.isEnabled = snapshot.latestUnreadSessionID != nil
    jump.toolTip = snapshot.latestUnreadTitle
    if snapshot.latestUnreadSessionID == nil {
      let empty = addItem(
        to: menu,
        title: "No Unread Chats",
        action: nil,
        symbolName: "bell.slash"
      )
      empty.isEnabled = false
    }

    if isStoreReadOnly {
      menu.addItem(.separator())
      let readOnly = addItem(
        to: menu,
        title: "Read-only — another Boltty owns the store",
        action: nil,
        symbolName: "lock"
      )
      readOnly.isEnabled = false
      readOnly.toolTip = "Chats can be read. New ones will not be saved until that Boltty quits."
    }

    switch updateOffer {
    case let .download(version):
      addItem(
        to: menu,
        title: "Download Boltty \(version)…",
        action: #selector(checkForUpdates),
        symbolName: "arrow.down.circle"
      )
    case let .check(enabled):
      let check = addItem(
        to: menu,
        title: "Check for Updates…",
        action: #selector(checkForUpdates),
        symbolName: "arrow.triangle.2.circlepath"
      )
      check.isEnabled = enabled
    case nil:
      break
    }
    addItem(to: menu, title: "Settings…", action: #selector(openSettings), symbolName: "gearshape")
    menu.addItem(.separator())
    addItem(to: menu, title: "Quit Boltty", action: #selector(quitApp), symbolName: "power")
    return menu
  }

  @discardableResult
  private func addItem(
    to menu: NSMenu,
    title: String,
    action: Selector?,
    keyEquivalent: String = "",
    symbolName: String? = nil,
    image: NSImage? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    item.isEnabled = action != nil
    if let image {
      item.image = image
    } else if let symbolName {
      item.image = BolttySFSymbolImage.make(name: symbolName, pointSize: 13, weight: .regular)
    }
    menu.addItem(item)
    return item
  }

  @objc private func bolttyAI() { onBolttyAI?() }
  @objc private func jumpLatestUnread() { onJumpLatestUnread?() }
  @objc private func openSettings() { onSettings?() }
  @objc private func checkForUpdates() { onCheckForUpdates?() }
  @objc private func quitApp() { onQuit?() }

  @objc private func selectAgent(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? NSUUID else { return }
    onSelectAgent?(id as UUID)
  }
}
