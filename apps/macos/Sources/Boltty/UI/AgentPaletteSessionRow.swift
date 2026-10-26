import AppKit

/// One row in the palette's session switcher.
// MARK: - Session row

/// Backing store for a row's highlight pill.
///
/// The gradient is the view's *backing* layer rather than a sublayer, so it
/// resizes with the row for free — a manually inserted `CAGradientLayer` would
/// need its frame kept in sync on every layout pass.
final class GradientFillView: NSView {
  override func makeBackingLayer() -> CALayer { CAGradientLayer() }
  var gradientLayer: CAGradientLayer? { layer as? CAGradientLayer }
}

final class BolttyAISessionRowView: NSView {
  var onActivate: (() -> Void)?
  /// A right click, or a Control-click: the row's menu (Open Chat, Show in
  /// Finder, Delete Chat…), built and shown by the controller.
  var onContextMenu: ((NSEvent) -> Void)?
  /// The pointer arrived over this row. Whether that *means* anything is the
  /// list's decision, not the row's: a row cannot tell a hover from a scroll
  /// that slid it under a stationary cursor. See `AgentPaletteView.hoverMoved`.
  var onHover: (() -> Void)?
  private(set) var isHighlightedRow = false

  /// What this row currently draws. Rows are reused across refreshes, so this
  /// is the answer to "does the list still need one for this conversation".
  private(set) var item: BolttyAISessionItem

  /// The pointer's selection crossfades; the keyboard's, the initial state
  /// and rebuilt rows apply at once — a keystroke is answered, not animated,
  /// and the list never flickers on appear.
  func setHighlighted(_ highlighted: Bool, animated: Bool) {
    guard highlighted != isHighlightedRow else { return }
    isHighlightedRow = highlighted
    renderHighlight(animated: animated)
  }

  private let background = GradientFillView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")
  /// The agent's face, in the Latest tab only — see `setShowsFace`.
  private let face = NSImageView()
  private(set) var showsFace = false
  /// The unread dot, on the trailing edge. See `syncUnread`.
  private let unreadDot = NSView()
  private var isHovered = false
  /// **While the keyboard drives the list the pointer's wash is not drawn**
  /// a row lit under a cursor nobody moved beside the row ↑/↓ chose reads as
  /// two current rows. Spotlight, Raycast and the
  /// menus do the same; the wash returns once the pointer really moves.
  /// The list sets it — only it knows where the pointer was when a key chose.
  var hoverIsQuiet = false {
    didSet { if hoverIsQuiet != oldValue, isHovered { renderHighlight(animated: false) } }
  }
  private var trackingArea: NSTrackingArea?

  /// **A row has no face — except in Latest.** A title and a line of the
  /// reply and nothing else: under an agent's tab the strip already says
  /// whose chats they are. Latest mixes every agent, and there the row says
  /// whose it is with that agent's face.
  init(item: BolttyAISessionItem) {
    self.item = item
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    background.wantsLayer = true
    if let gradient = background.gradientLayer {
      // The corner itself is settled in `layout()`: which curve it can carry
      // depends on the bounds, and there are none yet.
      gradient.cornerRadius = AgentPaletteMetrics.resultsRowCornerRadius
      // Same axis convention as `PaletteGlassHost`: unflipped geometry,
      // colours[0] is the top edge.
      gradient.isGeometryFlipped = false
      gradient.startPoint = CGPoint(x: 0.5, y: 1)
      gradient.endPoint = CGPoint(x: 0.5, y: 0)
      gradient.locations = [0, 1]
    }
    addSubview(background)

    // The title medium at 15 over the reply regular at 13: at one size and
    // weight the two lines are told apart by ink alone, and the reply
    // competes with the name it belongs to.
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
    // **Unread: a dot and a heavier title.** The dot
    // stands on the row's trailing edge, so it reads on every tab alike —
    // Latest's face owns the leading edge. A plain layer: the row already
    // repaints its own frames in `layout()` rather than constraining them.
    unreadDot.wantsLayer = true
    unreadDot.layer?.backgroundColor = AgentPaletteMetrics.resultsUnreadDotFill.cgColor
    unreadDot.isHidden = true
    unreadDot.setAccessibilityElement(false)
    background.addSubview(unreadDot)

    // **Frames inside the row, not constraints.** The list holds every chat an
    // agent has — 132 for Codex on this machine — and with a stack view and
    // eight constraints per row, switching a history tab spent ~400 ms solving
    // a layout whose answer is arithmetic: the row is a fixed height and its
    // two lines sit centred in it. Only the row's own height stays a
    // constraint, because the list stacking it still asks for one.
    heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.resultsRowHeight).isActive = true

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    // The identifier names the conversation, and a reused row never changes
    // which conversation it draws — so this is set once, unlike the label.
    setAccessibilityIdentifier("boltty.ask.session.\(item.id.uuidString)")

