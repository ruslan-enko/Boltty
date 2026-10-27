import AppKit

final class BolttyAIPreviewCard: NSView {
  var messageCountForTesting: Int { messageRows.count }
  func messageIdentityForTesting(_ id: String) -> ObjectIdentifier? { messageRows[id].map(ObjectIdentifier.init) }
  var bodyForTesting: String {
    guard bodyLabel.isHidden, let preview = displayedPreview else {
      return bodyLabel.attributedStringValue.string
    }
    return preview.visibleMessages.isEmpty && preview.question == nil ? preview.displayBody : ""
  }
  var selectableLabelsForTesting: [NSTextField] {
    [bodyLabel] + messageRows.values.flatMap { $0.textFieldsForTesting }
  }
  var bodyAttributesForTesting: [NSAttributedString.Key: Any] {
    var text = bodyLabel.attributedStringValue
    if bodyLabel.isHidden, let preview = displayedPreview,
       let body = Self.bodyMessage(for: preview),
       let field = messageRows[body.id]?.answerViewsForTesting.first {
      text = field.attributedStringValue
    }
    guard text.length > 0 else { return [:] }
    return text.attributes(at: 0, effectiveRange: nil)
  }
  var contentInsetsForTesting: NSEdgeInsets {
    NSEdgeInsets(
      top: bounds.maxY - scroll.frame.maxY + scroll.contentInsets.top,
      left: scroll.frame.minX,
      bottom: scroll.frame.minY + scroll.contentInsets.bottom,
      right: bounds.maxX - scroll.frame.maxX
    )
  }
  var isScrollableForTesting: Bool { scroll.documentVisibleRect.height < content.frame.height }
  var contentWidthForTesting: CGFloat { content.frame.width }
  var viewportFrameForTesting: NSRect { scroll.contentView.frame }
  var viewportBoundsForTesting: NSRect { scroll.bounds }
  var scrollOffsetForTesting: CGFloat { scroll.documentVisibleRect.minY }
  func scrollForTesting(to points: CGFloat) {
    scroll.contentView.scroll(to: NSPoint(x: 0, y: points))
    scroll.reflectScrolledClipView(scroll.contentView)
  }
  var contentHeightForTesting: CGFloat { content.bounds.height }
  func scrollToLatestForTesting() { scrollToLatest() }
  var followsBottomForTesting: Bool { followsBottom }
  var isLatestPillVisibleForTesting: Bool { offersLatest }
  var edgeMaskForTesting: CALayer? { scroll.layer?.mask }

  var edgeMaskRunsTopDownForTesting: Bool {
    let flipped = scroll.layer?.isGeometryFlipped ?? scroll.isFlipped
    return flipped
      ? scrollEdge.startPoint.y < scrollEdge.endPoint.y
      : scrollEdge.startPoint.y > scrollEdge.endPoint.y
  }

  func edgeOpacityForTesting(atY y: CGFloat) -> CGFloat {
    let height = scroll.bounds.height
    let stops = zip(
      (scrollEdge.locations ?? []).map { CGFloat($0.doubleValue) * height },
      (scrollEdge.colors as? [CGColor] ?? []).map(\.alpha)
    ).map { (y: $0, alpha: $1) }
    guard let first = stops.first, let last = stops.last else { return 1 }
    if y <= first.y { return first.alpha }
    for (a, b) in zip(stops, stops.dropFirst()) where y <= b.y {
      return b.y - a.y < 0.001 ? b.alpha : a.alpha + (b.alpha - a.alpha) * (y - a.y) / (b.y - a.y)
    }
    return last.alpha
  }

  var onStop: (() -> Void)?
  var onClose: (() -> Void)?
  var onRecover: ((String) -> Void)?
  var onUseFile: ((URL) -> Void)?
  /// Read an answer aloud, or stop it.
  var onSpeak: ((ConversationMessage) -> Void)?
  /// The answer being read aloud, which keeps its stop control up.
  var speakingMessageID: String? {
    didSet {
      guard speakingMessageID != oldValue else { return }
      for (id, row) in messageRows { row.isSpeaking = id == speakingMessageID }
    }
  }
  var onRetry: ((String) -> Void)?
  private let recoverButton = GlassPillButton.titled("Restore unsent message")
  private let failureCard = BolttyAIFailureCard()
  var onCancelQueued: ((String) -> Void)?
  private let queuedRow = PaletteServiceStack(frame: .zero)
  private let queuedTitle = PaletteServiceStack.makeEyebrow("Queued message")
  private let queuedLabel = NSTextField(wrappingLabelWithString: "")
  private let cancelQueuedButton = GlassPillButton.titled("Edit message")
  private var queuedPrompt: String?

  var queuedTextForTesting: String? { queuedRow.isHidden ? nil : queuedLabel.stringValue }
  func cancelQueuedForTesting() { cancelQueued(cancelQueuedButton.button) }
  var optionsFooterForTesting: String? { optionsFooter.isHidden ? nil : optionsFooter.stringValue }
  var chosenRowsForTesting: [Int] { optionRows.indices.filter { optionRows[$0].isChosen } }
  private var failureReport: AgentFailureReport?

  var failureCardForTesting: BolttyAIFailureCard { failureCard }
  var isFailureCardVisibleForTesting: Bool { !failureCard.isHidden }
  var filePathsForTesting: [String: [String]] {
    messageRows.mapValues(\.filePathsForTesting)
  }
  var messageFileRowsForTesting: [String: [PaletteFileRowView]] {
    messageRows.mapValues(\.fileRowsForTesting)
  }
  func messageRowForTesting(_ id: String) -> PaletteChatMessageView? { messageRows[id] }
  var statusTextForTesting: String? { statusLabel.isHidden ? nil : statusLabel.stringValue }
  var isRecoverVisibleForTesting: Bool { !recoverButton.isHidden }
  private let messages = NSStackView()
  private let closeButton = GlassCircleButton(
    symbol: "chevron.backward",
    accessibilityDescription: "Back",
    diameter: AgentPaletteMetrics.previewCloseDiameter,
    pointSize: AgentPaletteMetrics.previewCloseGlyphPointSize,
    weight: AgentPaletteMetrics.previewCloseGlyphWeight
  )
  var closeButtonUsesSystemGlassForTesting: Bool { closeButton.usesSystemGlass }
  var isCloseVisibleForTesting: Bool { !closeButton.isHidden }
  private var messageRows: [String: PaletteChatMessageView] = [:]
  private var turnHeaders: [String: PaletteTurnHeaderView] = [:]
  private var expandedTurns: Set<String> = []
  private var turnClock: Timer?
  private var pinnedFloor: NSLayoutConstraint!
  private var isFlying = false
  struct FlightOrigin {
    var frameInWindow: NSRect
    var image: NSImage?
  }
  private var fileFlightOrigins: [String: FlightOrigin] = [:]
  private var fileFlightOriginsAt: Date?
  private(set) var fileFlightsForTesting: [(path: String, start: NSRect, landing: NSRect)] = []
  private(set) var fileFlightGrowsForTesting: [Bool] = []
  private(set) var fileFlightWhipsForTesting = 0
  private var isGliding = false
  var pinnedFloorForTesting: CGFloat { pinnedFloor.constant }
  var turnHeaderTextsForTesting: [String] {
    messages.arrangedSubviews.compactMap { ($0 as? PaletteTurnHeaderView)?.textForTesting }
  }
  func turnHeaderForTesting(_ id: String) -> PaletteTurnHeaderView? { turnHeaders[id] }
  var transcriptOrderForTesting: [String] {
    messages.arrangedSubviews.compactMap { view in
      if let header = view as? PaletteTurnHeaderView { return "turn:" + header.turnID }
      return messageRows.first { $0.value === view }?.key
    }
  }
  private let workingLine = PaletteWorkingLineView()
  var workingLineForTesting: PaletteWorkingLineView { workingLine }
  private let streamingTail = PaletteStreamingTailView()
  private var streamedMessageID: String?
  var streamingTailTextForTesting: String? { streamingTail.isHidden ? nil : streamingTail.textForTesting }
  var streamingTailForTesting: PaletteStreamingTailView { streamingTail }
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private(set) var offersLatest = false {
    didSet { if offersLatest != oldValue { onOffersLatestChange?(offersLatest) } }
  }
  var onOffersLatestChange: ((Bool) -> Void)?
  private var followsBottom = true
  private var pendingBottomScroll = false
  private let scroll = NSScrollView()
  var transcriptScroll: NSScrollView { scroll }
  private let content = FlippedStackView()
  private var displayedPreview: BolttyAISessionPreview?
  private let options = NSStackView()
  private let optionsFooter = NSTextField(labelWithString: "")
  private let permissionWell = BolttyAICommandWell(frame: .zero)
  private let approvalHost = NSView()
  private var approvalBar: BolttyAIApprovalBar?
  private var composerHasWords = false
  private var optionRows: [BolttyAIOptionRow] = []
  private var question: AgentQuestion?
  private var chosenOptions: Set<Int> = []
  private var focusedOption = 0

  var onAnswer: ((AgentQuestion, [String]) -> Void)?

