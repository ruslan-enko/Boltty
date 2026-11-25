import AppKit
import SwiftUI

@MainActor
final class DesignWindowController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
  private enum Page {
    case sections(() -> [DesignSection])
    case view(() -> NSView)
  }
  private enum Row {
    case group(String)
    case page(String, Page)
  }

  private let window: NSWindow
  private let table = NSTableView()
  private let holder = NSView()
  private let scroll = NSScrollView()
  private let groundChoice = NSSegmentedControl(
    labels: DesignGround.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
  private let glassChoice = NSSegmentedControl(
    labels: ["Clear", "Frosted"], trackingMode: .selectOne, target: nil, action: nil)
  private let backdropChoice = NSSegmentedControl(
    labels: ChatBackdrop.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
  private var page: DesignPageView?
  private let store = DesignKnobStore()
  private lazy var inspector = DesignInspector(store: store)
  private lazy var picker = DesignPickerOverlay(over: scroll)
  private let pick = NSButton(title: "Pick an Element", target: nil, action: nil)
  private var source: DesignElementSource?
  private var chosen: (name: String, ordinal: Int)?
  private var refresh: Timer?
  private var lastRefresh: CFTimeInterval = 0
  private var refreshCost: CFTimeInterval = 0
  private var rows: [Row] = []
  private var ground = DesignGround.desktop
  private var isClear = true

  override init() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1480, height: 900),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init()
    ChatBackdrop.chosenForTesting = ChatBackdrop.chosen()
    isClear = AppSettings.load().panelClearGlass
    rows = makeRows()
    buildWindow()
  }

  func show() {
    NSApp.mainMenu = makeMenu()
    NSApp.setActivationPolicy(.regular)
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    table.selectRowIndexes([startRow], byExtendingSelection: false)
    Task { [weak self] in self?.source = await Task.detached { DesignElementSource() }.value }
    Task { [weak self] in
      let sources = DesktopPicture.sources()
      DesktopPicture.cached = await Task.detached {
        await DesktopPicture.load(from: sources, maxPixels: 1920)
      }.value
      self?.reload()
    }
  }

  private func makeRows() -> [Row] {
    func sections(_ title: String, _ make: @escaping () -> [DesignSection]) -> Row { .page(title, .sections(make)) }
    return [
      .group("Foundations"),
      sections("Colour") { DesignFoundations.colours() },
      sections("Type") { DesignFoundations.type() },
      sections("Corners and spacing") { DesignFoundations.shape() },
      sections("Icons") { DesignFoundations.icons() },
      sections("Motion") { DesignFoundations.motion() },
      sections("Glass") { [weak self] in DesignFoundations.glass(clear: self?.isClear ?? true) },
      sections("Faces") { DesignFoundations.faces() },
      sections("Backdrops") { DesignFoundations.backdrops() },
      .page("All values", .view { DesignValuesView(frame: .zero) }),
      .group("Elements"),
      sections("Buttons") { DesignElements.buttons() },
      sections("Chips") { DesignElements.chips() },
      sections("Cards") { DesignElements.cards() },
      sections("Rows and tabs") { DesignElements.rows() },
      sections("Help and hints") { DesignElements.help() },
      sections("Ask Boltty") { [weak self] in DesignElements.askBoltty(clear: self?.isClear ?? true) },
      .page("Settings controls", .view { NSHostingView(rootView: DesignSettingsSamples()) }),
      .group("Panel"),
    ] + DesignPanelState.allCases.map { state in
      sections(state.rawValue) { [weak self] in [state.section(clear: self?.isClear ?? true)] }
    }
  }

  private var startRow: Int {
    let wanted = UserDefaults.standard.string(forKey: "boltty.design.page")
    return rows.firstIndex { if case .page(let title, _) = $0 { title == wanted } else { false } } ?? 1
  }

  private func reload() {
    setPicking(false)
    letGo()
    load(isNewPage: true)
  }

  private func load(isNewPage: Bool) {
    guard rows.indices.contains(table.selectedRow), case .page(let title, let kind) = rows[table.selectedRow]
    else { return }
    window.subtitle = title
    inspector.page = title
    let place = scroll.contentView.bounds.origin
    _ = LiveValues.shared.takeSeen()
    PaletteAnswerText.forgetMeasurements()
    BolttyAIApprovalBar.forgetMeasurements()
    PaletteHelpPresenter.shared.dismiss()
    holder.subviews.filter { $0 !== scroll && $0 !== picker }.forEach { $0.removeFromSuperview() }
    defer {
      holder.layoutSubtreeIfNeeded()
      findChosen()
      inspector.pageUses(LiveValues.shared.takeSeen(), isNewPage: isNewPage)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
        self?.inspector.pageUses(LiveValues.shared.takeSeen(), isNewPage: false)
      }
    }
    switch kind {
    case .view(let make):
      scroll.isHidden = true
      scroll.documentView = nil
      page = nil
      let view = make()
      view.translatesAutoresizingMaskIntoConstraints = true
      view.frame = holder.bounds
      view.autoresizingMask = [.width, .height]
      holder.addSubview(view, positioned: .below, relativeTo: picker)
    case .sections(let make):
      scroll.isHidden = false
      let page = DesignPageView(sections: make(), ground: ground)
      self.page = page
      scroll.documentView = page
      arrange()
      page.scroll(isNewPage ? .zero : place)
    }
  }

  private func valuesChanged() {
    guard refresh == nil else { return }
    let wait = max(0.02, min(0.3, max(0.1, refreshCost)) - (CACurrentMediaTime() - lastRefresh))
    refresh = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.refresh = nil
        if case .page("All values", _) = self.rows[self.table.selectedRow] { return }
        let began = CACurrentMediaTime()
        self.load(isNewPage: false)
        self.lastRefresh = CACurrentMediaTime()
        self.refreshCost = self.lastRefresh - began
      }
    }
    if let refresh { RunLoop.main.add(refresh, forMode: .common) }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    guard store.readSource() else { return }
    inspector.sourceChanged()
    valuesChanged()
  }

  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { inspector.undoManager }

  func windowShouldClose(_ sender: NSWindow) -> Bool { mayClose() }

  func mayClose() -> Bool {
    guard !store.changes.isEmpty else { return true }
    let alert = NSAlert()
    alert.messageText = "Close without saving \(store.changes.count) changes?"
    alert.informativeText = "The Swift source stays as it was."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Close")
    guard alert.runModal() == .alertSecondButtonReturn else { return false }
    store.revertAll()
    return true
  }

  private func arrange() {
    guard let page else { return }
    let room = scroll.contentSize
    let height = page.arrange(width: room.width, viewport: room.height)
    page.frame = CGRect(x: 0, y: 0, width: room.width, height: max(height, room.height))
  }

  func windowDidResize(_ notification: Notification) { arrange() }

  func applicationDidFinishLaunching(_ notification: Notification) { show() }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    mayClose() ? .terminateNow : .terminateCancel
  }

  func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

  private func buildWindow() {
    window.title = "Boltty Design"
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.minSize = NSSize(width: 1160, height: 600)

    table.addTableColumn(NSTableColumn(identifier: .init("page")))
    table.headerView = nil
    table.style = .sourceList
    table.floatsGroupRows = false
    table.dataSource = self
    table.delegate = self
    let side = NSScrollView()
    side.documentView = table
    side.hasVerticalScroller = true
    side.drawsBackground = false

    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.autoresizingMask = [.width, .height]
    scroll.translatesAutoresizingMaskIntoConstraints = true
    holder.addSubview(scroll)
    picker.autoresizingMask = [.width, .height]
    picker.elements = { [weak self] in self?.elements ?? [] }
    picker.onPick = { [weak self] in self?.choose($0) }
    picker.onCancel = { [weak self] in self?.setPicking(false) }
    holder.addSubview(picker)
    inspector.onParent = { [weak self] in self?.chooseParent() }
    inspector.onLetGo = { [weak self] in self?.letGo() }
    pick.setButtonType(.pushOnPushOff)
    pick.target = self
    pick.action = #selector(togglePicking)

    groundChoice.selectedSegment = 0
    glassChoice.selectedSegment = isClear ? 0 : 1
    backdropChoice.selectedSegment = ChatBackdrop.allCases.firstIndex(of: ChatBackdrop.chosen()) ?? 0
    for control in [groundChoice, glassChoice, backdropChoice] {
      control.target = self
      control.action = #selector(choiceChanged)
    }
    let bar = NSStackView(views: [
      caption("Behind"), groundChoice, caption("Glass"), glassChoice, caption("Backdrop"), backdropChoice, pick,
    ])
    bar.spacing = 8
    bar.setCustomSpacing(20, after: groundChoice)
    bar.setCustomSpacing(20, after: glassChoice)
    bar.setCustomSpacing(20, after: backdropChoice)

    let content = NSView()
    inspector.onChange = { [weak self] in self?.valuesChanged() }
    for view in [side, bar, holder, inspector] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    NSLayoutConstraint.activate([
      side.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      side.topAnchor.constraint(equalTo: content.topAnchor),
      side.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      side.widthAnchor.constraint(equalToConstant: 210),
      bar.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 24),
      bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
      holder.leadingAnchor.constraint(equalTo: side.trailingAnchor),
      holder.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
      inspector.widthAnchor.constraint(equalToConstant: 300),
      inspector.topAnchor.constraint(equalTo: content.topAnchor),
      inspector.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      inspector.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      holder.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
      holder.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    window.contentView = content
    content.layoutSubtreeIfNeeded()
    scroll.frame = holder.bounds
    picker.frame = holder.bounds
  }

  private func caption(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
    field.textColor = .secondaryLabelColor
    return field
  }

  private var elements: [DesignElement] {
    page?.subviews.compactMap { $0 as? DesignTile }.flatMap(DesignElement.all(in:)) ?? []
  }

  @objc func togglePicking() { setPicking(!picker.isPicking) }

  private func setPicking(_ picking: Bool) {
    picker.isPicking = picking && page != nil
    pick.state = picker.isPicking ? .on : .off
  }

  private func choose(_ element: DesignElement) {
    let all = elements
    chosen = all.filter { $0.name == element.name }.firstIndex { $0.view === element.view }
      .map { (element.name, $0) }
    setPicking(false)
    picker.chosen = element
    let everything = elements
    inspector.show(element: element, source: source, around: Array(
      sequence(first: element) { $0.parent(among: everything) }.dropFirst().prefix(4)))
  }

  private func chooseParent() {
    guard let element = picker.chosen, let parent = element.parent(among: elements) else { return NSSound.beep() }
    choose(parent)
  }

  private func letGo() {
    chosen = nil
    picker.chosen = nil
    inspector.show(element: nil, source: nil)
  }

  private func findChosen() {
    guard let chosen else { return }
    let named = elements.filter { $0.name == chosen.name }
    picker.chosen = named.indices.contains(chosen.ordinal) ? named[chosen.ordinal] : nil
  }

  @objc private func choiceChanged() {
    ground = DesignGround.allCases[groundChoice.selectedSegment]
    isClear = glassChoice.selectedSegment == 0
    ChatBackdrop.chosenForTesting = ChatBackdrop.allCases[backdropChoice.selectedSegment]
    reload()
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    func submenu(_ title: String, _ items: [(String, Selector, String)]) {
      let item = NSMenuItem()
      let sub = NSMenu(title: title)
      for entry in items { sub.addItem(withTitle: entry.0, action: entry.1, keyEquivalent: entry.2) }
      item.submenu = sub
      menu.addItem(item)
    }
    submenu("Boltty Design", [("Quit Boltty Design", #selector(NSApplication.terminate(_:)), "q")])
    submenu("Edit", [
      ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
      ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ])
    submenu("Element", [("Pick an Element", #selector(togglePicking), "e")])
    menu.items.last?.submenu?.items.first?.target = self
    submenu("Window", [("Close", #selector(NSWindow.performClose(_:)), "w")])
    return menu
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
    if case .group = rows[row] { true } else { false }
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    !self.tableView(tableView, isGroupRow: row)
  }

  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    let cell = NSTableCellView()
    let label = NSTextField(labelWithString: "")
    switch rows[row] {
    case .group(let title), .page(let title, _): label.stringValue = title
    }
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(label)
    cell.textField = label
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) { reload() }
}
