import AppKit

final class BolttyAIOptionRow: NSView {
  var isFocused: Bool = false {
    didSet {
      guard isFocused != oldValue else { return }
      refreshFill(animated: true)
    }
  }

  var isChosen: Bool = false {
    didSet {
      guard isChosen != oldValue else { return }
      mark.isChosen = isChosen
      setAccessibilityValue(isChosen)
    }
  }

  var onClick: (() -> Void)?

  private var isHovered = false {
    didSet { if isHovered != oldValue { refreshFill(animated: true) } }
  }
  private var isPressed = false {
    didSet { if isPressed != oldValue { refreshFill(animated: false) } }
  }
  private var hoverArea: NSTrackingArea?

  var isHoveredForTesting: Bool {
    get { isHovered }
    set { isHovered = newValue }
  }
  var isPressedForTesting: Bool {
    get { isPressed }
    set { isPressed = newValue }
  }
  var fillAlphaForTesting: CGFloat {
    layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0
  }
  var textScaleForTesting: CGFloat { layer?.transform.m11 ?? 1 }
  var wordsAreSelectableForTesting: Bool { text.isSelectable }
  var wordsForTesting: NSAttributedString { text.attributedStringValue }
  var markUsesSystemControlForTesting: Bool { mark.usesSystemControl }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseEntered(with event: NSEvent) { isHovered = true }
  override func mouseExited(with event: NSEvent) { isHovered = false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, frame.contains(point) else { return nil }
    return self
  }

  override func mouseDown(with event: NSEvent) { isPressed = true }

  override func mouseDragged(with event: NSEvent) {
    isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    isPressed = false
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick?()
  }

  let label: String
  let detail: String?
  let value: String

  private let mark: OptionMarkView
  private let text = NSTextField(wrappingLabelWithString: "")
  private let numberLabel = NSTextField(labelWithString: "")
  var numberForTesting: String? { numberLabel.isHidden ? nil : numberLabel.stringValue }