  var optionLabelsForTesting: [String] { optionRows.map(\.label) }
  var chosenOptionLabelsForTesting: [String] { chosenValues }
  private let questionSurface = PaletteServiceStack(frame: .zero)
  private let questionTitle = NSTextField(labelWithString: "")
  private var questionWidthConstraints: [NSLayoutConstraint] = []
  var questionTitleForTesting: String? { questionTitle.isHidden ? nil : questionTitle.stringValue }
  private let bodyLabel = NSTextField(wrappingLabelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    bodyLabel.translatesAutoresizingMaskIntoConstraints = false
    bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    scroll.drawsBackground = false
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(
      top: AgentPaletteMetrics.previewHeaderHeight,
      left: 0,
      bottom: AgentPaletteMetrics.previewContentVerticalPadding,
      right: 0
    )
    applyFloatingBottomInset()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.scrollerStyle = .overlay
    scroll.verticalScroller = PaletteInvisibleScroller()
    scroll.scrollerStyle = .overlay
    scroll.scrollerKnobStyle = .light
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = AgentPaletteMetrics.previewOptionsTopSpacing
    content.translatesAutoresizingMaskIntoConstraints = false
    messages.orientation = .vertical
    messages.alignment = .leading
    messages.spacing = AgentPaletteMetrics.previewMessageSpacing
    messages.translatesAutoresizingMaskIntoConstraints = false
    messages.setHuggingPriority(.defaultHigh, for: .vertical)
    content.setHuggingPriority(.defaultLow - 1, for: .vertical)
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.font = roundedAppFont(size: AgentPaletteMetrics.previewBodyFontSize)
    bodyLabel.isSelectable = true
    bodyLabel.allowsEditingTextAttributes = true
    optionsFooter.translatesAutoresizingMaskIntoConstraints = false
    optionsFooter.font = roundedAppFont(size: AgentPaletteMetrics.previewFooterFontSize)
    optionsFooter.textColor = AgentPaletteMetrics.previewFooterTextColor
    optionsFooter.lineBreakMode = .byTruncatingTail
    optionsFooter.isHidden = true
    optionsFooter.setAccessibilityRole(.staticText)

    queuedLabel.translatesAutoresizingMaskIntoConstraints = false
    queuedLabel.font = roundedAppFont(size: AgentPaletteMetrics.previewBodyFontSize)
    queuedLabel.textColor = PaletteInk.primary
    queuedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    cancelQueuedButton.translatesAutoresizingMaskIntoConstraints = false
    cancelQueuedButton.button.target = self
    cancelQueuedButton.button.action = #selector(cancelQueued(_:))
    cancelQueuedButton.setAccessibilityIdentifier("boltty.ask.chat.cancelQueued")
    cancelQueuedButton.button.setContentHuggingPriority(.required, for: .horizontal)
    let queuedNote = NSTextField(labelWithString: "Sends after this turn finishes.")
    queuedNote.font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
    queuedNote.textColor = PaletteInk.secondary
    let queuedActions = NSStackView(views: [queuedNote, cancelQueuedButton])
    queuedActions.orientation = .horizontal
    queuedActions.alignment = .centerY
    queuedActions.spacing = 12
    queuedRow.orientation = .vertical
    queuedRow.alignment = .leading
    queuedRow.spacing = 12
    queuedRow.translatesAutoresizingMaskIntoConstraints = false
    queuedRow.setViews([queuedTitle, queuedLabel, queuedActions], in: .leading)
    queuedRow.setCustomSpacing(AgentPaletteMetrics.serviceEyebrowGap, after: queuedTitle)
    queuedRow.setCustomSpacing(AgentPaletteMetrics.serviceActionsGap, after: queuedLabel)
    queuedLabel.widthAnchor.constraint(equalTo: queuedRow.widthAnchor,
      constant: -AgentPaletteMetrics.failureCardPadding * 2).isActive = true
    queuedRow.isHidden = true

    questionTitle.font = PaletteServiceStack.eyebrowFont
    questionTitle.textColor = PaletteInk.secondary
    questionTitle.lineBreakMode = .byTruncatingTail
    questionTitle.isHidden = true
    permissionWell.isHidden = true
    permissionWell.onResize = { [weak self] in
      self?.needsLayout = true
      self?.superview?.needsLayout = true
    }
    approvalHost.translatesAutoresizingMaskIntoConstraints = false
    approvalHost.isHidden = true
    questionSurface.setViews([questionTitle, bodyLabel, permissionWell,
                              options, optionsFooter, approvalHost], in: .leading)
    questionSurface.setStyled(false)
    content.setViews(
      [messages, streamingTail, workingLine, queuedRow, questionSurface, statusLabel, failureCard, recoverButton],
      in: .leading
    )
    streamingTail.isHidden = true
    recoverButton.button.target = self
    recoverButton.button.action = #selector(recoverPrompt)
    recoverButton.isHidden = true
    failureCard.isHidden = true
    failureCard.onRetry = { [weak self] prompt in self?.onRetry?(prompt) }
    scroll.documentView = content
    scroll.contentView.scroll(to: restingScrollOrigin)
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.wantsLayer = true
    configureScrollEdge()
    addSubview(scroll)
    closeButton.button.toolTip = "Back"
    closeButton.button.helpShortcut = "Esc"
    closeButton.button.target = self
    closeButton.button.action = #selector(closeChat)
    closeButton.button.setAccessibilityIdentifier("boltty.ask.chat.close")
    addSubview(closeButton)
    NSLayoutConstraint.activate([
      closeButton.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: AgentPaletteMetrics.previewCloseInset
      ),
      closeButton.topAnchor.constraint(
        equalTo: topAnchor,
        constant: AgentPaletteMetrics.previewCloseInset
      ),
      messages.widthAnchor.constraint(equalTo: content.widthAnchor),
      workingLine.widthAnchor.constraint(equalTo: content.widthAnchor),
      streamingTail.widthAnchor.constraint(equalTo: content.widthAnchor),
      statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
      failureCard.widthAnchor.constraint(equalTo: content.widthAnchor),
    ])

    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(clipViewDidScroll),
      name: NSView.boundsDidChangeNotification,
      object: scroll.contentView
    )

    options.orientation = .vertical
    options.alignment = .leading
    options.distribution = .fill
    options.spacing = AgentPaletteMetrics.previewOptionSpacing
    options.translatesAutoresizingMaskIntoConstraints = false
    options.isHidden = true

    pinnedFloor = content.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
    let horizontal = AgentPaletteMetrics.previewContentHorizontalPadding
    let top = scroll.topAnchor.constraint(equalTo: topAnchor)
    let bottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
    top.priority = .defaultHigh
    bottom.priority = .defaultHigh
    setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontal),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontal),
      top,
      bottom,

      content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
      content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      pinnedFloor,
      questionSurface.widthAnchor.constraint(equalTo: content.widthAnchor),
      queuedRow.widthAnchor.constraint(equalTo: content.widthAnchor),
    ])

    questionWidthConstraints = [bodyLabel, options, optionsFooter,
                                permissionWell, approvalHost].map {
      $0.widthAnchor.constraint(equalTo: questionSurface.widthAnchor)
    }
    NSLayoutConstraint.activate(questionWidthConstraints)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("boltty.ask.preview")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var contentLayoutWidth: CGFloat {
    let cardWidth = bounds.width > 0 ? bounds.width : AgentPaletteMetrics.promptSize.width
    return max(1, cardWidth - AgentPaletteMetrics.previewContentHorizontalPadding * 2)
  }

  override func layout() {
    super.layout()
    updateScrollEdge()
    updatePinnedFloor()
    if pendingBottomScroll, !isFlying {
      pendingBottomScroll = false
      scrollToLatest()
    }
    let width = contentLayoutWidth
    let bodyWidth = width - (question == nil ? 0 : AgentPaletteMetrics.failureCardPadding * 2)
    guard bodyWidth > 0 else { return }
    for label in [bodyLabel] where abs(label.preferredMaxLayoutWidth - bodyWidth) > 0.5 {
      label.preferredMaxLayoutWidth = bodyWidth
      label.invalidateIntrinsicContentSize()
    }
    let queuedWidth = width - AgentPaletteMetrics.failureCardPadding * 2
    if abs(queuedLabel.preferredMaxLayoutWidth - queuedWidth) > 0.5 {
      queuedLabel.preferredMaxLayoutWidth = queuedWidth
      queuedLabel.invalidateIntrinsicContentSize()
    }
  }

  @discardableResult
  private func updatePinnedFloor() -> Bool {
    var floor: CGFloat = 0
    if let preview = displayedPreview, !messages.isHidden,
       let request = preview.visibleMessages.last(where: { $0.role == .user }),
       let row = messageRows[request.id], row.superview != nil {
      let top = content.convert(row.bounds, from: row).minY
      let visible = scroll.contentView.bounds.height
        - scroll.contentInsets.top - scroll.contentInsets.bottom
      floor = max(0, top + visible)
    }
    guard abs(pinnedFloor.constant - floor) > 0.5 else { return false }
    pinnedFloor.constant = floor
    return true
  }

  func prepareFileFlights(_ origins: [String: FlightOrigin]) {
    fileFlightOrigins = origins
    fileFlightOriginsAt = Date()
  }

  private func takeFileFlightOrigins() -> [String: FlightOrigin] {
    defer {
      fileFlightOrigins = [:]
      fileFlightOriginsAt = nil
    }
    guard let at = fileFlightOriginsAt, Date().timeIntervalSince(at) < 2 else { return [:] }
    return fileFlightOrigins
  }

  private func launch(_ message: ConversationMessage, from origin: NSPoint) {
    let origins = takeFileFlightOrigins()
    fileFlightsForTesting = []
    fileFlightGrowsForTesting = []
    guard let row = messageRows[message.id], let window, window.isVisible,
          !MotionPreferences.reduceMotion else { return }
    let target = scroll.contentView.bounds.origin
    let landing = convert(row.bounds, from: row)
    let landedBubble = convert(row.bubbleFrameForFlight, from: row)
    let cards = row.fileCardsForFlight.map { card in
      (card.path, card.name, convert(card.frame, from: row))
    }
    let words = row.drawsBubble ? NSRect(
      x: landing.minX, y: landedBubble.minY, width: landing.width, height: landedBubble.height
    ) : nil
    let lead = words ?? cards.last?.2 ?? landing
    let liftOff = max(composerBottomInset / 2, lead.height / 2)
    let rise = liftOff - lead.midY

    var risers: [(view: NSView, landing: NSPoint)] = []
    if let words {
      var typed = message
      typed.parts.removeAll { part in
        if case let .attachment(attachment) = part { return attachment.url != nil }
        return false
      }
      let ghost = PaletteChatMessageView(message: typed)
      ghost.translatesAutoresizingMaskIntoConstraints = true
      ghost.frame = words.offsetBy(dx: 0, dy: rise)
      addSubview(ghost, positioned: .above, relativeTo: scroll)
      ghost.layoutSubtreeIfNeeded()
      risers.append((ghost, words.origin))
    }
    var morphs: [(card: NSView, chip: NSImageView?, grow: CATransform3D?)] = []
    var whips: [PaletteWhipView] = []
    for (path, name, landed) in cards {
      let card = PaletteFileRowView(path: path, name: name)
      card.translatesAutoresizingMaskIntoConstraints = true
      card.frame = landed
      addSubview(card, positioned: .above, relativeTo: scroll)
      card.layoutSubtreeIfNeeded()
      guard let chip = origins[path] else {
        card.setFrameOrigin(landed.origin.applying(.init(translationX: 0, y: rise)))
        risers.append((card, landed.origin))
        fileFlightsForTesting.append((path, card.frame, landed))
        continue
      }
      let start = convert(chip.frameInWindow, from: nil)
      var picture: NSImageView?
      if let whip = makeWhip(chip.image, from: start, to: landed, above: card) {
        whips.append(whip)
      } else if let image = chip.image {
        let view = NSImageView(frame: start)
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        addSubview(view, positioned: .above, relativeTo: card)
        picture = view
      }
      let grow = card.layer.flatMap { Self.transform(of: $0, showing: start, framedAt: landed) }
      morphs.append((card, picture, grow))
      fileFlightsForTesting.append((path, start, landed))
      fileFlightGrowsForTesting.append(grow != nil)
    }
    fileFlightWhipsForTesting = whips.count

    row.alphaValue = 0
    scroll.contentView.setBoundsOrigin(origin)
    scroll.reflectScrolledClipView(scroll.contentView)
    isFlying = true
    let duration = AgentPaletteMetrics.previewSendFlightDuration
    for morph in morphs {
      if let layer = morph.card.layer, let from = morph.grow {
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: from)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = duration
        grow.timingFunction = Motion.emphasizedCurve
        layer.add(grow, forKey: "sendFlight")
      }
      morph.card.layer?.add(Self.fade([0, 1, 1], at: [0, 0.5, 1], over: duration), forKey: "sendFade")
      morph.chip?.layer?.add(Self.fade([1, 0, 0], at: [0, 0.4, 1], over: duration), forKey: "sendFade")
    }
    whips.forEach { $0.start() }
    let ghosts = risers.map(\.view) + morphs.flatMap { [$0.card, $0.chip].compactMap { $0 } }
      + whips
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = duration
      context.timingFunction = Motion.emphasizedCurve
      context.allowsImplicitAnimation = true
      for riser in risers { riser.view.animator().setFrameOrigin(riser.landing) }
      for morph in morphs { morph.chip?.animator().frame = morph.card.frame }
      scroll.contentView.animator().setBoundsOrigin(target)
    }, completionHandler: { [weak self, weak row] in
      MainActor.assumeIsolated {
        ghosts.forEach { $0.removeFromSuperview() }
        row?.alphaValue = 1
        guard let self else { return }
        self.isFlying = false
        self.scroll.reflectScrolledClipView(self.scroll.contentView)
        if self.pendingBottomScroll {
          self.pendingBottomScroll = false
          self.scrollToLatest()
        }
      }
    })
  }

  private func makeWhip(
    _ image: NSImage?, from start: NSRect, to landed: NSRect, above card: NSView
  ) -> PaletteWhipView? {
    guard let picture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    let room = AgentPaletteMetrics.whipMaxLagHeights * max(start.height, landed.height)
    let stretch = start.union(landed).insetBy(dx: -room, dy: -room)
    let local = { (rect: NSRect) in rect.offsetBy(dx: -stretch.minX, dy: -stretch.minY) }
    guard !isFlipped, let whip = PaletteWhipView.make(
      image: picture, from: local(start), to: local(landed),
      duration: AgentPaletteMetrics.previewSendFlightDuration)
    else { return nil }
    whip.frame = stretch
    addSubview(whip, positioned: .above, relativeTo: card)
    return whip
  }

  private static func fade(_ values: [Double], at times: [Double], over duration: TimeInterval) -> CAAnimation {
    let fade = CAKeyframeAnimation(keyPath: "opacity")
    fade.values = values
    fade.keyTimes = times.map { NSNumber(value: $0) }
    fade.duration = duration
    fade.fillMode = .forwards
    fade.isRemovedOnCompletion = false
    return fade
  }

  static func transform(of layer: CALayer, showing target: NSRect, framedAt framed: NSRect) -> CATransform3D? {
    guard framed.height > 0, abs(layer.frame.midX - framed.midX) < 0.5,
          abs(layer.frame.height - framed.height) < 0.5 else { return nil }
    let up: CGFloat
    if abs(layer.frame.midY - framed.midY) < 0.5 {
      up = 1
    } else if let superlayer = layer.superlayer,
              abs(layer.frame.midY - (superlayer.bounds.height - framed.midY)) < 0.5 {
      up = -1
    } else {
      return nil
    }
    let scale = max(0.1, min(1, target.height / framed.height))
    let goal = CGPoint(
      x: layer.frame.midX + (target.midX - framed.midX),
      y: layer.frame.midY + (target.midY - framed.midY) * up)
    let size = layer.bounds.size
    let saved = layer.transform
    defer {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.transform = saved
      CATransaction.commit()
    }
    for side: CGFloat in [1, -1] {
      let toCentre = CGPoint(
        x: (0.5 - layer.anchorPoint.x) * size.width,
        y: (0.5 - layer.anchorPoint.y) * size.height * side)
      let candidate = CATransform3DConcat(
        CATransform3DMakeScale(scale, scale, 1),
        CATransform3DMakeTranslation(
          goal.x - layer.frame.midX + (1 - scale) * toCentre.x,
          goal.y - layer.frame.midY + (1 - scale) * toCentre.y, 0))
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.transform = candidate
      CATransaction.commit()
      let shown = layer.frame
      if hypot(shown.midX - goal.x, shown.midY - goal.y) < 1,
         abs(shown.height - framed.height * scale) < 1 { return candidate }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.transform = saved
      CATransaction.commit()
    }
    return nil
  }

  @objc private func clipViewDidScroll() {
    guard !isGliding else { return }
    let distanceFromFloor = content.bounds.height - scroll.documentVisibleRect.maxY
    followsBottom = distanceFromFloor <= AgentPaletteMetrics.transcriptFollowSlack
    let hasTranscript = displayedPreview?.messages.isEmpty == false
    offersLatest =
      hasTranscript && distanceFromFloor > AgentPaletteMetrics.transcriptLatestPillSlack
  }

  @objc func scrollToLatest() {
    scroll.contentView.scroll(to: latestOrigin)
    scroll.reflectScrolledClipView(scroll.contentView)
    followsBottom = true
    offersLatest = false
  }

  private var latestOrigin: NSPoint {
    NSPoint(x: 0, y: max(
      -scroll.contentInsets.top,
      content.bounds.height - scroll.contentView.bounds.height + scroll.contentInsets.bottom
    ))
  }

  @objc func glideToLatest() {
    let target = latestOrigin
    let clip = scroll.contentView
    guard let window, window.isVisible, !MotionPreferences.reduceMotion,
          abs(target.y - clip.bounds.origin.y) > 1 else {
      scrollToLatest()
      return
    }
    let screen = clip.bounds.height
    if target.y - clip.bounds.origin.y > screen * 1.5 {
      clip.setBoundsOrigin(NSPoint(x: 0, y: target.y - screen))
    }
    followsBottom = true
    offersLatest = false
    isGliding = true
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Motion.standard
      context.timingFunction = Motion.emphasizedCurve
      context.allowsImplicitAnimation = true
      clip.animator().setBoundsOrigin(target)
    }, completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isGliding = false
        self.scroll.reflectScrolledClipView(self.scroll.contentView)
        if abs(self.scroll.contentView.bounds.origin.y - target.y) <= 1 {
          self.scrollToLatest()
        } else {
          self.clipViewDidScroll()
        }
      }
    })
  }

  private var expandedActivities: Set<String> = []

  var expandedActivitiesForTesting: Set<String> { expandedActivities }

  private func toggleActivity(_ id: String) {
    if expandedActivities.contains(id) {
      expandedActivities.remove(id)
    } else {
      expandedActivities.insert(id)
    }
    for row in messageRows.values { row.setExpandedActivities(expandedActivities) }
    needsLayout = true
    superview?.needsLayout = true
  }

  private func toggleTurn(_ id: String) {
    if expandedTurns.contains(id) {
      expandedTurns.remove(id)
    } else {
      expandedTurns.insert(id)
    }
    guard let preview = displayedPreview else { return }
    renderTranscript(preview, changedConversation: false)
    applyWorkingLine(preview)
    needsLayout = true
    superview?.needsLayout = true
  }

  private func applyWorkingLine(_ preview: BolttyAISessionPreview) {
    workingLine.isHidden = !preview.isBusy || preview.question != nil
    guard !workingLine.isHidden else { return }
    workingLine.apply(preview)
  }

  var permissionWellTextForTesting: String? { permissionWell.isHidden ? nil : permissionWell.stringForTesting }
  var approvalBarForTesting: BolttyAIApprovalBar? { approvalHost.isHidden ? nil : approvalBar }

  @objc private func closeChat() { onClose?() }

  @objc private func cancelQueued(_ sender: NSButton) {
    guard let prompt = queuedPrompt else { return }
    queuedRow.isHidden = true
    queuedPrompt = nil
    onCancelQueued?(prompt)
  }

  @objc private func recoverPrompt() {
    guard let prompt = displayedPreview?.retryPrompt else { return }
    onRecover?(prompt)
    recoverButton.button.isEnabled = false
  }

  private func applyStreamingTail(_ preview: BolttyAISessionPreview) {
    guard let tail = preview.streamingTail else {
      streamingTail.isHidden = true
      streamingTail.clear()
      return
    }
    streamedMessageID = preview.messages.last { $0.role == .agent && $0.completedAt == nil }
      .map { PaletteTranscript.rowID(
        of: $0.id, in: preview.visibleMessages.filter(PaletteChatMessageView.draws)) }
    streamingTail.isHidden = false
    streamingTail.apply(tail, column: contentLayoutWidth, agent: preview.agent)
    content.setCustomSpacing(Self.streamingTailSpacing(preview), after: messages)
  }

  private static func streamingTailSpacing(_ preview: BolttyAISessionPreview) -> CGFloat {
    guard let last = preview.visibleMessages.last, last.role == .agent,
          let segment = last.paletteSegments.last else { return AgentPaletteMetrics.previewMessageSpacing }
    switch segment {
    case .group: return AgentPaletteMetrics.previewWorkPillSpacingBelow
    case .text: return AgentPaletteMetrics.answerParagraphSpacing
    case .activity: return AgentPaletteMetrics.previewActivityRowsTopMargin
    }
  }

  private func streamingTailHeight(_ preview: BolttyAISessionPreview, width: CGFloat) -> CGFloat {
    guard let tail = preview.streamingTail else { return 0 }
    return PaletteStreamingTailView.height(of: tail, width: width) + Self.streamingTailSpacing(preview)
  }

  func suspendAnimations() {
    streamingTail.suspend()
    workingLine.suspend()
    stopTurnClock()
  }

  func resumeAnimations() {
    streamingTail.resume()
    if displayedPreview?.isBusy == true { startTurnClock() }
  }

  var turnClockIsRunningForTesting: Bool { turnClock != nil }

  func measuredHeight() -> CGFloat {
    guard let preview = displayedPreview else { return AgentPaletteMetrics.previewMinHeight }
    let width = contentLayoutWidth
    let items = transcriptItems(for: preview)
    let copies = Self.copyOffers(in: items, isBusy: preview.isBusy)
    var transcriptHeight: CGFloat = 0
    for (index, item) in items.enumerated() {
      switch item {
      case let .message(message, folded):
        transcriptHeight += PaletteChatMessageView.height(
          for: message, width: width, expanded: expandedActivities, folded: folded,
          offersCopy: copies.contains(message.id))
      case .turnHeader:
        transcriptHeight += AgentPaletteMetrics.previewTurnHeaderHeight
      }
      if index < items.count - 1 {
        transcriptHeight += Self.spacing(after: item, before: items[index + 1], copies: copies)
      }
    }
    let questionWidth = width - AgentPaletteMetrics.failureCardPadding * 2
    let questionHeight = preview.question.map { question in
      Self.serviceCardHeight(
        for: question, width: questionWidth, wellExpanded: permissionWell.showsEverything)
    } ?? 0
    let statusHeight = statusLabel.isHidden
      ? 0
      : PaletteChatMessageView.textHeight(statusLabel.stringValue, width: width) + 20
    let failureHeight = failureCard.isHidden
      ? 0
      : failureCard.measuredHeight(width: width) + AgentPaletteMetrics.previewMessageSpacing
    let recoverHeight = recoverButton.isHidden ? 0 : CGFloat(48)
    let queuedHeight = queuedRow.isHidden
      ? 0
      : PaletteServiceStack.eyebrowTopInset + PaletteServiceStack.eyebrowHeight
        + AgentPaletteMetrics.serviceEyebrowGap
        + PaletteChatMessageView.textHeight(queuedLabel.stringValue, width: questionWidth)
        + AgentPaletteMetrics.serviceActionsGap + AgentPaletteMetrics.directoryChipHeight
        + AgentPaletteMetrics.failureCardPadding
    return max(
      AgentPaletteMetrics.previewMinHeight,
      transcriptHeight
        + questionHeight
        + streamingTailHeight(preview, width: width)
        + (preview.isBusy ? 44 : 0)
        + statusHeight
        + failureHeight
        + recoverHeight
        + queuedHeight
        + AgentPaletteMetrics.previewHeaderHeight
        + AgentPaletteMetrics.previewContentVerticalPadding
    )
  }

  private var chipBottomInset: CGFloat = 0

  private var composerBottomInset: CGFloat = 0

  func setFloatingBottomInset(chip: CGFloat, composer: CGFloat) {
    guard chipBottomInset != chip || composerBottomInset != composer else { return }
    chipBottomInset = chip
    composerBottomInset = composer
    applyFloatingBottomInset()
  }

  private func applyFloatingBottomInset() {
    scroll.contentInsets.bottom = AgentPaletteMetrics.previewContentVerticalPadding
      + chipBottomInset + composerBottomInset
    updateScrollEdge()
  }

  // MARK: - The scroll edge

  private let scrollEdge = CAGradientLayer()

  private func configureScrollEdge() {
    scroll.layer?.mask = scrollEdge
  }

  /// The scroll view's layer is flipped: location 0 is the top.
  private func orientScrollEdge() {
    let flipped = scroll.layer?.isGeometryFlipped ?? scroll.isFlipped
    scrollEdge.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
    scrollEdge.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
  }

  private func updateScrollEdge() {
    let height = scroll.bounds.height
    guard height > 0 else { return }
    let soft = AgentPaletteMetrics.previewScrollEdgeSoftness
    let topWhole = min(
      height,
      AgentPaletteMetrics.previewCloseInset + AgentPaletteMetrics.previewCloseDiameter + soft
    )
    let band = chipBottomInset + composerBottomInset
    let edge = band > 0 ? max(0, band - AgentPaletteMetrics.surfaceStackSpacing) : 0
    let bottomWhole = max(topWhole, height - edge - soft)
    let bottomGone = min(height, max(bottomWhole, height - edge + soft))

    let curve = ScrollEdgeBlur.smoothstep
    var stops: [(y: CGFloat, alpha: CGFloat)] = curve.map { (topWhole * $0.t, $0.s) }
    stops += curve.map { (bottomWhole + (bottomGone - bottomWhole) * $0.t, 1 - $0.s) }
    stops.append((height, 0))

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    orientScrollEdge()
    scrollEdge.frame = scroll.bounds
    scrollEdge.colors = stops.map { NSColor.black.withAlphaComponent($0.alpha).cgColor }
    scrollEdge.locations = stops.map { NSNumber(value: Double(min(1, max(0, $0.y / height)))) }
    CATransaction.commit()

    ScrollEdgeBlur.apply(to: scroll.layer, stops: [], height: height, radius: 0)
  }

  private var restingScrollOrigin: NSPoint {
    NSPoint(x: 0, y: -scroll.contentInsets.top)
  }

  func apply(_ preview: BolttyAISessionPreview) {
    guard displayedPreview != preview else {
      applyWorkingLine(preview)
      return
    }
    let previous = displayedPreview
    let changedConversation = previous?.id != preview.id
    let sent: ConversationMessage? = {
      guard let previous, !changedConversation,
            let request = preview.visibleMessages.last(where: { $0.role == .user }),
            preview.visibleMessages.filter({ $0.role == .user }).count
              > previous.visibleMessages.filter({ $0.role == .user }).count
      else { return nil }
      return request
    }()
    let follow = changedConversation || followsBottom || sent != nil
    let scrollPosition = scroll.contentView.bounds.origin
    displayedPreview = preview
    applyQuestion(preview.question)
    let isTranscript = !preview.visibleMessages.isEmpty || Self.bodyMessage(for: preview) != nil
    messages.isHidden = !isTranscript
    applyStreamingTail(preview)
    if changedConversation {
      expandedActivities.removeAll()
      expandedTurns.removeAll()
      if preview.streamingTail == nil { streamedMessageID = nil }
    }
    renderTranscript(
      preview, changedConversation: changedConversation,
      revealsArrivals: previous != nil && !changedConversation,
      sentID: sent?.id)
    applyWorkingLine(preview)
    let body = preview.question == nil
      ? ""
      : (isTranscript ? preview.question?.prompt ?? "" : preview.displayBody)
    bodyLabel.isHidden = preview.withholdsAnswer || body.isEmpty
    let bodyWeight: NSFont.Weight = preview.question == nil ? .regular : .semibold
    let bodyText = Self.bodyText(body, color: PaletteInk.primary, weight: bodyWeight)
    if !bodyLabel.attributedStringValue.isEqual(to: bodyText) {
      bodyLabel.attributedStringValue = bodyText
    }
    questionSurface.isHidden = bodyLabel.isHidden && preview.question == nil
    applyServiceGaps()
    queuedPrompt = preview.queuedPrompt
    queuedRow.isHidden = preview.queuedPrompt == nil
    if let queued = preview.queuedPrompt {
      queuedLabel.stringValue = queued
      queuedLabel.toolTip = queued
    }

    let report = AgentFailureReport.make(from: preview)
    failureReport = report
    if let report {
      failureCard.apply(report)
    }
    failureCard.isHidden = report == nil

    var status = ""
    if report == nil, !preview.isBusy, preview.question == nil, isTranscript,
       Self.bodyMessage(for: preview) == nil,
       preview.messages.last?.role != .agent || preview.messages.last?.plainText.isEmpty == true { status = "Finished without a text response." }
    if report == nil, !preview.isBusy, preview.question == nil, !isTranscript {
      status = "No output yet."
    }
    recoverButton.isHidden = preview.retryPrompt == nil || report != nil
    if previous?.retryPrompt != preview.retryPrompt { recoverButton.button.isEnabled = true }
    statusLabel.stringValue = status
    statusLabel.isHidden = status.isEmpty
    layoutSubtreeIfNeeded()
    if updatePinnedFloor() { layoutSubtreeIfNeeded() }
    if isFlying {
      pendingBottomScroll = pendingBottomScroll || follow
    } else if !preview.visibleMessages.isEmpty || preview.question != nil {
      pendingBottomScroll = follow
      if follow { scrollToLatest() } else { scroll.contentView.scroll(to: scrollPosition) }
    } else if changedConversation {
      scroll.contentView.scroll(to: restingScrollOrigin)
    }
    scroll.reflectScrolledClipView(scroll.contentView)
    if let sent, !isFlying {
      pendingBottomScroll = false
      launch(sent, from: scrollPosition)
    }
    setAccessibilityLabel("\(preview.agent.displayName), \(preview.title), \(preview.statusLabel)")
  }

  private func transcriptItems(for preview: BolttyAISessionPreview) -> [PaletteTranscriptItem] {
    if let body = Self.bodyMessage(for: preview) { return [.message(body, folded: false)] }
    return PaletteTranscript.items(
      for: preview.visibleMessages.filter(PaletteChatMessageView.draws),
      isBusy: preview.isBusy,
      expandedTurns: expandedTurns
    )
  }

  private static func bodyMessage(for preview: BolttyAISessionPreview) -> ConversationMessage? {
    guard preview.visibleMessages.isEmpty, preview.question == nil,
          !preview.withholdsAnswer else { return nil }
    let body = preview.displayBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }
    return ConversationMessage(
      id: "body-\(preview.id)", role: .agent, createdAt: .distantPast, completedAt: .distantPast,
      parts: [.text(TextPart(id: "body", kind: .text, text: body))])
  }

  private static func spacing(
    after item: PaletteTranscriptItem, before next: PaletteTranscriptItem?, copies: Set<String>
  ) -> CGFloat {
    switch item {
    case let .message(message, _):
      var following: ConversationMessage?
      if case let .message(value, _)? = next { following = value }
      return PaletteChatMessageView.spacing(
        after: message, before: following, offersCopy: copies.contains(message.id))
    case .turnHeader:
      return AgentPaletteMetrics.previewTurnHeaderSpacing
    }
  }

  private static func copyOffers(in items: [PaletteTranscriptItem], isBusy: Bool) -> Set<String> {
    let messages = items.compactMap { item -> ConversationMessage? in
      if case let .message(message, _) = item { return message }
      return nil
    }
    var offers = Set<String>()
    for (index, message) in messages.enumerated()
    where message.role == .agent && message.completedAt != nil && !message.copyableText.isEmpty {
      let next = index + 1 < messages.count ? messages[index + 1] : nil
      if next?.role == .user || (next == nil && !isBusy) { offers.insert(message.id) }
    }
    return offers
  }

  private func renderTranscript(
    _ preview: BolttyAISessionPreview, changedConversation: Bool,
    revealsArrivals: Bool = false, sentID: String? = nil
  ) {
    let items = transcriptItems(for: preview)
    let copies = Self.copyOffers(in: items, isBusy: preview.isBusy)
    var arrived: [PaletteChatMessageView] = []
    var wanted: [NSView] = []
    var liveRows = Set<String>()
    var liveHeaders = Set<String>()
    var running = false
    for item in items {
      switch item {
      case let .message(message, folded):
        liveRows.insert(message.id)
        let row = changedConversation ? nil : messageRows[message.id] ?? adoptStandIn(for: message, items: items)
        let view = row ?? {
          let made = PaletteChatMessageView(
            message: message, folded: folded, offersCopy: copies.contains(message.id))
          made.onUseFile = { [weak self] in self?.onUseFile?($0) }
          made.onToggleActivity = { [weak self] in self?.toggleActivity($0) }
          made.onSpeak = { [weak self] in self?.onSpeak?($0) }
          if revealsArrivals, message.id != sentID { arrived.append(made) }
          return made
        }()
        if let old = messageRows[message.id], old !== view { old.removeFromSuperview() }
        messageRows[message.id] = view
        view.setExpandedActivities(expandedActivities)
        view.apply(message, folded: folded, offersCopy: copies.contains(message.id))
        view.isSpeaking = message.id == speakingMessageID
        view.revealsNewContent = message.id != streamedMessageID
        wanted.append(view)
      case let .turnHeader(header):
        liveHeaders.insert(header.id)
        running = running || header.isRunning
        let existing = changedConversation ? nil : turnHeaders[header.id]
        let view = existing ?? {
          let made = PaletteTurnHeaderView()
          made.onToggle = { [weak self] id in self?.toggleTurn(id) }
          return made
        }()
        if let old = turnHeaders[header.id], old !== view { old.removeFromSuperview() }
        turnHeaders[header.id] = view
        view.apply(header)
        wanted.append(view)
      }
    }
    for (id, row) in messageRows where !liveRows.contains(id) {
      row.removeFromSuperview()
      messageRows[id] = nil
    }
    for (id, header) in turnHeaders where !liveHeaders.contains(id) {
      header.removeFromSuperview()
      turnHeaders[id] = nil
    }
    if messages.arrangedSubviews != wanted {
      for view in messages.arrangedSubviews { messages.removeArrangedSubview(view) }
      for view in wanted {
        let isNew = view.superview !== messages
        messages.addArrangedSubview(view)
        if isNew { view.widthAnchor.constraint(equalTo: messages.widthAnchor).isActive = true }
      }
    }
    for (index, (view, item)) in zip(wanted, items).enumerated() {
      let next = index + 1 < items.count ? items[index + 1] : nil
      messages.setCustomSpacing(Self.spacing(after: item, before: next, copies: copies), after: view)
    }
    for row in arrived { row.revealArrival() }
    if running || preview.isBusy { startTurnClock() } else { stopTurnClock() }
  }

  private func adoptStandIn(
    for message: ConversationMessage, items: [PaletteTranscriptItem]
  ) -> PaletteChatMessageView? {
    guard message.role == .user else { return nil }
    let wanted = Set(items.compactMap { item -> String? in
      if case let .message(value, _) = item { return value.id }
      return nil
    })
    guard let key = messageRows.keys.first(where: { $0.hasPrefix("pending-") && !wanted.contains($0) }),
          let row = messageRows.removeValue(forKey: key)
    else { return nil }
    return row
  }

  private func startTurnClock() {
    guard turnClock == nil else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        for header in self.turnHeaders.values { header.tick() }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    turnClock = timer
  }

  private func stopTurnClock() {
    turnClock?.invalidate()
    turnClock = nil
  }

  // MARK: - The agent's question

  var isAnswering: Bool { !optionRows.isEmpty }

  var focusedOptionIndex: Int { focusedOption }

  var pendingQuestion: AgentQuestion? { question }

  private func applyQuestion(_ question: AgentQuestion?) {
    guard question != self.question else { return }
    self.question = question
    questionSurface.setStyled(
      question != nil, bottom: question.map(Self.serviceBottomInset(for:)))
    questionTitle.isHidden = question == nil
    questionTitle.stringValue = question.map(Self.title(of:)) ?? ""
    for constraint in questionWidthConstraints {
      constraint.constant = question == nil ? 0 : -AgentPaletteMetrics.failureCardPadding * 2
    }

    for row in optionRows {
      options.removeArrangedSubview(row)
      row.removeFromSuperview()
    }
    optionRows = []
    chosenOptions = []
    focusedOption = 0

    approvalBar?.removeFromSuperview()
    approvalBar = nil
    approvalHost.isHidden = true
    permissionWell.isHidden = true

    guard let question else {
      options.isHidden = true
      optionsFooter.isHidden = true
      return
    }
    let isPermission = question.kind != .question
    if isPermission {
      permissionWell.show(question.detail ?? "")
      permissionWell.isHidden = (question.detail ?? "").isEmpty
      let bar = BolttyAIApprovalBar(
        options: question.options, copyText: question.copyText,
        returnReach: question.returnReachableCount)
      bar.onClick = { [weak self] index in self?.clicked(index) }
      bar.returnPressesAnAnswer = !composerHasWords
      approvalHost.addSubview(bar)
      NSLayoutConstraint.activate([
        bar.leadingAnchor.constraint(equalTo: approvalHost.leadingAnchor),
        bar.trailingAnchor.constraint(equalTo: approvalHost.trailingAnchor),
        bar.topAnchor.constraint(equalTo: approvalHost.topAnchor),
        bar.bottomAnchor.constraint(equalTo: approvalHost.bottomAnchor),
      ])
      approvalBar = bar
      approvalHost.isHidden = false
    }
    optionsFooter.stringValue = wordsAreTheAnswer
      ? AgentQuestion.typedAnswerFooter
      : question.keyboardFooter
    optionsFooter.isHidden = isPermission

    for (index, option) in question.options.enumerated() {
      let row = BolttyAIOptionRow(
        option: option, multiple: question.allowsMultiple,
        number: question.answersByNumber ? index + 1 : nil)
      row.onClick = { [weak self] in self?.clicked(index) }
      options.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true
      optionRows.append(row)
    }

    if !question.allowsMultiple { chosenOptions = [0] }
    options.isHidden = isPermission
    refreshRows()
  }

  @discardableResult
  func moveOptionFocus(by delta: Int) -> Bool {
    guard !optionRows.isEmpty else { return false }
    let reachable = min(question?.returnReachableCount ?? optionRows.count, optionRows.count)
    focusedOption = min(max(focusedOption + delta, 0), reachable - 1)
    if question?.allowsMultiple == false { chosenOptions = [focusedOption] }
    refreshRows()
    optionRows[focusedOption].scrollToVisible(optionRows[focusedOption].bounds)
    return true
  }

  /// What stands in a card that asks, in order. The gap between two is
  /// `serviceGap`'s, the same for the card on screen and for its measure.
  enum ServicePiece: Equatable {
    case eyebrow, title, well, options, footer
    case actions(captioned: Bool)
  }

  static func serviceGap(_ above: ServicePiece, _ below: ServicePiece) -> CGFloat {
    switch (above, below) {
    case (.eyebrow, .title):
      AgentPaletteMetrics.serviceEyebrowGap
    case (.well, .actions(captioned: true)), (.options, .footer):
      AgentPaletteMetrics.serviceCaptionGap
    case (_, .actions(captioned: false)):
      AgentPaletteMetrics.serviceActionsGap
    default:
      AgentPaletteMetrics.serviceContentGap
    }
  }

  /// To the ink of what ends the card: a button's edge, or the footer's
  /// baseline.
  static func serviceBottomInset(for question: AgentQuestion) -> CGFloat {
    guard question.kind == .question else { return AgentPaletteMetrics.failureCardPadding }
    return AgentPaletteMetrics.inkInset(
      AgentPaletteMetrics.failureCardPadding,
      less: AgentPaletteMetrics.baselineTrim(optionsFooterFont))
  }

  private static var optionsFooterFont: NSFont {
    roundedAppFont(size: AgentPaletteMetrics.previewFooterFontSize)
  }

  private func applyServiceGaps() {
    let captioned = question.map { BolttyAIApprovalBar.isCaptioned($0.options) } ?? false
    let pieces: [(NSView, ServicePiece)] = [
      (questionTitle, .eyebrow), (bodyLabel, .title), (permissionWell, .well),
      (options, .options), (optionsFooter, .footer), (approvalHost, .actions(captioned: captioned)),
    ]
    let shown = pieces.filter { !$0.0.isHidden }
    for (above, below) in zip(shown, shown.dropFirst()) {
      questionSurface.setCustomSpacing(Self.serviceGap(above.1, below.1), after: above.0)
    }
  }

  static func serviceCardHeight(
    for question: AgentQuestion, width: CGFloat, wellExpanded: Bool
  ) -> CGFloat {
    var pieces: [(ServicePiece, CGFloat)] = [(.eyebrow, PaletteServiceStack.eyebrowHeight)]
    if !question.prompt.isEmpty {
      let title = bodyText(question.prompt, color: PaletteInk.primary, weight: .semibold)
        .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
      pieces.append((.title, ceil(title.height)))
    }
    if question.kind == .question {
      let rows = AgentPaletteMetrics.previewOptionsHeight(options: question.options, width: width)
        - AgentPaletteMetrics.previewOptionsTopSpacing
      pieces.append((.options, max(rows, 0)))
      pieces.append((.footer, AgentPaletteMetrics.labelHeight(optionsFooterFont)))
    } else {
      if let detail = question.detail, !detail.isEmpty {
        pieces.append((.well, BolttyAICommandWell.height(
          for: detail, width: width, expanded: wellExpanded)))
      }
      pieces.append((.actions(captioned: BolttyAIApprovalBar.isCaptioned(question.options)),
        BolttyAIApprovalBar.height(
          for: question.options, copies: question.copyText != nil,
          returnReach: question.returnReachableCount, width: width)))
    }
    let gaps = zip(pieces, pieces.dropFirst()).reduce(CGFloat(0)) { total, pair in
      total + serviceGap(pair.0.0, pair.1.0)
    }
    return PaletteServiceStack.eyebrowTopInset + serviceBottomInset(for: question)
      + pieces.reduce(0) { $0 + $1.1 } + gaps
  }

  static func title(of question: AgentQuestion) -> String {
    if question.kind == .permission { return "Needs your approval" }
    if question.kind == .plan { return question.header ?? "Plan" }
    let header = question.header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return header.isEmpty ? "Question" : header
  }

  func setComposerHasWords(_ hasWords: Bool) {
    guard hasWords != composerHasWords else { return }
    composerHasWords = hasWords
    approvalBar?.returnPressesAnAnswer = !hasWords
    if let question, question.takesWordsAsAnswer {
      optionsFooter.stringValue = wordsAreTheAnswer
        ? AgentQuestion.typedAnswerFooter
        : question.keyboardFooter
      refreshRows()
    }
  }

  private var wordsAreTheAnswer: Bool {
    composerHasWords && question?.takesWordsAsAnswer == true
  }

  @discardableResult
  func chooseOption(number: Int) -> Bool {
    guard let question, question.answersByNumber, optionRows.indices.contains(number - 1) else {
      return false
    }
    clicked(number - 1)
    return true
  }

  @discardableResult
  func toggleFocusedOption() -> Bool {
    guard !optionRows.isEmpty, question?.allowsMultiple == true else { return false }
    if chosenOptions.contains(focusedOption) {
      chosenOptions.remove(focusedOption)
    } else {
      chosenOptions.insert(focusedOption)
    }
    refreshRows()
    return true
  }

  @discardableResult
  func confirmOptions() -> Bool {
    guard let question, !chosenValues.isEmpty else { return false }
    onAnswer?(question, chosenValues)
    return true
  }

  private func clicked(_ index: Int) {
    focusedOption = index
    if question?.allowsMultiple == true {
      _ = toggleFocusedOption()
    } else {
      chosenOptions = [index]
      refreshRows()
      _ = confirmOptions()
    }
  }

  private var chosenValues: [String] {
    chosenOptions.sorted().compactMap { index in
      optionRows.indices.contains(index) ? optionRows[index].value : nil
    }
  }

  private func refreshRows() {
    let rowsAnswer = !wordsAreTheAnswer
    for (index, row) in optionRows.enumerated() {
      row.isFocused = rowsAnswer && index == focusedOption
      row.isChosen = rowsAnswer && chosenOptions.contains(index)
    }
    approvalBar?.focusedIndex = focusedOption
  }

  fileprivate static func bodyText(
    _ body: String,
    color: NSColor,
    weight: NSFont.Weight = .regular
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = AgentPaletteMetrics.previewBodyLineHeight
    paragraph.maximumLineHeight = AgentPaletteMetrics.previewBodyLineHeight
    paragraph.lineBreakMode = .byWordWrapping
    return NSAttributedString(
      string: body,
      attributes: [
        .font: roundedAppFont(size: AgentPaletteMetrics.previewBodyFontSize, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ]
    )
  }
}

