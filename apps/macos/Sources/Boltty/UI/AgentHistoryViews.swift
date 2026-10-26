import AppKit

// MARK: - Date heading

@MainActor
final class AgentHistorySectionHeaderView: NSView {
  private let label = NSTextField(labelWithString: "")

  let dayID: String
  private var height: NSLayoutConstraint!

  var title: String { label.stringValue }

  /// `followsRows`: a day's rows stand above it, so it takes
  /// `historyHeaderSeparation` more air over its words.
  init(section: AgentHistory.Section, followsRows: Bool = false) {
    dayID = section.id
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    label.stringValue = section.title
    label.font = roundedAppFont(size: AgentPaletteMetrics.historyHeaderFontSize, weight: .semibold)
    label.textColor = AgentPaletteMetrics.historyHeaderTextColor
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.alignment = .natural
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(section.title)
    addSubview(label)

    height = heightAnchor.constraint(
      equalToConstant: AgentPaletteMetrics.historyHeaderHeight(followsRows: followsRows)
    )
    NSLayoutConstraint.activate([
      height,
      label.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: AgentPaletteMetrics.historyHeaderLeading
      ),
      label.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor,
        constant: -AgentPaletteMetrics.historyHeaderLeading
      ),
      label.lastBaselineAnchor.constraint(
        equalTo: bottomAnchor,
        constant: -AgentPaletteMetrics.historyHeaderBottomInset
      )
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(_ section: AgentHistory.Section, followsRows: Bool = false) {
    let box = AgentPaletteMetrics.historyHeaderHeight(followsRows: followsRows)
    if height.constant != box { height.constant = box }
    guard label.stringValue != section.title else { return }
    label.stringValue = section.title
    setAccessibilityLabel(section.title)
  }
}

// MARK: - Faces, ahead of time

@MainActor
enum AgentHistoryFaces {
  static var stills: [(agent: AgentId, side: CGFloat)] {
    let sides = [AgentPaletteMetrics.historyTabMascotSize]
      + AgentHistoryTabView.clusterFaceSides
      + [AgentPaletteMetrics.resultsMascotSize]
    return AgentHistory.tabOrder.flatMap { agent in sides.map { (agent, $0) } }
  }

  static var scale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

  static func warm(from index: Int = 0) {
    let stills = stills
    guard stills.indices.contains(index) else { return }
    let still = stills[index]
    _ = MascotSnapshotCache.image(MascotLook.face(for: still.agent), size: still.side, scale: scale)
    DispatchQueue.main.async {
      MainActor.assumeIsolated { warm(from: index + 1) }
    }
  }
}

// MARK: - Tab strip

@MainActor
final class AgentHistoryTabView: NSView {
  let agent: AgentId?
  private let label = NSTextField(labelWithString: "")
  private var faces: [NSImageView] = []
  /// Whose faces the tab wears: its own agent's, or — on All — every agent
  /// that can take a prompt (`setFaceAgents`).
  private(set) var faceAgents: [AgentId]
  private var liveFaces: [MascotNSView] = []
  /// Whether the tab's faces are the live ones (true) or the pictures; a
  /// cross-fade may still be on its way there (`handOver`).
  private var showsLive = false
  private var handOverToken = 0
  private(set) var isActive = false
  private var isEmpty = false
  private var isHovered = false
  private var trackingAreaRef: NSTrackingArea?

  var onSelect: (() -> Void)?

  var title: String { label.stringValue }
  var titleColorForTesting: NSColor? { label.textColor }
  func hoverForTesting(_ hovered: Bool) {
    isHovered = hovered
    applyAppearance()
  }

  /// What All wears while no agent can take a prompt yet (a scan under way,
  /// none installed): all of them, as the strip's tabs are.
  static var fallbackFaceAgents: [AgentId] { AgentHistory.tabOrder }

  /// All has room for this many faces; the adapters are no more.
  static let clusterCapacity = 5

