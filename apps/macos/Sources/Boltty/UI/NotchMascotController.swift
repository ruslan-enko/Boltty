import AppKit
import Combine

struct NotchMascotGeometry: Equatable {
  static let inset: CGFloat = 2
  static let gap: CGFloat = 6
  static let slotShare: CGFloat = 0.66
  static let stepShare: CGFloat = 0.49
  static let maximumFaces = 4
  static let cornerShare: CGFloat = 0.5
  let notch: CGRect
  private(set) var faces = 1

  var diameter: CGFloat { notch.height - Self.inset * 2 }
  var slotSide: CGFloat { (diameter * Self.slotShare).rounded() }
  var margin: CGFloat { (diameter - slotSide) / 2 }
  var step: CGFloat { (slotSide * Self.stepShare).rounded() }
  var frame: CGRect {
    CGRect(x: notch.minX - travel, y: notch.minY,
           width: travel + min(diameter, notch.width), height: notch.height)
  }
  var bubble: CGRect {
    CGRect(x: 0, y: Self.inset, width: margin * 2 + slotSide + step * CGFloat(faces - 1), height: diameter)
  }
  var slots: [CGRect] {
    (0..<faces).map {
      CGRect(x: margin + step * CGFloat($0), y: Self.inset + margin, width: slotSide, height: slotSide)
    }
  }
  var face: CGRect { slots[faces - 1] }
  var travel: CGFloat { bubble.width + Self.gap }
  var cornerRadius: CGFloat { bubble.height * Self.cornerShare }

  func withFaces(_ count: Int) -> NotchMascotGeometry {
    var copy = self
    copy.faces = min(max(count, 1), Self.maximumFaces)
    return copy
  }

  @MainActor init?(screen: CGRect, topInset: CGFloat, left: CGRect?, right: CGRect?) {
    guard topInset > 0, let left, let right, right.minX > left.maxX,
          left.maxX > screen.minX, right.minX < screen.maxX else { return nil }
    let height = min(topInset, left.height)
    let diameter = height - Self.inset * 2
    guard diameter > 0, left.width >= diameter + Self.gap else { return nil }
    notch = CGRect(x: left.maxX, y: screen.maxY - height, width: right.minX - left.maxX, height: height)
  }

  @MainActor init?(screen: NSScreen) {
    self.init(screen: screen.frame, topInset: screen.safeAreaInsets.top,
              left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
  }

  @MainActor static func notch(on screen: NSScreen) -> CGRect? {
    NotchMascotGeometry(screen: screen)?.notch
  }

  func frame(lineWidth: CGFloat) -> CGRect {
    CGRect(x: frame.minX - lineWidth, y: frame.minY,
           width: frame.width + lineWidth, height: frame.height)
  }

  static let linePadding: CGFloat = 12
  static let lineGap: CGFloat = 0
  static let lineMaxWidth: CGFloat = 280
}

private let lineTitleLimit = 26

struct NotchMascotStatus: Equatable {
  let conversationID: UUID?
  let agent: AgentId?
  let emotion: MascotEmotion
  let label: String
  var line: String? = nil
  var holdsLine = false

  var hasSomethingToSay: Bool { conversationID != nil }

  var faces: [NotchMascotFace] = []

  private static func rank(_ conversation: Conversation) -> Int {
    // Ask Boltty says its own answer beside the pointer.
    guard !conversation.isAskBoltty else { return 0 }
    switch conversation.lastKnownState {
    case .waiting: return 5
    case .working: return 4
    case .failed, .interrupted, .rateLimited: return conversation.hasUnread ? 3 : 0
    case .idle: return conversation.hasUnread ? 2 : 0
    }
  }