final class PaletteChatMessageView: NSView {
  private let bubble = NSView()
  private let bodyStack = NSStackView()
  private var textViews: [NSTextField] = []
  private var answerViews: [PaletteAnswerTextView] = []
  private var codeViews: [PaletteCodeBlockView] = []
  private var activityRows: [PaletteActivityRowView] = []
  private var groupViews: [PaletteActivityGroupView] = []
  private var shownKeys: [String] = []
  var revealsNewContent = false
  private var userMaxWidth: NSLayoutConstraint?
  private var copyConstraints: [NSLayoutConstraint] = []
  private(set) var isFolded = false
  private var expandedActivities: Set<String> = []
  var onToggleActivity: ((String) -> Void)?
  var textFieldsForTesting: [NSTextField] { textViews }
  var answerViewsForTesting: [PaletteAnswerTextView] { answerViews }
  var codeBlocksForTesting: [PaletteCodeBlockView] { codeViews }
  var activityRowsForTesting: [PaletteActivityRowView] { activityRows }
  var activityGroupsForTesting: [PaletteActivityGroupView] { groupViews }
  private var message: ConversationMessage
  private var rowHeight: NSLayoutConstraint!
  private let fileStack = NSStackView()
  private var fileRowsTop: NSLayoutConstraint!
  private var userBubbleTop: NSLayoutConstraint?
  private var shownFiles: [String] = []
  var onUseFile: ((URL) -> Void)? {
    didSet {
      for row in fileRows { row.onUse = onUseFile }
    }
  }
  private var fileRows: [PaletteFileRowView] = []
  var filePathsForTesting: [String] { shownFiles }
  var fileRowsForTesting: [PaletteFileRowView] { fileRows }

