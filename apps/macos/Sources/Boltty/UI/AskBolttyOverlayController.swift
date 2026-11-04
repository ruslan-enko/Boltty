import AppKit

/// Ask Boltty on the screen, beside the pointer, as heyclicky draws it: the
/// answering agent's face rides just past the arrow with the sentence being
/// said in a bubble beside it; and when the answer
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
  /// One sentence is in the bubble at a time (`AskBolttySession.caption`);
  /// this is room for a long one at the bubble's size.
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

  // MARK: State

  private enum Mode: Equatable {
    case following
    case flying(from: CGPoint, to: CGPoint, start: CFTimeInterval, duration: CFTimeInterval)
    /// From the panel to the pointer, which may move on the way.
    case arriving(from: CGPoint, start: CFTimeInterval, duration: CFTimeInterval)
    case parked(CGPoint)
  }

  /// Where the pointer is; tests hand in their own.
  var pointer: () -> CGPoint = { NSEvent.mouseLocation }

  private var panel: PassivePanel?
  private let root = AskBolttyOverlayRootView()
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
  /// "Thinking…", a problem: words that are there at once.
  private let label = NSTextField(wrappingLabelWithString: "")
  /// The answer: its words arrive as the listening capsule's do.
  private let answerWords = ListeningWordsView(frame: .zero)

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
  /// The bubble as drawn, chasing `bubbleSize` as the words come.
  private var shownBubbleSize: CGSize = .zero
  /// The chase's time constant.
  static let bubbleGrowthTime: CFTimeInterval = 0.09
  /// The size the whole sentence will take, known before its words have come.
  private var wholeBubbleSize: CGSize = .zero
  private var bubbleSide = BubbleSide.right
  /// From the face's left edge to the bubble's, as drawn: gliding after a
  /// change of side; nil until first laid out, when it starts where it belongs.
  private var shownBubbleLead: CGFloat?
  /// The glide to the face's other side.
  static let bubbleSideTime: CFTimeInterval = 0.12
  private var lastBlip = 0
  private let blips = AskBolttyBlips()
  /// Settings › General › Sounds.
  var makesSounds = true
  /// A voice is saying this answer: the words still type out, without blips
  /// over it.
  var isSaidAloud = false
  /// The panel came or went: Escape is held only while it is here.
  var onVisibleChange: (() -> Void)?
  /// The answer is over and the face waits by the pointer a moment, words gone.
  private var resting = false
  /// The question has gone and the panel's face is still going: nothing shows
  /// until it has (`arrive`).
  private var holdsForArrival = false
  /// Where the next face to appear flies in from.
  private var arrival: CGPoint?
  /// The words are going back into the face; the bubble empties once they have.
  private var retractWork: DispatchWorkItem?
  /// The last "Thinking…" state, for laying the shimmer out once there is a bubble.
  private var wordsAreQuiet = false
  /// How long the face waits after an answer. Not for good: Escape is held
  /// from other apps while it is here.
  static let restAfterAnswer: TimeInterval = 12
  /// The panel's face against this one, which it starts the flight as.
  static var arrivalScale: CGFloat { AgentPaletteMetrics.listeningFaceSize / faceSide }
  /// How much bigger it is at the top of the arc.
  static let flightSwell: CGFloat = 0.15
  static let typingSpeed: Double = 38
  static let bobHeight: CGFloat = 2.5
  /// Measured when the words change, never per frame.
  private var bubbleSize: CGSize = .zero
  /// "Thinking…" wears a band of the face's light sweeping
  /// across them, as a working chat's row does in the list: something is
  /// under way. Masked by the words' silhouette, cut when the words change.
  private let shimmer = CALayer()
  private let shimmerWords = CALayer()
  private let shimmerBand = CAGradientLayer()
  private var shimmerCut: String?
  var isShimmeringForTesting: Bool { !shimmer.isHidden && shimmerBand.animation(forKey: "sweep") != nil }

  var isVisible: Bool { panel?.isVisible == true }
  /// The face itself is here: not only what it drew, and not on its way out.
  var isFaceUp: Bool { isVisible && !settled && panel?.alphaValue == 1 }
  var textForTesting: String { typesOut ? answerWords.text : label.stringValue }
  var facePositionForTesting: CGPoint? { position }
  var bubbleSizeForTesting: CGSize { bubbleSize }
  var faceFrameForTesting: CGRect? { face?.frame }
  var isPointingForTesting: Bool {
    switch mode {
    case .following, .arriving: return false
    case .flying, .parked: return true
    }
  }

  // MARK: - What Ask Boltty says

  func show(_ phase: AskBolttySession.Phase, caption: String, agent: AgentId?) {
    // Already over: a repeat of it must not cut the rest short.
    if phase == .idle, resting { return }
    let previous = self.phase
    self.phase = phase
    hideWork?.cancel()
    let next: String
    let emotion: MascotEmotion
    var lingering: TimeInterval?
    switch phase {
    case .idle:
      guard isVisible else { return }
      if case .following = mode {
        linger(Self.lingerAfterAnswer)
      } else {
        linger(Self.lingerAfterPointing)
      }
      return
    case .thinking:
      next = "Thinking…"
      emotion = .thinking
      // A new question: the last answer's place and drawings go.
      if previous != .thinking {
        release()
        clearDrawings()
      }
    case .speaking:
      next = caption.isEmpty ? text : caption
      emotion = .focused
    case let .needsYou(message):
      // Said, then gone: the chat waits in Boltty, not beside the pointer.
      next = message
      emotion = .concerned
      lingering = Self.lingerAfterProblem
    case let .failed(message):
      next = message
      emotion = .sad
      lingering = Self.lingerAfterProblem
    }
    build(agent: agent)
    face?.emotion = emotion
    // Speaking with no sentence reached yet: "Thinking…" stands until one is.
    let waiting = phase == .thinking || (phase == .speaking && caption.isEmpty)
    typesOut = phase == .speaking && !caption.isEmpty
    setText(next, quiet: waiting)
    if !holdsForArrival { appear() }
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
      setFaceScale(1)
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

  /// The answer is over and the face waits a moment: its words go, it comes
  /// back to the pointer, and a click or Escape takes it away.
  private func rest() {
    resting = true
    release()
    face?.emotion = .curious
    startDismissMonitor()
    linger(Self.restAfterAnswer)
    typesOut = false
    guard !MotionPreferences.reduceMotion, !text.isEmpty else {
      setText("", quiet: false)
      return
    }
    // Into the face: the bubble draws back to it as its words fade.
    let seed = Self.bubbleFirstLineHeight
    bubbleSize = CGSize(width: seed, height: seed)
    wholeBubbleSize = bubbleSize
    let duration = Motion.scaled(Motion.standard)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = Motion.standardCurve
      for part in [bubble, answerWords, label].compactMap({ $0 as NSView? }) {
        part.animator().alphaValue = 0
      }
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.setText("", quiet: false)
      self.restoreBubble()
    }
    retractWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
  }

  /// Calls off a bubble going back into the face, and stands it up again.
  private func restoreBubble() {
    retractWork?.cancel()
    retractWork = nil
    for part in [bubble, answerWords, label].compactMap({ $0 as NSView? }) {
      part.layer?.removeAllAnimations()
      part.alphaValue = 1
    }
  }

  private func startDismissMonitor() {
    guard dismissMonitor == nil else { return }
    dismissMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.hide() }
    }
  }

  private func stopDismissMonitor() {
    if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
    dismissMonitor = nil
  }

  /// Back to the pointer: the answer is over, or a new question began.
  func release() {
    if case .arriving = mode {} else { mode = .following }
    hideMarker()
  }

  func hide() {
    hideWork?.cancel()
    hideWork = nil
    guard let panel, panel.isVisible else { return }
    guard !MotionPreferences.reduceMotion else { return finishHiding() }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Motion.standard
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
    stopDismissMonitor()
    panel?.orderOut(nil)
    stopTicking()
    resting = false
    arrival = nil
    restoreBubble()
    setFaceScale(1)
    mode = .following
    release()
    clearDrawings()
    position = nil
    onVisibleChange?()
  }

  /// A question is going in: whatever it says waits for `arrive`.
  func holdForArrival() {
    holdsForArrival = true
    arrival = nil
  }

  /// The panel's face has gone: this one takes up from `point` (AppKit's
  /// global coordinates) and flies to the pointer, with whatever was held back.
  func arrive(from point: CGPoint?) {
    holdsForArrival = false
    arrival = point
    guard panel != nil, phase != .idle else { return }
    appear()
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

  enum BubbleSide { case right, left }

  /// The widest a bubble can be, with room for any sentence.
  static var bubbleMaxWidth: CGFloat { bubbleMaxTextWidth + bubblePadding.width * 2 }
  /// A bubble of one line of the answer's words.
  static let bubbleFirstLineHeight =
    ceil(AgentPaletteMetrics.listeningWordsFontSize * AgentPaletteMetrics.listeningWordsLineSpacing)
    + bubblePadding.height * 2

  /// The side the bubble stands on: it stays until the widest bubble no longer
  /// fits there, whatever this sentence's length, so it does not swap sides
  /// from one sentence to the next or as the pointer wanders near an edge.
  static func bubbleSide(current: BubbleSide, beside face: CGRect, in screen: CGRect) -> BubbleSide {
    let fitsRight = face.maxX + bubbleGap + bubbleMaxWidth <= screen.maxX - edgeMargin
    let fitsLeft = face.minX - bubbleGap - bubbleMaxWidth >= screen.minX + edgeMargin
    switch current {
    case .right: return fitsRight || !fitsLeft ? .right : .left
    case .left: return fitsLeft || !fitsRight ? .left : .right
    }
  }

  /// From the face's left edge to the bubble's. On the left the bubble stands
  /// at its whole sentence's width, since the words hang from its left edge
  /// and an edge that grew would carry them along.
  static func bubbleLead(on side: BubbleSide, wholeWidth: CGFloat) -> CGFloat {
    switch side {
    case .right: return faceSide + bubbleGap
    case .left: return -bubbleGap - wholeWidth
    }
  }

  /// The bubble beside the face: its first line level with the face and its
  /// top where it stays as lines are added below. Kept on the screen by the
  /// whole sentence's size, so it does not move as the words reach an edge.
  static func bubbleFrame(
    size: CGSize, whole: CGSize, lead: CGFloat, beside face: CGRect, in screen: CGRect
  ) -> CGRect {
    let width = max(size.width, whole.width)
    let height = max(size.height, whole.height)
    let x = min(max(face.minX + lead, screen.minX + edgeMargin), screen.maxX - edgeMargin - width)
    let top = min(
      max(face.midY + bubbleFirstLineHeight / 2, screen.minY + edgeMargin + height),
      screen.maxY - edgeMargin)
    return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
  }

  /// Slow away, slow in: how far along a flight it is at `t` of its time.
  static func flightEase(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

  /// A flight's arc: a quadratic curve lifted above the straight line by a
  /// share of its length, so the face hops there rather than slides. A low
  /// one: lifted further, a long flight looped up off the page and back.
  static func flightPoint(from: CGPoint, to: CGPoint, progress t: CGFloat) -> CGPoint {
    let distance = hypot(to.x - from.x, to.y - from.y)
    let lift = min(80, distance * 0.2)
    let control = CGPoint(x: (from.x + to.x) / 2, y: max(from.y, to.y) + lift)
    let u = 1 - t
    return CGPoint(
      x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
      y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
  }

  static func flightDuration(from: CGPoint, to: CGPoint) -> CFTimeInterval {
    let distance = Double(hypot(to.x - from.x, to.y - from.y))
    return min(1.1, max(0.55, distance / 900))
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
        paintShimmer(look)
        answerWords.colors = VoiceEdgeGlowLayout.rayColors(from: look.palette)
        drawing.colours = Self.lightColours(of: look)
        boardDrawing.colours = drawing.colours
      }
      return
    }
    self.agent = agent
    drawing.colours = Self.lightColours(of: look)
    boardDrawing.colours = drawing.colours
    root.layer?.addSublayer(drawing)

    root.wantsLayer = true
    root.layer?.masksToBounds = false
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
    answerWords.translatesAutoresizingMaskIntoConstraints = true
    answerWords.isCentred = false
    answerWords.wrapWidth = Self.bubbleMaxTextWidth
    answerWords.colors = VoiceEdgeGlowLayout.rayColors(from: look.palette)
    answerWords.isHidden = true
    content.addSubview(answerWords)
    shimmer.mask = shimmerWords
    shimmer.isHidden = true
    shimmerBand.startPoint = CGPoint(x: 0, y: 0.5)
    shimmerBand.endPoint = CGPoint(x: 1, y: 0.5)
    shimmer.addSublayer(shimmerBand)
    content.layer?.addSublayer(shimmer)
    paintShimmer(look)
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
    resting = false
    restoreBubble()
    unsettle()
    stopDismissMonitor()
    if !panel.isVisible || panel.alphaValue < 1 {
      if !panel.isVisible {
        if let screen = Self.screen(containing: pointer()) { place(on: screen) }
        position = Self.followGoal(for: pointer(), in: screenFrame)
        mode = .following
        layoutFace()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        onVisibleChange?()
      }
      if willFlyIn {
        panel.alphaValue = 1
      } else {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = MotionPreferences.reduceMotion ? 0 : Motion.quick
          panel.animator().alphaValue = 1
        }
      }
    }
    flyIn()
    startTicking()
  }

  private var willFlyIn: Bool {
    guard let arrival, !MotionPreferences.reduceMotion else { return false }
    return screenFrame.contains(arrival)
  }

  /// The panel's face has just gone: this one takes up where it stood, at its
  /// size there, and is on its way. Its words come once it has landed.
  private func flyIn() {
    defer { arrival = nil }
    guard willFlyIn, let origin = arrival else { return }
    let goal = Self.followGoal(for: pointer(), in: screenFrame)
    position = origin
    setFaceScale(Self.arrivalScale)
    mode = .arriving(
      from: origin, start: Motion.now, duration: Self.flightDuration(from: origin, to: goal))
    layoutFace()
    syncShimmer(wordsAreQuiet)
  }

  /// A transform, not a new frame: a new size would reallocate the face's
  /// drawable on every frame of the flight.
  private func setFaceScale(_ scale: CGFloat) {
    guard let layer = face?.layer else { return }
    let side = Self.faceSide
    let dx = (0.5 - layer.anchorPoint.x) * side
    let dy = (0.5 - layer.anchorPoint.y) * side
    var transform = CATransform3DMakeTranslation(dx, dy, 0)
    transform = CATransform3DScale(transform, scale, scale, 1)
    transform = CATransform3DTranslate(transform, -dx, -dy, 0)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = transform
    CATransaction.commit()
  }

  /// Landed: the bubble comes out of the face.
  private func popBubble() {
    guard !text.isEmpty, let bubble else { return }
    let seed = Self.bubbleFirstLineHeight
    shownBubbleSize = CGSize(width: seed, height: seed)
    shownBubbleLead = Self.bubbleLead(on: bubbleSide, wholeWidth: seed)
    bubble.isHidden = false
    bubble.alphaValue = 0
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Motion.standard
      context.timingFunction = Motion.standardCurve
      bubble.animator().alphaValue = 1
    }
  }

  private var isArriving: Bool {
    if case .arriving = mode { return true }
    return false
  }

  private func place(on screen: NSScreen) {
    guard let panel, screen.frame != screenFrame else { return }
    screenFrame = screen.frame
    backingScale = max(1, screen.backingScaleFactor)
    panel.setFrame(screen.frame, display: false)
    root.frame = CGRect(origin: .zero, size: screen.frame.size)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    marker.contentsScale = backingScale
    drawing.frame = root.bounds
    drawing.contentsScale = backingScale
    boardDrawing.contentsScale = backingScale
    CATransaction.commit()
    hideMarker()
    clearDrawings()
  }

  private func linger(_ delay: TimeInterval) {
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if self.phase == .idle, !self.resting {
        self.rest()
      } else if self.hasDrawings, self.phase == .idle {
        self.settle()
      } else {
        self.hide()
      }
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  // MARK: - The bubble

  /// A step up the ramp from the chat's — read at a glance beside the
  /// pointer.
  static let bubbleFont = roundedAppFont(size: AgentPaletteMetrics.typePrimary, weight: .medium)

  /// Up to `bubbleMaxLines`, wrapped.
  private func setText(_ next: String, quiet: Bool) {
    wordsAreQuiet = quiet
    let lines = Self.bubbleMaxLines
    label.textColor = quiet ? PaletteInk.secondary : PaletteInk.primary
    let wasTyping = !answerWords.isHidden
    label.isHidden = typesOut
    answerWords.isHidden = !typesOut
    guard next != text || wasTyping != typesOut || label.maximumNumberOfLines != lines else { return }
    let isNewSentence = !next.hasPrefix(text) || !wasTyping
    if typesOut {
      typed = Double(Self.carried(from: text, into: next))
      lastBlip = Int(typed)
      // A new sentence takes the last one's place: its words arrive afresh.
      if isNewSentence { answerWords.setText("", animated: false) }
    } else {
      typed = Double(next.count)
      answerWords.setText("", animated: false)
    }
    text = next
    if next.isEmpty {
      shownBubbleSize = .zero
      wholeBubbleSize = .zero
      shownBubbleLead = nil
      bubbleSide = .right
    }
    if typesOut {
      label.stringValue = ""
      let whole = answerWords.measure(next, width: Self.bubbleMaxTextWidth)
      wholeBubbleSize = CGSize(
        width: whole.widest + Self.bubblePadding.width * 2,
        height: CGFloat(max(1, whole.lines)) * answerWords.lineHeight + Self.bubblePadding.height * 2)
      revealWords()
      // On the left the bubble's edge is where the words hang: it is in its
      // place before the first of them comes.
      if isNewSentence, bubbleSide == .left {
        shownBubbleSize = bubbleGoal
        shownBubbleLead = nil
      }
    } else {
      label.maximumNumberOfLines = lines
      label.lineBreakMode = .byWordWrapping
      label.stringValue = next
      bubbleSize = Self.bubbleSize(for: next, lines: lines)
      wholeBubbleSize = bubbleSize
      label.preferredMaxLayoutWidth = max(1, bubbleSize.width - Self.bubblePadding.width * 2)
    }
    layoutFace()
    syncShimmer(quiet)
  }

  /// The words reached so far, whole: the word being typed arrives as it
  /// begins. The bubble is as big as they are, and grows as they come.
  private func revealWords() {
    let shown = text.index(text.startIndex, offsetBy: min(Int(typed), text.count))
    let end = text[shown...].firstIndex(where: \.isWhitespace) ?? text.endIndex
    let reached = String(text[..<end])
    guard reached != answerWords.text else { return }
    answerWords.setText(reached, animated: panel?.isVisible == true)
    let measured = answerWords.measure(width: Self.bubbleMaxTextWidth)
    bubbleSize = CGSize(
      width: measured.widest + Self.bubblePadding.width * 2,
      height: CGFloat(max(1, measured.lines)) * answerWords.lineHeight + Self.bubblePadding.height * 2)
    if shownBubbleSize == .zero { shownBubbleSize = bubbleSize }
  }

  /// The size the bubble is making for: as big as its words, and on the left
  /// as wide as its whole sentence (`bubbleLead`).
  private var bubbleGoal: CGSize {
    CGSize(
      width: bubbleSide == .left ? wholeBubbleSize.width : bubbleSize.width,
      height: bubbleSize.height)
  }

  /// One frame of the bubble's chase toward the size of its words and, after
  /// a change of side, across the face.
  private func growBubble(_ elapsed: CFTimeInterval) {
    let goal = bubbleGoal
    let leadGoal = Self.bubbleLead(on: bubbleSide, wholeWidth: wholeBubbleSize.width)
    guard !MotionPreferences.reduceMotion, shownBubbleSize != .zero, let lead = shownBubbleLead else {
      shownBubbleSize = goal
      shownBubbleLead = leadGoal
      return
    }
    func step(_ from: CGFloat, _ to: CGFloat, time: CFTimeInterval) -> CGFloat {
      abs(to - from) < 0.5 ? to : from + (to - from) * CGFloat(1 - exp(-elapsed / time))
    }
    shownBubbleSize = CGSize(
      width: step(shownBubbleSize.width, goal.width, time: Self.bubbleGrowthTime),
      height: step(shownBubbleSize.height, goal.height, time: Self.bubbleGrowthTime))
    shownBubbleLead = step(lead, leadGoal, time: Self.bubbleSideTime)
  }

  // MARK: - The shimmer

  /// On while the words are the quiet ones: the band crosses the words'
  /// own width, then rests, over and over. Under Reduce Motion nothing moves.
  private func syncShimmer(_ quiet: Bool) {
    guard quiet, !MotionPreferences.reduceMotion, let shade else {
      shimmer.isHidden = true
      shimmerBand.removeAnimation(forKey: "sweep")
      return
    }
    shade.layoutSubtreeIfNeeded()
    let frame = label.frame
    let words = min(frame.width, ceil(label.attributedStringValue.size().width) + 4)
    let band = max(
      AgentPaletteMetrics.resultsShimmerMinimumBand, words * AgentPaletteMetrics.resultsShimmerBandShare)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shimmer.frame = frame
    shimmerWords.frame = shimmer.bounds
    shimmerBand.frame = CGRect(x: -band, y: 0, width: band, height: frame.height)
    CATransaction.commit()
    cutShimmerWords()
    shimmer.isHidden = false
    guard shimmerBand.animation(forKey: "sweep") == nil else { return }
    let sweep = CABasicAnimation(keyPath: "transform.translation.x")
    sweep.fromValue = 0
    sweep.toValue = words + band
    sweep.duration = AgentPaletteMetrics.resultsShimmerSweepDuration
    sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    sweep.fillMode = .both
    let cycle = CAAnimationGroup()
    cycle.animations = [sweep]
    cycle.duration = sweep.duration + AgentPaletteMetrics.resultsShimmerRest
    cycle.repeatCount = .infinity
    shimmerBand.add(cycle, forKey: "sweep")
  }

  /// The face's arrival light, fading out at both ends of the band.
  private func paintShimmer(_ look: MascotLook) {
    let light = look.palette.arrivalLight
    guard let first = light.first, let last = light.last else { return }
    shimmerBand.colors = ([first.withAlphaComponent(0)] + light + [last.withAlphaComponent(0)])
      .map(\.cgColor)
    let inner = AgentPaletteMetrics.resultsShimmerFade
    let steps = max(1, light.count - 1)
    shimmerBand.locations = ([0] + light.indices.map {
      inner + (1 - 2 * inner) * CGFloat($0) / CGFloat(steps)
    } + [1]).map { NSNumber(value: Double($0)) }
  }

  /// The words in white, drawn by the label itself, as the band's mask.
  private func cutShimmerWords() {
    let text = label.stringValue
    guard shimmerCut != text, label.bounds.width > 0, label.bounds.height > 0,
          let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds)
    else { return }
    let ink = label.textColor
    label.textColor = .white
    label.cacheDisplay(in: label.bounds, to: rep)
    label.textColor = ink
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shimmerWords.contents = rep.cgImage
    shimmerWords.contentsScale = backingScale
    CATransaction.commit()
    shimmerCut = text
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
    typeOn(elapsed)
    growBubble(elapsed)
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
      position = Self.flightPoint(from: from, to: to, progress: Self.flightEase(progress))
      if progress >= 1 { mode = .parked(to) }
    case let .arriving(from, start, duration):
      let progress = CGFloat(min(1, (now - start) / duration))
      let goal = Self.followGoal(for: pointer, in: screenFrame)
      let eased = Self.flightEase(progress)
      position = Self.flightPoint(from: from, to: goal, progress: eased)
      // From the panel's size to its own, a little bigger at the top of the arc.
      setFaceScale(
        Self.arrivalScale + (1 - Self.arrivalScale) * eased + Self.flightSwell * sin(progress * .pi))
      if progress >= 1 {
        mode = .following
        setFaceScale(1)
        popBubble()
      }
    case let .parked(spot):
      position = spot
    }
    layoutFace()
  }

  private func typeOn(_ elapsed: CFTimeInterval) {
    guard typesOut, !isArriving, Int(typed) < text.count else { return }
    typed = min(Double(text.count), typed + elapsed * Self.typingSpeed)
    let shown = Int(typed)
    revealWords()
    guard makesSounds, !isSaidAloud, shown - lastBlip >= 2 else { return }
    lastBlip = shown
    let letter = text[text.index(text.startIndex, offsetBy: shown - 1)]
    guard letter.isLetter || letter.isNumber else { return }
    blips.blip(pitch: Self.basePitch(for: agent) * Double.random(in: 0.88...1.14))
  }

  private var isTyping: Bool { typesOut && !isArriving && Int(typed) < text.count }

  /// Frames are snapped to the screen's pixels and keep their sizes: a face
  /// whose frame rounded outward to 41 one frame and 40 the next reallocated
  /// its Metal drawable as it moved, and the glass relaid itself out.
  private func layoutFace() {
    guard let position, let face, let bubble else { return }
    let side = Self.faceSide
    let bob = isTyping && !MotionPreferences.reduceMotion
      ? Self.bobHeight * CGFloat(abs(sin(Motion.now * 18))) : 0
    let resting = CGRect(
      x: snap(position.x - screenFrame.minX - side / 2),
      y: snap(position.y - screenFrame.minY - side / 2),
      width: side, height: side)
    let faceFrame = resting.offsetBy(dx: 0, dy: snap(bob))
    if face.frame != faceFrame { face.frame = faceFrame }
    bubble.isHidden = text.isEmpty || isArriving
    guard !text.isEmpty else { return }
    // Beside the face at rest: only the face bobs as it speaks, or the words
    // being read would shake with it.
    let space = CGRect(origin: .zero, size: screenFrame.size)
    bubbleSide = Self.bubbleSide(current: bubbleSide, beside: resting, in: space)
    var bubbleFrame = Self.bubbleFrame(
      size: shownBubbleSize == .zero ? bubbleGoal : shownBubbleSize,
      whole: wholeBubbleSize,
      lead: shownBubbleLead ?? Self.bubbleLead(on: bubbleSide, wholeWidth: wholeBubbleSize.width),
      beside: resting, in: space)
    bubbleFrame.origin = CGPoint(x: snap(bubbleFrame.minX), y: snap(bubbleFrame.minY))
    bubbleFrame.size = CGSize(width: snap(bubbleFrame.width), height: snap(bubbleFrame.height))
    layoutAnswerWords(in: bubbleFrame.size)
    guard bubble.frame != bubbleFrame else { return }
    let resized = bubble.frame.size != bubbleFrame.size
    bubble.frame = bubbleFrame
    if resized {
      let corner = min(Self.bubbleCornerRadius, bubbleFrame.height / 2)
      bubble.cornerRadius = corner
      shade?.layer?.cornerRadius = corner
    }
  }

  /// Hung from the bubble's top left, with room round the words for their
  /// blur. Always as tall as the most lines: the words are placed from the
  /// view's foot, so a view that grew by a line sent every word gliding back
  /// to where it already stood.
  private func layoutAnswerWords(in size: CGSize) {
    guard !answerWords.isHidden else { return }
    let blur = AgentPaletteMetrics.listeningWordBlur
    let height = CGFloat(AgentPaletteMetrics.listeningMaxLines) * answerWords.lineHeight + blur * 2
    let frame = CGRect(
      x: Self.bubblePadding.width - blur,
      y: size.height - Self.bubblePadding.height + blur - height,
      width: Self.bubbleMaxTextWidth + blur * 2,
      height: height)
    if answerWords.frame != frame { answerWords.frame = frame }
  }

  private func snap(_ value: CGFloat) -> CGFloat {
    (value * backingScale).rounded() / backingScale
  }

  // MARK: - The marker

  private func showMarker(at location: CGPoint) {
    let local = CGPoint(x: location.x - screenFrame.minX, y: location.y - screenFrame.minY)
    let radius = Self.markerRadius
    let colour = drawing.colours.first ?? .white
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
