import AppKit

final class BolttyAIFailureCard: NSView {
  var onRetry: ((String) -> Void)?

  private let symbol = NSImageView()
  private let sentence = NSTextField(wrappingLabelWithString: "")
  private let retryButton = GlassPillButton.titled("Retry")
  private let disclosure = PaletteDisclosureButton()
  private let detailsText = NSTextField(wrappingLabelWithString: "")
  private let copyButton = PaletteIconButton()
  private var copyResetWork: DispatchWorkItem?
  private let detailsBox = NSView()
  private let column = NSStackView()
  private let controls = NSStackView()
  private var report: AgentFailureReport?

  var visibleSentenceForTesting: String { sentence.stringValue }
  var isShowingDetailsForTesting: Bool { !detailsBox.isHidden }
  var detailsTextForTesting: String { detailsText.stringValue }
  var isRetryVisibleForTesting: Bool { !retryButton.isHidden }
  func toggleDetailsForTesting() { toggleDetails(disclosure) }
  func retryForTesting() { retry(retryButton.button) }
  func copyDetailsForTesting() { copyDetails(copyButton) }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerCurve = .continuous
    layer?.applyPaletteCorner(radius: AgentPaletteMetrics.failureCardCornerRadius)
    layer?.borderWidth = 1
    layer?.borderColor = PaletteInk.fill.cgColor
    layer?.backgroundColor = AgentPaletteMetrics.failureCardFill.cgColor

    symbol.translatesAutoresizingMaskIntoConstraints = false
    symbol.image = NSImage(
      systemSymbolName: "exclamationmark.triangle",
      accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(
      pointSize: AgentPaletteMetrics.previewBodyFontSize, weight: .regular
    ))
    symbol.contentTintColor = AgentPaletteMetrics.failureCardAccent
    symbol.setContentHuggingPriority(.required, for: .horizontal)

    sentence.translatesAutoresizingMaskIntoConstraints = false
    sentence.font = roundedAppFont(size: AgentPaletteMetrics.previewBodyFontSize)
    sentence.textColor = PaletteInk.primary
    sentence.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    for button in [retryButton, disclosure, copyButton] as [NSView] {
      button.translatesAutoresizingMaskIntoConstraints = false
    }
    retryButton.button.target = self
    retryButton.button.action = #selector(retry(_:))
    retryButton.setAccessibilityIdentifier("boltty.ask.failure.retry")
    disclosure.font = roundedAppFont(size: AgentPaletteMetrics.previewActivityNameFontSize)
    disclosure.imagePosition = .imageTrailing
    disclosure.contentTintColor = PaletteInk.secondary
    disclosure.onHover = { [weak self] lit in
      self?.disclosure.contentTintColor = lit ? PaletteInk.primary : PaletteInk.secondary
    }
    disclosure.target = self
    disclosure.action = #selector(toggleDetails(_:))
    disclosure.setAccessibilityIdentifier("boltty.ask.failure.details")
    copyButton.isBordered = false
    copyButton.title = ""
    copyButton.imagePosition = .imageOnly
    copyButton.restingTint = ComposerControlGroup.restingInk
    copyButton.hoverTint = .white
    copyButton.hoverBackground = .clear
    copyButton.toolTip = "Copy"
    copyButton.setAccessibilityLabel("Copy the details")
    copyButton.target = self
    copyButton.action = #selector(copyDetails(_:))
    copyButton.setAccessibilityIdentifier("boltty.ask.failure.copy")
    applyCopyGlyph("doc.on.doc")

    detailsText.translatesAutoresizingMaskIntoConstraints = false
    detailsText.font = NSFont.monospacedSystemFont(
      ofSize: AgentPaletteMetrics.previewActivityDetailFontSize, weight: .regular
    )
    detailsText.textColor = PaletteInk.secondary
    detailsText.isSelectable = true
    detailsText.allowsEditingTextAttributes = true
    detailsText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    detailsBox.translatesAutoresizingMaskIntoConstraints = false
    detailsBox.wantsLayer = true
    detailsBox.layer?.cornerCurve = .continuous
    detailsBox.layer?.cornerRadius = AgentPaletteMetrics.failureDetailsCornerRadius
    detailsBox.layer?.backgroundColor = AgentPaletteMetrics.failureDetailsFill.cgColor
    detailsBox.addSubview(detailsText)
    detailsBox.addSubview(copyButton)
    detailsBox.isHidden = true

    let headline = NSStackView(views: [symbol, sentence])
    headline.orientation = .horizontal
    headline.alignment = .firstBaseline
    headline.spacing = 6
    headline.translatesAutoresizingMaskIntoConstraints = false

    controls.orientation = .horizontal
    controls.alignment = .centerY
    controls.spacing = 8
    controls.translatesAutoresizingMaskIntoConstraints = false
    controls.setViews([retryButton, disclosure], in: .leading)

    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 12
    column.translatesAutoresizingMaskIntoConstraints = false
    column.setViews([headline, controls, detailsBox], in: .leading)
    addSubview(column)

    let pad = AgentPaletteMetrics.failureCardPadding
    let detailsPad = AgentPaletteMetrics.failureDetailsPadding
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
      column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
      column.topAnchor.constraint(equalTo: topAnchor, constant: pad),
      column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
      headline.widthAnchor.constraint(equalTo: column.widthAnchor),
      detailsBox.widthAnchor.constraint(equalTo: column.widthAnchor),