  private static func attributed(_ message: ConversationMessage) -> NSAttributedString {
    attributed(blocks: message.paletteBlocks, of: message)
  }

  private static func attributed(
    blocks: [PaletteMessageBlock], of message: ConversationMessage
  ) -> NSAttributedString {
    guard message.role == .agent, message.completedAt != nil || message.proseIsClosed else {
      return message.role == .user
        ? BolttyAIPreviewCard.bodyText(Self.flat(blocks), color: AgentPaletteMetrics.previewUserBubbleInk)
        : PaletteAnswerText.streaming(Self.flat(blocks), color: PaletteInk.primary)
    }
    return PaletteAnswerText.attributed(blocks: blocks, color: PaletteInk.primary)
  }

  private static func flat(_ blocks: [PaletteMessageBlock]) -> String {
    blocks.compactMap { block -> String? in
      switch block {
      case let .prose(text): return text
      case let .attachment(attachment): return attachment.displayName
      case let .failure(message): return message
      case .reasoning, .activity: return nil
      }
    }.joined(separator: "\n\n")
  }

  private let copyButton = PaletteIconButton()
  private var copyResetWork: DispatchWorkItem?
  /// Reads the answer aloud; while it does, it stays up and stops it.
  private let speakButton = PaletteIconButton()
  var onSpeak: ((ConversationMessage) -> Void)?
  private var isHovered = false
  var isSpeaking = false {
    didSet {
      guard isSpeaking != oldValue else { return }
      applySpeakGlyph()
      setCopyRevealed(isHovered)
    }
  }
  var isSpeakVisibleForTesting: Bool { !speakButton.isHidden }
  func pressSpeakForTesting() { speak(speakButton) }