  static func select(from conversations: [Conversation], preferredID: UUID?,
                     waitingOn: [UUID: PendingInteraction.Kind] = [:]) -> Self {
    func before(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
      if rank(lhs) != rank(rhs) { return rank(lhs) > rank(rhs) }
      if (lhs.id == preferredID) != (rhs.id == preferredID) { return lhs.id == preferredID }
      return lhs.updatedAt > rhs.updatedAt
    }
    let active = conversations.filter { rank($0) > 0 }.sorted(by: before)
    guard let conversation = active.first else {
      return Self(conversationID: nil, agent: nil, emotion: .sleeping, label: "Open Boltty AI")
    }
    var leaders: [Conversation] = []
    var counts: [String: Int] = [:]
    for chat in active {
      counts[chat.providerID, default: 0] += 1
      if !leaders.contains(where: { $0.providerID == chat.providerID }) { leaders.append(chat) }
    }
    var status = describe(conversation, waitingOn: waitingOn)
    status.faces = leaders.prefix(NotchMascotGeometry.maximumFaces).reversed().map { chat in
      let said = describe(chat, waitingOn: waitingOn)
      return NotchMascotFace(
        conversationID: chat.id, agent: said.agent, emotion: said.emotion,
        label: said.label, line: said.line, holdsLine: said.holdsLine,
        chats: counts[chat.providerID] ?? 1)
    }
    return status
  }

  private static func describe(_ conversation: Conversation,
                               waitingOn: [UUID: PendingInteraction.Kind]) -> Self {
    let need = SystemAttentionNotification.needsWords(for: waitingOn[conversation.id])
    let state: String
    switch conversation.lastKnownState {
    case .working: state = "Working"
    case .waiting: state = need
    case .failed: state = "Task failed"
    case .interrupted: state = "Interrupted"
    case .rateLimited: state = "Rate limited"
    case .idle: state = "Finished"
    }
    let agent = AgentId(rawValue: conversation.providerID)
    let title = conversation.title.middleTruncated(to: lineTitleLimit)
    let who = agent?.shortDisplayName ?? "Boltty"
    let line: String
    switch conversation.lastKnownState {
    case .waiting: line = "\(need) · \(who)"
    case .working: line = "Working · \(who)"
    case .failed: line = "Didn't finish · \(title)"
    case .interrupted: line = "Interrupted · \(title)"
    case .rateLimited: line = "Rate limited · \(title)"
    case .idle: line = "Done · \(title)"
    }
    return Self(conversationID: conversation.id, agent: agent,
                emotion: MascotEmotion(executionState: conversation.lastKnownState),
                label: "\(state) — \(conversation.title)",
                line: line, holdsLine: conversation.lastKnownState == .waiting)
  }

  static func asks(in transcripts: [UUID: ConversationTranscript]) -> [UUID: PendingInteraction.Kind] {
    transcripts.compactMapValues { ($0.openInteraction ?? $0.interactions.last)?.kind }
  }
}

struct NotchMascotFace: Equatable {
  let conversationID: UUID
  let agent: AgentId?
  let emotion: MascotEmotion
  let label: String
  let line: String?
  let holdsLine: Bool
  let chats: Int
}

@MainActor
final class NotchMascotController {
  private let panel: PassivePanel
  private let faceView = NotchMascotView()
  private var subscriptions = Set<AnyCancellable>()
  private var conversations: [Conversation] = []
  private var waitingOn: [UUID: PendingInteraction.Kind] = [:]
  private var roster = MascotRoster()
  private var preferredID: UUID?
  private var preferredScreenNumber: NSNumber?
  private var panelVisible = true
  private var suspended = false
  private var stopped = false
  private var generation = 0
  private(set) var isDocked = false
  private(set) var status = NotchMascotStatus.select(from: [], preferredID: nil)
  private var hoveredID: UUID?
  var lineDuration: TimeInterval = 6
  private var dockGeometry: NotchMascotGeometry?
  private var foldWorkItem: DispatchWorkItem?
  private var hideWorkItem: DispatchWorkItem?
  var lineForTesting: String? { faceView.shownLine }
  var onOpen: ((UUID?) -> Void)?
  var geometryProvider: (() -> NotchMascotGeometry?)?

