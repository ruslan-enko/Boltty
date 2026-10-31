import AppKit

final class WorkingDirectoryChipView: PaletteIconButton {
  var onChoose: (() -> Void)?
  private(set) var chip: WorkingDirectoryChip?
  private let warningIcon = NSImageView()
  private let icon = NSImageView()
  private let nameLabel = NSTextField(labelWithString: "")

  var isEditableForTesting: Bool { chip?.isEditable ?? false }
  var nameForTesting: String? { nameLabel.isHidden ? nil : nameLabel.stringValue }
  var nameFitsForTesting: Bool {
    nameLabel.frame.width + 0.5 >= ceil(nameLabel.fittingSize.width)
  }
  var showsPillForTesting: Bool { chip?.folderLabel != nil }
  var iconWidthForTesting: CGFloat { iconWidth }
  var fillForTesting: NSColor? {
    layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
  }
  private static func symbolFolder(pointSize: CGFloat) -> NSImage? {
    NSImage(systemSymbolName: "folder", accessibilityDescription: "Working folder")?
      .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
  }
  private(set) var isChatSized = false
  private lazy var widthConstraint =
    widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceOrbDiameter)
  private lazy var heightConstraint =
    heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceOrbDiameter)
  var diameter: CGFloat = AgentPaletteMetrics.voiceOrbDiameter {
    didSet { if diameter != oldValue { syncSize() } }
  }
  var showsWarningForTesting: Bool { !warningIcon.isHidden }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    isBordered = false
    bezelStyle = .regularSquare
    imagePosition = .noImage
    title = ""
    focusRingType = .none
    target = self
    action = #selector(chooseFolder)
    setAccessibilityIdentifier("boltty.ask.workingDirectory")

    icon.imageScaling = .scaleNone
    addSubview(icon)

    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.maximumNumberOfLines = 1
    nameLabel.isSelectable = false
    nameLabel.isHidden = true
    addSubview(nameLabel)

    warningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
      accessibilityDescription: nil)
    warningIcon.contentTintColor = AgentPaletteMetrics.directoryChipWarningTint
    warningIcon.imageScaling = .scaleProportionallyUpOrDown
    warningIcon.isHidden = true
    addSubview(warningIcon)
    NSLayoutConstraint.activate([widthConstraint, heightConstraint])
    syncLook()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(_ chip: WorkingDirectoryChip) {
    guard self.chip != chip else { return }
    self.chip = chip
    isEnabled = true
    warningIcon.isHidden = chip.warning == nil
    toolTip = chip.tooltip
    setAccessibilityLabel(chip.accessibilityLabel)
    syncLook()
  }

  func setChatSized(_ chat: Bool) {
    guard chat != isChatSized else { return }
    isChatSized = chat
    syncLook()
  }

  private func syncIcon() {
    let named = chip?.folderLabel != nil
    let pointSize = named
      ? AgentPaletteMetrics.folderChipFontSize(chat: isChatSized)
      : ComposerControlGroup.pointSize(chat: isChatSized)
    guard pointSize != iconPointSize else { return }
    iconPointSize = pointSize
    icon.image = Self.symbolFolder(pointSize: pointSize)
  }
  private var iconPointSize: CGFloat = 0

  var slotWidth: CGFloat {
    chip?.folderLabel == nil
      ? diameter
      : pillWidth + AgentPaletteMetrics.folderChipSlotMargin * 2
  }

  private var nameWidth: CGFloat {
    min(ceil(nameLabel.attributedStringValue.size().width),
        AgentPaletteMetrics.folderChipMaxNameWidth)
  }

  private var nameCellInset: CGFloat {
    max(0, (ceil(nameLabel.fittingSize.width)
      - ceil(nameLabel.attributedStringValue.size().width)) / 2)
  }

  private var iconWidth: CGFloat { ceil(icon.image?.size.width ?? ComposerControlGroup.glyph) }

  private var pillWidth: CGFloat {
    let chat = isChatSized
    return AgentPaletteMetrics.folderChipPadding(chat: chat) * 2
      + iconWidth
      + AgentPaletteMetrics.folderChipIconGap(chat: chat)
      + nameWidth
  }

  private func syncLook() {
    let chat = isChatSized
    syncIcon()
    if let name = chip?.folderLabel {
      nameLabel.font = roundedAppFont(size: AgentPaletteMetrics.folderChipFontSize(chat: chat))
      nameLabel.stringValue = name
      nameLabel.isHidden = false
      restingBackground = AgentPaletteMetrics.folderChipFill
      hoverBackground = AgentPaletteMetrics.folderChipFill
      disabledTint = ComposerControlGroup.restingInk
    } else {
      nameLabel.stringValue = ""
      nameLabel.isHidden = true
      restingBackground = .clear
      hoverBackground = .clear
      disabledTint = ComposerControlGroup.disabledInk
    }
    layer?.backgroundColor = restingBackground.cgColor
    syncSize()
    applyTint()
    needsLayout = true
  }

  private func syncSize() {
    let named = chip?.folderLabel != nil
    let width = named ? pillWidth : diameter
    let height = named ? AgentPaletteMetrics.folderChipHeight(chat: isChatSized) : diameter
    if widthConstraint.constant != width { widthConstraint.constant = width }
    if heightConstraint.constant != height { heightConstraint.constant = height }
  }

  override func applyTint() {
    super.applyTint()
    icon.contentTintColor = contentTintColor
    nameLabel.textColor = contentTintColor
  }

  override func layout() {
    super.layout()
    let chat = isChatSized
    let glyph = ComposerControlGroup.glyph(chat: chat)
    let iconSize = icon.image?.size ?? NSSize(width: glyph, height: glyph)
    if chip?.folderLabel != nil {
      layer?.applyPaletteCorner(radius: AgentPaletteMetrics.folderChipCornerRadius(chat: chat))
      let padding = AgentPaletteMetrics.folderChipPadding(chat: chat)
      icon.frame = NSRect(
        x: padding, y: (bounds.height - iconSize.height) / 2,
        width: iconSize.width, height: iconSize.height)
      let labelHeight = ceil(nameLabel.fittingSize.height)
      let inset = nameCellInset
      nameLabel.frame = NSRect(
        x: padding + iconWidth + AgentPaletteMetrics.folderChipIconGap(chat: chat) - inset,
        y: (bounds.height - labelHeight) / 2, width: nameWidth + inset * 2, height: labelHeight)
    } else {
      icon.frame = NSRect(
        x: (bounds.width - iconSize.width) / 2, y: (bounds.height - iconSize.height) / 2,
        width: iconSize.width, height: iconSize.height)
    }
    let warning = AgentPaletteMetrics.directoryChipGlyphPointSize
    warningIcon.frame = NSRect(
      x: icon.frame.maxX - warning / 2,
      y: isFlipped ? icon.frame.maxY - warning / 2 : icon.frame.minY - warning / 2,
      width: warning, height: warning)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, frame.contains(point) else { return nil }
    return self
  }

  @objc private func chooseFolder() {
    guard chip != nil else { return }
    onChoose?()
  }

  override func accessibilityPerformPress() -> Bool {
    guard chip != nil else { return false }
    onChoose?()
    return true
  }
}