  init(agent: AgentId?, title: String, isEmpty: Bool) {
    self.agent = agent
    faceAgents = agent.map { [$0] } ?? Self.fallbackFaceAgents
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerCurve = .continuous

    label.stringValue = title
    label.font = roundedAppFont(size: AgentPaletteMetrics.historyTabFontSize)
    label.alignment = .center
    // A name that still does not fit says so with an ellipsis, rather than
    // being cut mid-letter ("OpenCod").
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)
    syncFaceViews()

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    apply(title: title, isEmpty: isEmpty, isActive: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var allowsVibrancy: Bool { false }

  func apply(title: String, isEmpty: Bool, isActive: Bool, reacts: Bool = false) {
    let isChosenNow = isActive && !self.isActive
    self.isActive = isActive
    self.isEmpty = isEmpty
    if label.stringValue != title {
      label.stringValue = title
      needsLayout = true
    }
    let frames = Self.faceFrames(count: faceAgents.count, isCluster: agent == nil)
    for (view, (owner, frame)) in zip(faces, zip(faceAgents, frames)) {
      view.image = Self.faceImage(for: owner, side: frame.width)
    }
    applyLiveFaces(agents: faceAgents, poke: isChosenNow && reacts)
    setAccessibilityLabel(title)
    setAccessibilityValue(isActive ? "Selected" : "Not selected")
    setAccessibilityHelp(
      agent == nil ? "Show the latest chats of every agent"
        : isEmpty ? "No chats with \(title) yet" : "Show only \(title) chats"
    )
    applyAppearance()
  }

  private func applyLiveFaces(agents: [AgentId], poke: Bool) {
    if isActive, liveFaces.isEmpty {
      liveFaces = agents.map { agent in
        let view = MascotNSView(conversationID: UUID(), look: MascotLook.face(for: agent))
        view.reduceMotion = MotionPreferences.reduceMotion
        view.setAccessibilityElement(false)
        // Its rest is exactly the picture standing under it.
        view.restAsPicture(of: MascotSnapshotCache.identity)
        view.isHidden = true
        addSubview(view, positioned: .below, relativeTo: label)
        return view
      }
      // A face with no frame is not on screen yet, and joins the clock only
      // when it is shown — so it is placed before the hand-over unhides it.
      if !bounds.isEmpty { layoutContent() }
      needsLayout = true
    }
    for (view, agent) in zip(liveFaces, agents) {
      let look = MascotLook.face(for: agent)
      if view.look != look { view.apply(look: look) }
    }
    handOver(toLive: isActive)
    if poke, window != nil { liveFaces.forEach { $0.poke() } }
  }

  /// How long a face takes to go to rest, or to wake (`MascotNSView.awake`).
  private static let faceSettleDuration = 0.3

  /// **A tab's face goes back to its standard pose, and wakes from it.** The
  /// picture is the face at rest, in one fixed colour; the live face has its
  /// own gaze, breath and drift, so any swap or fade between the two shows.
  /// Instead the live face *is* the picture at rest (`restAsPicture`), and
  /// a choice only moves it along `awake`: it wakes from the standard pose
  /// into its motion, and leaving it runs back — pose and colours — to the
  /// standard pose, drawing the very frame the picture holds, and only then
  /// does the picture stand in for it. Nothing is swapped while it differs.
  /// Under Reduce Motion, and with no window to see it, it is a swap.
  private func handOver(toLive live: Bool) {
    guard live != showsLive else { return }
    showsLive = live
    handOverToken += 1
    let token = handOverToken
    guard window != nil, !MotionPreferences.reduceMotion, !liveFaces.isEmpty else {
      settleHandOver()
      return
    }
    let duration = Self.faceSettleDuration
    if live {
      liveFaces.forEach { $0.isHidden = false }
      liveFaces.forEach { $0.transition(toAwake: 1, over: duration) }
      // The picture goes a moment after the live face has drawn over it: the
      // two are the same frame, and a picture taken away in the frame the
      // face is first shown leaves a gap if the face is late.
      DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(0.06)) { [weak self] in
        guard let self, self.handOverToken == token else { return }
        self.faces.forEach { $0.isHidden = true }
      }
    } else {
      var pending = liveFaces.count
      for view in liveFaces {
        view.isHidden = false
        view.transition(toAwake: 0, over: duration) { [weak self] in
          pending -= 1
          if pending == 0, let self, self.handOverToken == token { self.settleHandOver() }
        }
      }
      // A face that is not drawn (the panel put away mid-way) never finishes.
      DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(duration * 2 + 0.2)) { [weak self] in
        guard let self, self.handOverToken == token else { return }
        self.settleHandOver()
      }
    }
  }

