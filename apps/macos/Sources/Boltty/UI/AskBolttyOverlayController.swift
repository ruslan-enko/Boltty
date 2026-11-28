import AppKit

@MainActor
final class AskBolttyOverlayController {
  static let faceSide: CGFloat = 40
  static let pointerOffset = CGVector(dx: 30, dy: -30)
  static let followTime: CFTimeInterval = 0.06
  static let edgeMargin: CGFloat = 8
  static var bubbleGap: CGFloat { live(14) }
  static var bubbleMaxTextWidth: CGFloat { live(340) }
  static var bubblePadding: CGSize {
    CGSize(width: AgentPaletteMetrics.listeningWordsInset, height: AgentPaletteMetrics.listeningWordsBottomInset)
  }
  static var bubbleCornerShare: CGFloat {
    AgentPaletteMetrics.cornerRadius / AgentPaletteMetrics.listeningWordedHeight(
      lines: 1, lineHeight: bubbleFirstLineHeight - bubblePadding.height * 2)
  }
  static func bubbleCorner(height: CGFloat) -> CGFloat {
    min(AgentPaletteMetrics.cornerRadius, height * bubbleCornerShare)
  }

  static let landingOffset = CGVector(dx: 30, dy: -30)

  static let lingerAfterAnswer: TimeInterval = 1
  static let lingerAfterPointing: TimeInterval = 2
  static let lingerAfterProblem: TimeInterval = 4
  static let boardSide: CGFloat = 300
  static let boardInset: CGFloat = 12
  static let boardGap: CGFloat = 16

  private enum Mode: Equatable {
    case following
    case flying(from: CGPoint, to: CGPoint, start: CFTimeInterval, duration: CFTimeInterval)
    case arriving(from: CGPoint, start: CFTimeInterval, duration: CFTimeInterval)
    case parked(CGPoint)
  }

  var pointer: () -> CGPoint = { NSEvent.mouseLocation }

  private var panel: PassivePanel?
  private let root = AskBolttyOverlayRootView()
  private let marker = AskBolttyPointerMark()
  private var markerReach: CGVector?
  private let drawing = AskBolttyDrawingLayer()
  private var board: NSView?
  private let boardDrawing = AskBolttyDrawingLayer()
  private var drawnCount = 0
  private var settled = false
  private var dismissMonitor: Any?
  private var face: MascotNSView?
  private var bubble: PaletteGlassHost?
  private let answerWords = ListeningWordsView(frame: .zero)
  private let keyHints = PaletteKeyHints()
  private var wantedKeyHints: [PaletteKeyHints.Hint] = []
  static let keyHintsGap: CGFloat = 8

  private var phase: AskBolttySession.Phase = .idle
  private var agent: AgentId?
  private var mode = Mode.following
  private var position: CGPoint?
  private var screenFrame: CGRect = .zero
  private var backingScale: CGFloat = 2
  private var link: CADisplayLink?
  private var lastTick: CFTimeInterval = 0
  private var hideWork: DispatchWorkItem?
  private var restHintWork: DispatchWorkItem?
  private var text = ""
  private var typed: Double = 0
  private var typesOut = false
  private var wasTyped = false
  private var shownInk = PaletteInk.primary
  private var shownBubbleSize: CGSize = .zero
  static let bubbleGrowthTime: CFTimeInterval = 0.09
  private var wholeBubbleSize: CGSize = .zero
  private var bubbleSide = BubbleSide.right
  private var shownBubbleLead: CGFloat?
  static let bubbleSideTime: CFTimeInterval = 0.12
  private var lastBlip = 0
  private let blips = AskBolttyBlips()
  var makesSounds = true
  var isSaidAloud = false
  var onVisibleChange: (() -> Void)?
  private var resting = false
  var restHints: (() -> [PaletteKeyHints.Hint])?
  private var shownRestHints: [PaletteKeyHints.Hint] = []
  var usesClearGlass = true {
    didSet {
      guard usesClearGlass != oldValue else { return }
      bubble?.apply(surfaceStyle: glassStyle)
    }
  }
  private var glassStyle: PaletteSurfaceStyle { .bolttyAIPrompt(clearGlass: usesClearGlass) }
  var region: CGRect?
  private var drawnFrames: [CGRect] = []
  static let restHintTime: TimeInterval = 5
  private var holdsForArrival = false
  private var arrival: CGPoint?
  private var retractWork: DispatchWorkItem?
  private var wordsAreQuiet = false
  static let restAfterAnswer: TimeInterval = 12
  static var arrivalScale: CGFloat { AgentPaletteMetrics.listeningFaceSize / faceSide }
  static let flightSwell: CGFloat = 0.15
  static let typingSpeed: Double = 38
  static let bobHeight: CGFloat = 2.5
  private var bubbleSize: CGSize = .zero
  private let shimmer = ShimmerBand()
  private var shimmerCut: String?

