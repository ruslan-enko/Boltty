import AppKit

/// Ask Boltty on the screen, beside the pointer, as heyclicky draws it: the
/// answering agent's face rides just past the arrow with the sentence being
/// said in a bubble beside it; while the chord is held the pointer leaves a
/// line in the face's gradient, to circle what is meant; and when the answer
/// points somewhere the face flies there on an arc, lands beside the spot, and
/// a ring marks it. Nothing here takes a click or the keyboard — one passive
/// panel over the screen the pointer is on.
@MainActor
final class AskBolttyOverlayController {
  // MARK: Geometry, in points

  static let faceSide: CGFloat = 40
  /// From the pointer's tip to the face's centre: right of the arrow, under it.
  static let pointerOffset = CGVector(dx: 30, dy: -30)
  /// The chase's time constant: the face trails the pointer by about this.
  static let followTime: CFTimeInterval = 0.06
  static let edgeMargin: CGFloat = 8
  static let bubbleGap: CGFloat = 6
  /// Two sentences at most are in the bubble (`AskBolttySession.caption`); this
  /// is room for them at the bubble's size.
  static let bubbleMaxTextWidth: CGFloat = 340
  static let bubbleMaxLines = 5
  static let bubblePadding = CGSize(width: 14, height: 10)
  static let bubbleCornerRadius: CGFloat = 18
  /// Over the glass, under the words: bare glass over a bright page reads
  /// grey on grey. Density goes over the
  /// glass, never into its tint (*Design contract*).
  static let bubbleShade = NSColor.black.withAlphaComponent(0.5)

  /// From the spot pointed at to the face's centre: beside it, never over it.
  static let landingOffset = CGVector(dx: 30, dy: -30)
  static let markerRadius: CGFloat = 15
  static let markerLineWidth: CGFloat = 3

  static let lingerAfterAnswer: TimeInterval = 1
  static let lingerAfterPointing: TimeInterval = 2
  static let lingerAfterProblem: TimeInterval = 4
  static let boardSide: CGFloat = 320
  static let boardInset: CGFloat = 24
  static let boardCornerRadius: CGFloat = 28
  static let boardGap: CGFloat = 12
  private static let flightCurve = TimingCurve(Motion.emphasizedCurve)

  // MARK: State

  private enum Mode: Equatable {
    case following
    case flying(from: CGPoint, to: CGPoint, start: CFTimeInterval, duration: CFTimeInterval)
    case parked(CGPoint)
  }

  /// Where the pointer is; tests hand in their own.
  var pointer: () -> CGPoint = { NSEvent.mouseLocation }
  /// The pointer moved while the chord is held.
  var onTrace: ((CGPoint) -> Void)?

  private var panel: PassivePanel?
  private let root = AskBolttyOverlayRootView()
  private let trail = AskBolttyTrailLayer()
  private let marker = CAShapeLayer()
  /// What the answers drew on the screen, until the next question.
  private let drawing = AskBolttyDrawingLayer()
  /// And what they drew on a board beside the face.
  private var board: PaletteGlassHost?
  private let boardDrawing = AskBolttyDrawingLayer()
  private var drawnCount = 0
  /// The face and its words have gone; the drawings stay until a click,
  /// Escape or the next question.
  private var settled = false
  private var dismissMonitor: Any?
  private var face: MascotNSView?
  private var bubble: PaletteGlassHost?
  private let label = NSTextField(wrappingLabelWithString: "")

  private var phase: AskBolttySession.Phase = .idle
  private var agent: AgentId?
  private var mode = Mode.following
  /// The face's centre, in AppKit's global coordinates.
  private var position: CGPoint?
  private var screenFrame: CGRect = .zero
  private var backingScale: CGFloat = 2
  private var link: CADisplayLink?
  private var lastTick: CFTimeInterval = 0
  private var hideWork: DispatchWorkItem?
  private var text = ""
  private var shade: NSView?
  /// How much of `text` is on screen: an answer types out, as a character's
  /// words do in Zelda or Animal Crossing, with a blip a letter or two and
  /// the face bobbing as if it spoke.
  private var typed: Double = 0
  private var typesOut = false
  private var lastBlip = 0
  private let blips = AskBolttyBlips()
  /// Settings › General › Sounds.
  var makesSounds = true
  static let typingSpeed: Double = 38
  static let bobHeight: CGFloat = 2.5
  /// Measured when the words change, never per frame.
  private var bubbleSize: CGSize = .zero

