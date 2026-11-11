import AppKit

enum MascotSpec {
  static let designBox: CGFloat = 32

  static let seed: UInt32 = 488_462
  static let speed = 2.0

  static let eyeSize = 0.73
  static let eyeSpacing = 7.0
  static let eyeBridge = CGPoint(x: 16, y: 14.4)

  static let gradientRate = 0.9

  static let pointerRadiusInAvatars: CGFloat = 3
}

struct MascotRandom {
  private var state: UInt32

  init(seed: UInt32) { state = seed }

  mutating func next() -> Double {
    state = state &+ 0x6D2B_79F5
    var t = (state ^ (state >> 15)) &* (1 | state)
    t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
    return Double(t ^ (t >> 14)) / 4_294_967_296.0
  }
}

enum MascotEmotion: Equatable {
  case curious
  case listening
  case thinking
  case focused
  case concerned
  case sad
  case sleeping

  init(executionState: ConversationExecutionState) {
    switch executionState {
    case .idle: self = .curious
    case .working: self = .thinking
    case .waiting: self = .concerned
    case .failed: self = .sad
    case .interrupted, .rateLimited: self = .concerned
    }
  }

  init(reportedState: AgentReportedState?) {
    switch reportedState {
    case .none, .finished: self = .curious
    case .running: self = .thinking
    case .blocked: self = .concerned
    case .failed: self = .sad
    }
  }
}

@MainActor
final class MascotClock {
  static let shared = MascotClock()

  private(set) var time = 0.0
  private(set) var gradientTime = 0.0

  private var timer: Timer?
  private var lastTick: CFAbsoluteTime = 0
  private var members: [WeakMascot] = []

  private struct WeakMascot {
    weak var view: MascotNSView?
  }

  func join(_ view: MascotNSView) {
    guard !members.contains(where: { $0.view === view }) else { return }
    members.append(WeakMascot(view: view))
    startIfNeeded()
  }

  func leave(_ view: MascotNSView) {
    members.removeAll { $0.view === view || $0.view == nil }
    if members.isEmpty { stop() }
  }

  private func startIfNeeded() {
    guard timer == nil else { return }
    lastTick = Motion.now
    // A display link was measured worse than this timer: the test bundle
    // slowed and animation tests lost the main run loop.
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    let now = Motion.now
    let delta = min(now - lastTick, 1.0 / 30.0)
    lastTick = now

    members.removeAll { $0.view == nil }
    if members.isEmpty { stop(); return }

    time += delta
    gradientTime += delta * MascotSpec.speed * MascotSpec.gradientRate

    for member in members { member.view?.advance(delta) }
  }
}

@MainActor
final class MascotNSView: NSView {
  private let canvas = MascotCanvas()
  private var skipsThisDraw = false

  private var phase: Double
  private var palette: MascotPalette
  private var shape: MascotShape
  private var finish: MascotFinish

  private var motion: MascotMotion

  private(set) var lastFrame: MascotRenderer.Frame?
  fileprivate var isTicking: Bool?

  var ownsDisplayLink = false

  var renderScale: CGFloat? {
    didSet { canvas.scaleOverride = renderScale; render() }
  }
  private var link: CADisplayLink?
  private var linkLast: CFTimeInterval = 0
  private var ownGradientTime = 0.0

  var onBeat: ((Bool) -> Void)?

  var lookAtWindowPoint: CGPoint?

  // MARK: Going to rest, and waking

  private(set) var awake = 1.0
  private var swaysAboutRest = false
  private var swayTime = 0.0
  private var wakeFrom = 1.0
  private var wakeTo = 1.0
  private var wakeElapsed = 0.0
  private var wakeDuration = 0.0
  private var onWakeSettled: (() -> Void)?

  private static let swayReach = 4.0
  private static let swayPeriod = 12.0

  func restAsPicture(of identity: UUID) {
    var stream = Self.stream(for: identity)
    phase = stream.next() * 90
    swaysAboutRest = true
    awake = 0
    wakeFrom = 0
    wakeTo = 0
    wakeElapsed = 0
    wakeDuration = 0
    onWakeSettled = nil
    render()
  }

  func transition(toAwake target: Double, over duration: Double, completion: (() -> Void)? = nil) {
    onWakeSettled = nil
    wakeFrom = awake
    wakeTo = target
    wakeElapsed = 0
    wakeDuration = max(0, duration)
    guard duration > 0 else {
      awake = target
      render()
      return
    }
    onWakeSettled = completion
  }

  private var isWaking: Bool { wakeElapsed < wakeDuration }

  fileprivate func stepWake(_ elapsed: Double) -> (() -> Void)? {
    guard isWaking else { return nil }
    wakeElapsed += elapsed
    let progress = min(1, wakeElapsed / wakeDuration)
    awake = wakeFrom + (wakeTo - wakeFrom) * progress * progress * (3 - 2 * progress)
    guard progress >= 1 else { return nil }
    defer { onWakeSettled = nil }
    return onWakeSettled
  }