  var isVisible: Bool { panel?.isVisible == true }
  var isFaceUp: Bool { isVisible && !settled && panel?.alphaValue == 1 }
  var textForTesting: String { answerWords.text }
  var keyHintsForTesting: [PaletteKeyHints.Hint] { keyHints.isHidden ? [] : keyHints.hints }
  var bubbleForTesting: (isHidden: Bool, alpha: CGFloat, wordsAlpha: CGFloat, frame: CGRect) {
    (bubble?.isHidden ?? true, bubble?.alphaValue ?? 0, answerWords.alphaValue, bubble?.frame ?? .zero)
  }

  func show(_ phase: AskBolttySession.Phase, caption: String, agent: AgentId?, step: String? = nil) {
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
      next = step ?? String(localized: "Thinking…")
      emotion = .thinking
      if previous == .idle {
        release()
        clearDrawings()
      }
    case .speaking:
      next = caption.isEmpty ? text : caption
      emotion = .focused
    case let .needsYou(message):
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
    let waiting = phase == .thinking || (phase == .speaking && caption.isEmpty)
    typesOut = phase == .speaking && !caption.isEmpty
    setText(next, quiet: waiting)
    if !holdsForArrival { appear() }
    if let lingering { linger(lingering) }
  }

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
    showMarker(at: location, faceAt: landing)
    startTicking()
  }

  private var hasDrawings: Bool { drawnCount > 0 }

  func draw(_ strokes: [AskBolttyStroke]) {
    if strokes.count < drawnCount { clearDrawings() }
    guard isVisible || strokes.isEmpty else { return }
    for stroke in strokes.dropFirst(drawnCount) {
      if let frame = stroke.frame {
        if !screenFrame.contains(CGPoint(x: frame.midX, y: frame.midY)),
           let screen = Self.screen(containing: CGPoint(x: frame.midX, y: frame.midY)) {
          place(on: screen)
        }
        let space = frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        drawing.draw(stroke.shape, in: space)
        if let path = AskBolttyDrawingLayer.path(of: stroke.shape, in: space) {
          drawnFrames.append(path.boundingBoxOfPath)
        }
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
    drawnFrames = []
    board?.isHidden = true
    unsettle()
    stopDismissMonitor()
  }

  private func showBoard() -> NSView? {
    if let board, !board.isHidden { return board }
    let host: NSView
    if let board {
      host = board
    } else {
      host = NSView()
      host.wantsLayer = true
      host.layer?.masksToBounds = false
      host.layer?.addSublayer(boardDrawing)
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
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    boardDrawing.frame = CGRect(origin: .zero, size: frame.size)
    CATransaction.commit()
    host.isHidden = false
    return host
  }

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

  private func rest() {
    resting = true
    if !isPointing { release() }
    face?.emotion = .curious
    startDismissMonitor()
    linger(Self.restAfterAnswer)
    typesOut = false
    guard !MotionPreferences.reduceMotion, !text.isEmpty else {
      setText("", quiet: false)
      showRestHint()
      return
    }
    retractBubble { [weak self] in self?.showRestHint() }
  }

  private func showRestHint() {
    guard resting, let hints = restHints?(), !hints.isEmpty else { return }
    shownRestHints = hints
    layoutKeyHints()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.resting else { return }
      self.shownRestHints = []
      self.layoutKeyHints()
    }
    restHintWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.restHintTime, execute: work)
  }

  private func retractBubble(then done: (() -> Void)? = nil) {
    let seed = Self.bubbleFirstLineHeight
    bubbleSize = CGSize(width: seed, height: seed)
    wholeBubbleSize = bubbleSize
    let duration = Motion.scaled(Motion.standard)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = Motion.standardCurve
      for part in [bubble, answerWords].compactMap({ $0 as NSView? }) {
        part.animator().alphaValue = 0
      }
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.setText("", quiet: false)
      self.restoreBubble()
      done?()
    }
    retractWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
  }

  private func restoreBubble() {
    retractWork?.cancel()
    retractWork = nil
    restHintWork?.cancel()
    restHintWork = nil
    shownRestHints = []
    for part in [bubble, answerWords].compactMap({ $0 as NSView? }) {
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

  func release() {
    if case .arriving = mode {} else { mode = .following }
    hideMarker()
  }

  private var isPointing: Bool {
    switch mode {
    case .flying, .parked: true
    case .following, .arriving: false
    }
  }

  func giveWay() {
    hideWork?.cancel()
    hideWork = nil
    if hasDrawings { settle() } else { hide() }
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

  func holdForArrival() {
    holdsForArrival = true
    arrival = nil
  }

  func arrive(from point: CGPoint?) {
    holdsForArrival = false
    arrival = point
    guard panel != nil, phase != .idle else { return }
    appear()
  }

  static func followGoal(for pointer: CGPoint, in screen: CGRect) -> CGPoint {
    let reach = faceSide / 2 + edgeMargin
    var x = pointer.x + pointerOffset.dx
    var y = pointer.y + pointerOffset.dy
    if x + reach > screen.maxX { x = pointer.x - pointerOffset.dx }
    if y - reach < screen.minY { y = pointer.y - pointerOffset.dy }
    return clamp(CGPoint(x: x, y: y), inset: reach, in: screen)
  }

  static func landing(beside target: CGPoint, in screen: CGRect) -> CGPoint {
    let reach = faceSide / 2 + edgeMargin
    var x = target.x + landingOffset.dx
    var y = target.y + landingOffset.dy
    if x + reach > screen.maxX { x = target.x - landingOffset.dx }
    if y - reach < screen.minY { y = target.y - landingOffset.dy }
    return clamp(CGPoint(x: x, y: y), inset: reach, in: screen)
  }

  enum BubbleSide { case right, left }

  static var bubbleMaxWidth: CGFloat { bubbleMaxTextWidth + bubblePadding.width * 2 }
  static var bubbleFirstLineHeight: CGFloat {
    ceil(AgentPaletteMetrics.listeningWordsFontSize * AgentPaletteMetrics.listeningWordsLineSpacing)
      + bubblePadding.height * 2
  }

  static func bubbleSide(
    current: BubbleSide, beside face: CGRect, in screen: CGRect,
    clear: [CGRect] = [], height: CGFloat = 0
  ) -> BubbleSide {
    let fitsRight = face.maxX + bubbleGap + bubbleMaxWidth <= screen.maxX - edgeMargin
    let fitsLeft = face.minX - bubbleGap - bubbleMaxWidth >= screen.minX + edgeMargin
    if fitsRight, fitsLeft, !clear.isEmpty {
      let top = face.midY + bubbleFirstLineHeight / 2
      func covers(_ side: BubbleSide) -> Bool {
        let width = bubbleGap + bubbleMaxWidth
        let room = CGRect(
          x: side == .right ? face.maxX : face.minX - width, y: top - height, width: width, height: height)
        return clear.contains { $0.intersects(room) }
      }
      let other: BubbleSide = current == .right ? .left : .right
      if covers(current), !covers(other) { return other }
    }
    switch current {
    case .right: return fitsRight || !fitsLeft ? .right : .left
    case .left: return fitsLeft || !fitsRight ? .left : .right
    }
  }

  static func bubbleLead(on side: BubbleSide, wholeWidth: CGFloat) -> CGFloat {
    switch side {
    case .right: return faceSide + bubbleGap
    case .left: return -bubbleGap - wholeWidth
    }
  }

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

  static func flightEase(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

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
    root.wantsLayer = true
    root.layer?.addSublayer(drawing)
    root.layer?.masksToBounds = false
    root.layer?.addSublayer(marker)

    let content = NSView()
    content.wantsLayer = true
    answerWords.translatesAutoresizingMaskIntoConstraints = true
    answerWords.isCentred = false
    answerWords.wrapWidth = Self.bubbleMaxTextWidth
    answerWords.colors = VoiceEdgeGlowLayout.rayColors(from: look.palette)
    content.addSubview(answerWords)
    shimmer.isHidden = true
    answerWords.wantsLayer = true
    answerWords.layer?.addSublayer(shimmer)
    paintShimmer(look)
    let bubble = PaletteGlassHost(content: content, cornerRadius: Self.bubbleCorner(height: Self.bubbleFirstLineHeight), style: glassStyle)
    bubble.shadesRim = false
    keyHints.shadesRim = false
    bubble.translatesAutoresizingMaskIntoConstraints = true
    root.addSubview(bubble)

    let face = MascotNSView(conversationID: UUID(), look: look)
    face.ownsDisplayLink = true
    root.addSubview(face)
    root.addSubview(keyHints)

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

  private func popBubble() {
    guard !text.isEmpty, let bubble else { return }
    let seed = Self.bubbleFirstLineHeight
    shownBubbleSize = CGSize(width: seed, height: seed)
    shownBubbleLead = Self.bubbleLead(on: bubbleSide, wholeWidth: seed)
    if !typesOut {
      answerWords.setText("", animated: false, ink: shownInk)
      answerWords.setText(text, animated: true, ink: shownInk)
    }
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
    marker.setScale(backingScale)
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
      guard let self, self.isVisible else { return }
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

  private func setText(_ next: String, quiet: Bool) {
    wordsAreQuiet = quiet
    let ink = quiet ? PaletteInk.secondary : PaletteInk.primary
    guard next != text || wasTyped != typesOut || ink != shownInk else { return }
    let isNewSentence = !next.hasPrefix(text) || !wasTyped
    let animates = next != text && panel?.isVisible == true
    let carried = typesOut && wasTyped ? Self.carried(from: text, into: next) : 0
    wasTyped = typesOut
    shownInk = ink
    text = next
    typed = Double(typesOut ? carried : next.count)
    lastBlip = Int(typed)
    if isNewSentence || !typesOut { answerWords.setText("", animated: false, ink: ink) }
    if !quiet, !next.isEmpty { Self.announce(next) }
    if next.isEmpty {
      shownBubbleSize = .zero
      wholeBubbleSize = .zero
      shownBubbleLead = nil
      bubbleSide = .right
    } else {
      let whole = answerWords.measure(next, width: Self.bubbleMaxTextWidth)
      wholeBubbleSize = Self.bubbleSize(lines: whole.lines, widest: whole.widest, lineHeight: answerWords.lineHeight)
      if typesOut {
        revealWords()
      } else {
        answerWords.setText(next, animated: animates, ink: ink)
        bubbleSize = wholeBubbleSize
      }
      if isNewSentence, bubbleSide == .left {
        shownBubbleSize = bubbleGoal
        shownBubbleLead = nil
      }
    }
    layoutFace()
    syncShimmer(quiet)
  }

  static func bubbleSize(lines: Int, widest: CGFloat, lineHeight: CGFloat) -> CGSize {
    CGSize(
      width: widest + bubblePadding.width * 2,
      height: CGFloat(max(1, lines)) * lineHeight + bubblePadding.height * 2)
  }

  private static func announce(_ words: String) {
    guard NSWorkspace.shared.isVoiceOverEnabled else { return }
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }

  private func revealWords() {
    let shown = text.index(text.startIndex, offsetBy: min(Int(typed), text.count))
    let end = text[shown...].firstIndex { $0.isWhitespace || ListeningWordsView.standsAlone($0) } ?? text.endIndex
    let reached = String(text[..<end])
    guard reached != answerWords.text else { return }
    answerWords.setText(reached, animated: panel?.isVisible == true)
    let measured = answerWords.measure(width: Self.bubbleMaxTextWidth)
    bubbleSize = Self.bubbleSize(lines: measured.lines, widest: measured.widest, lineHeight: answerWords.lineHeight)
    if shownBubbleSize == .zero { shownBubbleSize = bubbleSize }
  }

  private var bubbleGoal: CGSize {
    CGSize(
      width: bubbleSide == .left ? wholeBubbleSize.width : bubbleSize.width,
      height: bubbleSize.height)
  }

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

  private func syncShimmer(_ quiet: Bool) {
    guard quiet, !text.isEmpty, !MotionPreferences.reduceMotion else {
      shimmer.isHidden = true
      shimmer.stopSweep()
      return
    }
    let words = answerWords.measure(width: Self.bubbleMaxTextWidth).widest
    let travel = shimmer.lay(
      in: answerWords.bounds, wordsWidth: words, leading: AgentPaletteMetrics.listeningWordBlur)
    if shimmerCut != text {
      shimmer.cut(answerWords.settledWords(scale: backingScale), scale: backingScale)
      shimmerCut = text
      shimmer.stopSweep()
    }
    shimmer.isHidden = false
    shimmer.sweep(across: travel, delay: AgentPaletteMetrics.listeningWordArrival * 0.7)
  }

  private func paintShimmer(_ look: MascotLook) {
    shimmer.paint(look.palette.arrivalLight)
  }

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

  static func basePitch(for agent: AgentId?) -> Double {
    let seed = (agent?.rawValue ?? "boltty").unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }
    return 420 + Double(abs(seed) % 220)
  }

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
      if progress >= 1 {
        mode = .parked(to)
        marker.tap()
      }
    case let .arriving(from, start, duration):
      let progress = CGFloat(min(1, (now - start) / duration))
      let goal = Self.followGoal(for: pointer, in: screenFrame)
      let eased = Self.flightEase(progress)
      position = Self.flightPoint(from: from, to: goal, progress: eased)
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
    placeMarker(from: position)
    bubble.isHidden = text.isEmpty || isArriving
    defer { layoutKeyHints() }
    guard !text.isEmpty else { return }
    let space = CGRect(origin: .zero, size: screenFrame.size)
    let asked = region.map { $0.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }
    bubbleSide = Self.bubbleSide(
      current: bubbleSide, beside: resting, in: space,
      clear: drawnFrames + [asked].compactMap { $0 }, height: wholeBubbleSize.height)
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
      bubble.cornerRadius = Self.bubbleCorner(height: bubbleFrame.height)
    }
  }

  func setKeyHints(_ hints: [PaletteKeyHints.Hint]) {
    wantedKeyHints = hints
    layoutKeyHints()
  }

  private func layoutKeyHints() {
    let wanted = resting ? shownRestHints : wantedKeyHints
    guard !wanted.isEmpty, !isArriving, !settled, let face, let bubble,
          panel?.isVisible == true
    else {
      keyHints.hide()
      return
    }
    keyHints.setHints(wanted)
    let above = bubble.isHidden ? face.frame : face.frame.union(bubble.frame)
    let size = keyHints.size
    let space = CGRect(origin: .zero, size: screenFrame.size)
    var origin = CGPoint(
      x: bubble.isHidden ? face.frame.midX - size.width / 2 : bubble.frame.minX,
      y: above.minY - Self.keyHintsGap - size.height)
    if resting {
      let right = face.frame.maxX + Self.bubbleGap
      let fits = right + size.width <= space.maxX - Self.edgeMargin
      origin = CGPoint(
        x: fits ? right : face.frame.minX - Self.bubbleGap - size.width, y: face.frame.midY - size.height / 2)
    }
    if origin.y < space.minY + Self.edgeMargin { origin.y = above.maxY + Self.keyHintsGap }
    origin.x = min(max(origin.x, Self.edgeMargin), space.maxX - Self.edgeMargin - size.width)
    let frame = CGRect(x: snap(origin.x), y: snap(origin.y), width: size.width, height: size.height)
    if keyHints.frame != frame { keyHints.frame = frame }
    keyHints.show()
  }

  private func layoutAnswerWords(in size: CGSize) {
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

  static func pointerTurn(reach: CGVector) -> CGFloat {
    atan2(reach.dy, reach.dx) - AskBolttyPointerMark.restingAngle
  }

  private func showMarker(at location: CGPoint, faceAt landing: CGPoint) {
    let reach = CGVector(dx: landing.x - location.x, dy: landing.y - location.y)
    markerReach = reach
    let wasShown = !marker.isHidden
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    marker.colours = drawing.colours
    marker.transform = CATransform3DMakeRotation(Self.pointerTurn(reach: reach), 0, 0, 1)
    marker.isHidden = false
    CATransaction.commit()
    placeMarker(from: position ?? landing)
    if !wasShown, !MotionPreferences.reduceMotion { marker.arrive() }
  }

  private func placeMarker(from face: CGPoint) {
    guard let markerReach, !marker.isHidden else { return }
    let tip = CGPoint(
      x: snap(face.x - markerReach.dx - screenFrame.minX),
      y: snap(face.y - markerReach.dy - screenFrame.minY))
    guard marker.position != tip else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    marker.position = tip
    CATransaction.commit()
  }

  private func hideMarker() {
    markerReach = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    marker.removeAllAnimations()
    marker.isHidden = true
    CATransaction.commit()
  }
}

final class AskBolttyPointerMark: CALayer {
  static let side: CGFloat = 18
  static let edgeWidth: CGFloat = 3
  static let restingAngle = -CGFloat.pi / 4

  private let edge = CAShapeLayer()
  private let fill = CAGradientLayer()
  private let fillShape = CAShapeLayer()

  var colours: [NSColor] = [] {
    didSet {
      let shades = colours.isEmpty ? [NSColor.white] : colours
      fill.colors = OklabGradient.cgColors(shades.count > 1 ? shades : shades + shades)
    }
  }

  override init() {
    super.init()
    let side = Self.side
    bounds = CGRect(x: 0, y: 0, width: side, height: side)
    anchorPoint = CGPoint(x: 0, y: 1)
    let outline = Self.outline(side: side)
    edge.frame = bounds
    edge.path = outline.copy(
      strokingWithWidth: Self.edgeWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
    edge.fillColor = NSColor.white.cgColor
    edge.shadowPath = edge.path
    edge.shadowColor = NSColor.black.cgColor
    edge.shadowOpacity = 0.35
    edge.shadowRadius = 3
    edge.shadowOffset = CGSize(width: 0, height: -1)
    addSublayer(edge)
    fillShape.frame = bounds
    fillShape.path = outline
    fill.frame = bounds
    fill.mask = fillShape
    fill.startPoint = CGPoint(x: 0, y: 1)
    fill.endPoint = CGPoint(x: 1, y: 0)
    addSublayer(fill)
    isHidden = true
  }

  override init(layer: Any) { super.init(layer: layer) }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setScale(_ scale: CGFloat) {
    for layer in [self, edge, fill, fillShape] { layer.contentsScale = scale }
  }

  func arrive() {
    let grow = CABasicAnimation(keyPath: "transform.scale")
    grow.fromValue = 0.4
    grow.toValue = 1
    grow.duration = Motion.standard
    grow.timingFunction = Motion.emphasizedCurve
    add(grow, forKey: "arrive")
  }

  func tap() {
    let press = CAKeyframeAnimation(keyPath: "transform.scale")
    press.values = [1, 0.84, 1]
    press.keyTimes = [0, 0.4, 1]
    press.duration = Motion.scaled(0.26)
    press.timingFunction = Motion.standardCurve
    add(press, forKey: "tap")
  }

  static func outline(side: CGFloat) -> CGPath {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * side, y: (1 - y) * side) }
    let corners: [(at: CGPoint, radius: CGFloat)] = [
      (point(0, 0), 2),
      (point(1, 0.38), 1.6),
      (point(0.46, 0.46), 1.5),
      (point(0.38, 1), 1.6),
    ]
    let path = CGMutablePath()
    let last = corners[corners.count - 1].at
    path.move(to: CGPoint(x: (last.x + corners[0].at.x) / 2, y: (last.y + corners[0].at.y) / 2))
    for (index, corner) in corners.enumerated() {
      let next = corners[(index + 1) % corners.count].at
      path.addArc(tangent1End: corner.at, tangent2End: next, radius: corner.radius)
    }
    path.closeSubpath()
    return path
  }
}

final class AskBolttyOverlayRootView: NSView {
  override var isFlipped: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