  private func settleHandOver() {
    for view in liveFaces {
      view.transition(toAwake: showsLive ? 1 : 0, over: 0)
      view.isHidden = !showsLive
    }
    for view in faces { view.isHidden = showsLive }
  }

  var faceImagesForTesting: [NSImage?] { faces.map(\.image) }
  /// The faces that are alive for the chosen tab — what it is going to,
  /// not where a fade has reached.
  var liveFaceReactionsForTesting: [MascotReaction?] {
    showsLive ? liveFaces.map(\.lastReactionForTesting) : []
  }
  var liveFaceLooksForTesting: [MascotLook] {
    showsLive ? liveFaces.map(\.look) : []
  }
  var faceFramesForTesting: [NSRect] { faces.map(\.frame) }
  var labelFrameForTesting: NSRect { label.frame }

  // MARK: Faces

  /// Latest's faces: every agent that can take a prompt (the panel's
  /// `agentChoices`), however many that is. None yet, and it is all of them.
  /// A change re-makes the faces; `apply` then draws them.
  func setFaceAgents(_ agents: [AgentId]) {
    guard agent == nil else { return }
    let wanted = Array((agents.isEmpty ? Self.fallbackFaceAgents : agents)
      .prefix(Self.clusterCapacity))
    guard wanted != faceAgents else { return }
    faceAgents = wanted
    syncFaceViews()
    liveFaces.forEach { $0.removeFromSuperview() }
    liveFaces = []
    showsLive = false
    handOverToken += 1
    faces.forEach { $0.isHidden = false }
    needsLayout = true
  }

  private func syncFaceViews() {
    while faces.count > faceAgents.count { faces.removeLast().removeFromSuperview() }
    while faces.count < faceAgents.count {
      let view = NSImageView()
      view.imageScaling = .scaleProportionallyUpOrDown
      view.setAccessibilityElement(false)
      addSubview(view, positioned: .below, relativeTo: label)
      faces.append(view)
    }
  }

  /// **The faces stand together like the pips of a die**: one face fills
  /// the square, two stand on its diagonal,
  /// three as a pyramid, four as a square, five with the fifth in the
  /// middle and on top. Each overlaps its neighbours a little, so they read
  /// as one group rather than a row. Centres and diameters are shares of the
  /// square, y down; a face later in the list stands over the ones before.
  private static let pips: [[(x: CGFloat, y: CGFloat, d: CGFloat)]] = [
    [(0.5, 0.5, 1.0)],
    [(0.31, 0.31, 0.62), (0.69, 0.69, 0.62)],
    [(0.27, 0.27, 0.54), (0.73, 0.27, 0.54), (0.5, 0.73, 0.54)],
    [(0.27, 0.27, 0.54), (0.73, 0.27, 0.54), (0.27, 0.73, 0.54), (0.73, 0.73, 0.54)],
    [(0.23, 0.23, 0.46), (0.77, 0.23, 0.46), (0.23, 0.77, 0.46), (0.77, 0.77, 0.46),
     (0.5, 0.5, 0.46)],
  ]