  var reduceMotion = false {
    didSet { if reduceMotion != oldValue { updateMembership() } }
  }

  var emotion: MascotEmotion = .curious {
    didSet {
      guard emotion != oldValue else { return }
      motion.setEmotion(emotion)
      render()
    }
  }

  override var isFlipped: Bool { true }

  func reseed(conversationID: UUID, palette: MascotPalette) {
    var stream = Self.stream(for: conversationID)
    phase = stream.next() * 90
    apply(palette: palette)
  }

  func apply(palette: MascotPalette) {
    self.palette = palette
    render()
  }

  var paletteID: String { palette.id }

  func apply(shape: MascotShape) {
    guard shape != self.shape else { return }
    self.shape = shape
    render()
  }

  var look: MascotLook { MascotLook(shape: shape, palette: palette, finish: finish) }

  func apply(look: MascotLook) {
    guard look != self.look else { return }
    palette = look.palette
    shape = look.shape
    finish = look.finish
    render()
  }

  func reseed(conversationID: UUID, look: MascotLook) {
    var stream = Self.stream(for: conversationID)
    phase = stream.next() * 90
    palette = look.palette
    shape = look.shape
    finish = look.finish
    render()
  }

  convenience init(conversationID: UUID) {
    self.init(conversationID: conversationID, palette: .forConversation(conversationID))
  }

  convenience init(conversationID: UUID, look: MascotLook) {
    self.init(conversationID: conversationID, palette: look.palette, shape: look.shape, finish: look.finish)
  }

  init(
    conversationID: UUID, palette: MascotPalette, shape: MascotShape = .hex,
    finish: MascotFinish = .velvet
  ) {
    var stream = Self.stream(for: conversationID)
    phase = stream.next() * 90
    self.palette = palette
    self.shape = shape
    self.finish = finish
    motion = MascotMotion(random: stream, emotion: .curious)

    super.init(frame: .zero)
    wantsLayer = true
    layer?.isOpaque = false
    layer?.backgroundColor = NSColor.clear.cgColor
    canvas.autoresizingMask = [.width, .height]
    addSubview(canvas)
  }

  private static func stream(for conversationID: UUID) -> MascotRandom {
    MascotRandom(seed: MascotSpec.seed &+ (fingerprint(conversationID) &* 971))
  }

  required init?(coder: NSCoder) { nil }

  private static func fingerprint(_ id: UUID) -> UInt32 {
    withUnsafeBytes(of: id.uuid) { bytes in
      bytes.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }
  }

  static let overscan: CGFloat = 0.3

  override func layout() {
    super.layout()
    let room = min(bounds.width, bounds.height) * Self.overscan
    canvas.frame = bounds.insetBy(dx: -room, dy: -room)
    render()
  }

  var isActing: Bool { motion.isActing }

  func poke(_ reaction: MascotReaction? = nil) {
    guard !reduceMotion else { return }
    motion.poke(reaction)
  }

  func nod() {
    guard !reduceMotion else { return }
    motion.nod()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    render()
  }

  // MARK: Testing seams

  var lastReactionForTesting: MascotReaction? { motion.lastReaction }

  var drawnTopStopForTesting: simd_float4 { canvas.drawnTopStopForTesting }

  var canvasAvoidsOffscreenPassForTesting: Bool { canvas.avoidsOffscreenPassForTesting }

  func snapshot(scale: CGFloat = 2, overscan: Bool = false) -> CGImage? {
    guard var frame = lastFrame ?? (bounds.isEmpty ? nil : currentFrame()) else { return nil }
    if !overscan { frame.overscan = 0 }
    return MascotRenderer.shared?.image(of: MascotRenderer.uniforms(for: frame, rays: 4), scale: scale)
  }
}

// MARK: - Motion

extension MascotNSView {
  func advance(_ elapsed: Double) {
    guard !reduceMotion else { render(); return }
    if let pointer = pointerOffset() {
      motion.setPointer(x: pointer.x, y: pointer.y, strength: pointer.strength)
    } else {
      motion.setPointer(x: 0, y: 0, strength: 0)
    }
    let beats = motion.beats
    motion.update(elapsed)
    if motion.beats != beats { onBeat?(motion.lastBeatIsBig) }
    var settled: (() -> Void)?
    var changesAwake = false
    if swaysAboutRest {
      swayTime += elapsed
      changesAwake = isWaking
      settled = stepWake(elapsed)
    }
    if bounds.width < MascotRenderer.largeFaceSide, !motion.isActing, !changesAwake {
      skipsThisDraw.toggle()
      if skipsThisDraw { return }
    }
    render()
    settled?()
  }