  var isCopyVisibleForTesting: Bool { !copyButton.isHidden }
  var copyLayoutForTesting: (copy: NSRect, text: NSRect) {
    func inSelf(_ view: NSView) -> NSRect {
      convert(view.alignmentRect(forFrame: view.frame), from: view.superview)
    }
    return (inSelf(copyButton), inSelf(answerViews.last ?? textViews.first ?? bodyStack))
  }
  var bubbleFrameForFlight: NSRect { convert(bubble.bounds, from: bubble) }
  func hoverForTesting(_ inside: Bool) { setCopyRevealed(inside) }
  func pressCopyForTesting() { copyText(copyButton) }

  private(set) var offersCopy = false

  init(message: ConversationMessage, folded: Bool = false, offersCopy: Bool = false) {
    self.message = message
    self.isFolded = folded
    self.offersCopy = offersCopy
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    bubble.translatesAutoresizingMaskIntoConstraints = false
    bubble.wantsLayer = true
    bodyStack.translatesAutoresizingMaskIntoConstraints = false
    bodyStack.orientation = .vertical
    bodyStack.alignment = .leading
    bodyStack.spacing = 0
    addSubview(bubble)
    bubble.addSubview(bodyStack)
    let user = message.role == .user
    fileStack.translatesAutoresizingMaskIntoConstraints = false
    fileStack.orientation = .vertical
    fileStack.alignment = user ? .trailing : .leading
    fileStack.spacing = AgentPaletteMetrics.previewFileRowSpacing
    if user { addSubview(fileStack) } else { bubble.addSubview(fileStack) }
    bubble.layer?.backgroundColor = user
      ? AgentPaletteMetrics.previewUserBubbleFill.cgColor
      : NSColor.clear.cgColor
    if user { bubble.layer?.applyPaletteCorner(radius: AgentPaletteMetrics.previewUserBubbleCornerRadius) }
    bubble.layer?.masksToBounds = user
    let side = user ? AgentPaletteMetrics.previewUserBubbleHorizontalPadding : 0
    let top = user ? AgentPaletteMetrics.previewUserBubbleVerticalPadding : 0
    if user {
      let limit = bubble.widthAnchor.constraint(
        lessThanOrEqualToConstant: AgentPaletteMetrics.previewBubbleMaxWidth(in: 464))
      userMaxWidth = limit
    }
    let bubbleTop = bubble.topAnchor.constraint(equalTo: topAnchor)
    NSLayoutConstraint.activate([
      bubbleTop,
      bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
      userMaxWidth ?? bubble.widthAnchor.constraint(equalTo: widthAnchor),
      user ? bubble.trailingAnchor.constraint(equalTo: trailingAnchor) : bubble.leadingAnchor.constraint(equalTo: leadingAnchor),
      bodyStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: side),
      bodyStack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -side),
      bodyStack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: top),
    ])
    if user {
      userBubbleTop = bubbleTop
      fileRowsTop = fileStack.topAnchor.constraint(equalTo: topAnchor)
      NSLayoutConstraint.activate([
        fileStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        fileStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
      ])
    } else {
      fileRowsTop = fileStack.topAnchor.constraint(equalTo: bodyStack.bottomAnchor)
      NSLayoutConstraint.activate([
        fileStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: side),
        fileStack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -side),
        fileStack.bottomAnchor.constraint(lessThanOrEqualTo: bubble.bottomAnchor),
      ])
    }
    fileRowsTop.isActive = true
    syncFileRows(message)
    rowHeight = heightAnchor.constraint(equalToConstant: Self.height(
      for: message, width: 464, folded: folded, offersCopy: offersCopy))
    rowHeight.isActive = true
    syncSegments(message)
    setAccessibilityIdentifier("boltty.ask.chat.message.\(message.id)")
    setUpCopyButton(user: user)
  }
  required init?(coder: NSCoder) { nil }

  private func setUpCopyButton(user: Bool) {
    copyButton.isHidden = true
    guard !user else { return }
    copyButton.translatesAutoresizingMaskIntoConstraints = false
    copyButton.isBordered = false
    copyButton.title = ""
    copyButton.imagePosition = .imageOnly
    copyButton.contentTintColor = .white
    copyButton.restingTint = ComposerControlGroup.restingInk
    copyButton.hoverTint = .white
    copyButton.hoverBackground = .clear
    copyButton.target = self
    copyButton.action = #selector(copyText(_:))
    copyButton.toolTip = "Copy this answer"
    copyButton.setAccessibilityIdentifier("boltty.ask.chat.message.copy")
    copyButton.setAccessibilityLabel("Copy this answer")
    applyCopyGlyph("doc.on.doc")
    bubble.addSubview(copyButton)
    speakButton.isHidden = true
    speakButton.translatesAutoresizingMaskIntoConstraints = false
    speakButton.isBordered = false
    speakButton.title = ""
    speakButton.imagePosition = .imageOnly
    speakButton.contentTintColor = .white
    speakButton.restingTint = ComposerControlGroup.restingInk
    speakButton.hoverTint = .white
    speakButton.hoverBackground = .clear
    speakButton.target = self
    speakButton.action = #selector(speak(_:))
    speakButton.setAccessibilityIdentifier("boltty.ask.chat.message.speak")
    applySpeakGlyph()
    bubble.addSubview(speakButton)
    NSLayoutConstraint.activate([
      copyButton.widthAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.previewCopyButtonSize),
      copyButton.heightAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.previewCopyButtonSize),
      speakButton.widthAnchor.constraint(equalTo: copyButton.widthAnchor),
      speakButton.heightAnchor.constraint(equalTo: copyButton.heightAnchor),
      speakButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor),
      speakButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
    ])
    pinCopyButton()
    addTrackingArea(NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    ))
  }

  private func pinCopyButton() {
    NSLayoutConstraint.deactivate(copyConstraints)
    guard copyButton.superview != nil else { return copyConstraints = [] }
    let glyph = Self.copyImage("doc.on.doc")?.size.width ?? AgentPaletteMetrics.previewFileGlyphPointSize
    let inkInset = (AgentPaletteMetrics.previewCopyButtonSize - glyph) / 2
    copyConstraints = [
      copyButton.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: -inkInset),
      copyButton.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
    ]
    NSLayoutConstraint.activate(copyConstraints)
  }

  private func applyCopyGlyph(_ name: String) {
    copyButton.image = Self.copyImage(name)
  }

  private static func copyImage(_ name: String) -> NSImage? {
    NSImage(
      systemSymbolName: name,
      accessibilityDescription: "Copy this answer"
    )?.withSymbolConfiguration(.init(
      pointSize: AgentPaletteMetrics.previewFileGlyphPointSize,
      weight: .medium
    ))
  }

  override func mouseEntered(with event: NSEvent) { setCopyRevealed(true) }
  override func mouseExited(with event: NSEvent) { setCopyRevealed(false) }

  private func setCopyRevealed(_ revealed: Bool) {
    isHovered = revealed
    guard copyButton.superview != nil else { return }
    let offered = offersCopy && !message.copyableText.isEmpty
    copyButton.isHidden = !revealed || !offered
    let shows = offered && (revealed || isSpeaking) && onSpeak != nil
    speakButton.isHidden = !(shows && speaksThisAnswer)
  }

  /// Whether this answer can be read aloud — in one of the languages Boltty
  /// speaks (`SpeechLanguages`). Worked out when the pointer first comes to
  /// it, not as the transcript draws, and kept while the words stay the same.
  private var speaksThisAnswer: Bool {
    let words = message.copyableText
    if let known = spokenAnswer, known.words == words { return known.speaks }
    let speaks = SpeechOutput.canSpeak(text: words)
    spokenAnswer = (words, speaks)
    return speaks
  }

  private var spokenAnswer: (words: String, speaks: Bool)?

  private func applySpeakGlyph() {
    let name = isSpeaking ? "stop.fill" : "speaker.wave.2"
    let label = isSpeaking ? "Stop reading aloud" : "Read this answer aloud"
    speakButton.image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
      .withSymbolConfiguration(.init(
        pointSize: AgentPaletteMetrics.previewFileGlyphPointSize, weight: .medium))
    speakButton.toolTip = label
    speakButton.setAccessibilityLabel(label)
  }

  @objc private func speak(_ sender: NSButton) {
    guard !message.copyableText.isEmpty else { return }
    onSpeak?(message)
  }

  @objc private func copyText(_ sender: NSButton) {
    let value = message.copyableText
    guard !value.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
    applyCopyGlyph("checkmark")
    copyResetWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.applyCopyGlyph("doc.on.doc") }
    copyResetWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
  }

  func apply(_ value: ConversationMessage, folded: Bool = false, offersCopy: Bool = false) {
    guard value != message || folded != isFolded || offersCopy != self.offersCopy else { return }
    if value.id != message.id { setAccessibilityIdentifier("boltty.ask.chat.message.\(value.id)") }
    message = value
    isFolded = folded
    self.offersCopy = offersCopy
    syncSegments(value)
    syncFileRows(value)
    if !copyButton.isHidden, !offersCopy || value.copyableText.isEmpty { copyButton.isHidden = true }
    if !speakButton.isHidden, !offersCopy || value.copyableText.isEmpty { speakButton.isHidden = true }
    needsLayout = true
  }

  func setExpandedActivities(_ ids: Set<String>) {
    guard ids != expandedActivities else { return }
    expandedActivities = ids
    for row in activityRows {
      row.apply(row.activity, isExpanded: ids.contains(row.activity.id))
    }
    for group in groupViews { group.apply(group.activities, expanded: ids) }
    needsLayout = true
  }

  fileprivate enum Unit {
    case field([PaletteMessageBlock])
    case answer([PaletteMessageBlock])
    case code(String)
    case activity(AgentActivity)
    case group([AgentActivity])
    case note(String)

    var key: String {
      switch self {
      case .field: "f"
      case .answer: "t"
      case .code: "c"
      case let .activity(activity): "a:\(activity.id)"
      case let .group(activities): AgentActivityGroup.id(of: activities)
      case .note: "n"
      }
    }

    var isText: Bool {
      switch self {
      case .field, .answer, .code: true
      case .activity, .group, .note: false
      }
    }
  }

  fileprivate static func units(of message: ConversationMessage, folded: Bool) -> [Unit] {
    var units = segments(of: message, folded: folded).flatMap { segment -> [Unit] in
      switch segment {
      case let .text(blocks):
        message.role == .user
          ? [.field(blocks)]
          : PaletteAnswerRun.pieces(of: blocks).map { piece -> Unit in
            switch piece {
            case let .text(words): .answer(words)
            case let .code(code): .code(code)
            }
          }
      case let .activity(activity): [.activity(activity)]
      case let .group(activities): [.group(activities)]
      }
    }
    if message.role == .agent, message.failure?.isAbort == true { units.append(.note("Stopped")) }
    return units
  }

  static func draws(_ message: ConversationMessage) -> Bool {
    guard !message.paletteText.isEmpty else { return false }
    return message.role == .user || !units(of: message, folded: false).isEmpty
      || !message.resultFiles.isEmpty
  }

  private func syncSegments(_ value: ConversationMessage) {
    let units = Self.units(of: value, folded: isFolded)
    let keys = units.map(\.key)
    if keys != shownKeys {
      let kept = zip(keys, shownKeys).prefix { $0 == $1 }.count
      for view in bodyStack.arrangedSubviews {
        bodyStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
      textViews = []
      answerViews = []
      codeViews = []
      activityRows = []
      groupViews = []
      for unit in units {
        switch unit {
        case .field:
          let field = NSTextField(wrappingLabelWithString: "")
          field.translatesAutoresizingMaskIntoConstraints = false
          field.isSelectable = true
          field.allowsEditingTextAttributes = true
          field.lineBreakMode = .byWordWrapping
          bodyStack.addArrangedSubview(field)
          field.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
          textViews.append(field)
        case .answer:
          let view = PaletteAnswerTextView()
          bodyStack.addArrangedSubview(view)
          view.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
          answerViews.append(view)
        case .code:
          let view = PaletteCodeBlockView()
          bodyStack.addArrangedSubview(view)
          view.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
          codeViews.append(view)
        case .note:
          let note = NSTextField(labelWithString: "")
          note.translatesAutoresizingMaskIntoConstraints = false
          note.font = roundedAppFont(size: AgentPaletteMetrics.previewActivityNameFontSize)
          note.textColor = PaletteInk.secondary
          bodyStack.addArrangedSubview(note)
          note.heightAnchor.constraint(
            equalToConstant: AgentPaletteMetrics.previewActivityRowHeight).isActive = true
        case let .activity(activity):
          let row = PaletteActivityRowView(
            activity: activity, isExpanded: expandedActivities.contains(activity.id)
          )
          row.onToggle = { [weak self] id in self?.onToggleActivity?(id) }
          bodyStack.addArrangedSubview(row)
          row.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
          activityRows.append(row)
        case let .group(activities):
          let group = PaletteActivityGroupView(activities: activities, expanded: expandedActivities)
          group.onToggle = { [weak self] id in self?.onToggleActivity?(id) }
          bodyStack.addArrangedSubview(group)
          group.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
          groupViews.append(group)
        }
      }
      applyBodySpacing(units)
      pinCopyButton()
      if revealsNewContent { Self.reveal(Array(bodyStack.arrangedSubviews.dropFirst(kept))) }
      shownKeys = keys
    }

    for (unit, view) in zip(units, bodyStack.arrangedSubviews) {
      switch unit {
      case let .field(blocks):
        (view as? NSTextField)?.attributedStringValue = Self.attributed(blocks: blocks, of: value)
      case let .answer(blocks):
        (view as? PaletteAnswerTextView)?.attributedStringValue = Self.attributed(blocks: blocks, of: value)
      case let .code(code):
        (view as? PaletteCodeBlockView)?.apply(code)
      case let .activity(activity):
        (view as? PaletteActivityRowView)?.apply(
          activity, isExpanded: expandedActivities.contains(activity.id))
      case let .group(activities):
        (view as? PaletteActivityGroupView)?.apply(activities, expanded: expandedActivities)
      case let .note(text):
        (view as? NSTextField)?.stringValue = text
      }
    }
    needsLayout = true
  }

  static func reveal(_ views: [NSView]) {
    guard let window = views.first?.window, window.isVisible else { return }
    for (index, view) in views.enumerated() {
      view.alphaValue = 0
      let beat = min(index, AgentPaletteMetrics.previewRevealStaggerSteps)
      DispatchQueue.main.asyncAfter(
        deadline: .now() + Motion.scaled(AgentPaletteMetrics.previewRevealStagger * Double(beat))
      ) { [weak view] in
        NSAnimationContext.runAnimationGroup { context in
          context.duration = AgentPaletteMetrics.previewRevealDuration
          context.timingFunction = Motion.emphasizedCurve
          view?.animator().alphaValue = 1
        }
      }
    }
  }

  func revealArrival() {
    Self.reveal(bodyStack.arrangedSubviews + fileRows)
  }

  private func applyBodySpacing(_ units: [Unit]) {
    let views = bodyStack.arrangedSubviews
    for (index, view) in views.enumerated() where index < views.count - 1 {
      bodyStack.setCustomSpacing(Self.gap(between: units[index], and: units[index + 1]), after: view)
    }
  }

  fileprivate static func segments(
    of message: ConversationMessage, folded: Bool = false
  ) -> [PaletteSegment] {
    guard message.role != .user else {
      let typed = message.typedBlocks
      return typed.isEmpty ? [] : [.text(typed)]
    }
    let segments = message.paletteSegments
    guard folded else { return segments }
    return segments.last(where: \.isText).map { [$0] } ?? []
  }

  private static func gap(between here: Unit, and next: Unit) -> CGFloat {
    if case .group = next { return AgentPaletteMetrics.previewWorkPillSpacingAbove }
    if case .group = here { return AgentPaletteMetrics.previewWorkPillSpacingBelow }
    if here.isText, next.isText { return AgentPaletteMetrics.answerParagraphSpacing }
    return here.isText || next.isText
      ? AgentPaletteMetrics.previewActivityRowsTopMargin
      : AgentPaletteMetrics.previewActivityRowSpacing
  }

  private func syncFileRows(_ message: ConversationMessage) {
    let paths = message.resultFiles
    guard paths != shownFiles else { return }
    shownFiles = paths
    for row in fileRows {
      fileStack.removeArrangedSubview(row)
      row.removeFromSuperview()
    }
    let names = message.fileCardNames
    let user = message.role == .user
    fileRows = paths.map { path in
      let row = PaletteFileRowView(path: path, name: names[path])
      row.onUse = onUseFile
      fileStack.addArrangedSubview(row)
      let preferred = row.widthAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.previewFileCardWidth)
      preferred.priority = .defaultHigh
      NSLayoutConstraint.activate([
        preferred,
        row.widthAnchor.constraint(lessThanOrEqualTo: user ? widthAnchor : fileStack.widthAnchor),
      ])
      return row
    }
    fileRowsTop.constant = paths.isEmpty || user ? 0 : AgentPaletteMetrics.previewFileRowsTopMargin
  }

  var fileCardsForFlight: [(path: String, name: String?, frame: NSRect)] {
    let names = message.fileCardNames
    return zip(shownFiles, fileRows).map { path, row in
      (path, names[path], convert(row.bounds, from: row))
    }
  }

  var drawsBubble: Bool { !Self.units(of: message, folded: isFolded).isEmpty }
  var isBubbleShownForTesting: Bool { !bubble.isHidden }
  override func layout() {
    super.layout()
    let width = bounds.width > 0 ? bounds.width : 464
    let inner = Self.textWidth(for: message, in: width)
    for field in textViews { field.preferredMaxLayoutWidth = inner }
    for view in answerViews { view.fit(width: inner) }
    for view in codeViews { view.fit(width: inner) }
    userMaxWidth?.constant = AgentPaletteMetrics.previewBubbleMaxWidth(in: width)
    for row in activityRows {
      row.setWidth(inner, height: PaletteActivityRowView.height(
        for: row.activity, width: inner,
        isExpanded: expandedActivities.contains(row.activity.id)
      ))
    }
    for group in groupViews {
      group.setWidth(inner, height: PaletteActivityGroupView.height(
        for: group.activities, width: inner, expanded: expandedActivities
      ), expanded: expandedActivities)
    }
    let height = Self.height(
      for: message, width: width, expanded: expandedActivities, folded: isFolded,
      offersCopy: offersCopy)
    if abs(rowHeight.constant - height) > 0.5 { rowHeight.constant = height }
    if let userBubbleTop {
      let offset = Self.userBubbleOffset(for: message)
      if abs(userBubbleTop.constant - offset) > 0.5 { userBubbleTop.constant = offset }
      bubble.isHidden = !drawsBubble
    }
    if message.role == .user {
      bubble.layer?.applyPaletteCorner(
        radius: AgentPaletteMetrics.previewUserBubbleCornerRadius
      )
    }
  }

  static func textWidth(for message: ConversationMessage, in width: CGFloat) -> CGFloat {
    guard message.role == .user else { return width }
    return AgentPaletteMetrics.previewBubbleMaxWidth(in: width)
      - AgentPaletteMetrics.previewUserBubbleHorizontalPadding * 2
  }
  static func textHeight(_ message: ConversationMessage, width: CGFloat) -> CGFloat {
    height(of: attributed(message), width: width)
  }

  static func bodyHeight(
    for message: ConversationMessage, width: CGFloat, expanded: Set<String>,
    folded: Bool = false
  ) -> CGFloat {
    let units = units(of: message, folded: folded)
    var total: CGFloat = 0
    for (index, unit) in units.enumerated() {
      switch unit {
      case let .field(blocks), let .answer(blocks):
        total += height(of: attributed(blocks: blocks, of: message), width: width)
      case let .code(code):
        total += PaletteCodeBlockView.height(for: code, width: width)
      case let .activity(activity):
        total += PaletteActivityRowView.height(
          for: activity, width: width, isExpanded: expanded.contains(activity.id)
        )
      case let .group(activities):
        total += PaletteActivityGroupView.height(
          for: activities, width: width, expanded: expanded)
      case .note:
        total += AgentPaletteMetrics.previewActivityRowHeight
      }
      guard index < units.count - 1 else { continue }
      total += gap(between: unit, and: units[index + 1])
    }
    return total
  }

  static func textHeight(
    _ text: String,
    width: CGFloat,
    weight: NSFont.Weight = .regular
  ) -> CGFloat {
    height(of: BolttyAIPreviewCard.bodyText(text, color: PaletteInk.primary, weight: weight), width: width)
  }

  fileprivate static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
    PaletteAnswerText.height(of: text, width: width)
  }
  static func height(
    for message: ConversationMessage, width: CGFloat, expanded: Set<String> = [],
    folded: Bool = false, offersCopy: Bool = false
  ) -> CGFloat {
    let user = message.role == .user
    let body = max(AgentPaletteMetrics.previewBodyLineHeight,
                   bodyHeight(for: message,
                              width: textWidth(for: message, in: width),
                              expanded: expanded, folded: folded))
    guard user else {
      let copy = offersCopy && !message.copyableText.isEmpty ? AgentPaletteMetrics.previewCopyRowHeight : 0
      return body + fileRowsHeight(for: message) + copy
    }
    let bubble = units(of: message, folded: folded).isEmpty && !message.resultFiles.isEmpty
      ? 0 : body + AgentPaletteMetrics.previewUserBubbleVerticalPadding * 2
    return userBubbleOffset(for: message) + bubble
  }

  static func userBubbleOffset(for message: ConversationMessage) -> CGFloat {
    let count = message.resultFiles.count
    guard count > 0 else { return 0 }
    let cards = CGFloat(count) * AgentPaletteMetrics.previewFileRowHeight
      + CGFloat(count - 1) * AgentPaletteMetrics.previewFileRowSpacing
    return units(of: message, folded: false).isEmpty
      ? cards : cards + AgentPaletteMetrics.previewSentFilesGap
  }

  static func spacing(
    after message: ConversationMessage, before next: ConversationMessage?, offersCopy: Bool
  ) -> CGFloat {
    if message.role == .agent, next?.role == .agent { return AgentPaletteMetrics.previewAgentMessageSpacing }
    guard message.role == .agent, offersCopy, !message.copyableText.isEmpty else {
      return AgentPaletteMetrics.previewMessageSpacing
    }
    return max(0, AgentPaletteMetrics.previewMessageSpacing - AgentPaletteMetrics.previewCopyRowHeight)
  }

  static func fileRowsHeight(for message: ConversationMessage) -> CGFloat {
    let count = message.resultFiles.count
    guard count > 0, message.role != .user else { return 0 }
    return AgentPaletteMetrics.previewFileRowsTopMargin
      + CGFloat(count) * AgentPaletteMetrics.previewFileRowHeight
      + CGFloat(count - 1) * AgentPaletteMetrics.previewFileRowSpacing
  }
}