// MARK: - Plan usage text

enum UsagePillText {
  static func title(for usage: AgentUsage, now: Date = Date()) -> String? {
    guard let window = usage.pressing else { return nil }
    if window.severity == .exhausted {
      guard let reset = window.resetsAt else { return "Limit reached" }
      return "Limit reached · back \(when(reset, now: now))"
    }
    return "\(window.title) \(window.usedPercent)%"
  }

  static func detail(for usage: AgentUsage, agent: AgentId, now: Date = Date()) -> String {
    (["\(agent.displayName) plan", windowDetails(for: usage, now: now)]).joined(separator: "\n")
  }

  static func windowDetails(for usage: AgentUsage, now: Date = Date()) -> String {
    usage.windows.map { window in
      var line = "\(window.title): \(window.usedPercent)% used"
      if let reset = window.resetsAt { line += ", resets \(when(reset, now: now))" }
      return line
    }.joined(separator: "\n")
  }

  static func when(_ date: Date, now: Date) -> String {
    AgentUsageWindow.resetPhrase(date, now: now)
  }

  static func symbolName(for percent: Int) -> String {
    let steps = [0, 33, 50, 67, 100]
    let nearest = steps.min { abs($0 - percent) < abs($1 - percent) } ?? 0
    return "gauge.with.dots.needle.\(nearest)percent"
  }
}

enum PlanUsageRingReading {
  static func percent(_ usage: AgentUsage?) -> Int {
    min(100, max(0, usage?.pressing?.usedPercent ?? 0))
  }
  static func detail(
    usage: AgentUsage?, agent: AgentId?, context: AgentContextUsage?, chatIsOpen: Bool
  ) -> String {
    let heading = agent.map { "\($0.displayName) plan limits" } ?? "Plan limits"
    let plan = usage.flatMap { $0.windows.isEmpty ? nil : $0 }.map {
      UsagePillText.windowDetails(for: $0)
    } ?? "Usage is not available from this agent."
    let contextText = (chatIsOpen ? context : nil).map {
      "Chat context: \($0.percent)% used\n"
        + "\(AgentCompaction.tokens($0.usedTokens)) of \(AgentCompaction.tokens($0.limitTokens)) tokens"
    } ?? (chatIsOpen ? "Chat context: usage is not available." : "Chat context: available after a chat starts.")
    return "\(heading)\n\(plan)\n\n\(contextText)"
  }
}