  /// Where `count` faces stand on a square of `side`, origin at its top left.
  static func faceFrames(count: Int, in side: CGFloat) -> [CGRect] {
    guard count > 0 else { return [] }
    let placed = pips[min(count, pips.count) - 1]
    func grid(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
    return placed.prefix(count).map { pip in
      let diameter = pip.d * side
      return CGRect(
        x: grid(pip.x * side - diameter / 2), y: grid(pip.y * side - diameter / 2),
        width: diameter, height: diameter)
    }
  }

  private static func faceFrames(count: Int, isCluster: Bool) -> [CGRect] {
    isCluster
      ? faceFrames(count: count, in: AgentPaletteMetrics.historyTabClusterSide)
      : [CGRect(
          x: 0, y: 0,
          width: AgentPaletteMetrics.historyTabMascotSize,
          height: AgentPaletteMetrics.historyTabMascotSize)]
  }

  /// Every size a face of the cluster is drawn at, for the pictures made
  /// ahead of time (`AgentHistoryFaces`).
  static var clusterFaceSides: [CGFloat] {
    let sides = (1...clusterCapacity).flatMap {
      faceFrames(count: $0, in: AgentPaletteMetrics.historyTabClusterSide).map(\.width)
    }
    return Array(Set(sides)).sorted()
  }

  /// What the segment needs: its name or its faces, whichever is wider, and
  /// the air round it.
  var preferredWidth: CGFloat {
    let name = ceil(label.attributedStringValue.size().width)
    let faces = agent == nil
      ? AgentPaletteMetrics.historyTabClusterSide
      : AgentPaletteMetrics.historyTabMascotSize
    return max(name, faces) + 2 * AgentPaletteMetrics.historyTabSegmentInset
  }

  private static func faceImage(for agent: AgentId, side: CGFloat) -> NSImage? {
    guard let image = MascotSnapshotCache.image(
      MascotLook.face(for: agent), size: side, scale: AgentHistoryFaces.scale
    ) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: side, height: side))
  }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    layer?.cornerRadius = AgentPaletteMetrics.historyTabCornerRadius
    layoutContent()
  }

  private func layoutContent() {
    let isLatest = agent == nil
    let block = isLatest
      ? AgentPaletteMetrics.historyTabClusterSide
      : AgentPaletteMetrics.historyTabMascotSize
    let spacing = isLatest
      ? AgentPaletteMetrics.historyTabLatestTextSpacing
      : AgentPaletteMetrics.historyTabMascotTextSpacing
    let labelHeight = AgentPaletteMetrics.historyTabLabelHeight
    let top = ((bounds.height - block - spacing - labelHeight) / 2).rounded()
    let left = ((bounds.width - block) / 2).rounded()
    let frames = Self.faceFrames(count: faces.count, isCluster: isLatest)
    for (view, placed) in zip(faces, frames) {
      let frame = placed.offsetBy(dx: left, dy: top)
      if view.frame != frame { view.frame = frame }
    }
    for (live, still) in zip(liveFaces, faces) where live.frame != still.frame {
      live.frame = still.frame
    }
    let labelFrame = NSRect(
      x: 0, y: top + block + spacing, width: bounds.width, height: labelHeight
    )
    if label.frame != labelFrame { label.frame = labelFrame }
  }

  private func applyAppearance() {
    let fill: NSColor = !isActive && isHovered
      ? AgentPaletteMetrics.historyTabHoverFill
      : .clear
    if let layer, layer.backgroundColor != fill.cgColor {
      let previous = layer.presentation()?.backgroundColor ?? layer.backgroundColor
      layer.backgroundColor = fill.cgColor
      if !MotionPreferences.reduceMotion, window != nil {
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = previous
        fade.toValue = fill.cgColor
        fade.duration = AgentPaletteMetrics.hoverFadeDuration
        fade.timingFunction = Motion.standardCurve
        layer.add(fade, forKey: "hover")
      }
    }
    label.textColor = isActive || isHovered
      ? AgentPaletteMetrics.historyTabActiveTextColor
      : AgentPaletteMetrics.historyTabTextColor
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingAreaRef = area
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    applyAppearance()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    applyAppearance()
  }

  func pressForTesting() { onSelect?() }

  override func mouseDown(with event: NSEvent) {
    onSelect?()
  }
}

@MainActor
final class AgentHistoryTabStripView: NSView {
  private var tabViews: [AgentHistoryTabView] = []
  private let glass = PaletteGlassCircle.makeCapsule(
    height: AgentPaletteMetrics.historyTabHeight, interactive: false
  )
  private var heightConstraint: NSLayoutConstraint!
  private(set) var activeAgent: AgentId?

  private struct Arrangement: Equatable {
    var tabs: [NSRect]
    var glass: NSRect?
    var agent: AgentId?
  }

  private var from: Arrangement?
  private var to: Arrangement?
  private var progress: CGFloat = 1
  private var velocity: CGFloat = 0
  private var link: CADisplayLink?
  private var lastTick: CFTimeInterval = 0
  private var shown: Arrangement?