final class PaletteStreamingTailView: NSView {
  private let field = NSTextField(wrappingLabelWithString: "")
  private(set) var textForTesting = ""
  private var text: String { textForTesting }
  private var births: [(range: NSRange, born: CFTimeInterval)] = []
  private var link: CADisplayLink?
  private var height: NSLayoutConstraint!
  private var agent: AgentId?
  private(set) var lightForTesting: [NSColor] = []
  private var light: [NSColor] { lightForTesting }

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    field.translatesAutoresizingMaskIntoConstraints = false
    field.isSelectable = false
    field.lineBreakMode = .byWordWrapping
    addSubview(field)
    height = heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: leadingAnchor),
      field.trailingAnchor.constraint(equalTo: trailingAnchor),
      field.topAnchor.constraint(equalTo: topAnchor),
      height,
    ])
  }
  required init?(coder: NSCoder) { nil }

  func apply(_ newText: String, column: CGFloat, agent: AgentId) {
    defer { fit(column) }
    if agent != self.agent {
      self.agent = agent
      lightForTesting = MascotLook.face(for: agent).palette.arrivalLight
      if newText == text { render(at: Motion.now) }
    }
    guard newText != text else { return }
    let now = Motion.now
    let previous = !text.isEmpty && newText.hasPrefix(text) ? births : []
    textForTesting = newText
    births = Self.words(in: newText).map { range in
      (range, previous.first { $0.range.location == range.location }?.born ?? now)
    }
    render(at: now)
    startClockIfNeeded()
  }

  func clear() {
    stopClock()
    textForTesting = ""
    births = []
    field.attributedStringValue = NSAttributedString()
  }

  func arriveForTesting(every interval: TimeInterval) {
    let now = Motion.now
    let count = births.count
    births = births.enumerated().map { index, word in
      (word.range, now - Double(count - index) * interval)
    }
    render(at: now)
  }

  func suspend() { stopClock() }

  static func height(of text: String, width: CGFloat) -> CGFloat {
    PaletteChatMessageView.height(
      of: PaletteAnswerText.streaming(text, color: PaletteInk.primary), width: width)
  }

  private func fit(_ column: CGFloat) {
    field.preferredMaxLayoutWidth = column
    let measured = Self.height(of: text, width: column)
    if abs(height.constant - measured) > 0.5 { height.constant = measured }
  }

  func resume() {
    guard !births.isEmpty else { return }
    render(at: Motion.now)
    startClockIfNeeded()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { stopClock() } else { startClockIfNeeded() }
  }

  private static func words(in text: String) -> [NSRange] {
    let ns = text as NSString
    var ranges: [NSRange] = []
    var start: Int?
    for index in 0..<ns.length {
      let isSpace = CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: index)) ?? " ")
      if isSpace {
        if let s = start { ranges.append(NSRange(location: s, length: index - s)); start = nil }
      } else if start == nil {
        start = index
      }
    }
    if let s = start { ranges.append(NSRange(location: s, length: ns.length - s)) }
    return ranges
  }

  private var isSettling: Bool {
    let now = Motion.now
    return births.contains { now - $0.born < AgentPaletteMetrics.previewStreamingWordSettle }
  }

  private func startClockIfNeeded() {
    guard link == nil, window != nil, isSettling else { return }
    let link = displayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  private func stopClock() {
    link?.invalidate()
    link = nil
  }

  @objc private func tick() {
    render(at: Motion.now)
    if !isSettling { stopClock() }
  }

  private func render(at now: CFTimeInterval) {
    let base = PaletteAnswerText.streaming(text, color: PaletteInk.primary)
    guard !births.isEmpty else { field.attributedStringValue = base; return }
    let styled = NSMutableAttributedString(attributedString: base)
    let still = MotionPreferences.reduceMotion
    var ink = PaletteInk.primary
    effectiveAppearance.performAsCurrentDrawingAppearance {
      ink = PaletteInk.primary.usingColorSpace(.sRGB) ?? PaletteInk.primary
    }
    for word in births {
      let age = now - word.born
      guard age < AgentPaletteMetrics.previewStreamingWordSettle,
            NSMaxRange(word.range) <= styled.length else { continue }
      let fade = Self.smoothstep(age / AgentPaletteMetrics.previewStreamingWordFade)
      let colour = still
        ? ink
        : Self.light(at: age / AgentPaletteMetrics.previewStreamingWordSettle, through: light, ink: ink)
      styled.addAttribute(
        .foregroundColor, value: colour.withAlphaComponent(ink.alphaComponent * fade), range: word.range)
    }
    field.attributedStringValue = styled
  }

  static func light(at progress: Double, through light: [NSColor], ink: NSColor) -> NSColor {
    let stops = light + [ink]
    guard stops.count >= 2 else { return ink }
    let scaled = CGFloat(min(1, max(0, progress))) * CGFloat(stops.count - 1)
    let index = min(Int(scaled), stops.count - 2)
    let local = smoothstep(Double(scaled - CGFloat(index)))
    return MascotPalette.mix(stops[index], stops[index + 1], local)
  }

  private static func smoothstep(_ x: Double) -> CGFloat {
    let t = CGFloat(min(1, max(0, x)))
    return t * t * (3 - 2 * t)
  }

}