final class PlanUsageRingView: PaletteIconButton {
  private lazy var diameterConstraint =
    heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceOrbDiameter)
  private lazy var widthConstraint =
    widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceOrbDiameter)
  var diameter: CGFloat {
    get { diameterConstraint.constant }
    set {
      if diameterConstraint.constant != newValue { diameterConstraint.constant = newValue }
      syncWidth()
    }
  }
  var ringOuterDiameter: CGFloat = AgentPaletteMetrics.planRingDiameter + AgentPaletteMetrics.planRingStroke {
    didSet { if ringOuterDiameter != oldValue { needsDisplay = true } }
  }
  var hasReading: Bool { !(usage?.windows.isEmpty ?? true) || context != nil }
  private func syncWidth() {
    let width = hasReading ? diameterConstraint.constant : 0
    if widthConstraint.constant != width { widthConstraint.constant = width }
  }
  private(set) var usage: AgentUsage?
  private var agent: AgentId?
  private(set) var context: AgentContextUsage?
  private var canCompact = false
  var chatIsOpen = false {
    didSet { if chatIsOpen != oldValue { refreshHelp() } }
  }
  var onCompact: (() -> Void)?
  var percentForTesting: Int { PlanUsageRingReading.percent(usage) }
  var tintForTesting: NSColor { AgentPaletteMetrics.planRingInk }
  var titleForTesting: String { usage.flatMap { UsagePillText.title(for: $0) } ?? "Plan usage unavailable" }
  var detailForTesting: String { toolTip ?? "" }
  private var cacheIsCold = false
  var offersCompactForTesting: Bool {
    canCompact && chatIsOpen
      && AgentContextUsage.offersCompact(percent: context?.percent ?? 0, cacheIsCold: cacheIsCold)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    isBordered = false
    bezelStyle = .regularSquare
    imagePosition = .imageOnly
    title = ""
    focusRingType = .none
    target = self
    action = #selector(showLimits)
    setAccessibilityIdentifier("boltty.ask.usage")
    setAccessibilityLabel("Plan limits and chat context")
    NSLayoutConstraint.activate([diameterConstraint, widthConstraint])
    syncWidth()
    refreshHelp()
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(_ usage: AgentUsage?, agent: AgentId?) {
    guard self.usage != usage || self.agent != agent else { return }
    self.usage = usage
    self.agent = agent
    needsDisplay = true
    syncWidth()
    refreshHelp()
  }
  func apply(context: AgentContextUsage?, canCompact: Bool, cacheIsCold: Bool = false) {
    guard self.context != context || self.canCompact != canCompact || self.cacheIsCold != cacheIsCold
    else { return }
    self.context = context
    self.canCompact = canCompact
    self.cacheIsCold = cacheIsCold
    syncWidth()
    refreshHelp()
  }
  private func refreshHelp() {
    toolTip = PlanUsageRingReading.detail(usage: usage, agent: agent, context: context, chatIsOpen: chatIsOpen)
      + (cacheIsCold && offersCompactForTesting
        ? "\n\nAway for over an hour, this chat's cache has expired: compacting first makes the next message cheaper."
        : "")
    setAccessibilityValue(titleForTesting)
    if PaletteHelpPresenter.shared.isPinned(for: self) { showLimits() }
  }
  @objc private func showLimits() {
    let offers = offersCompactForTesting
    PaletteHelpPresenter.shared.show(
      for: self, text: detailForTesting, pinned: true,
      actionTitle: offers ? "Compact conversation" : nil,
      action: offers ? { [weak self] in
        guard let self, self.offersCompactForTesting else { return }
        self.onCompact?()
      } : nil)
  }
  func compactForTesting() {
    guard offersCompactForTesting else { return }
    onCompact?()
  }
  override func draw(_ dirtyRect: NSRect) {
    let stroke = ringOuterDiameter * AgentPaletteMetrics.planRingStrokeRatio
    let diameter = ringOuterDiameter - stroke
    let rect = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                      width: diameter, height: diameter)
    let track = NSBezierPath(ovalIn: rect)
    track.lineWidth = stroke
    AgentPaletteMetrics.planRingTrack.setStroke()
    track.stroke()
    let percent = percentForTesting
    guard percent > 0 else { return }
    let arc = NSBezierPath()
    arc.lineWidth = track.lineWidth
    arc.lineCapStyle = .round
    arc.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: diameter / 2,
                  startAngle: AgentPaletteMetrics.planRingStartAngle,
                  endAngle: AgentPaletteMetrics.planRingStartAngle + CGFloat(percent) * 3.6)
    tintForTesting.setStroke()
    arc.stroke()
  }
}