      detailsText.leadingAnchor.constraint(
        equalTo: detailsBox.leadingAnchor, constant: detailsPad
      ),
      detailsText.trailingAnchor.constraint(
        equalTo: copyButton.leadingAnchor, constant: -AgentPaletteMetrics.failureDetailsCopyGap
      ),
      detailsText.topAnchor.constraint(equalTo: detailsBox.topAnchor, constant: detailsPad),
      detailsBox.bottomAnchor.constraint(equalTo: detailsText.bottomAnchor, constant: detailsPad),
      copyButton.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewCopyButtonSize),
      copyButton.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewCopyButtonSize),
      copyButton.trailingAnchor.constraint(
        equalTo: detailsBox.trailingAnchor, constant: -AgentPaletteMetrics.failureDetailsCopyInset),
      copyButton.centerYAnchor.constraint(
        equalTo: detailsText.firstBaselineAnchor,
        constant: -(detailsText.font?.capHeight ?? 0) / 2),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("boltty.ask.failure")
    applyDisclosure()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    wrapContents(inCardWidth: bounds.width)
  }

  private func wrapContents(inCardWidth cardWidth: CGFloat) {
    let inner = cardWidth - AgentPaletteMetrics.failureCardPadding * 2
    guard inner > 0 else { return }
    let sentenceWidth = inner - 18
    if abs(sentence.preferredMaxLayoutWidth - sentenceWidth) > 0.5 {
      sentence.preferredMaxLayoutWidth = sentenceWidth
      sentence.invalidateIntrinsicContentSize()
    }
    let detailsWidth = inner - AgentPaletteMetrics.failureDetailsPadding
      - AgentPaletteMetrics.failureDetailsCopyGap - AgentPaletteMetrics.previewCopyButtonSize
      - AgentPaletteMetrics.failureDetailsCopyInset
    if abs(detailsText.preferredMaxLayoutWidth - detailsWidth) > 0.5 {
      detailsText.preferredMaxLayoutWidth = detailsWidth
      detailsText.invalidateIntrinsicContentSize()
    }
  }

  func apply(_ report: AgentFailureReport) {
    guard self.report != report else { return }
    let isNewFailure = self.report?.details != report.details
    self.report = report
    sentence.stringValue = report.sentence
    detailsText.stringValue = report.details
    retryButton.isHidden = !report.canRetry
    retryButton.button.isEnabled = report.canRetry
    if isNewFailure { collapseDetails() }
    applyCopyGlyph("doc.on.doc")
    setAccessibilityLabel(report.sentence)
    needsLayout = true
  }

  func measuredHeight(width: CGFloat) -> CGFloat {
    guard report != nil else { return 0 }
    wrapContents(inCardWidth: width)
    layoutSubtreeIfNeeded()
    return fittingSize.height
  }

  private func collapseDetails() {
    detailsBox.isHidden = true
    applyDisclosure()
  }

  @objc private func toggleDetails(_ sender: NSButton) {
    detailsBox.isHidden.toggle()
    applyDisclosure()
    needsLayout = true
    superview?.needsLayout = true
  }

  private func applyDisclosure() {
    let open = !detailsBox.isHidden
    disclosure.title = "Details"
    disclosure.image = NSImage(
      systemSymbolName: open ? "chevron.down" : "chevron.right",
      accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(
      pointSize: AgentPaletteMetrics.previewActivityChevronPointSize, weight: .semibold))
    disclosure.setAccessibilityValue(open ? "expanded" : "collapsed")
  }

  private func applyCopyGlyph(_ name: String) {
    copyButton.image = NSImage(
      systemSymbolName: name, accessibilityDescription: "Copy the details"
    )?.withSymbolConfiguration(.init(
      pointSize: AgentPaletteMetrics.previewFileGlyphPointSize, weight: .medium))
  }

  @objc private func retry(_ sender: NSButton) {
    guard retryButton.button.isEnabled, let prompt = report?.retryPrompt else { return }
    retryButton.button.isEnabled = false
    onRetry?(prompt)
  }

  @objc private func copyDetails(_ sender: NSButton) {
    guard let details = report?.details else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(details, forType: .string)
    applyCopyGlyph("checkmark")
    copyResetWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.applyCopyGlyph("doc.on.doc") }
    copyResetWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
  }
}

final class PaletteServiceStack: NSStackView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    orientation = .vertical
    alignment = .leading
    spacing = 12
    setStyled(true)
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  /// Every styled card opens on an eyebrow, so its top is measured to the
  /// eyebrow's caps; `bottom` is the caller's, measured to whatever ends it.
  func setStyled(_ styled: Bool, bottom: CGFloat? = nil) {
    let inset = styled ? AgentPaletteMetrics.failureCardPadding : 0
    edgeInsets = NSEdgeInsets(
      top: styled ? Self.eyebrowTopInset : 0, left: inset,
      bottom: styled ? bottom ?? inset : 0, right: inset)
    layer?.backgroundColor = (styled ? AgentPaletteMetrics.failureCardFill : .clear).cgColor
    layer?.borderWidth = styled ? 1 : 0
    layer?.borderColor = PaletteInk.fill.cgColor
    layer?.applyPaletteCorner(radius: AgentPaletteMetrics.failureCardCornerRadius)
  }

  static var eyebrowFont: NSFont { roundedAppFont(size: AgentPaletteMetrics.serviceEyebrowFontSize) }

  static func makeEyebrow(_ words: String = "") -> NSTextField {
    let eyebrow = NSTextField(labelWithString: words)
    eyebrow.translatesAutoresizingMaskIntoConstraints = false
    eyebrow.font = eyebrowFont
    eyebrow.textColor = PaletteInk.secondary
    eyebrow.lineBreakMode = .byTruncatingTail
    eyebrow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return eyebrow
  }

  static var eyebrowTopInset: CGFloat {
    AgentPaletteMetrics.inkInset(
      AgentPaletteMetrics.failureCardPadding, less: AgentPaletteMetrics.capTrim(eyebrowFont))
  }

  static var eyebrowHeight: CGFloat { AgentPaletteMetrics.labelHeight(eyebrowFont) }
}