  var occupiedHeight: CGFloat { isHidden ? 0 : AgentPaletteMetrics.historyTabStripHeight }

  var onSelect: ((AgentId?) -> Void)?
  private var choiceIsAClick = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    glass.translatesAutoresizingMaskIntoConstraints = true
    glass.isHidden = true
    addSubview(glass)

    heightConstraint = heightAnchor.constraint(
      equalToConstant: AgentPaletteMetrics.historyTabStripHeight
    )
    heightConstraint.priority = .defaultHigh
    heightConstraint.isActive = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window == nil, link != nil else { return }
    stopClock()
    from = nil
    progress = 1
    if let to { render(to) }
  }

  override var isFlipped: Bool { true }

  /// `everyone` is whom All wears: the agents that can take a prompt.
  func apply(tabs: [AgentHistory.Tab], activeAgent: AgentId?, everyone: [AgentId] = []) {
    self.activeAgent = activeAgent
    let entries: [(agent: AgentId?, title: String, isEmpty: Bool)] =
      [(nil, "All", false)] + tabs.map { ($0.agent, $0.title, $0.isEmpty) }
    for entry in entries {
      let view: AgentHistoryTabView
      if let existing = tabViews.first(where: { $0.agent == entry.agent }) {
        view = existing
      } else {
        view = AgentHistoryTabView(
          agent: entry.agent, title: entry.title, isEmpty: entry.isEmpty
        )
        view.onSelect = { [weak self] in self?.select(entry.agent) }
        tabViews.append(view)
        addSubview(view)
      }
      if entry.agent == nil { view.setFaceAgents(everyone) }
      view.apply(
        title: entry.title, isEmpty: entry.isEmpty,
        isActive: entry.agent == activeAgent, reacts: choiceIsAClick
      )
    }
    needsLayout = true
  }

  var tabsForTesting: [AgentHistoryTabView] { tabViews }
  var trackFrameForTesting: NSRect { backingAligned(trackFrame) }
  var glassFrameForTesting: NSRect? { glass.isHidden || glass.alphaValue == 0 ? nil : glass.frame }
  var glassForTesting: NSView { glass }
  var isTravellingForTesting: Bool { link != nil }
  func advanceForTesting(by dt: CGFloat) { advance(by: dt) }

  func setVisible(_ visible: Bool) {
    isHidden = !visible
    heightConstraint.constant = visible ? AgentPaletteMetrics.historyTabStripHeight : 0
  }

  private func select(_ agent: AgentId?) {
    guard agent != activeAgent else { return }
    choiceIsAClick = true
    defer { choiceIsAClick = false }
    onSelect?(agent)
  }

  // MARK: - Layout

  private var trackFrame: NSRect {
    let inset = AgentPaletteMetrics.historyTabTopInset
    return NSRect(
      x: inset, y: inset,
      width: max(0, bounds.width - inset * 2),
      height: AgentPaletteMetrics.historyTabTrackHeight
    )
  }

  private func arrangement() -> Arrangement? {
    guard !tabViews.isEmpty, bounds.width > 0 else { return nil }
    let inner = trackFrame.insetBy(
      dx: AgentPaletteMetrics.historyTabTrackPadding,
      dy: AgentPaletteMetrics.historyTabTrackPadding
    )
    let widths = Self.segmentWidths(needs: tabViews.map(\.preferredWidth), available: inner.width)
    var frames: [NSRect] = []
    var glassFrame: NSRect?
    var left = inner.minX
    for (view, width) in zip(tabViews, widths) {
      let frame = backingAligned(NSRect(
        x: left, y: inner.minY, width: width, height: inner.height
      ))
      left += width
      frames.append(frame)
      if view.agent == activeAgent { glassFrame = frame }
    }
    return Arrangement(tabs: frames, glass: glassFrame, agent: activeAgent)
  }

  /// **Equal segments, where the names fit**, and what a name needs where
  /// they do not: at the card's narrowest, six equal shares cut "OpenCode"
  /// and "Antigravity" mid-letter. A name wider
  /// than the equal share keeps its width; the others split what is left,
  /// equally — the strip is still one track from wall to wall. Only when the
  /// names together outgrow the track do they all shrink, in proportion, and
  /// the labels end in an ellipsis.
  static func segmentWidths(needs: [CGFloat], available: CGFloat) -> [CGFloat] {
    guard !needs.isEmpty else { return [] }
    let total = needs.reduce(0, +)
    if total >= available { return needs.map { $0 * available / max(total, 1) } }
    var pinned = Set<Int>()
    while true {
      let free = needs.indices.filter { !pinned.contains($0) }
      guard !free.isEmpty else { return needs }
      let share = (available - pinned.reduce(0) { $0 + needs[$1] }) / CGFloat(free.count)
      let outgrown = free.filter { needs[$0] > share }
      if outgrown.isEmpty {
        return needs.indices.map { pinned.contains($0) ? needs[$0] : share }
      }
      pinned.formUnion(outgrown)
    }
  }

  override func layout() {
    super.layout()
    guard let target = arrangement() else { return }
    let heading: AgentId?? = link != nil ? to.map(\.agent) : shown.map(\.agent)
    let changedAgent = heading != nil && heading! != target.agent
    let canTravel = window != nil && !MotionPreferences.reduceMotion
    if changedAgent, canTravel, let current = shown {
      from = current
      to = target
      progress = 0
      velocity = 0
      startClock()
    } else if link != nil {
      to = target
    } else {
      render(target)
    }
  }

  // MARK: - Motion

  private func startClock() {
    guard link == nil else { return }
    lastTick = Motion.now
    let link = displayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = MotionPreferences.highFrameRateRange
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  private func stopClock() {
    link?.invalidate()
    link = nil
  }

  @objc private func tick() {
    let now = Motion.now
    let dt = CGFloat(min(now - lastTick, 1.0 / 15))
    lastTick = now
    advance(by: dt)
  }

  func advance(by dt: CGFloat) {
    guard let from, let to else { stopClock(); return }
    let omega = 2 * .pi / AgentPaletteMetrics.historyTabSlideResponse
    let delta = progress - 1
    let c = velocity + omega * delta
    let decay = exp(-omega * dt)
    progress = 1 + (delta + c * dt) * decay
    velocity = (velocity - omega * c * dt) * decay
    if abs(progress - 1) < 0.001, abs(velocity) < 0.01 {
      progress = 1
      stopClock()
      self.from = nil
      render(to)
      return
    }
    render(Self.mix(from, to, progress))
  }

  private static func mix(_ a: Arrangement, _ b: Arrangement, _ t: CGFloat) -> Arrangement {
    func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
    func lerp(_ x: NSRect, _ y: NSRect) -> NSRect {
      NSRect(x: lerp(x.minX, y.minX), y: lerp(x.minY, y.minY),
             width: lerp(x.width, y.width), height: lerp(x.height, y.height))
    }
    let glass: NSRect? = switch (a.glass, b.glass) {
    case let (x?, y?): lerp(x, y)
    case let (x?, nil): x
    case let (nil, y?): y
    case (nil, nil): nil
    }
    return Arrangement(
      tabs: zip(a.tabs, b.tabs).map { lerp($0, $1) },
      glass: glass,
      agent: t < 0.5 ? a.agent : b.agent
    )
  }

  private func render(_ state: Arrangement) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0
    NSAnimationContext.current.allowsImplicitAnimation = false
    defer {
      NSAnimationContext.endGrouping()
      CATransaction.commit()
    }

    shown = state
    for (view, frame) in zip(tabViews, state.tabs) where view.frame != frame {
      view.frame = frame
    }
    guard let glassFrame = state.glass else {
      glass.isHidden = true
      return
    }
    glass.isHidden = false
    if glass.alphaValue != 1 { glass.alphaValue = 1 }
    let snapped = backingAligned(glassFrame)
    if glass.frame != snapped { glass.frame = snapped }
    let corner = AgentPaletteMetrics.historyTabCornerRadius
    if let glassView = glass as? NSGlassEffectView, glassView.cornerRadius != corner {
      glassView.cornerRadius = corner
    }
  }

  private func backingAligned(_ rect: NSRect) -> NSRect {
    guard window != nil else { return rect }
    return backingAlignedRect(rect, options: .alignAllEdgesNearest)
  }
}
