import AppKit

// MARK: - Session row

final class GradientFillView: NSView {
  override func makeBackingLayer() -> CALayer { CAGradientLayer() }
  var gradientLayer: CAGradientLayer? { layer as? CAGradientLayer }
}

final class BolttyAISessionRowView: NSView {
  var onActivate: (() -> Void)?
  var onContextMenu: ((NSEvent) -> Void)?
  var onHover: (() -> Void)?
  private(set) var isHighlightedRow = false

  private(set) var item: BolttyAISessionItem

  func setHighlighted(_ highlighted: Bool, animated: Bool) {
    guard highlighted != isHighlightedRow else { return }
    isHighlightedRow = highlighted
    renderHighlight(animated: animated)
  }

  private let background = GradientFillView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private let face = NSImageView()
  private(set) var showsFace = false
  private let unreadDot = NSView()
  private var isHovered = false
  var hoverIsQuiet = false {
    didSet { if hoverIsQuiet != oldValue, isHovered { renderHighlight(animated: false) } }
  }
  private var trackingArea: NSTrackingArea?

  init(item: BolttyAISessionItem) {
    self.item = item
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    background.wantsLayer = true
    if let gradient = background.gradientLayer {
      gradient.cornerRadius = AgentPaletteMetrics.resultsRowCornerRadius
      gradient.isGeometryFlipped = false
      gradient.startPoint = CGPoint(x: 0.5, y: 1)
      gradient.endPoint = CGPoint(x: 0.5, y: 0)
      gradient.locations = [0, 1]
    }
    addSubview(background)

    titleLabel.font = roundedAppFont(
      size: AgentPaletteMetrics.resultsTitleFontSize, weight: .medium
    )
    titleLabel.textColor = PaletteInk.primary
    titleLabel.lineBreakMode = .byTruncatingTail

    subtitleLabel.font = roundedAppFont(
      size: AgentPaletteMetrics.resultsSubtitleFontSize, weight: .regular
    )
    subtitleLabel.textColor = PaletteInk.secondary
    subtitleLabel.lineBreakMode = .byTruncatingTail

    background.addSubview(titleLabel)
    background.addSubview(subtitleLabel)
    face.imageScaling = .scaleProportionallyUpOrDown
    face.isHidden = true
    face.setAccessibilityElement(false)
    background.addSubview(face)
    unreadDot.wantsLayer = true
    unreadDot.layer?.backgroundColor = AgentPaletteMetrics.resultsUnreadDotFill.cgColor
    unreadDot.isHidden = true
    unreadDot.setAccessibilityElement(false)
    background.addSubview(unreadDot)

    heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.resultsRowHeight).isActive = true

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityIdentifier("boltty.ask.session.\(item.id.uuidString)")