  init() {
    panel = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.animationBehavior = .none
    panel.isMovable = false
    panel.acceptsMouseMovedEvents = true
    panel.contentView = faceView
    Motion.applyTimeScale(to: panel)
    panel.identifier = NSUserInterfaceItemIdentifier("boltty.notch")
    faceView.onOpen = { [weak self] conversationID in
      guard let self else { return }
      self.onOpen?(conversationID ?? self.status.conversationID)
    }
    faceView.onHover = { [weak self] conversationID in self?.hover(conversationID) }
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.refresh(animated: false) }
      .store(in: &subscriptions)
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
      workspace.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
        self?.suspended = true
        self?.refresh(animated: false)
      }.store(in: &subscriptions)
    }
    for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
      workspace.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
        self?.suspended = false
        self?.refresh(animated: false)
      }.store(in: &subscriptions)
    }
  }

  func update(conversations: [Conversation], roster: MascotRoster,
              waitingOn: [UUID: PendingInteraction.Kind] = [:]) {
    self.conversations = conversations
    self.roster = roster
    self.waitingOn = waitingOn
    updateFace()
  }

  func setPanelVisible(_ visible: Bool, screen: NSScreen?, conversationID: UUID?) {
    panelVisible = visible
    if !visible {
      preferredID = conversationID
      preferredScreenNumber = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
    updateFace(refreshing: false)
    refresh(animated: true)
  }

  private var spoken: (line: String?, holds: Bool) {
    if let hoveredID, let face = status.faces.first(where: { $0.conversationID == hoveredID }) {
      return (face.line, true)
    }
    return (status.line, status.holdsLine)
  }

  private func updateFace(refreshing: Bool = true) {
    let previous = status
    let previousLine = spoken.line
    status = .select(from: conversations, preferredID: preferredID, waitingOn: waitingOn)
    if let hoveredID, !status.faces.contains(where: { $0.conversationID == hoveredID }) {
      self.hoveredID = nil
    }
    faceView.update(status, roster: roster)
    if refreshing, status.hasSomethingToSay != previous.hasSomethingToSay {
      refresh(animated: true)
      return
    }
    if isDocked { reshape() }
    if isDocked, spoken.line != previousLine { sayLine() }
  }

  private func reshape() {
    guard let current = dockGeometry else { return }
    let next = current.withFaces(status.faces.count)
    guard next != current else { return }
    dockGeometry = next
    let needed = next.frame(lineWidth: faceView.shownLineWidth)
    if needed.width > panel.frame.width { resize(to: needed) }
    faceView.reshape(to: next) { [weak self] in
      guard let self, self.isDocked, let geometry = self.dockGeometry else { return }
      let fitted = geometry.frame(lineWidth: self.faceView.shownLineWidth)
      if fitted.width < self.panel.frame.width { self.resize(to: fitted) }
    }
  }

  private func hover(_ conversationID: UUID?) {
    guard conversationID != hoveredID, isDocked else { return }
    hoveredID = conversationID
    sayLine()
  }

  private func sayLine() {
    foldWorkItem?.cancel()
    foldWorkItem = nil
    let spoken = spoken
    guard let line = spoken.line else { setLine(nil); return }
    setLine(line)
    guard !spoken.holds else { return }
    let item = DispatchWorkItem { [weak self] in self?.setLine(nil) }
    foldWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + lineDuration, execute: item)
  }

  private func setLine(_ line: String?) {
    guard isDocked, let geometry = dockGeometry else { return }
    let width = line.map { faceView.lineWidth(for: $0) } ?? 0
    let needed = geometry.frame(lineWidth: max(width, faceView.shownLineWidth))
    if needed.width > panel.frame.width { resize(to: needed) }
    faceView.showLine(line, width: width) { [weak self] in
      guard let self, self.isDocked, let geometry = self.dockGeometry else { return }
      let fitted = geometry.frame(lineWidth: self.faceView.shownLineWidth)
      if fitted.width < self.panel.frame.width { self.resize(to: fitted) }
    }
  }

  private func resize(to frame: CGRect) {
    panel.setFrame(frame, display: false)
    faceView.needsLayout = true
    faceView.layoutSubtreeIfNeeded()
  }

  private func geometry() -> NotchMascotGeometry? {
    let base: NotchMascotGeometry?
    if let geometryProvider {
      base = geometryProvider()
    } else {
      let screens = NSScreen.screens.sorted {
        let lhs = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let rhs = $1.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return lhs == preferredScreenNumber && rhs != preferredScreenNumber
      }
      base = screens.compactMap { NotchMascotGeometry(screen: $0) }.first
    }
    return base?.withFaces(status.faces.count)
  }

  private func refresh(animated: Bool) {
    let geometry = geometry()
    let show = !panelVisible && !suspended && !stopped && geometry != nil && status.hasSomethingToSay
    generation += 1
    let token = generation
    isDocked = show
    panel.ignoresMouseEvents = !show
    if show, let geometry {
      let interrupted = hideWorkItem != nil
      hideWorkItem?.cancel()
      hideWorkItem = nil
      let arriving = !panel.isVisible
      dockGeometry = geometry
      if arriving {
        foldWorkItem?.cancel()
        hoveredID = nil
        faceView.resetLine()
      }
      panel.setFrame(geometry.frame(lineWidth: faceView.shownLineWidth), display: false)
      faceView.configure(geometry)
      if arriving { faceView.setExpanded(false, animated: false) }
      panel.orderFrontRegardless()
      faceView.setExpanded(true, animated: animated)
      if arriving || interrupted { sayLine() }
    } else if panel.isVisible {
      foldWorkItem?.cancel()
      foldWorkItem = nil
      hideWorkItem?.cancel()
      hideWorkItem = nil
      faceView.setExpanded(false, animated: animated)
      if animated {
        let item = DispatchWorkItem { [weak self] in
          guard let self, self.generation == token, !self.isDocked else { return }
          self.hideWorkItem = nil
          self.panel.orderOut(nil)
          self.faceView.stopAnimating()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(Motion.standard), execute: item)
      } else {
        panel.orderOut(nil)
        faceView.stopAnimating()
      }
    }
  }

  func shutdown() {
    stopped = true
    refresh(animated: false)
    subscriptions.removeAll()
  }

  var windowForTesting: NSWindow { panel }
  var backdropSlideStartForTesting: CGRect? { faceView.slideStartOnScreen() }
  func snapshotForTesting() -> CGImage? { faceView.snapshot() }
  var shownFacesForTesting: [UUID] { faceView.shownFaces }
  func hoverForTesting(_ conversationID: UUID?) { hover(conversationID) }
}