  var isVisible: Bool { panel?.isVisible == true }
  var textForTesting: String { label.stringValue }
  var facePositionForTesting: CGPoint? { position }
  var trailRunsForTesting: Int { trail.runCount }
  var bubbleSizeForTesting: CGSize { bubbleSize }
  var faceFrameForTesting: CGRect? { face?.frame }
  var isPointingForTesting: Bool {
    if case .following = mode { return false }
    return true
  }

  // MARK: - What Ask Boltty says

  func show(_ phase: AskBolttySession.Phase, heard: String, caption: String, agent: AgentId?) {
    let previous = self.phase
    self.phase = phase
    hideWork?.cancel()
    let next: String
    let emotion: MascotEmotion
    var lingering: TimeInterval?
    switch phase {
    case .idle:
      guard isVisible else { return }
      trail.finish()
      if case .following = mode {
        linger(Self.lingerAfterAnswer)
      } else {
        linger(Self.lingerAfterPointing)
      }
      return
    case .listening:
      next = heard.isEmpty ? "Listening…" : heard
      emotion = .listening
      if previous != .listening {
        trail.clear()
        release()
        clearDrawings()
      }
    case .thinking:
      next = "Thinking…"
      emotion = .thinking
    case .speaking:
      next = caption.isEmpty ? text : caption
      emotion = .focused
      trail.finish()
    case let .needsYou(message):
      // Said, then gone: the chat waits in Boltty, not beside the pointer.
      next = message
      emotion = .concerned
      trail.finish()
      lingering = Self.lingerAfterProblem
    case let .failed(message):
      next = message
      emotion = .sad
      trail.finish()
      lingering = Self.lingerAfterProblem
    }
    build(agent: agent)
    face?.emotion = emotion
    typesOut = phase == .speaking
    setText(next, quiet: (phase == .listening && heard.isEmpty) || phase == .thinking)
    appear()
    if let lingering { linger(lingering) }
  }

  /// Flies the face to `location` (AppKit's global coordinates) and marks it.
  func point(at location: CGPoint) {
    guard isVisible else { return }
    if !screenFrame.contains(location), let screen = Self.screen(containing: location) {
      place(on: screen)
    }
    let landing = Self.landing(beside: location, in: screenFrame)
    let from = position ?? landing
    if MotionPreferences.reduceMotion {
      mode = .parked(landing)
    } else {
      mode = .flying(from: from, to: landing, start: Motion.now,
                     duration: Self.flightDuration(from: from, to: landing))
    }
    showMarker(at: location)
    startTicking()
  }

  // MARK: - What the answer draws

  var drawnCountForTesting: Int { drawnCount }
  var isSettledForTesting: Bool { settled }
  var boardFrameForTesting: CGRect? { board?.isHidden == false ? board?.frame : nil }

  private var hasDrawings: Bool { drawnCount > 0 }

