import AppKit
import Combine

/// The limits window under the menu-bar mark: each agent's face, name and plan
/// windows on the panel's own glass. A click outside or Escape closes it.
@MainActor
final class UsageGlanceController: NSObject {
  var rows: () -> [UsageGlanceRow] = { [] }
  var refresh: () async -> Void = {}
  var changes: AnyPublisher<Void, Never>? {
    didSet { if isVisible { watchChanges() } }
  }
  var onOpenSettings: (() -> Void)?
  var onMore: (() -> Void)?
  var onVisibilityChange: ((Bool) -> Void)?

  private var panel: KeyablePanel?
  private var host: PaletteGlassHost?
  private var hostHeight: NSLayoutConstraint?
  private let list = NSStackView()
  private let spinner = NSProgressIndicator()
  private var anchor: NSRect = .zero
  private var statusWindow: NSWindow?
  private var monitors: [Any] = []
  private var subscription: AnyCancellable?
  private var ticker: Timer?
  private var reading: Task<Void, Never>?
  private var shownRows: [UsageGlanceRow]?

  var isVisible: Bool { panel?.isVisible == true }

  static let width: CGFloat = 288
  static let cornerRadius: CGFloat = 24
  static let inset: CGFloat = 12
  static let wellCorner: CGFloat = cornerRadius - inset
  static let wellPadding: CGFloat = 11
  static let shadowMargin: CGFloat = 32
  static let gapUnderMenuBar: CGFloat = 6
  static let faceSize: CGFloat = 16
  static let meterHeight: CGFloat = 4
  static let footDisc: CGFloat = 28
  static let footGlyph: CGFloat = 14
  /// The discs sit concentric in the window's corners, as far from the side as from the foot.
  static let footInset: CGFloat = cornerRadius - footDisc / 2

  func toggle(under anchor: NSRect, statusWindow: NSWindow?) {
    if isVisible { close() } else { show(under: anchor, statusWindow: statusWindow) }
  }

  func show(under anchor: NSRect, statusWindow: NSWindow?) {
    self.anchor = anchor
    self.statusWindow = statusWindow
    let panel = self.panel ?? makePanel()
    host?.apply(showsGlass: true)
    rebuild(force: true)
    place()
    panel.orderFrontRegardless()
    panel.makeKey()
    startWatching()
    onVisibilityChange?(true)
    read()
  }

  func close() {
    guard let panel, panel.isVisible else { return }
    panel.orderOut(nil)
    stopWatching()
    onVisibilityChange?(false)
  }

  // MARK: - Reading

  private func read() {
    guard reading == nil else { return }
    spinner.startAnimation(nil)
    spinner.isHidden = false
    rebuild(force: true)
    reading = Task { [weak self] in
      await self?.refresh()
      guard let self else { return }
      reading = nil
      spinner.stopAnimation(nil)
      spinner.isHidden = true
      rebuild(force: true)
    }
  }

  private var isReading: Bool { reading != nil }