@MainActor
private final class NotchMascotView: NSView {
  private let backdrop = CALayer()
  private let dockSpace = CALayer()

  private struct Seat {
    let mascot: MascotNSView
    let rim: NSView
    let badge: NSView
    let count: NSTextField
  }
  private var seats: [Seat] = []
  private var order: [(conversationID: UUID, agentKey: String, seat: Int)] = []

  private let lineLabel = NSTextField(labelWithString: "")
  private let leavingLabel = NSTextField(labelWithString: "")
  private var geometry: NotchMascotGeometry?
  private var expanded = false
  private(set) var shownLine: String?
  private(set) var shownLineWidth: CGFloat = 0
  private var leavingLineWidth: CGFloat = 0
  private var lineGeneration = 0
  private var reshapeGeneration = 0
  private var hoverArea: NSTrackingArea?
  var onOpen: ((UUID?) -> Void)?
  var onHover: ((UUID?) -> Void)?

  var shownFaces: [UUID] { order.map(\.conversationID) }

  override init(frame: NSRect) {
    super.init(frame: frame)
    appearance = NSAppearance(named: .darkAqua)
    wantsLayer = true
    backdrop.backgroundColor = NSColor.black.cgColor
    backdrop.cornerCurve = .continuous
    dockSpace.addSublayer(backdrop)
    dockSpace.zPosition = -10
    layer?.addSublayer(dockSpace)
    for _ in 0..<NotchMascotGeometry.maximumFaces {
      let mascot = MascotNSView(conversationID: UUID(), look: MascotLook.face(for: nil))
      mascot.isHidden = true
      addSubview(mascot)
      let rim = NSView()
      rim.wantsLayer = true
      rim.layer?.backgroundColor = NSColor.black.cgColor
      rim.isHidden = true
      addSubview(rim)
      let badge = NSView()
      badge.wantsLayer = true
      badge.layer?.backgroundColor = NSColor.black.cgColor
      let tint = CALayer()
      tint.backgroundColor = PaletteInk.selectedFill.cgColor
      badge.layer?.addSublayer(tint)
      badge.layer?.zPosition = 50
      badge.isHidden = true
      let count = NSTextField(labelWithString: "")
      count.alignment = .center
      count.textColor = PaletteInk.primary
      badge.addSubview(count)
      addSubview(badge)
      seats.append(Seat(mascot: mascot, rim: rim, badge: badge, count: count))
    }
    for label in [lineLabel, leavingLabel] {
      label.font = roundedAppFont(size: AgentPaletteMetrics.typeMeta, weight: .medium)
      label.textColor = PaletteInk.primary
      label.lineBreakMode = .byTruncatingTail
      label.wantsLayer = true
      label.layer?.zPosition = 60
      label.alphaValue = 0
      addSubview(label)
    }
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityIdentifier("boltty.notch.open")
  }
  required init?(coder: NSCoder) { nil }