final class PaletteTurnHeaderView: NSView {
  var onToggle: ((String) -> Void)?
  private(set) var turnID = ""
  private var header: PaletteTurnHeader?
  private let label = NSTextField(labelWithString: "")
  private let chevron = NSImageView()
  private let button = PaletteDisclosureButton()

  var textForTesting: String { label.stringValue }
  var isCollapsedForTesting: Bool { header?.isCollapsed ?? false }
  func pressForTesting() { didPress() }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = roundedAppFont(size: AgentPaletteMetrics.previewActivityNameFontSize)
    label.textColor = PaletteInk.secondary
    label.lineBreakMode = .byTruncatingTail
    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.imageScaling = .scaleProportionallyDown
    chevron.contentTintColor = PaletteInk.tertiary
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.title = ""
    button.target = self
    button.action = #selector(didPress)
    button.onHover = { [weak self] lit in
      self?.label.textColor = lit ? PaletteInk.primary : PaletteInk.secondary
      self?.chevron.contentTintColor = lit ? PaletteInk.secondary : PaletteInk.tertiary
    }
    for view in [label, chevron, button] { addSubview(view) }
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewTurnHeaderHeight),
      label.leadingAnchor.constraint(equalTo: leadingAnchor),
      label.topAnchor.constraint(equalTo: topAnchor),
      label.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewTurnHeaderLabelHeight),
      chevron.leadingAnchor.constraint(
        equalTo: label.trailingAnchor, constant: AgentPaletteMetrics.previewActivityRowSpacing * 2),
      chevron.centerYAnchor.constraint(
        equalTo: label.firstBaselineAnchor,
        constant: -(label.font?.capHeight ?? 0) / 2),
      chevron.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewActivityGlyphSize),
      chevron.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.disclosureTriangle)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(_ value: PaletteTurnHeader) {
    header = value
    turnID = value.id
    label.stringValue = value.text()
    chevron.isHidden = value.isRunning
    button.isEnabled = !value.isRunning
    chevron.image = NSImage(
      systemSymbolName: value.isCollapsed ? "chevron.right" : "chevron.down",
      accessibilityDescription: value.isCollapsed ? "Show the work" : "Hide the work"
    )?.withSymbolConfiguration(.init(
      pointSize: AgentPaletteMetrics.previewActivityChevronPointSize, weight: .semibold
    ))
    setAccessibilityLabel(label.stringValue)
    setAccessibilityValue(value.isRunning ? nil : (value.isCollapsed ? "collapsed" : "expanded"))
  }

  func tick() {
    guard let header, header.isRunning else { return }
    label.stringValue = header.text()
  }

  @objc private func didPress() {
    guard let header, !header.isRunning else { return }
    onToggle?(header.id)
  }
}

