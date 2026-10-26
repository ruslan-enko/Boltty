import AppKit

final class PaletteActivityRowView: NSView {
  var onToggle: ((String) -> Void)?

  private(set) var activity: AgentActivity
  private(set) var isExpanded: Bool

  private let glyph = NSImageView()
  private let headline = NSTextField(labelWithString: "")
  private let chevron = NSImageView()
  private let detail = NSTextField(wrappingLabelWithString: "")
  private let steps = NSStackView()
  private let button = PaletteDisclosureButton()
  private var rowHeight: NSLayoutConstraint!

  var headlineForTesting: String { headline.stringValue }
  var detailForTesting: String { detail.attributedStringValue.string }
  var isDetailVisibleForTesting: Bool { !detail.isHidden }
  var hasDisclosureForTesting: Bool { !chevron.isHidden }
  var stepTextsForTesting: [String] {
    steps.isHidden ? [] : steps.arrangedSubviews.compactMap {
      ($0.subviews.first { $0 is NSTextField } as? NSTextField)?.stringValue
    }
  }
  func pressForTesting() { didPress() }

  init(activity: AgentActivity, isExpanded: Bool) {
    self.activity = activity
    self.isExpanded = isExpanded
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    glyph.translatesAutoresizingMaskIntoConstraints = false
    glyph.imageScaling = .scaleProportionallyDown

    headline.translatesAutoresizingMaskIntoConstraints = false
    headline.font = roundedAppFont(size: AgentPaletteMetrics.previewActivityNameFontSize)
    headline.lineBreakMode = .byTruncatingTail
    headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.imageScaling = .scaleProportionallyDown
    chevron.setContentHuggingPriority(.required, for: .horizontal)

    detail.translatesAutoresizingMaskIntoConstraints = false
    detail.lineBreakMode = .byWordWrapping
    detail.isSelectable = true
    detail.allowsEditingTextAttributes = true

    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.title = ""
    button.target = self
    button.action = #selector(didPress)
    button.onHover = { [weak self] _ in self?.applyInk() }

    let head = NSStackView(views: [glyph, headline, chevron])
    head.translatesAutoresizingMaskIntoConstraints = false
    head.orientation = .horizontal
    head.alignment = .centerY
    head.spacing = AgentPaletteMetrics.previewActivityRowSpacing * 2
    steps.translatesAutoresizingMaskIntoConstraints = false
    steps.orientation = .vertical
    steps.alignment = .leading
    steps.spacing = 0
    addSubview(head)
    addSubview(detail)
    addSubview(steps)
    addSubview(button)

    NSLayoutConstraint.activate([
      head.leadingAnchor.constraint(equalTo: leadingAnchor),
      head.trailingAnchor.constraint(equalTo: trailingAnchor),
      head.topAnchor.constraint(equalTo: topAnchor),
      head.heightAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.previewActivityRowHeight),
      glyph.widthAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.previewActivityGlyphSize),
      glyph.heightAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.previewActivityGlyphSize),
      chevron.widthAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.previewActivityGlyphSize),
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.heightAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.previewActivityRowHeight),
      detail.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: AgentPaletteMetrics.previewActivityDetailIndent),
      detail.trailingAnchor.constraint(equalTo: trailingAnchor),
      detail.topAnchor.constraint(
        equalTo: head.bottomAnchor,
        constant: AgentPaletteMetrics.previewActivityDetailTopMargin),
      detail.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
      steps.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: AgentPaletteMetrics.previewActivityDetailIndent),
      steps.trailingAnchor.constraint(equalTo: trailingAnchor),
      steps.topAnchor.constraint(
        equalTo: head.bottomAnchor,
        constant: AgentPaletteMetrics.previewActivityDetailTopMargin),
    ])

    rowHeight = heightAnchor.constraint(
      equalToConstant: AgentPaletteMetrics.previewActivityRowHeight)
    rowHeight.isActive = true

    setAccessibilityElement(true)
    setAccessibilityRole(.disclosureTriangle)
    apply(activity, isExpanded: isExpanded)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func applyInk() {
    let lit = button.isHovered
    headline.textColor = activity.state == .failed
      ? Self.tint(for: .failed)
      : (lit ? PaletteInk.primary : PaletteInk.secondary)
    chevron.contentTintColor = lit ? PaletteInk.secondary : PaletteInk.tertiary
  }

  @objc private func didPress() {
    guard Self.opens(activity) else { return }
    onToggle?(activity.id)
  }

  static func opens(_ activity: AgentActivity) -> Bool {
    if let plan = activity.plan, !plan.isEmpty { return activity.state == .completed }
    return !(activity.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func showsSteps(_ activity: AgentActivity, isExpanded: Bool) -> Bool {
    guard let plan = activity.plan, !plan.isEmpty else { return false }
    return isExpanded || activity.state != .completed
  }

  func apply(_ value: AgentActivity, isExpanded expanded: Bool) {
    activity = value
    isExpanded = expanded

    let tint = Self.tint(for: value.state)
    let isCompaction = value.name == AgentCompaction.toolName
    let symbol = isCompaction ? "arrow.down.right.and.arrow.up.left"
      : value.isThought ? "brain" : Self.symbol(for: value.state)
    glyph.image = NSImage(
      systemSymbolName: symbol,
      accessibilityDescription: value.state.rawValue
    )?.withSymbolConfiguration(.init(
      pointSize: AgentPaletteMetrics.previewActivityGlyphPointSize, weight: .medium
    ))
    glyph.contentTintColor = tint

    headline.stringValue = value.headline
    headline.toolTip = value.files.first ?? value.name

    let opens = Self.opens(value)
    chevron.isHidden = !opens
    button.isEnabled = opens
    chevron.image = NSImage(
      systemSymbolName: expanded ? "chevron.down" : "chevron.right",
      accessibilityDescription: expanded ? "Hide output" : "Show output"
    )?.withSymbolConfiguration(.init(
      pointSize: AgentPaletteMetrics.previewActivityChevronPointSize, weight: .semibold
    ))
    applyInk()

    let showsSteps = Self.showsSteps(value, isExpanded: expanded)
    steps.isHidden = !showsSteps
    steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if showsSteps {
      for step in value.plan ?? [] { steps.addArrangedSubview(Self.stepRow(step)) }
    }
    detail.isHidden = value.plan != nil || !(opens && expanded)
    detail.attributedStringValue = detail.isHidden
      ? NSAttributedString()
      : Self.detailText(value.detail ?? "")
    setAccessibilityLabel(value.headline)
    setAccessibilityValue(expanded ? "expanded" : "collapsed")
    needsLayout = true
  }

  func setWidth(_ width: CGFloat, height: CGFloat) {
    detail.preferredMaxLayoutWidth = width - AgentPaletteMetrics.previewActivityDetailIndent
    guard abs(rowHeight.constant - height) > 0.5 else { return }
    rowHeight.constant = height
    needsLayout = true
  }

  static func shown(_ detail: String) -> String {
    let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count > AgentPaletteMetrics.previewActivityDetailLineCap else { return trimmed }
    let kept = lines.prefix(AgentPaletteMetrics.previewActivityDetailLineCap)
      .joined(separator: "\n")
    return kept + "\n… \(lines.count - AgentPaletteMetrics.previewActivityDetailLineCap) more lines"
  }

  private static func detailText(_ raw: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.minimumLineHeight = AgentPaletteMetrics.previewActivityDetailLineHeight
    paragraph.maximumLineHeight = AgentPaletteMetrics.previewActivityDetailLineHeight
    return NSAttributedString(
      string: shown(raw),
      attributes: [
        .font: NSFont.monospacedSystemFont(
          ofSize: AgentPaletteMetrics.previewActivityDetailFontSize, weight: .regular
        ),
        .foregroundColor: PaletteInk.secondary,
        .paragraphStyle: paragraph,
      ]
    )
  }

  private static func symbol(for state: AgentActivity.State) -> String {
    switch state {
    case .pending: return "circle.dotted"
    case .running: return "circle.dashed"
    case .completed: return "checkmark.circle"
    case .failed: return "exclamationmark.triangle"
    }
  }

  private static func tint(for state: AgentActivity.State) -> NSColor {
    switch state {
    case .failed: return AgentPaletteMetrics.failureCardAccent
    case .completed: return PaletteInk.secondary
    case .pending, .running: return PaletteInk.tertiary
    }
  }

  private static func stepRow(_ step: PlanStep) -> NSView {
    let (symbol, tint): (String, NSColor) = switch step.status {
    case .completed: ("checkmark.circle", PaletteInk.secondary)
    case .inProgress: ("circle.dashed", PaletteInk.primary)
    case .pending: ("circle", PaletteInk.tertiary)
    }
    let glyph = NSImageView()
    glyph.translatesAutoresizingMaskIntoConstraints = false
    glyph.imageScaling = .scaleProportionallyDown
    glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: step.status.rawValue)?
      .withSymbolConfiguration(.init(
        pointSize: AgentPaletteMetrics.previewActivityGlyphPointSize, weight: .medium))
    glyph.contentTintColor = tint
    let label = NSTextField(labelWithString: step.text)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = roundedAppFont(size: AgentPaletteMetrics.previewActivityNameFontSize)
    label.textColor = tint
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.toolTip = step.text
    let row = NSStackView(views: [glyph, label])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = AgentPaletteMetrics.previewActivityRowSpacing * 2
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      row.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewActivityRowHeight),
      glyph.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewActivityGlyphSize),
      glyph.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewActivityGlyphSize),
    ])
    row.setAccessibilityElement(true)
    row.setAccessibilityLabel("\(step.text), \(step.status.rawValue)")
    return row
  }

  static func height(for activity: AgentActivity, width: CGFloat, isExpanded: Bool) -> CGFloat {
    let head = AgentPaletteMetrics.previewActivityRowHeight
    if showsSteps(activity, isExpanded: isExpanded) {
      return head + AgentPaletteMetrics.previewActivityDetailTopMargin * 2
        + CGFloat(activity.plan?.count ?? 0) * AgentPaletteMetrics.previewActivityRowHeight
    }
    guard isExpanded, opens(activity) else { return head }
    let inner = max(width - AgentPaletteMetrics.previewActivityDetailIndent, 1)
    let measured = ceil(detailText(activity.detail ?? "").boundingRect(
      with: NSSize(width: inner, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height)
    return head + AgentPaletteMetrics.previewActivityDetailTopMargin * 2 + measured
  }
}

final class PaletteActivityGroupView: NSView {
  var onToggle: ((String) -> Void)?

  private(set) var activities: [AgentActivity]
  private(set) var isExpanded = false
  private(set) var rows: [PaletteActivityRowView] = []

  private let chevron = NSImageView()
  private let warning = NSImageView()
  private let headline = NSTextField(labelWithString: "")
  private let button = PaletteDisclosureButton()
  private let list = NSStackView()
  private var rowHeight: NSLayoutConstraint!
  private var headlineLeading: NSLayoutConstraint!

  var groupID: String { AgentActivityGroup.id(of: activities) }
  var headlineForTesting: String { headline.stringValue }
  var isOpenForTesting: Bool { !list.isHidden }
  func pressForTesting() { didPress() }

  init(activities: [AgentActivity], expanded: Set<String>) {
    self.activities = activities
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = AgentPaletteMetrics.previewWorkPillFill.cgColor

    headline.translatesAutoresizingMaskIntoConstraints = false
    let font = roundedAppFont(size: AgentPaletteMetrics.previewBodyFontSize)
    headline.font = font
    headline.lineBreakMode = .byTruncatingTail
    headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for glyph in [chevron, warning] {
      glyph.translatesAutoresizingMaskIntoConstraints = false
      glyph.imageScaling = .scaleProportionallyDown
    }
    warning.image = NSImage(
      systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Something failed"
    )?.withSymbolConfiguration(.init(
      pointSize: AgentPaletteMetrics.previewActivityGlyphPointSize, weight: .medium))
    warning.contentTintColor = AgentPaletteMetrics.failureCardAccent

    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.title = ""
    button.target = self
    button.action = #selector(didPress)
    button.onHover = { [weak self] _ in self?.applyInk() }

    list.translatesAutoresizingMaskIntoConstraints = false
    list.orientation = .vertical
    list.alignment = .leading
    list.spacing = AgentPaletteMetrics.previewActivityRowSpacing

    for view in [chevron, warning, headline, list, button] as [NSView] { addSubview(view) }
    let middle = AgentPaletteMetrics.previewWorkPillHeight / 2
    headlineLeading = headline.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: AgentPaletteMetrics.previewWorkPillTextInset)
    NSLayoutConstraint.activate([
      chevron.centerXAnchor.constraint(
        equalTo: leadingAnchor, constant: AgentPaletteMetrics.previewWorkPillChevronCenter),
      chevron.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewWorkPillChevronWidth),
      chevron.centerYAnchor.constraint(equalTo: topAnchor, constant: middle),
      warning.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: AgentPaletteMetrics.previewWorkPillTextInset),
      warning.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewActivityGlyphSize),
      warning.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
      headlineLeading,
      headline.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor, constant: -AgentPaletteMetrics.previewWorkPillTrailingInset),
      headline.firstBaselineAnchor.constraint(
        equalTo: topAnchor, constant: middle + font.capHeight / 2),
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewWorkPillHeight),
      list.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: AgentPaletteMetrics.previewWorkPillTextInset),
      list.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -AgentPaletteMetrics.previewWorkPillTrailingInset),
      list.topAnchor.constraint(equalTo: topAnchor, constant: AgentPaletteMetrics.previewWorkPillListTop),
    ])
    rowHeight = heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewWorkPillHeight)
    rowHeight.isActive = true
    setAccessibilityElement(true)
    setAccessibilityRole(.disclosureTriangle)
    apply(activities, expanded: expanded)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func didPress() { onToggle?(groupID) }

  override func layout() {
    super.layout()
    layer?.applyPaletteCorner(radius: AgentPaletteMetrics.previewWorkPillCornerRadius)
  }

  private func applyInk() {
    let ink = button.isHovered ? PaletteInk.primary : PaletteInk.secondary
    headline.textColor = ink
    chevron.contentTintColor = ink
  }

  func apply(_ value: [AgentActivity], expanded: Set<String>) {
    activities = value
    isExpanded = expanded.contains(groupID)

    let failed = value.contains { $0.state == .failed }
    warning.isHidden = !failed
    headlineLeading.constant = AgentPaletteMetrics.previewWorkPillTextInset
      + (failed ? AgentPaletteMetrics.previewActivityGlyphSize + AgentPaletteMetrics.previewActivityRowSpacing * 3 : 0)
    headline.stringValue = AgentActivityGroup.summary(of: value)
    headline.toolTip = value.filter { !$0.isThought }.map(\.headline).joined(separator: "\n")
    chevron.image = NSImage(
      systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
      accessibilityDescription: isExpanded ? "Hide steps" : "Show steps"
    )?.withSymbolConfiguration(.init(
      pointSize: AgentPaletteMetrics.previewWorkPillChevronPointSize, weight: .regular
    ))
    applyInk()

    if rows.map(\.activity.id) != value.map(\.id) {
      rows.forEach { $0.removeFromSuperview() }
      rows = value.map { activity in
        let row = PaletteActivityRowView(activity: activity, isExpanded: expanded.contains(activity.id))
        row.onToggle = { [weak self] id in self?.onToggle?(id) }
        list.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        return row
      }
    }
    for (row, activity) in zip(rows, value) {
      row.apply(activity, isExpanded: expanded.contains(activity.id))
    }
    list.isHidden = !isExpanded
    setAccessibilityLabel(headline.stringValue)
    setAccessibilityValue(isExpanded ? "expanded" : "collapsed")
    needsLayout = true
  }

  func setWidth(_ width: CGFloat, height: CGFloat, expanded: Set<String>) {
    let inner = Self.listWidth(in: width)
    for row in rows {
      row.setWidth(inner, height: PaletteActivityRowView.height(
        for: row.activity, width: inner, isExpanded: expanded.contains(row.activity.id)))
    }
    guard abs(rowHeight.constant - height) > 0.5 else { return }
    rowHeight.constant = height
    needsLayout = true
  }

  private static func listWidth(in width: CGFloat) -> CGFloat {
    width - AgentPaletteMetrics.previewWorkPillTextInset - AgentPaletteMetrics.previewWorkPillTrailingInset
  }

  static func height(for activities: [AgentActivity], width: CGFloat, expanded: Set<String>) -> CGFloat {
    let head = AgentPaletteMetrics.previewWorkPillHeight
    guard expanded.contains(AgentActivityGroup.id(of: activities)) else { return head }
    let inner = listWidth(in: width)
    let rows = activities.reduce(CGFloat(0)) {
      $0 + PaletteActivityRowView.height(for: $1, width: inner, isExpanded: expanded.contains($1.id))
    }
    return AgentPaletteMetrics.previewWorkPillListTop + rows
      + CGFloat(max(activities.count - 1, 0)) * AgentPaletteMetrics.previewActivityRowSpacing
      + AgentPaletteMetrics.previewWorkPillListBottomInset
  }
}