  private var dockOrigin: CGFloat {
    guard let geometry else { return 0 }
    return bounds.width - geometry.frame.width
  }

  func configure(_ geometry: NotchMascotGeometry) {
    self.geometry = geometry
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  override func layout() {
    super.layout()
    guard let geometry else { return }
    layoutFaces(geometry)
    lineLabel.frame = lineRect(width: shownLineWidth)
    leavingLabel.frame = lineRect(width: leavingLineWidth)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dockSpace.frame = CGRect(x: dockOrigin, y: 0, width: geometry.frame.width, height: bounds.height)
    backdrop.frame = shape(expanded: expanded)
    backdrop.cornerRadius = geometry.cornerRadius
    CATransaction.commit()
  }

  private func layoutFaces(_ geometry: NotchMascotGeometry) {
    let slots = geometry.slots
    for (index, entry) in order.enumerated() where index < slots.count {
      let seat = seats[entry.seat]
      let slot = slots[index].offsetBy(dx: dockOrigin, dy: 0)
      seat.mascot.frame = slot
      seat.mascot.layer?.zPosition = CGFloat(index * 2 + 1)
      seat.mascot.layoutSubtreeIfNeeded()
      seat.rim.frame = slot
      seat.rim.layer?.cornerRadius = slot.height / 2
      seat.rim.layer?.zPosition = CGFloat(index * 2)
      seat.rim.isHidden = index == 0
      let side = max(10, (slot.height * 0.46).rounded())
      seat.badge.frame = CGRect(x: slot.maxX - side * 0.75, y: slot.minY - side * 0.15,
                                width: side, height: side)
      seat.badge.layer?.cornerRadius = side / 2
      if let tint = seat.badge.layer?.sublayers?.first(where: { !($0.delegate is NSView) }) {
        let ring = max(1, side * 0.12)
        tint.frame = seat.badge.bounds.insetBy(dx: ring, dy: ring)
        tint.cornerRadius = tint.frame.height / 2
      }
      seat.count.font = roundedAppFont(size: (side * 0.68).rounded(), weight: .bold)
      let height = ceil(seat.count.intrinsicContentSize.height)
      seat.count.frame = CGRect(x: 0, y: (side - height) / 2, width: side, height: height)
    }
  }

  func update(_ status: NotchMascotStatus, roster: MascotRoster) {
    var free = Set(seats.indices)
    var kept: [String: Int] = [:]
    for entry in order { kept[entry.agentKey] = entry.seat }
    let keys = status.faces.map { $0.agent?.rawValue ?? $0.conversationID.uuidString }
    for key in keys { if let seat = kept[key] { free.remove(seat) } }
    var next: [(conversationID: UUID, agentKey: String, seat: Int)] = []
    for (face, key) in zip(status.faces, keys) {
      let seat = kept[key] ?? free.sorted().first ?? 0
      free.remove(seat)
      next.append((face.conversationID, key, seat))
      let parts = seats[seat]
      parts.mascot.apply(look: roster.look(for: face.agent))
      parts.mascot.emotion = face.emotion
      parts.mascot.reduceMotion = MotionPreferences.reduceMotion
      parts.badge.isHidden = face.chats < 2
      parts.count.stringValue = "\(face.chats)"
    }
    let arriving = Set(next.map(\.seat)).subtracting(order.map(\.seat))
    order = next
    for (index, seat) in seats.enumerated() where !next.contains(where: { $0.seat == index }) {
      seat.mascot.isHidden = true
      seat.rim.isHidden = true
      seat.badge.isHidden = true
    }
    for entry in next {
      seats[entry.seat].mascot.isHidden = false
      if arriving.contains(entry.seat), window != nil { fadeIn(seats[entry.seat]) }
    }
    toolTip = status.label
    setAccessibilityLabel(shownLine ?? status.label)
    setAccessibilityHelp("Open Boltty AI")
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  private func fadeIn(_ seat: Seat) {
    for layer in [seat.mascot.layer, seat.rim.layer] {
      guard let layer else { continue }
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0
      fade.toValue = 1
      fade.duration = Motion.standard
      fade.timingFunction = Motion.emphasizedCurve
      layer.add(fade, forKey: "arrive")
    }
  }

  func reshape(to next: NotchMascotGeometry, completion: @escaping () -> Void) {
    let old = geometry
    let shift = (next.travel - (old?.travel ?? next.travel))
    let from = (backdrop.presentation()?.frame ?? backdrop.frame).offsetBy(dx: shift, dy: 0)
    geometry = next
    needsLayout = true
    layoutSubtreeIfNeeded()
    setBackdrop(shape(expanded: expanded), from: from, animated: true)
    reshapeGeneration += 1
    let token = reshapeGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(Motion.standard)) { [weak self] in
      guard let self, self.reshapeGeneration == token else { return }
      completion()
    }
  }

  // MARK: Shape

  private func shape(expanded: Bool) -> CGRect {
    guard let geometry else { return .zero }
    let bubble = geometry.bubble
    guard expanded || MotionPreferences.reduceMotion else {
      return bubble.offsetBy(dx: geometry.travel, dy: 0)
    }
    return CGRect(x: bubble.minX - shownLineWidth, y: bubble.minY,
                  width: bubble.width + shownLineWidth, height: bubble.height)
  }

  private func setBackdrop(_ rect: CGRect, from start: CGRect? = nil, animated: Bool) {
    let old = start ?? backdrop.presentation()?.frame ?? backdrop.frame
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    backdrop.frame = rect
    backdrop.cornerRadius = geometry?.cornerRadius ?? 0
    CATransaction.commit()
    backdrop.removeAnimation(forKey: "dock")
    guard animated, !MotionPreferences.reduceMotion, !old.isEmpty, old != rect else { return }
    let bounds = CABasicAnimation(keyPath: "bounds.size")
    bounds.fromValue = old.size
    bounds.toValue = rect.size
    let position = CABasicAnimation(keyPath: "position")
    position.fromValue = CGPoint(x: old.midX, y: old.midY)
    position.toValue = CGPoint(x: rect.midX, y: rect.midY)
    let group = CAAnimationGroup()
    group.animations = [bounds, position]
    group.duration = Motion.standard
    group.timingFunction = Motion.emphasizedCurve
    backdrop.add(group.preferringHighFrameRate(), forKey: "dock")
  }

  private func animatePath(expanded: Bool) {
    setBackdrop(shape(expanded: expanded), animated: true)
  }

  private var slidingLayers: [CALayer] {
    order.flatMap { entry -> [CALayer] in
      let seat = seats[entry.seat]
      return [seat.mascot.layer, seat.rim.layer, seat.badge.layer].compactMap { $0 }
    }
  }

  func setExpanded(_ expanded: Bool, animated: Bool) {
    guard let geometry else { return }
    self.expanded = expanded
    let animate = animated && !MotionPreferences.reduceMotion
    let nextX: CGFloat = expanded || MotionPreferences.reduceMotion ? 0 : geometry.travel
    let oldOpacity = layer?.presentation()?.opacity ?? layer?.opacity ?? 0
    setBackdrop(shape(expanded: expanded), animated: animate)
    for face in slidingLayers {
      let oldX = face.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat
        ?? (face.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      face.setValue(nextX, forKeyPath: "transform.translation.x")
      CATransaction.commit()
      face.removeAnimation(forKey: "dock")
      if animate {
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = oldX
        slide.toValue = nextX
        slide.duration = Motion.standard
        slide.timingFunction = Motion.emphasizedCurve
        face.add(slide.preferringHighFrameRate(), forKey: "dock")
      }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.opacity = expanded ? 1 : 0
    CATransaction.commit()
    layer?.removeAnimation(forKey: "visibility")
    if animated {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = oldOpacity
      fade.toValue = expanded ? 1 : 0
      fade.duration = Motion.quick
      layer?.add(fade, forKey: "visibility")
    }
  }

  // MARK: The line

  func lineWidth(for line: String) -> CGFloat {
    let text = NSAttributedString(string: line, attributes: [.font: lineLabel.font as Any])
    let words = ceil(text.size().width) + 4
    return min(NotchMascotGeometry.lineMaxWidth,
               NotchMascotGeometry.linePadding + words + NotchMascotGeometry.lineGap)
  }

  private func lineRect(width: CGFloat) -> CGRect {
    let height = ceil(lineLabel.intrinsicContentSize.height)
    let x = dockOrigin - width + NotchMascotGeometry.linePadding
    let w = max(0, width - NotchMascotGeometry.linePadding - NotchMascotGeometry.lineGap)
    return CGRect(x: x, y: (bounds.height - height) / 2, width: w, height: height)
  }

  func resetLine() {
    lineGeneration += 1
    shownLine = nil
    shownLineWidth = 0
    leavingLineWidth = 0
    lineLabel.alphaValue = 0
    leavingLabel.alphaValue = 0
    lineLabel.stringValue = ""
  }

  func showLine(_ line: String?, width: CGFloat, completion: @escaping () -> Void) {
    guard line != shownLine else { completion(); return }
    lineGeneration += 1
    let token = lineGeneration
    let previous = shownLine
    let previousWidth = shownLineWidth
    shownLine = line
    shownLineWidth = line == nil ? 0 : width
    setAccessibilityLabel(line ?? toolTip ?? "")
    animatePath(expanded: expanded)

    if let previous, let line, previous != line {
      leavingLabel.stringValue = previous
      leavingLineWidth = previousWidth
      leavingLabel.frame = lineRect(width: previousWidth)
      leavingLabel.alphaValue = 1
      lift(leavingLabel, from: 0, to: -6, fadeTo: 0)
    }
    if let line {
      lineLabel.stringValue = line
      lineLabel.frame = lineRect(width: width)
      lineLabel.alphaValue = 1
      lift(lineLabel, from: previous == nil ? 0 : 6, to: 0, fadeFrom: 0)
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Motion.quick
        lineLabel.animator().alphaValue = 0
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(Motion.standard)) { [weak self] in
      guard let self, self.lineGeneration == token else { return }
      self.leavingLabel.alphaValue = 0
      completion()
    }
  }

  private func lift(_ label: NSTextField, from: CGFloat, to: CGFloat,
                    fadeFrom: Float? = nil, fadeTo: Float? = nil) {
    guard let layer = label.layer else { return }
    let group = CAAnimationGroup()
    var parts: [CAAnimation] = []
    if !MotionPreferences.reduceMotion, from != to {
      let move = CABasicAnimation(keyPath: "transform.translation.y")
      move.fromValue = -from
      move.toValue = -to
      parts.append(move)
    }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = fadeFrom ?? 1
    fade.toValue = fadeTo ?? 1
    parts.append(fade)
    group.animations = parts
    group.duration = Motion.standard
    group.timingFunction = Motion.emphasizedCurve
    group.fillMode = .forwards
    group.isRemovedOnCompletion = fadeTo == nil
    layer.removeAnimation(forKey: "swap")
    layer.add(group, forKey: "swap")
  }

  func stopAnimating() { seats.forEach { $0.mascot.leaveClock() } }

  func slideStartOnScreen() -> CGRect? {
    guard let window, let group = backdrop.animation(forKey: "dock") as? CAAnimationGroup else {
      return nil
    }
    let parts = group.animations?.compactMap { $0 as? CABasicAnimation } ?? []
    guard let size = parts.first(where: { $0.keyPath == "bounds.size" })?.fromValue as? CGSize,
          let center = parts.first(where: { $0.keyPath == "position" })?.fromValue as? CGPoint
    else { return nil }
    let start = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                       width: size.width, height: size.height)
    let inView = start.offsetBy(dx: dockSpace.frame.minX, dy: dockSpace.frame.minY)
    return window.convertToScreen(convert(inView, to: nil))
  }

  func snapshot() -> CGImage? {
    let scale: CGFloat = 4
    guard let geometry, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: Int(geometry.frame.width * scale),
                                  height: Int(geometry.frame.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -dockOrigin, y: 0)
    context.addPath(CGPath(
      roundedRect: geometry.bubble.offsetBy(dx: dockOrigin, dy: 0),
      cornerWidth: geometry.cornerRadius, cornerHeight: geometry.cornerRadius, transform: nil))
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    for (index, entry) in order.enumerated() {
      let mascot = seats[entry.seat].mascot
      if index > 0 {
        context.fillEllipse(in: mascot.frame)
      }
      let reduceMotion = mascot.reduceMotion
      mascot.reduceMotion = true
      mascot.render()
      defer { mascot.reduceMotion = reduceMotion }
      guard let image = mascot.snapshot(scale: scale, overscan: true) else { return nil }
      let room = mascot.frame.width * MascotNSView.overscan
      context.draw(image, in: mascot.frame.insetBy(dx: -room, dy: -room))
    }
    return context.makeImage()
  }

  // MARK: Pointer

  private func face(at point: NSPoint) -> UUID? {
    guard let geometry else { return nil }
    let slots = geometry.slots
    for (index, entry) in order.enumerated().reversed() where index < slots.count {
      if slots[index].offsetBy(dx: dockOrigin, dy: 0).contains(point) { return entry.conversationID }
    }
    return nil
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                     .activeAlways, .inVisibleRect],
                              owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    onHover?(face(at: convert(event.locationInWindow, from: nil)))
  }
  override func mouseExited(with event: NSEvent) { onHover?(nil) }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
  override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
  override func mouseDown(with event: NSEvent) {
    let id = face(at: convert(event.locationInWindow, from: nil)) ?? order.last?.conversationID
    if let seat = order.first(where: { $0.conversationID == id })?.seat { seats[seat].mascot.poke() }
  }
  override func mouseUp(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if bounds.contains(point) { onOpen?(face(at: point)) }
  }
  override func accessibilityPerformPress() -> Bool { onOpen?(nil); return true }
}