    apply(item: item)
    syncUnread()
    renderHighlight(animated: false)
  }

  override func layout() {
    super.layout()
    layoutContent()
    background.gradientLayer?.applyPaletteCorner(
      radius: AgentPaletteMetrics.resultsRowCornerRadius
    )
    layoutShimmer()
  }

  private func layoutContent() {
    let pill = NSRect(
      x: AgentPaletteMetrics.resultsRowHorizontalInset,
      y: AgentPaletteMetrics.resultsRowInset,
      width: max(0, bounds.width - AgentPaletteMetrics.resultsRowHorizontalInset * 2),
      height: max(0, bounds.height - AgentPaletteMetrics.resultsRowInset * 2)
    )
    if background.frame != pill { background.frame = pill }

    let padding = AgentPaletteMetrics.resultsRowTextLeading
    let leading = showsFace ? AgentPaletteMetrics.resultsRowFacedTextLeading : padding
    let showsUnread = item.hasUnread
    let trailing = AgentPaletteMetrics.resultsRowTextTrailing
      + (showsUnread
        ? AgentPaletteMetrics.resultsUnreadDotDiameter + AgentPaletteMetrics.resultsUnreadDotGap
        : 0)
    let width = max(0, pill.width - leading - trailing)
    if showsFace {
      let side = AgentPaletteMetrics.resultsMascotSize
      let faceFrame = NSRect(
        x: padding, y: ((pill.height - side) / 2).rounded(), width: side, height: side
      )
      if face.frame != faceFrame { face.frame = faceFrame }
    }
    let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
    let subtitleHeight = ceil(subtitleLabel.intrinsicContentSize.height)
    let spacing = AgentPaletteMetrics.resultsTitleSubtitleSpacing
    let column = titleHeight + spacing + subtitleHeight
    let bottom = ((pill.height - column) / 2).rounded()
    let subtitleFrame = subtitleLabel.frame(
      forAlignmentRect: NSRect(x: leading, y: bottom, width: width, height: subtitleHeight)
    )
    let titleFrame = titleLabel.frame(
      forAlignmentRect: NSRect(
        x: leading, y: bottom + subtitleHeight + spacing, width: width, height: titleHeight
      )
    )
    if subtitleLabel.frame != subtitleFrame { subtitleLabel.frame = subtitleFrame }
    if titleLabel.frame != titleFrame { titleLabel.frame = titleFrame }
    if showsUnread {
      let side = AgentPaletteMetrics.resultsUnreadDotDiameter
      let dotFrame = NSRect(
        x: background.bounds.width - AgentPaletteMetrics.resultsRowTextTrailing - side,
        y: (bottom + column / 2 - side / 2).rounded(),
        width: side, height: side)
      if unreadDot.frame != dotFrame { unreadDot.frame = dotFrame }
      unreadDot.layer?.cornerRadius = side / 2
    }
  }

  func apply(item newItem: BolttyAISessionItem) {
    precondition(newItem.id == item.id, "a row is bound to one conversation")
    let agentChanged = newItem.agent != item.agent
    let unreadChanged = newItem.hasUnread != item.hasUnread
    item = newItem
    if showsFace, agentChanged { face.image = Self.faceImage(for: newItem.agent) }

    if titleLabel.stringValue != newItem.title {
      if window != nil, !MotionPreferences.reduceMotion {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Motion.standard
        titleLabel.layer?.add(fade, forKey: "name")
      }
      titleLabel.stringValue = newItem.title
    }
    if subtitleLabel.stringValue != newItem.subtitle {
      subtitleLabel.stringValue = newItem.subtitle
    }
    setAccessibilityLabel(accessibilityText(for: newItem))
    if unreadChanged { syncUnread() }
    syncWorking()
  }

  private func accessibilityText(for item: BolttyAISessionItem) -> String {
    "\(item.title), \(item.subtitle)" + (item.hasUnread ? ", unread" : "")
  }

  private func syncUnread() {
    titleLabel.font = roundedAppFont(
      size: AgentPaletteMetrics.resultsTitleFontSize,
      weight: item.hasUnread ? .semibold : .medium
    )
    unreadDot.isHidden = !item.hasUnread
    setAccessibilityLabel(accessibilityText(for: item))
    needsLayout = true
  }

  // MARK: Working

  private let shimmer = CALayer()
  private let shimmerWords = CALayer()
  private let shimmerBand = CAGradientLayer()
  private var shimmerCut: (text: String, size: NSSize)?
  private var shimmerPaint: (agent: AgentId, still: Bool)?
  private var sweptWidth: CGFloat = 0
  private(set) var isShowingWorking = false

  private func syncWorking() {
    let working = item.state == .running
    guard working != isShowingWorking else {
      if working { needsLayout = true }
      return
    }
    isShowingWorking = working
    if working {
      if shimmer.superlayer == nil, let host = background.layer {
        shimmer.mask = shimmerWords
        shimmerBand.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerBand.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.addSublayer(shimmerBand)
        host.addSublayer(shimmer)
      }
      shimmer.isHidden = false
      needsLayout = true
    } else {
      shimmer.isHidden = true
      shimmerBand.removeAnimation(forKey: "sweep")
      sweptWidth = 0
    }
  }

  private func layoutShimmer() {
    guard isShowingWorking else { return }
    let frame = subtitleLabel.frame
    let words = min(frame.width, ceil(subtitleLabel.attributedStringValue.size().width) + 4)
    let still = MotionPreferences.reduceMotion
    let band = still
      ? words
      : max(AgentPaletteMetrics.resultsShimmerMinimumBand, words * AgentPaletteMetrics.resultsShimmerBandShare)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shimmer.frame = frame
    shimmerWords.frame = shimmer.bounds
    shimmerBand.frame = CGRect(x: still ? 0 : -band, y: 0, width: band, height: frame.height)
    shimmerBand.opacity = still ? Float(AgentPaletteMetrics.resultsWorkingStillOpacity) : 1
    paintShimmer(still: still)
    CATransaction.commit()
    cutShimmerWords()
    if still {
      shimmerBand.removeAnimation(forKey: "sweep")
      sweptWidth = 0
    } else {
      startSweepIfNeeded(across: words + band)
    }
  }

  private func paintShimmer(still: Bool) {
    guard shimmerPaint?.agent != item.agent || shimmerPaint?.still != still else { return }
    shimmerPaint = (item.agent, still)
    let light = MascotPalette.face(for: item.agent).arrivalLight
    guard let first = light.first, let last = light.last else { return }
    if still {
      shimmerBand.colors = light.map(\.cgColor)
      shimmerBand.locations = nil
      return
    }
    shimmerBand.colors = ([first.withAlphaComponent(0)] + light + [last.withAlphaComponent(0)])
      .map(\.cgColor)
    let inner = AgentPaletteMetrics.resultsShimmerFade
    let steps = max(1, light.count - 1)
    shimmerBand.locations = ([0] + light.indices.map {
      inner + (1 - 2 * inner) * CGFloat($0) / CGFloat(steps)
    } + [1]).map { NSNumber(value: Double($0)) }
  }

  private func cutShimmerWords() {
    let size = subtitleLabel.bounds.size
    let text = subtitleLabel.stringValue
    guard size.width > 0, size.height > 0,
          shimmerCut?.text != text || shimmerCut?.size != size,
          let rep = subtitleLabel.bitmapImageRepForCachingDisplay(in: subtitleLabel.bounds)
    else { return }
    let ink = subtitleLabel.textColor
    subtitleLabel.textColor = .white
    subtitleLabel.cacheDisplay(in: subtitleLabel.bounds, to: rep)
    subtitleLabel.textColor = ink
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shimmerWords.contents = rep.cgImage
    shimmerWords.contentsScale = window?.backingScaleFactor ?? 2
    CATransaction.commit()
    shimmerCut = (text, size)
  }

  private func startSweepIfNeeded(across travel: CGFloat) {
    guard window != nil else { return }
    if abs(travel - sweptWidth) > 0.5 { shimmerBand.removeAnimation(forKey: "sweep") }
    guard shimmerBand.animation(forKey: "sweep") == nil else { return }
    sweptWidth = travel
    let sweep = CABasicAnimation(keyPath: "transform.translation.x")
    sweep.fromValue = 0
    sweep.toValue = travel
    sweep.duration = AgentPaletteMetrics.resultsShimmerSweepDuration
    sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    sweep.fillMode = .both
    let cycle = CAAnimationGroup()
    cycle.animations = [sweep]
    cycle.duration = sweep.duration + AgentPaletteMetrics.resultsShimmerRest
    cycle.repeatCount = .infinity
    cycle.timeOffset = shimmerPhase() * cycle.duration
    shimmerBand.add(cycle, forKey: "sweep")
  }

  private func shimmerPhase() -> Double {
    Double(UInt(bitPattern: item.id.hashValue) % 1000) / 1000
  }

  func setShowsFace(_ shows: Bool) {
    guard shows != showsFace else { return }
    showsFace = shows
    face.isHidden = !shows
    if shows { face.image = Self.faceImage(for: item.agent) }
    needsLayout = true
  }

  var faceImageForTesting: NSImage? { face.isHidden ? nil : face.image }

  private static func faceImage(for agent: AgentId) -> NSImage? {
    let side = AgentPaletteMetrics.resultsMascotSize
    guard let image = MascotSnapshotCache.image(
      MascotLook.face(for: agent), size: side, scale: AgentHistoryFaces.scale
    ) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: side, height: side))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    renderHighlight(animated: false)
  }

  /// A row is kept while a history tab hides it, and a row taken out from
  /// under the pointer never hears `mouseExited` — so it would come back lit.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { renderHighlight(animated: false) }
    if window != nil, isShowingWorking { layoutShimmer() }
    guard window == nil, isHovered || isPressed else { return }
    isHovered = false
    setPressed(false)
    renderHighlight(animated: false)
  }

  override func viewDidHide() {
    super.viewDidHide()
    guard isHovered || isPressed else { return }
    isHovered = false
    setPressed(false)
    renderHighlight(animated: false)
  }

  func syncHover(pointerInWindow point: NSPoint?) {
    // `visibleRect` alone can reach past the row's own bounds (measured: a
    // 60pt row reported 200pt visible), so it is cut to them.
    let inside = point.map { point in
      !isHiddenOrHasHiddenAncestor
        && bounds.intersection(visibleRect).contains(convert(point, from: nil))
    } ?? false
    guard inside != isHovered else { return }
    isHovered = inside
    renderHighlight(animated: true)
  }

  var isHoveredForTesting: Bool { isHovered }

  var isCoveredAt: ((NSPoint) -> Bool)?

  override func mouseEntered(with event: NSEvent) {
    guard isCoveredAt?(event.locationInWindow) != true else { return }
    isHovered = true
    renderHighlight(animated: true)
    onHover?()
  }

  override func mouseMoved(with event: NSEvent) {
    let covered = isCoveredAt?(event.locationInWindow) == true
    if covered == isHovered {
      isHovered = !covered
      renderHighlight(animated: true)
      if !covered { onHover?() }
      return
    }
    if hoverIsQuiet, !covered { onHover?() }
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    renderHighlight(animated: true)
  }

  func setHoveredForTesting(_ hovered: Bool) {
    isHovered = hovered
    renderHighlight(animated: false)
  }

  override func mouseDown(with event: NSEvent) {
    if event.modifierFlags.contains(.control), onContextMenu != nil {
      isControlClick = true
      onContextMenu?(event)
      return
    }
    setPressed(true)
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let onContextMenu else { return super.rightMouseDown(with: event) }
    onContextMenu(event)
  }

  override func mouseDragged(with event: NSEvent) {
    guard !isControlClick else { return }
    let local = convert(event.locationInWindow, from: nil)
    setPressed(bounds.contains(local))
  }

  override func mouseUp(with event: NSEvent) {
    if isControlClick {
      isControlClick = false
      return
    }
    setPressed(false)
    let local = convert(event.locationInWindow, from: nil)
    if bounds.contains(local) {
      onActivate?()
    }
  }

  private var isControlClick = false

  private var isPressed = false

  private func setPressed(_ pressed: Bool) {
    guard pressed != isPressed, let layer = background.layer else { return }
    isPressed = pressed
    let scale: CGFloat = pressed ? AgentPaletteMetrics.rowPressedScale : 1
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    MotionPreferences.springScale(layer, to: scale)
    CATransaction.commit()
  }

  func setPressedForTesting(_ pressed: Bool) { setPressed(pressed) }

  private func highlightColors() -> [CGColor] {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    func flat(_ dark: NSColor) -> [CGColor] {
      let color = isDark
        ? dark
        : NSColor.black.withAlphaComponent(dark.alphaComponent * 0.6)
      return [color.cgColor, color.cgColor]
    }
    if isHighlightedRow {
      return flat(AgentPaletteMetrics.historyRowSelectedFill)
    }
    if isHovered, !hoverIsQuiet {
      return flat(AgentPaletteMetrics.historyRowHoverFill)
    }
    return [NSColor.clear.cgColor, NSColor.clear.cgColor]
  }

  private func renderHighlight(animated: Bool) {
    guard let layer = background.gradientLayer else { return }
    let colors = highlightColors()
    let previous = layer.colors as? [CGColor] ?? []
    let unchanged = previous.count == colors.count
      && zip(previous, colors).allSatisfy { $0 == $1 }
    guard !unchanged else { return }
    layer.colors = colors

    guard animated, !MotionPreferences.reduceMotion else { return }
    let fade = CABasicAnimation(keyPath: "colors")
    fade.fromValue = previous.isEmpty ? nil : previous
    fade.toValue = colors
    fade.duration = AgentPaletteMetrics.hoverFadeDuration
    fade.timingFunction = Motion.standardCurve
    fade.preferringHighFrameRate()
    layer.add(fade, forKey: "highlight")
  }

  var highlightFillAlphaForTesting: CGFloat {
    (background.gradientLayer?.colors as? [CGColor])?.first?.alpha ?? 0
  }

  var showsUnreadDotForTesting: Bool { !unreadDot.isHidden }
  var unreadDotFrameForTesting: CGRect { unreadDot.frame }
  var titleFontForTesting: NSFont {
    titleLabel.font ?? roundedAppFont(size: AgentPaletteMetrics.resultsTitleFontSize)
  }
  var titleFrameForTesting: CGRect { titleLabel.frame }

}