  init(option: AgentQuestion.Option, multiple: Bool, number: Int? = nil) {
    self.label = option.label
    self.detail = option.detail
    self.value = option.value
    self.mark = OptionMarkView(multiple: multiple)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    text.translatesAutoresizingMaskIntoConstraints = false
    text.isSelectable = false
    text.attributedStringValue = Self.attributed(option)
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    text.setAccessibilityRole(.staticText)

    mark.translatesAutoresizingMaskIntoConstraints = false
    addSubview(mark)
    addSubview(text)

    numberLabel.translatesAutoresizingMaskIntoConstraints = false
    numberLabel.font = roundedAppFont(size: AgentPaletteMetrics.typeMeta, weight: .medium)
    numberLabel.textColor = PaletteInk.tertiary
    numberLabel.alignment = .right
    numberLabel.stringValue = number.map(String.init) ?? ""
    numberLabel.isHidden = number == nil
    addSubview(numberLabel)

    let horizontal = AgentPaletteMetrics.previewOptionHorizontalPadding
    let vertical = AgentPaletteMetrics.previewOptionVerticalPadding
    let markSize = AgentPaletteMetrics.previewOptionMarkSize

    NSLayoutConstraint.activate([
      mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontal),
      mark.widthAnchor.constraint(equalToConstant: markSize),
      mark.heightAnchor.constraint(equalToConstant: markSize),
      mark.topAnchor.constraint(
        equalTo: topAnchor,
        constant: vertical + (Self.labelLineHeight - markSize) / 2
      ),

      text.leadingAnchor.constraint(
        equalTo: mark.trailingAnchor,
        constant: AgentPaletteMetrics.previewOptionMarkSpacing
      ),
      text.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -horizontal - Self.numberColumn),
      text.topAnchor.constraint(equalTo: topAnchor, constant: vertical),
      text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vertical),
      numberLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontal),
      numberLabel.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(multiple ? .checkBox : .radioButton)
    setAccessibilityLabel(option.detail.map { "\(option.label), \($0)" } ?? option.label)
    refreshFill()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    layer?.applyPaletteCorner(radius: AgentPaletteMetrics.previewOptionCornerRadius)
    let width = Self.textWidth(in: bounds.width)
    guard width > 0, abs(text.preferredMaxLayoutWidth - width) > 0.5 else { return }
    text.preferredMaxLayoutWidth = width
    text.invalidateIntrinsicContentSize()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshFill()
  }

  override func accessibilityPerformPress() -> Bool {
    guard let onClick else { return false }
    onClick()
    return true
  }

  private func refreshFill(animated: Bool = false) {
    guard let layer else { return }
    let lit = isFocused || isPressed
    let target = (lit
      ? PaletteInk.secondaryFill
      : isHovered ? PaletteInk.tertiaryFill : NSColor.clear).cgColor
    let previous = layer.presentation()?.backgroundColor ?? layer.backgroundColor
    layer.backgroundColor = target
    layer.borderWidth = lit ? 1 / max(window?.backingScaleFactor ?? 2, 1) : 0
    layer.borderColor = PaletteInk.selectedFill.cgColor
    guard animated, !MotionPreferences.reduceMotion else { return }
    let fade = CABasicAnimation(keyPath: "backgroundColor")
    fade.fromValue = previous
    fade.toValue = target
    fade.duration = AgentPaletteMetrics.hoverFadeDuration
    fade.timingFunction = Motion.standardCurve
    layer.add(fade, forKey: "hover")
  }

  static func height(for option: AgentQuestion.Option, width: CGFloat) -> CGFloat {
    let bounds = attributed(option).boundingRect(
      with: CGSize(width: max(textWidth(in: width), 1), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let text = max(ceil(bounds.height), AgentPaletteMetrics.previewOptionMarkSize)
    return text + AgentPaletteMetrics.previewOptionVerticalPadding * 2
  }

  private static func textWidth(in width: CGFloat) -> CGFloat {
    width
      - AgentPaletteMetrics.previewOptionHorizontalPadding * 2
      - AgentPaletteMetrics.previewOptionMarkSize
      - AgentPaletteMetrics.previewOptionMarkSpacing
      - numberColumn
  }

  private static let numberColumn: CGFloat = 20

  private static var labelLineHeight: CGFloat { AgentPaletteMetrics.previewBodyLineHeight }

  private static func attributed(_ option: AgentQuestion.Option) -> NSAttributedString {
    let labelParagraph = NSMutableParagraphStyle()
    labelParagraph.minimumLineHeight = labelLineHeight
    labelParagraph.maximumLineHeight = labelLineHeight
    labelParagraph.lineBreakMode = .byWordWrapping

    let string = NSMutableAttributedString(
      string: option.label,
      attributes: [
        .font: roundedAppFont(size: AgentPaletteMetrics.previewBodyFontSize, weight: .medium),
        .foregroundColor: PaletteInk.primary,
        .paragraphStyle: labelParagraph,
      ]
    )
    if let detail = option.detail, !detail.isEmpty {
      let detailParagraph = NSMutableParagraphStyle()
      detailParagraph.lineBreakMode = .byWordWrapping
      detailParagraph.paragraphSpacingBefore = AgentPaletteMetrics.previewOptionDetailSpacing
      let attributes: [NSAttributedString.Key: Any] = [
        .font: roundedAppFont(size: AgentPaletteMetrics.typeMeta),
        .foregroundColor: PaletteInk.secondary,
        .paragraphStyle: detailParagraph,
      ]
      string.append(NSAttributedString(string: "\n", attributes: attributes))
      string.append(codeSpans(detail, attributes: attributes))
    }
    return string
  }

  static func codeSpans(
    _ text: String,
    attributes: [NSAttributedString.Key: Any]
  ) -> NSAttributedString {
    let pieces = text.components(separatedBy: "`")
    guard pieces.count > 2, pieces.count % 2 == 1 else {
      return NSAttributedString(string: text, attributes: attributes)
    }
    var code = attributes
    code[.font] = NSFont.monospacedSystemFont(ofSize: AgentPaletteMetrics.typeMeta, weight: .regular)
    let out = NSMutableAttributedString()
    for (index, piece) in pieces.enumerated() {
      out.append(NSAttributedString(string: piece, attributes: index.isMultiple(of: 2) ? attributes : code))
    }
    return out
  }
}

private final class OptionMarkView: NSView {
  private let button: NSButton

  var isChosen = false {
    didSet { button.state = isChosen ? .on : .off }
  }

  var usesSystemControl: Bool { true }

  init(multiple: Bool) {
    button = multiple
      ? NSButton(checkboxWithTitle: "", target: nil, action: nil)
      : NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    super.init(frame: .zero)
    button.controlSize = .large
    button.refusesFirstResponder = true
    button.setAccessibilityElement(false)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.centerXAnchor.constraint(equalTo: centerXAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - A permission, as a Mac asks for one

/// What a permission is about, verbatim: the tool's own name as a label, the
/// command under it in mono, and a long one cut to `maximumLines` with a link
/// that says how much is left. The tool's name is a label, not the
/// command's first line: in the same mono it reads as part of the command.
final class BolttyAICommandWell: NSView {
  /// The lines a long command shows. One line more shows whole: the link
  /// would take that line's room to hide it.
  static let maximumLines = 6

  private let label = NSTextField(labelWithString: "")
  private let text = NSTextField(wrappingLabelWithString: "")
  private let more = BolttyAIWellLink(labelWithString: "")
  private let column = NSStackView()
  private var tool: String?
  private var command = ""
  private var isExpanded = false

  var stringForTesting: String {
    ([tool].compactMap { $0 } + [text.stringValue]).joined(separator: "\n")
  }
  var isTruncatedForTesting: Bool { !showsEverything }
  var moreTitleForTesting: String? { more.isHidden ? nil : more.stringValue }
  func toggleForTesting() { toggle() }
  var showsEverything: Bool { more.isHidden || isExpanded }

  var onResize: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = AgentPaletteMetrics.failureDetailsFill.cgColor

    label.font = Self.labelFont
    label.textColor = PaletteInk.secondary
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    text.isSelectable = true
    text.allowsEditingTextAttributes = true
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    more.font = Self.labelFont
    more.textColor = PaletteInk.secondary
    more.setAccessibilityRole(.button)
    more.onClick = { [weak self] in self?.toggle() }
    more.isHidden = true

    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 0
    column.translatesAutoresizingMaskIntoConstraints = false
    column.setViews([label, text, more], in: .leading)
    column.setCustomSpacing(AgentPaletteMetrics.serviceWellLabelGap, after: label)
    column.setCustomSpacing(AgentPaletteMetrics.serviceWellLinkGap, after: text)
    addSubview(column)

    let pad = AgentPaletteMetrics.serviceWellPadding
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.trailingAnchor.constraint(equalTo: trailingAnchor),
      column.topAnchor.constraint(equalTo: topAnchor),
      column.bottomAnchor.constraint(equalTo: bottomAnchor),
      text.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -pad * 2),
      label.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor, constant: -pad * 2),
    ])
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ words: String) {
    let parts = Self.parts(of: words)
    tool = parts.tool
    command = parts.command
    isExpanded = false
    refresh()
  }

  /// `PermissionSentence.detail`'s shape: the tool's name, then what it
  /// would touch, a line each. One line alone is shown as it is.
  static func parts(of words: String) -> (tool: String?, command: String) {
    let lines = words.components(separatedBy: "\n")
    guard lines.count > 1 else { return (nil, words) }
    return (lines[0], lines.dropFirst().joined(separator: "\n"))
  }

  override func layout() {
    super.layout()
    layer?.applyPaletteCorner(radius: AgentPaletteMetrics.failureDetailsCornerRadius)
    let width = bounds.width - AgentPaletteMetrics.serviceWellPadding * 2
    guard width > 0, abs(text.preferredMaxLayoutWidth - width) > 0.5 else { return }
    text.preferredMaxLayoutWidth = width
    text.invalidateIntrinsicContentSize()
  }

  private func toggle() {
    isExpanded.toggle()
    refresh()
    onResize?()
  }

  private func refresh() {
    let lines = command.components(separatedBy: "\n")
    let truncates = Self.truncates(lines)
    label.stringValue = tool ?? ""
    label.isHidden = tool == nil
    text.attributedStringValue = Self.styled(Self.shown(lines, expanded: isExpanded))
    more.isHidden = !truncates
    more.stringValue = isExpanded ? "Show Less" : "Show \(lines.count - Self.maximumLines) More Lines"
    more.setAccessibilityLabel(more.stringValue)
    column.edgeInsets = Self.insets(labelled: tool != nil, linked: truncates)
    needsLayout = true
  }

  private static func truncates(_ lines: [String]) -> Bool { lines.count > maximumLines + 1 }

  private static func shown(_ lines: [String], expanded: Bool) -> String {
    let cut = truncates(lines) && !expanded ? Array(lines.prefix(maximumLines)) : lines
    return cut.joined(separator: "\n")
  }

  /// Measured to the ink: the first line's caps and the last line's
  /// baseline stand `serviceWellPadding` from the well's edge.
  private static func insets(labelled: Bool, linked: Bool) -> NSEdgeInsets {
    let pad = AgentPaletteMetrics.serviceWellPadding
    let top = labelled
      ? AgentPaletteMetrics.capTrim(labelFont)
      : AgentPaletteMetrics.capTrim(codeFont, lineHeight: AgentPaletteMetrics.serviceWellCodeLineHeight)
    let bottom = AgentPaletteMetrics.baselineTrim(linked ? labelFont : codeFont)
    return NSEdgeInsets(
      top: AgentPaletteMetrics.inkInset(pad, less: top), left: pad,
      bottom: AgentPaletteMetrics.inkInset(pad, less: bottom), right: pad)
  }

  private static var labelFont: NSFont {
    roundedAppFont(size: AgentPaletteMetrics.serviceWellLabelFontSize, weight: .medium)
  }

  private static var codeFont: NSFont {
    NSFont.monospacedSystemFont(ofSize: AgentPaletteMetrics.answerCodeFontSize, weight: .regular)
  }

  private static func styled(_ command: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = AgentPaletteMetrics.serviceWellCodeLineHeight
    paragraph.maximumLineHeight = AgentPaletteMetrics.serviceWellCodeLineHeight
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.headIndent = ceil(("  " as NSString).size(withAttributes: [.font: codeFont]).width)
    return NSAttributedString(
      string: command,
      attributes: [.font: codeFont, .foregroundColor: PaletteInk.primary, .paragraphStyle: paragraph])
  }

  static func height(for words: String, width: CGFloat, expanded: Bool = false) -> CGFloat {
    let parts = parts(of: words)
    let lines = parts.command.components(separatedBy: "\n")
    let truncates = truncates(lines)
    let insets = insets(labelled: parts.tool != nil, linked: truncates)
    let codeWidth = max(width - AgentPaletteMetrics.serviceWellPadding * 2, 1)
    let code = ceil(styled(shown(lines, expanded: expanded)).boundingRect(
      with: CGSize(width: codeWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height)
    let line = AgentPaletteMetrics.labelHeight(labelFont)
    return insets.top + code + insets.bottom
      + (parts.tool == nil ? 0 : line + AgentPaletteMetrics.serviceWellLabelGap)
      + (truncates ? AgentPaletteMetrics.serviceWellLinkGap + line : 0)
  }
}

/// Words that do one thing when clicked — the well's Show More. A label
/// rather than a borderless button, so its words start where the label's
/// and the command's do: a button's title stands two points further in.
final class BolttyAIWellLink: NSTextField {
  var onClick: (() -> Void)?
  private var hoverArea: NSTrackingArea?
  private var isHovered = false {
    didSet {
      guard isHovered != oldValue else { return }
      textColor = isHovered ? PaletteInk.primary : PaletteInk.secondary
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseEntered(with event: NSEvent) { isHovered = true }
  override func mouseExited(with event: NSEvent) { isHovered = false }
  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick?()
  }

  override func accessibilityPerformPress() -> Bool {
    guard let onClick else { return false }
    onClick()
    return true
  }
}

/// A permission's answers as a dialog's buttons, and what "always" reaches
/// said over them — under them, at the leading edge, it reads as Deny's.
/// The card ends on the buttons, as a
/// dialog does.
final class BolttyAIApprovalBar: NSView {
  static let buttonHeight: CGFloat = 32
  static let buttonSpacing: CGFloat = 8
  static var noteSpacing: CGFloat { AgentPaletteMetrics.serviceActionsGap }

  var onClick: ((Int) -> Void)?

  var focusedIndex = 0 {
    didSet { if focusedIndex != oldValue { refreshTitles() } }
  }
  var returnPressesAnAnswer = true {
    didSet { if returnPressesAnAnswer != oldValue { refreshTitles() } }
  }

  private let options: [AgentQuestion.Option]
  private var buttons: [NSButton] = []
  private let copyText: String?
  private let returnReach: Int
  private let copyButton = GlassPillLabelButton(frame: .zero)
  private var copyReset: DispatchWorkItem?
  private let row = NSStackView()
  private let spacer = NSView()
  private let note = NSTextField(wrappingLabelWithString: "")
  private var rowHeight: NSLayoutConstraint?
  private var stackedWidths: [NSLayoutConstraint] = []
  private(set) var isStacked = false

  var buttonTitlesForTesting: [String] {
    answerButtonsInRow.map { options[$0.tag].label }
  }
  private var answerButtonsInRow: [NSButton] {
    row.arrangedSubviews.compactMap { view in buttons.first { $0 === view } }
  }
  var returnTitleForTesting: String? {
    returnPressesAnAnswer ? options[focusedIndex].label : nil
  }
  func buttonForTesting(_ label: String) -> NSButton? {
    options.firstIndex { $0.label == label }.map { buttons[$0] }
  }
  var noteForTesting: String? { note.isHidden ? nil : note.stringValue }
  func pressForTesting(_ index: Int) { onClick?(index) }
  var copyButtonForTesting: NSButton? { copyText == nil ? nil : copyButton }
  var rowTitlesForTesting: [String] {
    row.arrangedSubviews.compactMap { view in
      if view === copyButton { return copyButton.title }
      return buttons.first { $0 === view }.map { options[$0.tag].label }
    }
  }

  init(options: [AgentQuestion.Option], copyText: String? = nil, returnReach: Int? = nil) {
    self.options = options
    self.copyText = copyText
    self.returnReach = returnReach ?? options.count
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    for (index, option) in options.enumerated() {
      let button = Self.makeButton(at: index)
      button.title = option.label
      button.tag = index
      button.target = self
      button.action = #selector(pressed(_:))
      button.translatesAutoresizingMaskIntoConstraints = false
      button.setContentCompressionResistancePriority(.required, for: .horizontal)
      button.setAccessibilityLabel(option.detail.map { "\(option.label), \($0)" } ?? option.label)
      button.heightAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true
      buttons.append(button)
    }

    if copyText != nil {
      copyButton.titleFontSize = AgentPaletteMetrics.typeMeta
      copyButton.height = Self.buttonHeight
      copyButton.title = Self.copyTitle
      copyButton.target = self
      copyButton.action = #selector(copyPressed)
      copyButton.toolTip = "Copy the plan as markdown"
      copyButton.setAccessibilityLabel("Copy the plan")
      copyButton.translatesAutoresizingMaskIntoConstraints = false
      copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
      copyButton.heightAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true
    }

    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    row.spacing = Self.buttonSpacing
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)

    note.translatesAutoresizingMaskIntoConstraints = false
    note.font = roundedAppFont(size: AgentPaletteMetrics.typeFootnote)
    note.textColor = PaletteInk.secondary
    note.stringValue = Self.noteText(options) ?? ""
    note.isHidden = Self.noteText(options) == nil
    addSubview(note)

    let height = row.heightAnchor.constraint(equalToConstant: Self.buttonHeight)
    rowHeight = height
    NSLayoutConstraint.activate([
      note.leadingAnchor.constraint(equalTo: leadingAnchor),
      note.trailingAnchor.constraint(equalTo: trailingAnchor),
      note.topAnchor.constraint(equalTo: topAnchor),
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
      height,
    ])
    let top = note.isHidden
      ? row.topAnchor.constraint(equalTo: topAnchor)
      : row.topAnchor.constraint(equalTo: note.bottomAnchor, constant: Self.noteSpacing)
    top.isActive = true
    refreshTitles()
    arrange(stacked: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    guard bounds.width > 0 else { return }
    let stacked = !Self.fitsInOneRow(
      options, copies: copyText != nil, returnReach: returnReach, width: bounds.width)
    if stacked != isStacked { arrange(stacked: stacked) }
    if abs(note.preferredMaxLayoutWidth - bounds.width) > 0.5 {
      note.preferredMaxLayoutWidth = bounds.width
      note.invalidateIntrinsicContentSize()
    }
  }

  private func arrange(stacked: Bool) {
    isStacked = stacked
    NSLayoutConstraint.deactivate(stackedWidths)
    stackedWidths = []
    let copy: [NSButton] = copyText == nil ? [] : [copyButton]
    if stacked {
      row.setViews(buttons + copy, in: .leading)
      row.orientation = .vertical
      row.alignment = .leading
      stackedWidths = (buttons + copy).map { $0.widthAnchor.constraint(equalTo: row.widthAnchor) }
      NSLayoutConstraint.activate(stackedWidths)
    } else {
      var arranged: [NSView] = []
      if buttons.count >= 3, let last = buttons.last {
        arranged = [last] + copy + [spacer] + buttons.dropLast().reversed()
      } else {
        arranged = copy + [spacer] + buttons.reversed()
      }
      row.setViews(arranged, in: .leading)
      row.orientation = .horizontal
      row.alignment = .centerY
    }
    rowHeight?.constant = Self.rowHeight(count: buttons.count + copy.count, stacked: stacked)
    needsLayout = true
  }

  private static func rowHeight(count: Int, stacked: Bool) -> CGFloat {
    stacked
      ? CGFloat(count) * buttonHeight + CGFloat(max(count - 1, 0)) * buttonSpacing
      : buttonHeight
  }

  @objc private func pressed(_ sender: NSButton) { onClick?(sender.tag) }

  static let copyTitle = "Copy"
  static let copiedTitle = "Copied"

  @objc private func copyPressed() {
    guard let copyText else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(copyText, forType: .string)
    copyButton.title = Self.copiedTitle
    copyReset?.cancel()
    let reset = DispatchWorkItem { [weak self] in self?.copyButton.title = Self.copyTitle }
    copyReset = reset
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
  }

  private static func makeButton(at index: Int) -> NSButton {
    guard index > 0 else { return ApprovalDefaultButton(frame: .zero) }
    let glass = GlassPillLabelButton(frame: .zero)
    glass.titleFontSize = AgentPaletteMetrics.typeMeta
    glass.height = buttonHeight
    return glass
  }

  private func refreshTitles() {
    for (index, button) in buttons.enumerated() {
      let key = returnPressesAnAnswer && index == focusedIndex ? "↵" : ""
      Self.setTitle(of: button, to: options[index].label, key: key)
    }
  }

  private static func setTitle(of button: NSButton, to label: String, key: String) {
    if let primary = button as? ApprovalDefaultButton {
      primary.setLabel(label, key: key)
    } else if let glass = button as? GlassPillLabelButton {
      glass.title = label
      glass.trailingKey = key
    }
  }

  var keysForTesting: [String] {
    answerButtonsInRow.map(\.attributedTitle.string)
  }

  /// Whether the bar opens on a note, which the card stands closer to what
  /// it captions.
  static func isCaptioned(_ options: [AgentQuestion.Option]) -> Bool { noteText(options) != nil }

  private static func noteText(_ options: [AgentQuestion.Option]) -> String? {
    let notes = options.compactMap { option -> String? in
      guard let detail = option.detail, !detail.isEmpty else { return nil }
      return "\(option.label): \(detail)"
    }
    return notes.isEmpty ? nil : notes.joined(separator: " · ")
  }

  static func fitsInOneRow(
    _ options: [AgentQuestion.Option], copies: Bool = false, returnReach: Int? = nil,
    width: CGFloat
  ) -> Bool {
    let total = buttonWidths(for: options, returnReach: returnReach).reduce(0, +)
      + buttonSpacing * CGFloat(options.count)
      + (copies ? copyWidth + buttonSpacing : 0)
    return total <= width
  }

  @MainActor static var copyWidth: CGFloat {
    if let measuredCopyWidth { return measuredCopyWidth }
    let button = GlassPillLabelButton(frame: .zero)
    button.titleFontSize = AgentPaletteMetrics.typeMeta
    button.height = buttonHeight
    button.title = copiedTitle
    let width = ceil(button.intrinsicContentSize.width)
    measuredCopyWidth = width
    return width
  }

  @MainActor private static var measuredCopyWidth: CGFloat?

  static func buttonWidths(
    for options: [AgentQuestion.Option], returnReach: Int? = nil
  ) -> [CGFloat] {
    let labels = options.map(\.label)
    let reach = returnReach ?? labels.count
    if let measured = measuredWidths, measured.labels == labels, measured.reach == reach {
      return measured.widths
    }
    let widths = labels.indices.map { index -> CGFloat in
      let button = makeButton(at: index)
      setTitle(of: button, to: labels[index], key: index < reach ? "↵" : "")
      return ceil(button.intrinsicContentSize.width)
    }
    measuredWidths = (labels: labels, reach: reach, widths: widths)
    return widths
  }

  @MainActor private static var measuredWidths: (labels: [String], reach: Int, widths: [CGFloat])?

  static func height(
    for options: [AgentQuestion.Option], copies: Bool = false, returnReach: Int? = nil,
    width: CGFloat
  ) -> CGFloat {
    let stacked = !fitsInOneRow(options, copies: copies, returnReach: returnReach, width: width)
    let buttons = rowHeight(count: options.count + (copies ? 1 : 0), stacked: stacked)
    guard let note = noteText(options) else { return buttons }
    let bounds = (note as NSString).boundingRect(
      with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: roundedAppFont(size: AgentPaletteMetrics.typeFootnote)]
    )
    return buttons + noteSpacing + ceil(bounds.height)
  }
}

private final class ApprovalDefaultButton: PaletteIconButton {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isBordered = false
    imagePosition = .noImage
    restingBackground = NSColor.white.withAlphaComponent(0.92)
    hoverBackground = .white
    cell?.usesSingleLineMode = true
    cell?.lineBreakMode = .byTruncatingTail
    applyRestingBackground()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setLabel(_ label: String, key: String) {
    let quiet: [NSAttributedString.Key: Any] = [
      .font: roundedAppFont(size: AgentPaletteMetrics.typeMeta, weight: .medium),
      .foregroundColor: NSColor.black.withAlphaComponent(0.4),
    ]
    let title = NSMutableAttributedString()
    title.append(NSAttributedString(
      string: label,
      attributes: [
        .font: roundedAppFont(size: AgentPaletteMetrics.typeMeta, weight: .semibold),
        .foregroundColor: NSColor.black.withAlphaComponent(0.88),
      ]
    ))
    if !key.isEmpty { title.append(NSAttributedString(string: "  " + key, attributes: quiet)) }
    attributedTitle = title
    setAccessibilityTitle(label)
    invalidateIntrinsicContentSize()
  }

  /// The room a glass button beside it leaves either side of its words.
  /// The white one took its words and 14 a side against the glass's ~25,
  /// so "Allow once" stood squeezed beside a roomy "Always allow".
  private static let sidePadding: CGFloat = {
    let glass = GlassPillLabelButton(frame: .zero)
    glass.titleFontSize = AgentPaletteMetrics.typeMeta
    glass.height = BolttyAIApprovalBar.buttonHeight
    glass.title = "Allow once"
    let words = glass.attributedTitle.size().width
    return max(
      ((glass.intrinsicContentSize.width - words) / 2).rounded(),
      GlassPillLabelButton.horizontalInset)
  }()

  override var intrinsicContentSize: NSSize {
    NSSize(
      width: ceil(attributedTitle.size().width) + Self.sidePadding * 2,
      height: BolttyAIApprovalBar.buttonHeight
    )
  }
}