  /// Everything the answers have drawn, in order: the new ones go up.
  func draw(_ strokes: [AskBolttyStroke]) {
    if strokes.count < drawnCount { clearDrawings() }
    guard isVisible || strokes.isEmpty else { return }
    for stroke in strokes.dropFirst(drawnCount) {
      if let frame = stroke.frame {
        if !screenFrame.contains(CGPoint(x: frame.midX, y: frame.midY)),
           let screen = Self.screen(containing: CGPoint(x: frame.midX, y: frame.midY)) {
          place(on: screen)
        }
        drawing.draw(stroke.shape, in: frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY))
      } else {
        guard let board = showBoard() else { continue }
        boardDrawing.draw(stroke.shape, in: board.bounds.insetBy(dx: Self.boardInset, dy: Self.boardInset))
      }
    }
    drawnCount = strokes.count
  }

  private func clearDrawings() {
    drawing.clear()
    boardDrawing.clear()
    drawnCount = 0
    board?.isHidden = true
    unsettle()
    stopDismissMonitor()
  }

  /// The board, put up beside the face where there is room, and kept there.
  private func showBoard() -> PaletteGlassHost? {
    if let board, !board.isHidden { return board }
    let host: PaletteGlassHost
    if let board {
      host = board
    } else {
      let content = NSView()
      content.wantsLayer = true
      content.layer?.backgroundColor = Self.bubbleShade.cgColor
      content.layer?.cornerRadius = Self.boardCornerRadius
      content.layer?.cornerCurve = .continuous
      content.layer?.addSublayer(boardDrawing)
      host = PaletteGlassHost(content: content, cornerRadius: Self.boardCornerRadius, style: .bolttyAI)
      host.translatesAutoresizingMaskIntoConstraints = true
      root.addSubview(host, positioned: .below, relativeTo: face)
      board = host
    }
    let side = Self.boardSide
    let space = CGRect(origin: .zero, size: screenFrame.size)
    let anchor = (bubble?.isHidden == false ? bubble?.frame : nil) ?? face?.frame
      ?? CGRect(x: space.midX, y: space.midY, width: 0, height: 0)
    var x = anchor.maxX + Self.boardGap
    if x + side > space.maxX - Self.edgeMargin {
      x = min(anchor.minX, face?.frame.minX ?? anchor.minX) - Self.boardGap - side
    }
    let y = anchor.midY - side / 2
    let frame = CGRect(
      x: min(max(x, Self.edgeMargin), space.maxX - Self.edgeMargin - side),
      y: min(max(y, Self.edgeMargin), space.maxY - Self.edgeMargin - side),
      width: side, height: side)
    host.frame = CGRect(x: snap(frame.minX), y: snap(frame.minY), width: side, height: side)
    // A glass host takes its corner when it is set: set it again on a new size.
    host.cornerRadius = Self.boardCornerRadius
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    boardDrawing.frame = CGRect(origin: .zero, size: frame.size)
    CATransaction.commit()
    host.isHidden = false
    if !MotionPreferences.reduceMotion {
      host.alphaValue = 0
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Motion.standard
        host.animator().alphaValue = 1
      }
    }
    return host
  }

  /// The answer is over and it drew: the face and its words go, the
  /// drawings stay, and a click or Escape anywhere takes them away.
  private func settle() {
    guard !settled, let panel, panel.isVisible else { return }
    settled = true
    blips.stop()
    let parts: [NSView] = [face, bubble].compactMap { $0 }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = MotionPreferences.reduceMotion ? 0 : Motion.quick
      for part in parts { part.animator().alphaValue = 0 }
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.settled else { return }
        for part in parts { part.isHidden = true }
        self.stopTicking()
      }
    }
    startDismissMonitor()
  }

  private func unsettle() {
    guard settled else { return }
    settled = false
    for part in [face, bubble].compactMap({ $0 }) {
      part.isHidden = false
      part.alphaValue = 1
    }
    stopDismissMonitor()
  }

  private func startDismissMonitor() {
    guard dismissMonitor == nil else { return }
    dismissMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    ) { [weak self] event in
      guard event.type != .keyDown || event.keyCode == 53 else { return }
      MainActor.assumeIsolated { self?.hide() }
    }
  }

  private func stopDismissMonitor() {
    if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
    dismissMonitor = nil
  }

  /// Back to the pointer: the answer is over, or a new question began.
  func release() {
    mode = .following
    hideMarker()
  }

  func hide() {
    hideWork?.cancel()
    hideWork = nil
    guard let panel, panel.isVisible else { return }
    guard !MotionPreferences.reduceMotion else { return finishHiding() }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Motion.quick
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.panel?.alphaValue == 0 else { return }
        self.finishHiding()
      }
    }
  }

  private func finishHiding() {
    blips.stop()
    panel?.orderOut(nil)
    stopTicking()
    trail.clear()
    release()
    clearDrawings()
    position = nil
  }

  // MARK: - Pure geometry

  /// Where the face wants to be for a pointer at `pointer`: past the arrow,
  /// turned to the other side of it near an edge so it stays on the screen.
  static func followGoal(for pointer: CGPoint, in screen: CGRect) -> CGPoint {
    let reach = faceSide / 2 + edgeMargin
    var x = pointer.x + pointerOffset.dx
    var y = pointer.y + pointerOffset.dy
    if x + reach > screen.maxX { x = pointer.x - pointerOffset.dx }
    if y - reach < screen.minY { y = pointer.y - pointerOffset.dy }
    return clamp(CGPoint(x: x, y: y), inset: reach, in: screen)
  }

  /// Beside the spot, as the face stands beside the pointer; never over it.
  static func landing(beside target: CGPoint, in screen: CGRect) -> CGPoint {
    let reach = faceSide / 2 + edgeMargin
    var x = target.x + landingOffset.dx
    var y = target.y + landingOffset.dy
    if x + reach > screen.maxX { x = target.x - landingOffset.dx }
    if y - reach < screen.minY { y = target.y - landingOffset.dy }
    return clamp(CGPoint(x: x, y: y), inset: reach, in: screen)
  }

  /// The bubble beside the face: to its right where it fits, else to its
  /// left, centred on it and kept on the screen.
  static func bubbleFrame(size: CGSize, beside face: CGRect, in screen: CGRect) -> CGRect {
    var x = face.maxX + bubbleGap
    if x + size.width > screen.maxX - edgeMargin {
      x = face.minX - bubbleGap - size.width
    }
    x = min(max(x, screen.minX + edgeMargin), screen.maxX - edgeMargin - size.width)
    var y = face.midY - size.height / 2
    y = min(max(y, screen.minY + edgeMargin), screen.maxY - edgeMargin - size.height)
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
  }

  /// A flight's arc: a quadratic curve lifted above the straight line by a
  /// share of its length, so the face hops there rather than slides.
  static func flightPoint(from: CGPoint, to: CGPoint, progress t: CGFloat) -> CGPoint {
    let distance = hypot(to.x - from.x, to.y - from.y)
    let lift = min(180, distance * 0.35)
    let control = CGPoint(x: (from.x + to.x) / 2, y: max(from.y, to.y) + lift)
    let u = 1 - t
    return CGPoint(
      x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
      y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
  }

  static func flightDuration(from: CGPoint, to: CGPoint) -> CFTimeInterval {
    let distance = Double(hypot(to.x - from.x, to.y - from.y))
    return min(0.8, max(0.4, 0.35 + distance / 2400))
  }

  private static func clamp(_ point: CGPoint, inset: CGFloat, in screen: CGRect) -> CGPoint {
    let box = screen.insetBy(dx: inset, dy: inset)
    guard !box.isNull, box.width > 0, box.height > 0 else { return point }
    return CGPoint(x: min(max(point.x, box.minX), box.maxX), y: min(max(point.y, box.minY), box.maxY))
  }

  private static func lightColours(of look: MascotLook) -> [NSColor] {
    look.palette.light(atLeast: AgentPaletteMetrics.screenSelectionLightness)
  }

  private static func screen(containing point: CGPoint) -> NSScreen? {
    NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
  }

  // MARK: - Building

  private func build(agent: AgentId?) {
    let look = MascotLook.face(for: agent)
    if panel != nil {
      if agent != self.agent {
        self.agent = agent
        face?.apply(look: look)
        trail.colours = Self.lightColours(of: look)
        drawing.colours = trail.colours
        boardDrawing.colours = trail.colours
      }
      return
    }
    self.agent = agent
    trail.colours = Self.lightColours(of: look)
    drawing.colours = trail.colours
    boardDrawing.colours = trail.colours
    root.layer?.addSublayer(drawing)

    root.wantsLayer = true
    root.layer?.masksToBounds = false
    root.layer?.addSublayer(trail)
    marker.fillColor = nil
    marker.lineWidth = Self.markerLineWidth
    marker.isHidden = true
    root.layer?.addSublayer(marker)

    let content = NSView()
    content.wantsLayer = true
    content.layer?.backgroundColor = Self.bubbleShade.cgColor
    content.layer?.cornerCurve = .continuous
    shade = content
    label.font = Self.bubbleFont
    label.textColor = PaletteInk.primary
    label.cell?.truncatesLastVisibleLine = true
    label.isSelectable = false
    label.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.bubblePadding.width),
      label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.bubblePadding.width),
      label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
    ])
    let bubble = PaletteGlassHost(content: content, cornerRadius: Self.bubbleCornerRadius, style: .bolttyAI)
    bubble.translatesAutoresizingMaskIntoConstraints = true
    root.addSubview(bubble)

    let face = MascotNSView(conversationID: UUID(), look: look)
    face.ownsDisplayLink = true
    root.addSubview(face)

    let panel = PassivePanel(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.contentView = root
    self.panel = panel
    self.face = face
    self.bubble = bubble
  }

  private func appear() {
    guard let panel else { return }
    unsettle()
    if !panel.isVisible || panel.alphaValue < 1 {
      if !panel.isVisible {
        if let screen = Self.screen(containing: pointer()) { place(on: screen) }
        position = Self.followGoal(for: pointer(), in: screenFrame)
        mode = .following
        layoutFace()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = MotionPreferences.reduceMotion ? 0 : Motion.quick
        panel.animator().alphaValue = 1
      }
    }
    startTicking()
  }

  private func place(on screen: NSScreen) {
    guard let panel, screen.frame != screenFrame else { return }
    screenFrame = screen.frame
    backingScale = max(1, screen.backingScaleFactor)
    panel.setFrame(screen.frame, display: false)
    root.frame = CGRect(origin: .zero, size: screen.frame.size)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trail.frame = root.bounds
    trail.contentsScale = backingScale
    marker.contentsScale = backingScale
    drawing.frame = root.bounds
    drawing.contentsScale = backingScale
    boardDrawing.contentsScale = backingScale
    CATransaction.commit()
    trail.clear()
    hideMarker()
    clearDrawings()
  }

  private func linger(_ delay: TimeInterval) {
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if self.hasDrawings, self.phase == .idle { self.settle() } else { self.hide() }
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  // MARK: - The bubble

  /// A step up the ramp from the chat's — read at a glance beside the
  /// pointer.
  static let bubbleFont = roundedAppFont(size: AgentPaletteMetrics.typePrimary, weight: .medium)

  /// Listening, the words still coming are what matter: one line, its start
  /// cut. Otherwise up to `bubbleMaxLines`, wrapped.
  private func setText(_ next: String, quiet: Bool) {
    let listening = phase == .listening
    let lines = listening ? 1 : Self.bubbleMaxLines
    label.textColor = quiet ? PaletteInk.secondary : PaletteInk.primary
    guard next != text || label.maximumNumberOfLines != lines else { return }
    if typesOut {
      typed = Double(Self.carried(from: text, into: next))
      lastBlip = Int(typed)
    } else {
      typed = Double(next.count)
    }
    text = next
    label.maximumNumberOfLines = lines
    label.lineBreakMode = listening ? .byTruncatingHead : .byWordWrapping
    label.stringValue = String(next.prefix(Int(typed)))
    // Measured whole, so the bubble does not grow letter by letter.
    bubbleSize = Self.bubbleSize(for: next, lines: lines)
    // Wrapped at the bubble's own width, not the widest it may be: while an
    // answer typed out, a line that fitted the widest and not the bubble
    // ended in "…" until the next word wrapped it.
    label.preferredMaxLayoutWidth = max(1, bubbleSize.width - Self.bubblePadding.width * 2)
    layoutFace()
  }

  /// How much of `new` was already on screen in `old`: all of it when the
  /// caption grew, the sentence carried over when it moved on.
  static func carried(from old: String, into new: String) -> Int {
    guard !old.isEmpty else { return 0 }
    if new.hasPrefix(old) { return old.count }
    var start = old.startIndex
    while start < old.endIndex {
      let tail = old[start...]
      if new.hasPrefix(tail) { return tail.count }
      start = old.index(after: start)
    }
    return 0
  }

  /// The face's own pitch: the same agent always sounds the same.
  static func basePitch(for agent: AgentId?) -> Double {
    let seed = (agent?.rawValue ?? "boltty").unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }
    return 420 + Double(abs(seed) % 220)
  }

  /// The bubble round `text` at most `lines` tall. Measured by a cell set
  /// up as the label is, so the bubble and the label's own wrapping agree to
  /// the point — a size worked out apart cut the third line short.
  static func bubbleSize(for text: String, lines: Int) -> CGSize {
    guard !text.isEmpty else { return .zero }
    let cell = NSTextFieldCell(textCell: text)
    cell.font = bubbleFont
    cell.wraps = lines > 1
    cell.isScrollable = false
    cell.truncatesLastVisibleLine = true
    cell.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingHead
    let measured = cell.cellSize(forBounds: NSRect(
      x: 0, y: 0, width: bubbleMaxTextWidth, height: .greatestFiniteMagnitude))
    let height = min(ceil(measured.height), bubbleLineHeight * CGFloat(lines))
    return CGSize(width: min(ceil(measured.width), bubbleMaxTextWidth) + bubblePadding.width * 2,
                  height: max(height, bubbleLineHeight) + bubblePadding.height * 2)
  }

  /// One line of the bubble's words, as the same cell measures it.
  static let bubbleLineHeight: CGFloat = {
    let cell = NSTextFieldCell(textCell: "Ag")
    cell.font = bubbleFont
    return ceil(cell.cellSize.height)
  }()

  // MARK: - The clock

  private func startTicking() {
    guard link == nil else { return }
    lastTick = Motion.now
    let link = root.displayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = MotionPreferences.highFrameRateRange
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  private func stopTicking() {
    link?.invalidate()
    link = nil
  }

  @objc private func tick(_ link: CADisplayLink) {
    let now = Motion.now
    let elapsed = min(0.05, max(0, now - lastTick))
    lastTick = now
    let pointer = self.pointer()
    trail.sweep()
    typeOn(elapsed)
    if phase == .listening {
      onTrace?(pointer)
      trail.extend(to: CGPoint(x: pointer.x - screenFrame.minX, y: pointer.y - screenFrame.minY))
    }
    switch mode {
    case .following:
      if !screenFrame.contains(pointer), let screen = Self.screen(containing: pointer) {
        place(on: screen)
      }
      let goal = Self.followGoal(for: pointer, in: screenFrame)
      guard let current = position, !MotionPreferences.reduceMotion else {
        position = goal
        break
      }
      let share = CGFloat(1 - exp(-elapsed / Self.followTime))
      position = CGPoint(x: current.x + (goal.x - current.x) * share,
                         y: current.y + (goal.y - current.y) * share)
    case let .flying(from, to, start, duration):
      let progress = CGFloat(min(1, (now - start) / duration))
      let eased = Self.flightCurve.value(at: progress)
      position = Self.flightPoint(from: from, to: to, progress: eased)
      if progress >= 1 { mode = .parked(to) }
    case let .parked(spot):
      position = spot
    }
    layoutFace()
  }

  private func typeOn(_ elapsed: CFTimeInterval) {
    guard typesOut, Int(typed) < text.count else { return }
    typed = min(Double(text.count), typed + elapsed * Self.typingSpeed)
    let shown = Int(typed)
    label.stringValue = String(text.prefix(shown))
    guard makesSounds, shown - lastBlip >= 2 else { return }
    lastBlip = shown
    let letter = text[text.index(text.startIndex, offsetBy: shown - 1)]
    guard letter.isLetter || letter.isNumber else { return }
    blips.blip(pitch: Self.basePitch(for: agent) * Double.random(in: 0.88...1.14))
  }

  private var isTyping: Bool { typesOut && Int(typed) < text.count }

  /// Frames are snapped to the screen's pixels and keep their sizes: a face
  /// whose frame rounded outward to 41 one frame and 40 the next reallocated
  /// its Metal drawable as it moved, and the glass relaid itself out.
  private func layoutFace() {
    guard let position, let face, let bubble else { return }
    let side = Self.faceSide
    let bob = isTyping && !MotionPreferences.reduceMotion
      ? Self.bobHeight * CGFloat(abs(sin(Motion.now * 18))) : 0
    let faceFrame = CGRect(
      x: snap(position.x - screenFrame.minX - side / 2),
      y: snap(position.y - screenFrame.minY - side / 2 + bob),
      width: side, height: side)
    if face.frame != faceFrame { face.frame = faceFrame }
    bubble.isHidden = text.isEmpty
    guard !text.isEmpty else { return }
    var bubbleFrame = Self.bubbleFrame(
      size: bubbleSize, beside: faceFrame, in: CGRect(origin: .zero, size: screenFrame.size))
    bubbleFrame.origin = CGPoint(x: snap(bubbleFrame.minX), y: snap(bubbleFrame.minY))
    guard bubble.frame != bubbleFrame else { return }
    let resized = bubble.frame.size != bubbleFrame.size
    bubble.frame = bubbleFrame
    if resized {
      let corner = min(Self.bubbleCornerRadius, bubbleFrame.height / 2)
      bubble.cornerRadius = corner
      shade?.layer?.cornerRadius = corner
    }
  }

  private func snap(_ value: CGFloat) -> CGFloat {
    (value * backingScale).rounded() / backingScale
  }

  // MARK: - The marker

  private func showMarker(at location: CGPoint) {
    let local = CGPoint(x: location.x - screenFrame.minX, y: location.y - screenFrame.minY)
    let radius = Self.markerRadius
    let colour = trail.colours.first ?? .white
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    marker.removeAllAnimations()
    marker.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
    marker.position = local
    marker.path = CGPath(ellipseIn: marker.bounds.insetBy(dx: Self.markerLineWidth / 2,
                                                          dy: Self.markerLineWidth / 2), transform: nil)
    marker.strokeColor = colour.cgColor
    marker.fillColor = colour.withAlphaComponent(0.18).cgColor
    marker.isHidden = false
    CATransaction.commit()
    guard !MotionPreferences.reduceMotion else { return }
    let arrive = CABasicAnimation(keyPath: "transform.scale")
    arrive.fromValue = 0.4
    arrive.toValue = 1
    arrive.duration = Motion.standard
    arrive.timingFunction = Motion.emphasizedCurve
    marker.add(arrive, forKey: "arrive")
    let pulse = CABasicAnimation(keyPath: "opacity")
    pulse.fromValue = 1
    pulse.toValue = 0.45
    pulse.duration = 0.8
    pulse.autoreverses = true
    pulse.repeatCount = .infinity
    pulse.beginTime = CACurrentMediaTime() + Motion.standard
    marker.add(pulse, forKey: "pulse")
  }

  private func hideMarker() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    marker.removeAllAnimations()
    marker.isHidden = true
    CATransaction.commit()
  }
}

/// The panel's content: AppKit's own coordinates, origin at the bottom left,
/// so a global point less the screen's origin is a place in it.
final class AskBolttyOverlayRootView: NSView {
  override var isFlipped: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