  private func pointerOffset() -> (x: Double, y: Double, strength: Double)? {
    func offset(of windowPoint: NSPoint) -> (dx: Double, dy: Double, d: Double) {
      let inView = convert(windowPoint, from: nil)
      let dx = (inView.x - bounds.midX) / bounds.width
      let dy = (inView.y - bounds.midY) / bounds.width
      return (dx, dy, (dx * dx + dy * dy).squareRoot())
    }
    if let target = lookAtWindowPoint, window != nil, !bounds.isEmpty {
      let (dx, dy, d) = offset(of: target)
      return (dx / max(1, d), dy / max(1, d), 1)
    }
    guard let window, NSApp.isActive, !bounds.isEmpty else { return nil }
    let (dx, dy, d) = offset(of: window.mouseLocationOutsideOfEventStream)
    let reach = MascotSpec.pointerRadiusInAvatars
    let strength = d < 1 ? 1 : d > reach ? 0 : 1 - (d - 1) / (reach - 1)
    return (dx / max(1, d), dy / max(1, d), strength)
  }

  func render() {
    guard !bounds.isEmpty else { return }
    let frame = currentFrame()
    lastFrame = frame
    canvas.show(MascotRenderer.uniforms(for: frame))
  }

  func currentFrame() -> MascotRenderer.Frame {
    let still = reduceMotion
    let pose: MascotMotionPose
    if still || (swaysAboutRest && awake < 1) {
      var resting = motion
      resting.settle()
      pose = still ? resting.pose : .blend(resting.pose, motion.pose, awake)
    } else {
      pose = motion.pose
    }
    let scale = renderScale ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let clock: Double
    if still {
      clock = phase
    } else if swaysAboutRest {
      clock = phase + Self.swayReach * awake * sin(swayTime * 2 * .pi / Self.swayPeriod)
    } else {
      clock = (ownsDisplayLink ? ownGradientTime : MascotClock.shared.gradientTime) + phase
    }
    return frame(for: pose, clock: clock, scale: scale)
  }

  func still(_ pose: MascotMotionPose, scale: CGFloat) async -> CGImage? {
    guard !bounds.isEmpty, let renderer = MascotRenderer.shared else { return nil }
    let frame = frame(for: pose, clock: phase, scale: scale)
    return await renderer.render(MascotRenderer.uniforms(for: frame, rays: 4), scale: scale)
  }

  private func frame(for pose: MascotMotionPose, clock: Double, scale: CGFloat) -> MascotRenderer.Frame {
    let bridgeY = MascotSpec.designBox / 2 - MascotSpec.eyeBridge.y
    let eyes = (0..<2).map { index -> MascotRenderer.Eye in
      let side = index == 0 ? -1.0 : 1.0
      return MascotRenderer.Eye(
        centre: CGPoint(
          x: side * MascotSpec.eyeSpacing / 2 + pose.gazeX,
          y: bridgeY + pose.gazeY
        ),
        turn: 0,
        shape: pose.eyes[index]
      )
    }

    return MascotRenderer.Frame(
      size: bounds.size,
      pixelSize: 1 / max(scale, 1),
      pose: MascotRenderer.Pose(
        yaw: pose.yaw, pitch: pose.pitch, roll: pose.roll,
        sx: pose.sx, sy: pose.sy, lift: -pose.rise
      ),
      eyes: eyes,
      clock: clock,
      phase: phase,
      palette: palette,
      shape: shape,
      overscan: Self.overscan,
      finish: finish
    )
  }
}

// MARK: - Visibility

extension MascotNSView {
  private func updateMembership() {
    let visible = window?.occlusionState.contains(.visible) == true
      && !isHiddenOrHasHiddenAncestor
      && !visibleRect.isEmpty
    if visible && !reduceMotion {
      if ownsDisplayLink { startLink() } else { MascotClock.shared.join(self) }
      isTicking = true
    } else {
      stopLink()
      MascotClock.shared.leave(self)
      if isTicking != false { render() }
      isTicking = false
    }
  }

  func leaveClock() {
    stopLink()
    MascotClock.shared.leave(self)
  }

  private func startLink() {
    guard link == nil else { return }
    let link = displayLink(target: self, selector: #selector(linkTick(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    linkLast = Motion.now
    self.link = link
  }

  private func stopLink() {
    link?.invalidate()
    link = nil
  }

  @objc private func linkTick(_ link: CADisplayLink) {
    let now = Motion.now
    let delta = min(now - linkLast, 1.0 / 30.0)
    linkLast = now
    ownGradientTime += delta * MascotSpec.speed * MascotSpec.gradientRate
    advance(delta)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    if let window {
      NotificationCenter.default.addObserver(
        self, selector: #selector(visibilityChanged),
        name: NSWindow.didChangeOcclusionStateNotification, object: window
      )
    }
    if let clip = enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(visibilityChanged),
        name: NSView.boundsDidChangeNotification, object: clip
      )
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(reduceMotionChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
    )
    updateMembership()
  }

  @objc private func reduceMotionChanged(_ notification: Notification) {
    reduceMotion = MotionPreferences.refreshReduceMotion()
  }

  override func viewDidHide() { super.viewDidHide(); updateMembership() }
  override func viewDidUnhide() { super.viewDidUnhide(); updateMembership() }

  @objc private func visibilityChanged(_ notification: Notification) {
    updateMembership()
  }
}