final class PaletteWorkingLineView: NSView {
  private let faceBox = NSView()
  private var face: MascotNSView?
  private var identity: UUID?
  private let label = NSTextField(labelWithString: "Thinking")
  private let glow = CALayer()
  private let textMask = CALayer()
  private let band = CAGradientLayer()
  private let halo = CAGradientLayer()
  private let haloMask = CALayer()
  private var maskedSize = NSSize.zero
  private var animates = false
  private var lightAgent: AgentId?
  private var light: [NSColor] = []

  var textForTesting: String { label.stringValue }
  var showsFaceForTesting: Bool { face?.isHidden == false }
  var lightColorsForTesting: [CGColor] { (band.colors as? [CGColor]) ?? [] }
  var isBreathingForTesting: Bool { glow.animation(forKey: "breath") != nil }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    for view in [faceBox, label] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    label.font = roundedAppFont(size: AgentPaletteMetrics.previewBodyFontSize)
    label.textColor = PaletteInk.primary
    label.wantsLayer = true
    for gradient in [band, halo] {
      gradient.startPoint = CGPoint(x: 0, y: 0.5)
      gradient.endPoint = CGPoint(x: 1, y: 0.5)
    }
    glow.mask = textMask
    glow.addSublayer(band)
    halo.mask = haloMask
    layer?.insertSublayer(halo, at: 0)
    layer?.addSublayer(glow)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.workingLineHeight),
      faceBox.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: AgentPaletteMetrics.workingLineLeadingInset),
      faceBox.centerYAnchor.constraint(equalTo: centerYAnchor),
      faceBox.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.workingLineFaceSize),
      faceBox.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.workingLineFaceSize),
      label.leadingAnchor.constraint(
        equalTo: faceBox.trailingAnchor, constant: AgentPaletteMetrics.workingLineFaceGap),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(label.stringValue)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(motionChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(_ preview: BolttyAISessionPreview) {
    if identity != preview.id {
      face?.removeFromSuperview()
      let made = MascotNSView(conversationID: preview.id, look: MascotLook.face(for: preview.agent))
      made.emotion = .thinking
      face = made
      identity = preview.id
      addSubview(made)
      needsLayout = true
    }
    if lightAgent != preview.agent {
      lightAgent = preview.agent
      light = MascotLook.face(for: preview.agent).palette.arrivalLight
      needsLayout = true
    }
    motionChanged()
  }

  func suspend() {
    animates = false
    stopBreathing()
    face?.isHidden = true
  }

  override var isHidden: Bool {
    didSet { if isHidden != oldValue { motionChanged() } }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    motionChanged()
  }

  override func layout() {
    super.layout()
    face?.frame = faceBox.frame
    let reach = AgentPaletteMetrics.workingLineHaloBlur * 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glow.frame = label.frame
    textMask.frame = glow.bounds
    band.frame = glow.bounds
    halo.frame = label.frame.insetBy(dx: -reach, dy: -reach)
    haloMask.frame = halo.bounds
    paintLight()
    if !animates { rest() }
    CATransaction.commit()
    refreshMask()
    if animates, glow.animation(forKey: "breath") == nil { breathe() }
  }

  private func paintLight() {
    let colors = light.map(\.cgColor)
    band.colors = colors
    halo.colors = colors
  }

  private func breathe() {
    let half = AgentPaletteMetrics.workingLineBreathDuration
    func breath(_ keyPath: String, from: CGFloat, to: CGFloat) -> CABasicAnimation {
      let animation = CABasicAnimation(keyPath: keyPath)
      animation.fromValue = from
      animation.toValue = to
      animation.duration = half
      animation.autoreverses = true
      animation.repeatCount = .infinity
      animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      return animation
    }
    glow.add(breath("opacity", from: AgentPaletteMetrics.workingLineBreathLitLow, to: 1), forKey: "breath")
    let swell = CAAnimationGroup()
    swell.animations = [
      breath("opacity", from: 0, to: AgentPaletteMetrics.workingLineHaloOpacity),
      breath("transform.scale", from: 0.96, to: 1.04),
    ]
    swell.duration = half
    swell.autoreverses = true
    swell.repeatCount = .infinity
    halo.add(swell, forKey: "breath")
  }

  private func stopBreathing() {
    glow.removeAnimation(forKey: "breath")
    halo.removeAnimation(forKey: "breath")
  }

  private func rest() {
    glow.opacity = 1
    halo.opacity = Float(AgentPaletteMetrics.workingLineHaloOpacity / 3)
    halo.transform = CATransform3DIdentity
  }

  private func refreshMask() {
    let size = label.bounds.size
    guard size.width > 0, size.height > 0, maskedSize != size,
          let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds)
    else { return }
    let ink = label.textColor
    label.textColor = .white
    label.cacheDisplay(in: label.bounds, to: rep)
    label.textColor = ink
    let scale = window?.backingScaleFactor ?? 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    textMask.contents = rep.cgImage
    textMask.contentsScale = scale
    haloMask.contents = rep.cgImage.flatMap {
      Self.blurred($0, reach: AgentPaletteMetrics.workingLineHaloBlur * 2 * scale,
                   blur: AgentPaletteMetrics.workingLineHaloBlur * scale)
    }
    haloMask.contentsScale = scale
    CATransaction.commit()
    maskedSize = size
  }

  private static func blurred(_ silhouette: CGImage, reach: CGFloat, blur: CGFloat) -> CGImage? {
    let width = silhouette.width + Int(ceil(reach * 2))
    let height = silhouette.height + Int(ceil(reach * 2))
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let away = CGFloat(width) * 4
    context.setShadow(
      offset: CGSize(width: away, height: 0), blur: blur, color: CGColor(gray: 1, alpha: 1))
    context.draw(silhouette, in: CGRect(
      x: reach - away, y: reach,
      width: CGFloat(silhouette.width), height: CGFloat(silhouette.height)))
    return context.makeImage()
  }

  @objc private func motionChanged() {
    animates = !isHidden && window != nil && !MotionPreferences.refreshReduceMotion()
    face?.isHidden = isHidden
    if !animates { stopBreathing() }
    needsLayout = true
  }
}