  private func startWatching() {
    stopWatching()
    let close: (NSEvent) -> Void = { [weak self] event in
      guard let self else { return }
      if event.window === panel || (event.window != nil && event.window === statusWindow) { return }
      self.close()
    }
    if let global = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: close
    ) {
      monitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
      handler: { event in close(event); return event }
    ) {
      monitors.append(local)
    }
    watchChanges()
    // The countdowns move; a minute is their finest step.
    ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.rebuild(force: true) }
    }
  }

  private func watchChanges() {
    subscription = changes?.sink { [weak self] in self?.rebuild(force: false) }
  }

  private func stopWatching() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors.removeAll()
    subscription = nil
    ticker?.invalidate()
    ticker = nil
  }

  // MARK: - The window

  private func makePanel() -> KeyablePanel {
    let panel = KeyablePanel(
      contentRect: NSRect(x: 0, y: 0, width: Self.width + 2 * Self.shadowMargin, height: 200),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.setAccessibilityIdentifier("boltty.usageGlance")
    panel.onKeyDown = { [weak self] event in
      guard event.keyCode == 53 else { return false }
      self?.close()
      return true
    }

    let content = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false

    list.orientation = .vertical
    list.alignment = .leading
    list.spacing = 6
    list.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(list)

    let host = PaletteGlassHost(
      content: content,
      cornerRadius: Self.cornerRadius,
      // Frosted whatever the panel wears: it opens over any window, and clear
      // glass let that window's words read through the lower half.
      style: .bolttyAIPrompt(clearGlass: false)
    )
    let root = NSView()
    root.addSubview(host)
    panel.contentView = root

    let height = host.heightAnchor.constraint(equalToConstant: 200)
    NSLayoutConstraint.activate([
      list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
      list.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.inset),
      list.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.inset),
      host.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.shadowMargin),
      host.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.shadowMargin),
      host.widthAnchor.constraint(equalToConstant: Self.width),
      height,
    ])

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.isHidden = true
    spinner.translatesAutoresizingMaskIntoConstraints = false

    self.panel = panel
    self.host = host
    hostHeight = height
    return panel
  }

  private func place() {
    guard let panel, let host, let hostHeight else { return }
    list.layoutSubtreeIfNeeded()
    let height = (list.fittingSize.height + Self.inset + Self.footInset).rounded(.up)
    hostHeight.constant = height
    host.cornerRadius = Self.cornerRadius

    let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
      ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var x = anchor.midX - Self.width / 2
    x = min(max(x, visible.minX + 8), visible.maxX - 8 - Self.width)
    let top = min(anchor.minY, visible.maxY) - Self.gapUnderMenuBar
    let frame = NSRect(
      x: x - Self.shadowMargin,
      y: top - height - Self.shadowMargin,
      width: Self.width + 2 * Self.shadowMargin,
      height: height + 2 * Self.shadowMargin
    )
    panel.setFrame(frame, display: true)
  }

  // MARK: - What it shows

  private func rebuild(force: Bool) {
    guard panel != nil else { return }
    let rows = rows()
    guard force || rows != shownRows else { return }
    shownRows = rows
    list.arrangedSubviews.forEach { $0.removeFromSuperview() }
    add(header())
    if rows.isEmpty {
      add(Self.label("No agents are switched on.", size: AgentPaletteMetrics.typeMeta, ink: PaletteInk.secondary), inset: 8)
    }
    for row in rows { add(well(for: row)) }
    add(foot())
    if isVisible { place() }
  }

  private func add(_ view: NSView, inset: CGFloat = 0) {
    if inset > 0 {
      let padded = NSView()
      view.translatesAutoresizingMaskIntoConstraints = false
      padded.addSubview(view)
      NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: inset),
        view.trailingAnchor.constraint(lessThanOrEqualTo: padded.trailingAnchor, constant: -inset),
        view.topAnchor.constraint(equalTo: padded.topAnchor),
        view.bottomAnchor.constraint(equalTo: padded.bottomAnchor),
      ])
      list.addArrangedSubview(padded)
      padded.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
      return
    }
    list.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
  }

  private func header() -> NSView {
    let title = Self.label("Limits", size: AgentPaletteMetrics.typeMeta, weight: .semibold, ink: PaletteInk.primary)
    let row = NSStackView(views: [title, NSView(), spinner])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 0, right: 6)
    title.setContentHuggingPriority(.required, for: .horizontal)
    return row
  }

  private func well(for row: UsageGlanceRow) -> NSView {
    let well = UsageGlanceWell()
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    well.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: Self.wellPadding),
      stack.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -Self.wellPadding),
      stack.topAnchor.constraint(equalTo: well.topAnchor, constant: Self.wellPadding),
      stack.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -Self.wellPadding),
    ])

    func place(_ view: NSView) {
      stack.addArrangedSubview(view)
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    place(identity(of: row.agent, takesNextChat: row.takesNextChat))
    switch row.content {
    case let .limits(usage):
      for window in usage.windows.sorted(by: { $0.kind.order < $1.kind.order }) {
        place(meterBlock(for: window))
      }
      for note in usage.notes {
        let line = Self.label(note, size: AgentPaletteMetrics.typeFootnote, ink: PaletteInk.secondary)
        line.lineBreakMode = .byWordWrapping
        line.maximumNumberOfLines = 0
        line.preferredMaxLayoutWidth = Self.width - 2 * (Self.inset + Self.wellPadding)
        place(line)
      }
    case let .signedOut(command):
      let words = NSMutableAttributedString(
        string: "Signed out. Run ",
        attributes: Self.attributes(size: AgentPaletteMetrics.typeFootnote, ink: PaletteInk.secondary)
      )
      words.append(NSAttributedString(
        string: command,
        attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: AgentPaletteMetrics.typeFootnote, weight: .regular),
          .foregroundColor: PaletteInk.primary,
        ]
      ))
      words.append(NSAttributedString(
        string: " in a terminal.",
        attributes: Self.attributes(size: AgentPaletteMetrics.typeFootnote, ink: PaletteInk.secondary)
      ))
      let label = NSTextField(labelWithAttributedString: words)
      label.isSelectable = false
      label.maximumNumberOfLines = 0
      label.preferredMaxLayoutWidth = Self.width - 2 * (Self.inset + Self.wellPadding)
      place(label)
    case .noPlanLimit:
      place(Self.label(UsageGlanceText.noPlanLimit, size: AgentPaletteMetrics.typeFootnote, ink: PaletteInk.secondary))
    case .waiting:
      place(Self.label(
        UsageGlanceText.waiting(isReading: isReading),
        size: AgentPaletteMetrics.typeFootnote, ink: PaletteInk.secondary
      ))
    }
    well.setAccessibilityElement(true)
    well.setAccessibilityRole(.group)
    well.setAccessibilityLabel(row.agent.displayName)
    well.setAccessibilityIdentifier("boltty.usageGlance.\(row.agent.rawValue)")
    return well
  }

  private func identity(of agent: AgentId, takesNextChat: Bool) -> NSView {
    let face = MascotNSView(conversationID: UUID(), look: MascotLook.face(for: agent))
    face.restAsPicture(of: UUID())
    face.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      face.widthAnchor.constraint(equalToConstant: Self.faceSize),
      face.heightAnchor.constraint(equalToConstant: Self.faceSize),
    ])
    let name = Self.label(agent.shortDisplayName, size: AgentPaletteMetrics.typeMeta, weight: .semibold, ink: PaletteInk.primary)
    let row = NSStackView(views: [face, name])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    if takesNextChat {
      let next = Self.label(
        UsageGlanceText.takesNextChat, size: AgentPaletteMetrics.typeFootnote, ink: PaletteInk.secondary)
      next.setContentHuggingPriority(.required, for: .horizontal)
      let gap = NSView()
      gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
      row.addArrangedSubview(gap)
      row.addArrangedSubview(next)
    }
    return row
  }

  private func meterBlock(for window: AgentUsageWindow) -> NSView {
    let words = NSAttributedString(
      string: window.title,
      attributes: Self.attributes(size: AgentPaletteMetrics.typeFootnote, ink: PaletteInk.primary)
    )
    let title = NSTextField(labelWithAttributedString: words)
    title.isSelectable = false
    title.maximumNumberOfLines = 1
    title.cell?.wraps = false
    title.cell?.truncatesLastVisibleLine = true
    title.lineBreakMode = .byTruncatingTail
    if let date = window.resetsAt { title.toolTip = "Resets \(AgentUsageWindow.resetPhrase(date))" }
    let left = Self.label(UsageGlanceText.used(window), size: AgentPaletteMetrics.typeFootnote, ink: PaletteInk.secondary)
    left.font = roundedAppFont(size: AgentPaletteMetrics.typeFootnote).withMonospacedDigits
    left.setContentCompressionResistancePriority(.required, for: .horizontal)
    let top = NSStackView(views: [title, NSView(), left])
    top.orientation = .horizontal
    top.alignment = .firstBaseline
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let meter = UsageGlanceMeter()
    meter.used = Double(min(100, max(0, window.usedPercent))) / 100
    meter.translatesAutoresizingMaskIntoConstraints = false
    meter.heightAnchor.constraint(equalToConstant: Self.meterHeight).isActive = true

    // On its own line, so a long title never cuts it.
    var lines: [NSView] = [top, meter]
    if let reset = UsageGlanceText.reset(window) {
      let when = Self.label(reset, size: AgentPaletteMetrics.typeFootnote, ink: PaletteInk.tertiary)
      when.lineBreakMode = .byTruncatingTail
      lines.append(when)
    }
    let block = NSStackView(views: lines)
    block.orientation = .vertical
    block.alignment = .leading
    block.spacing = 5
    for view in lines {
      view.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
    }
    block.setAccessibilityElement(true)
    block.setAccessibilityLabel(window.title)
    block.setAccessibilityValue(
      [UsageGlanceText.used(window), UsageGlanceText.reset(window)].compactMap { $0 }.joined(separator: ", ")
    )
    return block
  }

  private func foot() -> NSView {
    let settings = GlassCircleButton(
      icon: .settings, accessibilityDescription: "Usage in Settings",
      diameter: Self.footDisc, size: Self.footGlyph
    )
    settings.button.target = self
    settings.button.action = #selector(openSettings)
    settings.button.toolTip = "Usage in Settings"
    let more = GlassCircleButton(
      icon: .chevronDown, accessibilityDescription: "More",
      diameter: Self.footDisc, size: Self.footGlyph
    )
    more.button.image = more.button.image.map { Self.lowered($0, by: Self.chevronDrop) }
    more.button.target = self
    more.button.action = #selector(openMore)
    more.button.toolTip = "Boltty AI, chats, updates and Quit"
    let row = NSStackView(views: [settings, NSView(), more])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.edgeInsets = NSEdgeInsets(
      top: 2, left: Self.footInset - Self.inset, bottom: 0, right: Self.footInset - Self.inset)
    return row
  }

  @objc private func openSettings() {
    close()
    onOpenSettings?()
  }

  @objc private func openMore() {
    close()
    onMore?()
  }

  // MARK: - Parts

  /// A down chevron's weight is in its arms, so centred by its box it reads
  /// high in the disc (measured 0.75 pt above the disc's centre on screen).
  static let chevronDrop: CGFloat = 1.5

  private static func lowered(_ image: NSImage, by drop: CGFloat) -> NSImage {
    let lowered = NSImage(size: image.size, flipped: false) { rect in
      image.draw(in: rect.offsetBy(dx: 0, dy: -drop))
      return true
    }
    lowered.isTemplate = image.isTemplate
    lowered.accessibilityDescription = image.accessibilityDescription
    return lowered
  }

  private static func attributes(size: CGFloat, weight: NSFont.Weight = .regular, ink: NSColor) -> [NSAttributedString.Key: Any] {
    [.font: roundedAppFont(size: size, weight: weight), .foregroundColor: ink]
  }

  private static func label(
    _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, ink: NSColor
  ) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = roundedAppFont(size: size, weight: weight)
    label.textColor = ink
    label.lineBreakMode = .byTruncatingTail
    label.isSelectable = false
    return label
  }
}

private final class UsageGlanceWell: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = PaletteInk.tertiaryFill.cgColor
    layer?.cornerRadius = UsageGlanceController.wellCorner
    layer?.cornerCurve = .continuous
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// What is used, in Boltty's accent, on a track of the glass's own fill.
private final class UsageGlanceMeter: NSView {
  var used: Double = 0 { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    let radius = bounds.height / 2
    PaletteInk.fill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    let width = bounds.width * min(max(used, 0), 1)
    guard width > 0 else { return }
    var filled = bounds
    filled.size.width = max(width, bounds.height)
    BolttyBrand.accentOnGlass.setFill()
    NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
  }
}

private extension NSFont {
  var withMonospacedDigits: NSFont {
    let descriptor = fontDescriptor.addingAttributes([
      .featureSettings: [[
        NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
        NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
      ]],
    ])
    return NSFont(descriptor: descriptor, size: pointSize) ?? self
  }
}