    apply(item: item)
    syncUnread()
    renderHighlight(animated: false)
  }

  override func layout() {
    super.layout()
    layoutContent()
    // A capsule, drawn as one. The pill is 60 tall asking for a 30 corner, and
    // a squircle needs 1.34× its radius of wall per corner — 80pt of the 60
    // there are — so `.continuous` here would meet past its tangent point and
    // flatten both ends. `applyPaletteCorner` picks the curve that fits.
    background.gradientLayer?.applyPaletteCorner(
      radius: AgentPaletteMetrics.resultsRowCornerRadius
    )
    layoutWorkingEdge()
  }

  /// The pill inset from the row's walls, and the title and subtitle centred
  /// as a pair in it — so the row stays balanced if either font size changes —
  /// running to the frame's tighter trailing padding, so a truncated line
  /// stops nearer the pill's end than it starts.
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
    // `background` is unflipped: the title is the upper of the two.
    let bottom = ((pill.height - column) / 2).rounded()
    // **The text's own edge stands at `leading`, not the label's**: a label
    // draws its text 2pt in from its frame (`alignmentRectInsets`). The day
    // headings are placed by Auto Layout, which aligns that inner edge, so
    // frames set by hand would stand every title and reply 2pt right of the
    // heading over them.
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
      // Centred on the two lines, against the pill's trailing edge with its
      // own padding past it. `background` is unflipped: up is +y.
      let side = AgentPaletteMetrics.resultsUnreadDotDiameter
      let dotFrame = NSRect(
        x: background.bounds.width - AgentPaletteMetrics.resultsRowTextTrailing - side,
        y: (bottom + column / 2 - side / 2).rounded(),
        width: side, height: side)
      if unreadDot.frame != dotFrame { unreadDot.frame = dotFrame }
      unreadDot.layer?.cornerRadius = side / 2
    }
  }

  /// Re-points an existing row at the same conversation's newer state.
  ///
  /// The list reuses rows by conversation id rather than rebuilding them,
  /// because a rebuild throws away everything the row was holding that the
  /// model does not describe: which row the pointer is over, a press spring
  /// still settling, the mascot's place in its drift, and the tracking area
  /// that would only re-arm on the next mouse move. A session merely changing
  /// from idle to working used to cost all of that.
  func apply(item newItem: BolttyAISessionItem) {
    precondition(newItem.id == item.id, "a row is bound to one conversation")
    let agentChanged = newItem.agent != item.agent
    let textChanged = newItem.title != item.title || newItem.subtitle != item.subtitle
    let unreadChanged = newItem.hasUnread != item.hasUnread
    item = newItem
    if showsFace, agentChanged { face.image = Self.faceImage(for: newItem.agent) }

    if titleLabel.stringValue != newItem.title {
      titleLabel.stringValue = newItem.title
    }
    if subtitleLabel.stringValue != newItem.subtitle {
      subtitleLabel.stringValue = newItem.subtitle
    }
    setAccessibilityLabel(accessibilityText(for: newItem))
    if unreadChanged { syncUnread() }
    syncWorking(agentChanged: agentChanged)
    // A fresh reply hurries the orbiting window briefly. Title/subtitle are
    // the row's only live text, so their change is the news — `updatedAt`
    // moves on every touch and would hurry it constantly.
    if textChanged, newItem.state == .running { pulseWorkingOrbit() }
  }

  /// What the row announces: the title, the reply, and whether it is unread.
  private func accessibilityText(for item: BolttyAISessionItem) -> String {
    "\(item.title), \(item.subtitle)" + (item.hasUnread ? ", unread" : "")
  }

  /// An unread chat wears its dot and a semibold title; a read one neither.
  /// The width the text may take depends on the dot, so a change re-lays out.
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

  /// **A chat whose agent is working says so with light, not only a word**:
  /// a hairline round the row's pill in the agent's mascot gradient, lit in
  /// a window that orbits the outline — round and round, never back and
  /// forth — and "Working…" under the title breathing in opacity. A word
  /// alone makes a running chat read like any other.
  ///
  /// The outline is a dashed stroke masking a full-pill gradient, and the
  /// dashes' phase runs linearly: the window travels the whole perimeter
  /// while the outline stays. No two rows share a phase or quite a pace —
  /// both are seeded from the conversation id — so two working chats never
  /// march together. A new reply hurries the window briefly
  /// (`pulseWorkingOrbit`); the speed change re-anchors the layer's time,
  /// so it hurries from where it stands rather than jumping. Under Reduce
  /// Motion the whole edge is lit, faintly, and nothing moves.
  private let workingEdge = CALayer()
  private let workingEdgeShape = CAShapeLayer()
  private let workingBand = CAGradientLayer()
  private(set) var isShowingWorking = false
  /// The dash cycle (lit window plus gap) the orbit animation runs over —
  /// the outline's own perimeter, recomputed with it.
  private var orbitCycle: CGFloat = 0
  /// Guards the delayed end of a speed pulse against a newer one.
  private var orbitBoostGeneration = 0

  private func syncWorking(agentChanged: Bool) {
    let working = item.state == .running
    if working, agentChanged || workingBand.colors == nil { paintWorkingGlow() }
    guard working != isShowingWorking else { return }
    isShowingWorking = working
    if working {
      if workingEdge.superlayer == nil, let host = background.layer {
        workingEdge.mask = workingEdgeShape
        workingEdgeShape.fillColor = NSColor.clear.cgColor
        workingEdgeShape.strokeColor = NSColor.white.cgColor
        workingEdgeShape.lineWidth = AgentPaletteMetrics.resultsWorkingEdgeWidth
        workingEdgeShape.lineCap = .round
        workingBand.startPoint = CGPoint(x: 0, y: 0.5)
        workingBand.endPoint = CGPoint(x: 1, y: 0.5)
        workingEdge.addSublayer(workingBand)
        host.addSublayer(workingEdge)
      }
      if workingBand.colors == nil { paintWorkingGlow() }
      workingEdge.isHidden = false
      layoutWorkingEdge()
    } else {
      workingEdge.isHidden = true
      workingEdgeShape.removeAnimation(forKey: "orbit")
      workingEdgeShape.speed = 1
      workingEdgeShape.timeOffset = 0
      orbitBoostGeneration += 1
      subtitleLabel.layer?.removeAnimation(forKey: "breathing")
    }
  }

  /// The agent's gradient lifted to read on dark glass — the words' own
  /// arrival light — spanning the whole pill, so the orbiting window shows
  /// a different hue as it travels.
  private func paintWorkingGlow() {
    let light = MascotPalette.face(for: item.agent).arrivalLight
    workingBand.colors = light.map(\.cgColor)
  }

  private func layoutWorkingEdge() {
    guard isShowingWorking else { return }
    let pill = background.bounds
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    workingEdge.frame = pill
    workingEdgeShape.frame = pill
    workingBand.frame = pill
    let inset = AgentPaletteMetrics.resultsWorkingEdgeWidth / 2
    let outline = pill.insetBy(dx: inset, dy: inset)
    let radius = min(AgentPaletteMetrics.resultsRowCornerRadius, outline.height / 2) - inset
    workingEdgeShape.path = outline.width > 0 && outline.height > 0
      ? CGPath(roundedRect: outline, cornerWidth: max(0, radius), cornerHeight: max(0, radius), transform: nil)
      : nil
    let still = MotionPreferences.reduceMotion
    if still {
      // The whole edge lit, faintly, and nothing moves.
      workingEdgeShape.lineDashPattern = nil
      workingEdgeShape.removeAnimation(forKey: "orbit")
      subtitleLabel.layer?.removeAnimation(forKey: "breathing")
    } else {
      let straightW = max(0, outline.width - 2 * radius)
      let straightH = max(0, outline.height - 2 * radius)
      let perimeter = 2 * straightW + 2 * straightH + 2 * .pi * max(0, radius)
      let cycle = max(1, perimeter)
      // A new period with the old animation's `toValue` jumps at every lap's
      // seam, so a resized row restarts the lap (keeping its phase offset).
      if abs(cycle - orbitCycle) > 0.5 { workingEdgeShape.removeAnimation(forKey: "orbit") }
      orbitCycle = cycle
      let lit = cycle * AgentPaletteMetrics.resultsWorkingOrbitShare
      workingEdgeShape.lineDashPattern = [lit as NSNumber, (cycle - lit) as NSNumber]
    }
    workingBand.opacity = still ? Float(AgentPaletteMetrics.resultsWorkingStillOpacity) : 1
    CATransaction.commit()
    if !still { startOrbitIfNeeded() }
    startWorkingBreathIfNeeded(still: still)
  }

  /// The window orbits; it is (re)added only when missing, never on every
  /// layout — re-adding restarts the phase, and layout runs on every scroll,
  /// which used to pin the light in place while the list moved under it.
  /// Lost across a window change (which AppKit does not promise to keep),
  /// it is added back with this row's own phase.
  private func startOrbitIfNeeded() {
    guard window != nil, orbitCycle > 0 else { return }
    guard workingEdgeShape.animation(forKey: "orbit") == nil else { return }
    let duration = orbitDuration()
    let orbit = CABasicAnimation(keyPath: "lineDashPhase")
    orbit.fromValue = 0
    orbit.toValue = -orbitCycle
    orbit.duration = duration
    orbit.repeatCount = .infinity
    orbit.timingFunction = CAMediaTimingFunction(name: .linear)
    orbit.timeOffset = orbitPhase() * duration
    workingEdgeShape.add(orbit, forKey: "orbit")
  }

  /// This row's place in the lap, and its lap's length — both seeded from
  /// the conversation id, so rows never start together and drift apart
  /// rather than back together.
  private func orbitPhase() -> Double {
    Double(UInt(bitPattern: item.id.hashValue) % 1000) / 1000
  }

  private func orbitDuration() -> CFTimeInterval {
    let drift = Double(UInt(bitPattern: item.id.hashValue >> 7) % 1000) / 1000 - 0.5
    return AgentPaletteMetrics.resultsWorkingOrbitDuration
      * (1 + drift * 2 * AgentPaletteMetrics.resultsWorkingOrbitVariance)
  }

  /// A new reply hurries the window, then lets it back to its pace. The
  /// speed change re-anchors the layer's time at the switch, so the dash
  /// keeps its place on the outline and only moves faster — without that
  /// the window jumps to wherever the new speed reads that instant as.
  private func pulseWorkingOrbit() {
    guard isShowingWorking, !MotionPreferences.reduceMotion else { return }
    guard workingEdgeShape.animation(forKey: "orbit") != nil else { return }
    orbitBoostGeneration += 1
    let generation = orbitBoostGeneration
    setOrbitSpeed(AgentPaletteMetrics.resultsWorkingBoostSpeed)
    DispatchQueue.main.asyncAfter(deadline: .now() + AgentPaletteMetrics.resultsWorkingBoostDuration) { [weak self] in
      guard let self, self.orbitBoostGeneration == generation, self.isShowingWorking else { return }
      self.setOrbitSpeed(1)
    }
  }

  private func setOrbitSpeed(_ speed: Float) {
    let now = CACurrentMediaTime()
    let local = workingEdgeShape.convertTime(now, from: nil)
    workingEdgeShape.speed = speed
    workingEdgeShape.timeOffset = local - now * Double(speed)
  }

  private func startWorkingBreathIfNeeded(still: Bool) {
    subtitleLabel.wantsLayer = true
    guard let words = subtitleLabel.layer else { return }
    guard !still, words.animation(forKey: "breathing") == nil else { return }
    let breath = CABasicAnimation(keyPath: "opacity")
    breath.fromValue = 1
    breath.toValue = AgentPaletteMetrics.resultsWorkingBreathFloor
    breath.duration = AgentPaletteMetrics.resultsWorkingBreathDuration
    breath.autoreverses = true
    breath.repeatCount = .infinity
    breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    words.add(breath, forKey: "breathing")
  }

  var workingOrbitIsRunningForTesting: Bool { workingEdgeShape.animation(forKey: "orbit") != nil }

  /// Whether the row leads with its agent's face: in Latest, and nowhere else.
  ///
  /// A still picture (`MascotSnapshotCache`), not a live face: the list holds
  /// every chat there is, and ninety Metal surfaces hopping at once would be a
  /// crowd. The picture is read when the face is needed, so a face chosen in
  /// Settings reaches the rows the next time Latest is shown.
  ///
  /// Read once per row, not each time the list places it: the list asks for
  /// a row on every scroll, and the face is a roster read out of the
  /// defaults. A row lives no longer than one showing of the list, and a face
  /// chosen in Settings cannot change under an open one.
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

  /// A row is kept while a history tab hides it, and a row taken out from
  /// under the pointer never hears `mouseExited` — so it would come back lit.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil, isShowingWorking { layoutWorkingEdge() }
    guard window == nil, isHovered || isPressed else { return }
    isHovered = false
    setPressed(false)
    renderHighlight(animated: false)
  }

  /// Rows are hidden in place when a history tab leaves them out, so the
  /// window check above no longer sees them go: this is the same reset for
  /// that path.
  override func viewDidHide() {
    super.viewDidHide()
    guard isHovered || isPressed else { return }
    isHovered = false
    setPressed(false)
    renderHighlight(animated: false)
  }

  /// **Enter and exit are not a hover's whole story.** When the list scrolls
  /// under a pointer that stays put — the wheel, or ↑/↓ moving the selection —
  /// AppKit delivers the enter of the row arriving and often not the exit of
  /// the row leaving, so rows stayed lit one after another down the list. The
  /// list calls this after every scroll with where the pointer really is, and
  /// the row believes that over whatever events it did or did not get.
  /// Deliberately silent: `onHover` means the pointer *moved*, and it did not.
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

  /// Whether a point in the window is over something standing above the
  /// list — the tab strip, which the rows scroll up under
  /// (`AgentPaletteMetrics.historyTabOverlap`). A tracking area does not
  /// know it is covered, so the list says so.
  var isCoveredAt: ((NSPoint) -> Bool)?

  override func mouseEntered(with event: NSEvent) {
    guard isCoveredAt?(event.locationInWindow) != true else { return }
    isHovered = true
    renderHighlight(animated: true)
    onHover?()
  }

  /// A pointer moving inside the row it already stands on sends no enter, and
  /// is still the pointer taking the list back from the keyboard. It also
  /// crosses the strip's foot inside one row, which no enter or exit marks.
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
    // A Control-click is the Mac's right click, and opens nothing.
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

  /// Selection reads stronger than hover; both are appearance-relative so the
  /// row stays legible if the palette ever follows a light appearance.
  ///
  /// Returned top-first as a two-stop ramp. A flat white block at 0.20 was the
  /// loudest thing on the panel — brighter than the prompt capsule it sits
  /// under. Lit from the top edge, the pill reads as a raised surface instead
  /// of a painted rectangle, and the card's own wash carries the rest.
  ///
  /// The fill was raised from a ~10% average once the list was used with the
  /// keyboard: see `highlightBorderColor` for why it could not carry selection
  /// on its own.
  /// The selected row's fill, and the fainter one hover gets.
  ///
  /// **Flat, not a gradient.** The mock fills the pill with a single
  /// `rgba(255,255,255,0.08)` and nothing else. The ramp that used to be here
  /// (0.18 → 0.09) was a second light source on a surface that already has one:
  /// the card's own wash runs top-to-bottom, so a row near the foot sat on a
  /// lighter backdrop *and* carried a lighter fill, and the list appeared to be
  /// lit from two directions at once.
  ///
  /// Both stops are still emitted, because the layer under this is a
  /// `CAGradientLayer` and its `colors` crossfade is what animates the state
  /// change — two copies of one colour is a flat fill that can still be
  /// animated, not a gradient with no contrast.
  ///
  /// Hover is half the selection rather than the 0.07-against-0.08 it would
  /// otherwise be: the mock says nothing about hover, and at that distance the
  /// two states were indistinguishable without reading the edge.
  private func highlightColors() -> [CGColor] {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    func flat(_ dark: NSColor) -> [CGColor] {
      let color = isDark
        ? dark
        : NSColor.black.withAlphaComponent(dark.alphaComponent * 0.6)
      return [color.cgColor, color.cgColor]
    }
    if isHighlightedRow {
      return flat(PaletteInk.secondaryFill)
    }
    if isHovered, !hoverIsQuiet {
      return flat(PaletteInk.tertiaryFill)
    }
    return [NSColor.clear.cgColor, NSColor.clear.cgColor]
  }

  /// The edge that makes a keyboard selection unmistakable. Hover never gets
  /// one.
  ///
  /// A translucent wash could not carry selection alone, for two reasons that
  /// only show up in use. The card is glass, so how much of a white ramp
  /// survives depends on the desktop behind the panel — over a bright wallpaper
  /// the selected row and its neighbours land within a few percent of each
  /// other and the list reads as having nothing selected at all. And a row the
  /// cursor happens to rest on is lit too, so "brighter" was never a reliable
  /// answer to "which one does Enter mean". A drawn hairline is independent of
  /// the backdrop and belongs to exactly one row.
  private func highlightBorderColor() -> CGColor {
    guard isHighlightedRow else { return NSColor.clear.cgColor }
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return isDark
      ? PaletteInk.selectedFill.cgColor
      : NSColor.black.withAlphaComponent(0.16).cgColor
  }

  private func renderHighlight(animated: Bool) {
    guard let layer = background.gradientLayer else { return }
    let colors = highlightColors()
    let border = highlightBorderColor()
    let previous = layer.colors as? [CGColor] ?? []
    let previousBorder = layer.borderColor
    let unchanged = previous.count == colors.count
      && zip(previous, colors).allSatisfy { $0 == $1 }
      && previousBorder == border
    guard !unchanged else { return }
    layer.colors = colors
    layer.borderWidth = AgentPaletteMetrics.resultsRowSelectedBorderWidth
    layer.borderColor = border

    guard animated, !MotionPreferences.reduceMotion else { return }
    let fade = CABasicAnimation(keyPath: "colors")
    fade.fromValue = previous.isEmpty ? nil : previous
    fade.toValue = colors
    fade.duration = AgentPaletteMetrics.hoverFadeDuration
    fade.timingFunction = Motion.standardCurve
    fade.preferringHighFrameRate()
    layer.add(fade, forKey: "highlight")

    // The edge crossfades with the fill rather than snapping in, or the row
    // appears to be outlined a frame before it is lit.
    let edge = CABasicAnimation(keyPath: "borderColor")
    edge.fromValue = previousBorder
    edge.toValue = border
    edge.duration = AgentPaletteMetrics.hoverFadeDuration
    edge.timingFunction = Motion.standardCurve
    edge.preferringHighFrameRate()
    layer.add(edge, forKey: "highlightBorder")
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
