import AppKit
import CoreImage.CIFilterBuiltins

@MainActor
final class FirstRunShowController {
  // MARK: - What it says

  static let captions = [
    String(localized: "Ask any agent, from anywhere."),
    String(localized: "Every chat, by agent."),
    String(localized: "Select anything, and ask out loud."),
  ]
  static let closing = String(localized: "Your agents, one key away.")
  static let placeholder = String(localized: "Ask anything")
  static let prompt = String(localized: "Make this launch video small enough to email")
  static let answer = String(localized: "Done — launch.mp4 is 18 MB, down from 240. It’s right next to the original.")
  static let askQuestion = String(localized: "What can I cut here?")
  static let askAnswer = String(localized: "This stretch is silent. You can cut it.")

  // MARK: - Timing

  static let perLetter: TimeInterval = 0.032
  static let pace: TimeInterval = 0.82

  /// `scripts/render-sounds.py`'s tempo, and where its beat comes in.
  static let beat: TimeInterval = 60.0 / 115
  static let musicDrop: TimeInterval = 14 * beat

  // MARK: - Geometry

  static let pile: [(center: CGPoint, side: CGFloat, tilt: CGFloat)] = [
    (CGPoint(x: 0.31, y: 0.64), 0.50, -9),
    (CGPoint(x: 0.71, y: 0.58), 0.44, 11),
    (CGPoint(x: 0.36, y: 0.24), 0.40, 7),
    (CGPoint(x: 0.75, y: 0.20), 0.33, -13),
    (CGPoint(x: 0.56, y: 0.90), 0.27, 5),
  ]

  static func pileFrames(count: Int, center: CGPoint, side: CGFloat) -> [(frame: CGRect, tilt: CGFloat)] {
    let spots = Array(pile.prefix(max(0, min(count, pile.count))))
    guard !spots.isEmpty else { return [] }
    let rects = spots.map { spot in
      CGRect(x: spot.center.x - spot.side / 2, y: spot.center.y - spot.side / 2,
             width: spot.side, height: spot.side)
    }
    let bounds = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
    return zip(rects, spots).map { rect, spot in
      let frame = CGRect(
        x: center.x + (rect.minX - bounds.midX) * side,
        y: center.y + (rect.minY - bounds.midY) * side,
        width: rect.width * side, height: rect.height * side
      )
      return (frame, spot.tilt * .pi / 180)
    }
  }

  /// Where the agents' faces stand round the title, the biggest first.
  static let crowd: [(center: CGPoint, side: CGFloat, tilt: CGFloat)] = [
    (CGPoint(x: 1330, y: 350), 300, 10),
    (CGPoint(x: 1480, y: 700), 250, -9),
    (CGPoint(x: 330, y: 790), 270, 12),
    (CGPoint(x: 900, y: 890), 210, -6),
    (CGPoint(x: 900, y: 265), 190, 7),
  ]


  // MARK: - State

  private let agents: [AgentId]
  private let planned: AgentId
  /// The face the show carries: Boltty's own, where no agent has been chosen.
  private let hero = MascotLook(shape: .hex, palette: .standard)
  private let faceLooks: [AgentId: MascotLook]
  private let screen: NSScreen
  private var backdrop: PassivePanel?
  private var sunset: SunsetView?
  private var stage: PassivePanel?
  private var root: NSView?
  private var clock: ShowClock?
  private var space = ShowSpace(bounds: .zero)
  private var keyMonitor: Any?
  private var run = 0
  private var finished = false
  private var completion: (() -> Void)?

  var onSound: ((InterfaceSounds.FaceSound, Int) -> Void)?
  var onSend: (() -> Void)?
  var onMusic: ((Bool) -> Void)?
  var onEnding: (() -> Void)?
  /// Seconds into the music, `nil` while there is none.
  var musicTime: (() -> TimeInterval?)?
  var isPlaying: Bool { stage != nil && !finished }

  init(agents: [AgentId], planned: AgentId?, on screen: NSScreen) {
    let agents = agents.isEmpty ? AgentHistory.tabOrder : agents
    self.agents = agents
    self.planned = planned.flatMap { agents.contains($0) ? $0 : nil } ?? agents.first ?? .claude
    faceLooks = MascotRoster.load().looks(besides: hero)
    self.screen = screen
  }

  private func faceLook(_ agent: AgentId) -> MascotLook { faceLooks[agent] ?? hero }

  func play(completion: @escaping () -> Void) {
    self.completion = completion
    guard !MotionPreferences.reduceMotion, MascotRenderer.shared != nil else { return finish() }
    build()
    sunset?.dawn()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, !self.finished, event.keyCode == 53 else { return event }
      self.finish()
      return nil
    }
    onMusic?(true)
    after(0.5) { [weak self] in self?.sceneRise() }
  }

  func settle(under window: NSWindow) {
    guard let backdrop else { return }
    backdrop.level = .normal
    backdrop.order(.below, relativeTo: window.windowNumber)
  }

  func dismissBackdrop() {
    guard let backdrop else { return }
    self.backdrop = nil
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Motion.standard
      backdrop.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated { backdrop.orderOut(nil) }
    }
  }

  private func after(_ delay: TimeInterval, _ body: @escaping () -> Void) {
    let run = self.run
    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(delay * Self.pace)) { [weak self] in
      guard let self, self.run == run, !self.finished else { return }
      body()
    }
  }

  /// On the music's next beat, and not before `moment` in it.
  private func onBeat(from moment: TimeInterval = 0, _ body: @escaping () -> Void) {
    guard let now = musicTime?() else { return body() }
    let next = max(moment, (now / Self.beat).rounded(.up) * Self.beat)
    let run = self.run
    DispatchQueue.main.asyncAfter(deadline: .now() + min(1.6, next - now)) { [weak self] in
      guard let self, self.run == run, !self.finished else { return }
      body()
    }
  }

  private func sound(_ kind: InterfaceSounds.FaceSound, _ index: Int) {
    onSound?(kind, index)
  }

  private static func typing(_ words: String) -> TimeInterval {
    perLetter / pace * Double(words.count)
  }

  // MARK: - Windows

  private func build() {
    let frame = screen.frame
    func panel(level: NSWindow.Level) -> PassivePanel {
      let panel = PassivePanel(
        contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
      )
      panel.level = level
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
      panel.appearance = NSAppearance(named: .darkAqua)
      return panel
    }
    let backdrop = panel(level: .statusBar)
    let sunset = SunsetView(
      frame: CGRect(origin: .zero, size: frame.size), sky: hero.palette)
    sunset.onSkip = { [weak self] in self?.finish() }
    backdrop.contentView = sunset
    Motion.applyTimeScale(to: backdrop)
    backdrop.orderFrontRegardless()

    let stage = panel(level: .popUpMenu)
    stage.ignoresMouseEvents = true
    let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
    root.wantsLayer = true
    stage.contentView = root
    let camera = ShowScene(frame: root.bounds)
    root.addSubview(camera)
    self.camera = camera
    let faces = ShowScene(frame: camera.bounds)
    camera.addSubview(faces)
    self.faces = faces

    Motion.applyTimeScale(to: stage)
    stage.orderFrontRegardless()

    self.backdrop = backdrop
    self.sunset = sunset
    self.stage = stage
    self.root = root
    space = ShowSpace(bounds: root.bounds)
    clock = ShowClock(view: root)
  }

  // MARK: - Scene: the face, close

  private var crowd: [ShowFace] = []

  private func square(_ centre: CGPoint, _ side: CGFloat) -> CGRect {
    let middle = space.point(centre.x, centre.y)
    let side = space.v(side)
    return CGRect(x: middle.x - side / 2, y: middle.y - side / 2, width: side, height: side)
  }

  private func sceneRise() {
    guard let clock, let faces else { return }
    let side = space.v(2150)
    let face = ShowFace(in: faces, look: hero, side: side, sharpness: 0.6, clock: clock)
    face.view.turn = SIMD3(0.1, 0.5, 0)
    face.place(at: square(CGPoint(x: 860, y: 2500), 2150), angle: -0.2)
    self.face = face
    let sky = space.point(1500, 80)
    face.view.lookAtWindowPoint = sky
    face.fly(to: square(CGPoint(x: 900, y: 1060), 2150), response: 2.2, angle: -0.12)
    clock.tween(2.6, curve: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1), key: "rise") { t in
      face.view.turn = SIMD3(0.1 - 0.14 * Double(t), 0.5 - 0.6 * Double(t), 0)
    }
    after(1.9) { [weak self] in
      face.view.lookAtWindowPoint = nil
      face.view.emotion = .curious
      self?.sound(.pop, 0)
    }
    after(2.45) { face.view.poke(.wink) }
    after(3.3) { [weak self] in self?.sceneTitle() }
  }

  // MARK: - Scene: the title

  private func sceneTitle() {
    guard let clock, let faces, let face else { return }
    clock.cancel("rise")
    let view = makeScene()
    let scale = min(1.25, max(1, screen.backingScaleFactor))
    face.view.lookAtWindowPoint = nil
    face.spin(0.85, from: face.view.turn) { [weak self] in
      guard let self else { return }
      face.resize(side: self.space.v(420), sharpness: scale)
    }
    face.fly(to: square(CGPoint(x: 560, y: 345), 340), response: 0.7, bounce: 0.14, angle: -0.08)
    sound(.run, 1)

    let words = words(of: String(localized: "This is Boltty"), size: 150, middle: CGPoint(x: 900, y: 584), in: view)
    for (index, word) in words.enumerated() {
      after(0.45 + 0.24 * Double(index)) { [weak self] in
        self?.arrive(word)
        self?.sound(.tap, index)
      }
    }

    let out = 0.5 + 0.24 * Double(words.count)
    for (index, pair) in zip(agents, Self.crowd).enumerated() {
      let (agent, spot) = pair
      let member = ShowFace(in: faces, look: faceLook(agent), side: space.v(spot.side), sharpness: scale,
                            clock: clock)
      member.holder.layer?.zPosition = 900
      member.holder.alphaValue = 0
      member.place(at: square(CGPoint(x: 900, y: 584), spot.side * 0.25))
      crowd.append(member)
      after(out + 0.09 * Double(index)) { [weak self] in
        guard let self else { return }
        ShowClock.fade(member.holder, to: 1, duration: 0.15)
        member.fly(to: self.square(spot.center, spot.side), response: 0.6, bounce: 0.2, angle: spot.tilt * .pi / 180)
        member.spin(0.9)
        self.sound(.pop, index)
      }
      after(out + 1.5 + 0.16 * Double(index)) { member.spin(0.8) }
    }
    after(out + 1.4) { face.spin(0.9) }
    let reactions: [MascotReaction] = [.boing, .wink, .doubleHop, .boing, .wink]
    for index in crowd.indices {
      after(out + 2.1 + 0.08 * Double(index)) { [weak self] in
        guard let self, self.crowd.indices.contains(index) else { return }
        self.crowd[index].view.poke(reactions[index % reactions.count])
      }
    }
    let gone = out + 2.7
    for (index, word) in words.reversed().enumerated() {
      after(gone + 0.1 * Double(index)) {
        ShowBlur.set(word, radius: 16, duration: 0.25)
        ShowClock.fade(word, to: 0, duration: 0.2)
      }
    }
    after(gone) { [weak self] in
      guard let self else { return }
      self.gather(into: self.centre(face.rect))
    }
    after(gone + 0.5) { [weak self] in
      self?.onBeat(from: Self.musicDrop) { [weak self] in
        view.removeFromSuperview()
        self?.sceneWords()
      }
    }
  }

  private func gather(into middle: CGPoint) {
    for (index, member) in crowd.enumerated() {
      after(0.05 * Double(index)) {
        member.spin(0.5)
        member.fly(to: CGRect(x: middle.x - 20, y: middle.y - 20, width: 40, height: 40), response: 0.45)
        ShowClock.fade(member.holder, to: 0, duration: 0.35)
      }
    }
  }

  private func clearCrowd() {
    for member in crowd { member.holder.removeFromSuperview() }
    crowd = []
  }

  private func words(of line: String, size: CGFloat, middle: CGPoint, ink: NSColor = .white,
                     in view: NSView) -> [NSTextField] {
    var size = size
    let whole = ShowText.label(line, size: space.v(size), weight: .semibold)
    whole.sizeToFit()
    size = min(size, size * space.v(1560) / max(1, whole.frame.width))
    let labels = line.split(separator: " ").map { word -> NSTextField in
      let label = ShowText.label(String(word), size: space.v(size), ink: ink, weight: .semibold)
      label.sizeToFit()
      return label
    }
    let gap = space.v(size * 0.22)
    let width = labels.reduce(0) { $0 + $1.frame.width } + gap * CGFloat(max(0, labels.count - 1))
    let centre = space.point(middle.x, middle.y)
    var x = centre.x - width / 2
    for label in labels {
      label.frame.origin = CGPoint(x: x.rounded(), y: (centre.y - label.frame.height / 2).rounded())
      label.alphaValue = 0
      view.addSubview(label)
      x += label.frame.width + gap
    }
    return labels
  }

  private func arrive(_ label: NSTextField, from offset: CGPoint? = nil) {
    let end = label.frame.origin
    let shift = offset ?? CGPoint(x: 0, y: -space.v(40))
    let start = CGPoint(x: end.x + shift.x, y: end.y + shift.y)
    ShowBlur.set(label, radius: 24)
    ShowBlur.set(label, radius: 0, duration: 0.45)
    ShowClock.fade(label, to: 1, duration: 0.2)
    clock?.spring(0.45, bounce: 0.14) { t in label.frame.origin = ShowClock.mix(start, end, t) }
  }

  // MARK: - The camera

  private var camera: NSView?
  private var lens: (scale: CGFloat, focus: CGPoint, place: CGPoint)?

  /// Brings `focus` to `place` (where it stands, with none) at that scale.
  private func zoom(
    to scale: CGFloat, at focus: CGPoint, place: CGPoint? = nil, duration: CFTimeInterval = 1.6,
    curve: CAMediaTimingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.15, 1)
  ) {
    guard let camera, let clock else { return }
    let to = (scale: scale, focus: focus, place: place ?? focus)
    let from = lens ?? (1, focus, focus)
    lens = to
    func offset(_ lens: (scale: CGFloat, focus: CGPoint, place: CGPoint)) -> CGPoint {
      CGPoint(x: lens.place.x - lens.scale * lens.focus.x, y: lens.place.y - lens.scale * lens.focus.y)
    }
    let (start, end) = (offset(from), offset(to))
    clock.tween(duration, curve: curve, key: "camera") { t in
      let s = ShowClock.mix(from.scale, scale, t)
      let p = ShowClock.mix(start, end, t)
      camera.layer?.transform = CATransform3DConcat(
        CATransform3DMakeScale(s, s, 1), CATransform3DMakeTranslation(p.x, p.y, 0))
    }
  }

  private func centre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

  // MARK: - Scenes

  private var scene: NSView?
  private var faces: NSView?
  private var face: ShowFace?
  private var pieces: [AnyObject] = []

  @discardableResult
  private func keep<T: AnyObject>(_ piece: T) -> T {
    pieces.append(piece)
    return piece
  }

  private func makeScene() -> NSView {
    pieces = []
    let view = ShowScene(frame: camera?.bounds ?? root?.bounds ?? .zero)
    if let camera, let faces {
      camera.addSubview(view, positioned: .below, relativeTo: faces)
    } else {
      root?.addSubview(view)
    }
    scene = view
    return view
  }

  private func leave(_ view: NSView) {
    guard let clock else { return }
    let size = view.bounds.size
    let lift = space.v(120)
    clock.tween(0.45, curve: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)) { t in
      view.layer?.transform = ShowClock.transform(size: size, translation: CGPoint(x: 0, y: lift * t),
                                                  scale: 1 - 0.04 * t, rotation: 0)
    }
    ShowClock.fade(view, to: 0, duration: 0.35)
    after(0.55) { view.removeFromSuperview() }
  }

  // MARK: - The field

  private static func tint(_ palette: MascotPalette, l: Double = 0.957, c: Double = 0.05) -> NSColor {
    Oklab(hue: palette.stops[0].h, chroma: c, l: l).color(fitting: true)
  }

  private static let paper = OKLCH(0.985, 0.002, 264).color
  private static let ink = NSColor.black

  private func field(_ look: MascotLook) { sunset?.field(Self.tint(look.palette)) }

  // MARK: - Pieces of a scene

  private func label(_ words: String, size: CGFloat, ink: NSColor = .white, weight: NSFont.Weight = .regular,
                     fitting width: CGFloat? = nil) -> NSTextField {
    var label = ShowText.label(words, size: space.v(size), ink: ink, weight: weight)
    label.sizeToFit()
    if let width, label.frame.width > space.v(width) {
      label = ShowText.label(words, size: space.v(size) * space.v(width) / label.frame.width, ink: ink, weight: weight)
      label.sizeToFit()
    }
    return label
  }

  /// Leading edge at `x`, its middle at `middle`.
  private func put(_ label: NSTextField, x: CGFloat, middle: CGFloat, in view: NSView) {
    let at = space.point(x, middle)
    label.frame.origin = CGPoint(x: at.x.rounded(), y: (at.y - label.frame.height / 2).rounded())
    view.addSubview(label)
  }

  private var cards = 0

  private func fadeOut(_ view: NSView, _ duration: TimeInterval = 0.25) {
    ShowBlur.set(view, radius: 14, duration: duration)
    ShowClock.fade(view, to: 0, duration: duration)
  }

  /// A line alone on the field, a word at a time, with the face over it.
  private func card(_ line: String, then next: @escaping () -> Void) {
    guard let face else { return }
    sound(.boom, cards)
    cards += 1
    let view = makeScene()
    let words = words(of: line, size: 92, middle: CGPoint(x: 900, y: 640), ink: Self.ink, in: view)
    face.fly(to: square(CGPoint(x: 900, y: 450), 170), response: 0.6, bounce: 0.14)
    face.spin(0.75)
    for (index, word) in words.enumerated() {
      after(0.25 + 0.13 * Double(index)) { [weak self] in
        self?.arrive(word)
        self?.sound(.tap, index)
      }
    }
    let gone = 0.25 + 0.13 * Double(words.count) + 1.0
    for (index, word) in words.enumerated() {
      after(gone + 0.04 * Double(index)) { [weak self] in self?.fadeOut(word, 0.22) }
    }
    after(gone + 0.25) { [weak self] in
      self?.onBeat {
        view.removeFromSuperview()
        next()
      }
    }
  }

  // MARK: - Scene: ask anything

  private func sceneWords() {
    sunset?.field(Self.paper)
    card(Self.captions[0]) { [weak self] in self?.sceneAsk() }
  }

  private func sceneAsk() {
    guard let clock, let face else { return }
    field(hero)
    clearCrowd()
    let view = makeScene()
    let slab = keep(ShowSlab(in: view, space: space, clock: clock, rect: space.rect(815, 499, 170, 170), radius: 85))
    slab.show()
    let wide = space.rect(275, 469, 1250, 230)
    slab.go(to: wide, radius: 115, response: 0.6, bounce: 0.1)
    face.fly(to: square(CGPoint(x: 398, y: 584), 176), response: 0.6, bounce: 0.1)
    sound(.pop, 2)

    let hint = label(Self.placeholder, size: 74, ink: NSColor.white.withAlphaComponent(0.5))
    put(hint, x: 520, middle: 584, in: view)
    hint.alphaValue = 0
    after(0.2) { [weak self] in self?.arrive(hint) }
    let discs = [(BolttyIcon.folder, CGFloat(1262)), (.mic, 1414)].map { icon, x in
      keep(ShowDisc(in: view, space: space, clock: clock, icon: icon, rect: square(CGPoint(x: x, y: 584), 132)))
    }
    for (index, disc) in discs.enumerated() { after(0.3 + 0.08 * Double(index)) { disc.pop() } }

    var t = 0.9
    let walk = agents.count > 1 ? agents : []
    if !walk.isEmpty {
      let cap = keep(ShowDisc(in: view, space: space, clock: clock, words: "⇧ Tab", middle: space.point(900, 820)))
      after(t) { cap.pop() }
      t += 0.45
      for (index, look) in (walk.map { faceLook($0) } + [hero]).enumerated() {
        let words = index < walk.count ? String(localized: "Ask \(walk[index].shortDisplayName)") : Self.placeholder
        after(t + 0.52 * Double(index)) { [weak self] in
          cap.press()
          self?.sound(.pop, index)
          face.spin(0.46) {
            face.view.apply(look: look)
            self?.field(look)
            hint.stringValue = words
            hint.sizeToFit()
          }
        }
      }
      t += 0.52 * Double(walk.count + 1) + 0.35
      after(t - 0.2) { cap.vanish() }
    }

    let typed = label(Self.prompt, size: 74)
    let textWidth = typed.frame.width
    typed.stringValue = ""
    put(typed, x: 520, middle: 584, in: view)
    typed.frame.size.width = textWidth + 4
    let long = CGRect(x: wide.minX, y: wide.minY, width: max(wide.width, space.v(245) + textWidth + space.v(200)),
                      height: wide.height)
    let start = t
    let typing = Self.typing(Self.prompt)
    after(start) { [weak self] in
      guard let self else { return }
      for disc in discs { disc.vanish() }
      self.fadeOut(hint, 0.15)
      slab.go(to: long, radius: self.space.v(115), response: 0.7)
      self.zoom(to: 2.1, at: self.space.point(690, 584), place: self.space.point(900, 584), duration: 0.7)
    }
    for (index, letter) in Self.prompt.enumerated() {
      after(start + 0.35 + Self.perLetter / Self.pace * Double(index)) { [weak self] in
        typed.stringValue += String(letter)
        if index.isMultiple(of: 2) { self?.sound(.tap, index / 2) }
      }
    }
    after(start + 0.75) { [weak self] in
      guard let self else { return }
      let end = CGPoint(x: typed.frame.maxX - self.space.v(150), y: wide.midY)
      self.zoom(to: 2.1, at: end, place: self.space.point(900, 584), duration: max(0.4, typing * Self.pace),
                curve: CAMediaTimingFunction(controlPoints: 0.3, 0.1, 0.5, 1))
    }
    after(start + 0.75 + typing + 0.25) { [weak self] in self?.sceneAnswer(slab: slab, typed: typed) }
  }

  private func sceneAnswer(slab: ShowSlab, typed: NSTextField) {
    guard let clock, let face, let view = scene else { return }
    onSend?()
    zoom(to: 1, at: space.point(900, 584), duration: 0.75)
    slab.go(to: space.rect(275, 339, 1250, 490), radius: space.v(96), response: 0.6, bounce: 0.08)

    let words = label(Self.prompt, size: 52, ink: Self.ink, fitting: 1020)
    let size = CGSize(width: words.frame.width + space.v(96), height: space.v(124))
    let corner = space.point(1525 - 56, 339 + 56)
    let end = CGRect(x: corner.x - size.width, y: corner.y - size.height, width: size.width, height: size.height)
    let bubble = keep(ShowSlab(in: view, space: space, clock: clock, rect: typed.frame.insetBy(dx: -20, dy: -10),
                               radius: space.v(62), fill: .white, casts: false))
    bubble.show()
    bubble.go(to: end, radius: size.height / 2, response: 0.55, bounce: 0.06)
    fadeOut(typed, 0.18)
    words.frame.origin = CGPoint(x: (end.midX - words.frame.width / 2).rounded(),
                                 y: (end.midY - words.frame.height / 2).rounded())
    words.alphaValue = 0
    view.addSubview(words)
    after(0.12) { [weak self] in self?.arrive(words) }

    face.fly(to: square(CGPoint(x: 405, y: 674), 132), response: 0.55, bounce: 0.12)
    face.spin(0.7)
    after(0.95) { [weak self] in
      guard let self else { return }
      face.view.poke(.wink)
      let height = ShowText.height(size: self.space.v(52))
      ShowText.stream(Self.answer, into: view, at: self.space.point(510, 608), width: self.space.v(930),
                      size: self.space.v(52), clock: clock, lineHeight: height * 1.12)
      self.zoom(to: 1.08, at: self.space.point(900, 640), duration: 3)
    }
    after(3.4) { [weak self] in
      guard let self else { return }
      self.zoom(to: 1, at: self.space.point(900, 584), duration: 0.5)
      self.leave(view)
      self.sunset?.field(Self.paper)
      self.after(0.1) { [weak self] in
        self?.onBeat { [weak self] in self?.card(Self.captions[1]) { [weak self] in self?.sceneList() } }
      }
    }
  }

  // MARK: - Scene: the chats

  private func sceneList() {
    guard let clock, let face else { return }
    let look = faceLook(planned)
    field(look)
    let view = makeScene()
    face.fly(to: square(CGPoint(x: 900, y: 584), 30), response: 0.4)
    face.spin(0.4)
    ShowClock.fade(face.holder, to: 0, duration: 0.3)

    let scale = min(1.25, max(1, screen.backingScaleFactor))
    let ring = Self.tint(look.palette)
    let step: CGFloat = 220
    let width = step * CGFloat(agents.count) + 280
    let first = 900 - width / 2 + 140
    let slab = keep(ShowSlab(in: view, space: space, clock: clock, rect: square(CGPoint(x: 900, y: 584), 260),
                             radius: space.v(96)))
    let coins = agents.enumerated().map { index, agent in
      keep(ShowCoin(in: view, space: space, clock: clock, look: faceLook(agent), ring: ring,
                    rect: square(CGPoint(x: first + step * CGFloat(index), y: 584), 280), sharpness: scale))
    }
    let more = keep(ShowDisc(in: view, space: space, clock: clock, icon: .chevronDown, fill: .white, ink: Self.ink,
                             rect: square(CGPoint(x: first + step * CGFloat(agents.count), y: 584), 280)))
    for (index, coin) in coins.enumerated() {
      after(0.03 + 0.1 * Double(index)) { [weak self] in
        coin.pop()
        coin.face.spin(0.7)
        self?.sound(.pop, index)
      }
    }
    var t = 0.03 + 0.1 * Double(coins.count)
    after(t) { more.pop() }
    t += 1.2
    after(t) { [weak self] in
      more.press()
      self?.sound(.tap, 0)
    }
    t += 0.3
    after(t) { [weak self] in
      guard let self else { return }
      more.vanish()
      slab.show()
      slab.go(to: self.space.rect(275, 214, 1250, 740), radius: self.space.v(96), response: 0.6, bounce: 0.08)
      let gap = 1250 / CGFloat(coins.count + 1)
      for (index, coin) in coins.enumerated() {
        coin.go(to: self.square(CGPoint(x: 275 + gap * CGFloat(index + 1), y: 340), 140), index: index)
      }
      self.sound(.run, 1)
    }
    let others = agents.filter { $0 != planned }
    let rows: [(AgentId, String)] = [
      (planned, Self.prompt),
      (others.first ?? planned, String(localized: "Fix the flaky sign-up test")),
      (others.dropFirst().first ?? planned, String(localized: "Draft the launch post")),
    ]
    for (index, row) in rows.enumerated() {
      let middle = 530 + 144 * CGFloat(index)
      after(t + 0.5 + 0.12 * Double(index)) { [weak self] in
        guard let self else { return }
        if index == 0 {
          let chosen = self.keep(ShowSlab(in: view, space: self.space, clock: clock,
                                          rect: self.space.rect(320, middle - 66, 1160, 132), radius: self.space.v(52),
                                          fill: NSColor.white.withAlphaComponent(0.14), casts: false))
          chosen.show()
        }
        let face = ShowStill.face(faceLook(row.0), in: self.square(CGPoint(x: 400, y: middle), 92))
        face.alphaValue = 0
        view.addSubview(face)
        ShowClock.fade(face, to: 1, duration: 0.25)
        let title = self.label(row.1, size: 52, fitting: 940)
        self.put(title, x: 486, middle: middle, in: view)
        title.alphaValue = 0
        self.arrive(title)
      }
    }
    after(t + 1.4) { [weak self] in
      coins.first?.face.view.poke(.wink)
      self?.zoom(to: 1.08, at: self?.space.point(900, 530) ?? .zero, duration: 2.4)
    }
    after(t + 2.9) { [weak self] in
      guard let self else { return }
      self.zoom(to: 1, at: self.space.point(900, 584), duration: 0.5)
      self.leave(view)
      self.sunset?.field(Self.paper)
      face.view.apply(look: self.hero)
      face.place(at: self.square(CGPoint(x: 900, y: 450), 40))
      ShowClock.fade(face.holder, to: 1, duration: 0.2)
      self.after(0.1) { [weak self] in
        self?.onBeat { [weak self] in self?.card(Self.captions[2]) { [weak self] in self?.sceneVoice() } }
      }
    }
  }

  // MARK: - Scene: Ask Boltty

  private func sceneVoice() {
    guard let clock, let face else { return }
    sunset?.field(OKLCH(0.957, 0.034, 62).color)
    let view = makeScene()
    face.fly(to: square(CGPoint(x: 900, y: 470), 30), response: 0.35)
    ShowClock.fade(face.holder, to: 0, duration: 0.15)

    let track = keep(ShowTrack(in: view, space: space, clock: clock, name: "launch.mp4",
                               rect: space.rect(240, 262, 1320, 400)))
    track.pop()
    sound(.run, 2)

    let overlay = ScreenSelectionOverlay(frame: view.bounds)
    overlay.palette = hero.palette.colors.map { colour in
      let lab = Oklab(colour)
      return Oklab(hue: lab.hue, chroma: max(0.13, lab.chroma), l: min(0.7, lab.l)).color(fitting: true)
    }
    view.addSubview(overlay)
    let whole = space.rect(212, 234, 1376, 456)
    let from = CGPoint(x: whole.minX, y: whole.maxY)
    let to = CGPoint(x: whole.maxX, y: whole.minY)
    let pointer = keep(ShowPointer(in: view, space: space))
    let rest = space.point(820, 960)
    after(0.75) {
      pointer.show(at: rest)
      clock.tween(0.55, key: "pointer") { t in pointer.move(to: ShowClock.mix(rest, from, t)) }
    }
    after(1.35) {
      clock.tween(0.8, curve: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1), key: "drag") { t in
        let tip = ShowClock.mix(from, to, t)
        overlay.selection = CGRect(x: from.x, y: tip.y, width: max(1, tip.x - from.x), height: max(1, from.y - tip.y))
        pointer.move(to: tip)
      } done: { overlay.showsHandles = true }
    }

    let height = space.v(168)
    let centre = CGPoint(x: space.point(900, 0).x, y: space.point(0, 830).y)
    func pillRect(_ width: CGFloat) -> CGRect {
      CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
    }
    func faceRect(_ width: CGFloat) -> CGRect {
      let side = height * 0.76
      return CGRect(x: centre.x - width / 2 + (height - side) / 2, y: centre.y - side / 2, width: side, height: side)
    }
    let orb = height
    let heard = space.v(760)
    let pill = keep(ShowSlab(in: view, space: space, clock: clock,
                             rect: CGRect(x: to.x - 4, y: to.y - 4, width: 8, height: 8), radius: 4))
    let wave = keep(ShowWave(in: view, space: space, clock: clock, colours: hero.palette.arrivalLight,
                             rect: CGRect(x: centre.x - heard / 2 + space.v(190), y: centre.y - space.v(52),
                                          width: heard - space.v(260), height: space.v(104))))
    after(2.35) { [weak self] in
      pointer.hide()
      pill.show()
      pill.go(to: pillRect(orb), radius: height / 2, response: 0.5, bounce: 0.18)
      face.place(at: CGRect(x: to.x - 15, y: to.y - 15, width: 30, height: 30))
      face.view.emotion = .listening
      ShowClock.fade(face.holder, to: 1, duration: 0.15)
      face.fly(to: faceRect(orb), response: 0.5, bounce: 0.18)
      self?.sound(.pop, 0)
    }
    after(2.95) {
      pill.go(to: pillRect(heard), radius: height / 2, response: 0.5, bounce: 0.1)
      face.fly(to: faceRect(heard), response: 0.5, bounce: 0.1)
    }
    after(3.15) { wave.start() }

    after(4.4) { [weak self] in
      guard let self else { return }
      wave.stop()
      let question = self.label(Self.askQuestion, size: 60, fitting: 530)
      question.frame.origin = CGPoint(x: centre.x - heard / 2 + self.space.v(182), y: centre.y - question.frame.height / 2)
      question.alphaValue = 0
      view.addSubview(question)
      let asked = question.frame.width + self.space.v(250)
      pill.go(to: pillRect(asked), radius: height / 2, response: 0.45)
      face.fly(to: faceRect(asked), response: 0.45)
      question.frame.origin.x = centre.x - asked / 2 + self.space.v(182)
      self.arrive(question)
      self.after(1.25) { [weak self] in
        guard let self else { return }
        self.onSend?()
        self.fadeOut(question, 0.2)
        overlay.showsHandles = false
        ShowClock.fade(overlay, to: 0, duration: 0.3)
        pill.go(to: pillRect(orb), radius: height / 2, response: 0.4)
        face.fly(to: faceRect(orb), response: 0.4)
        face.view.emotion = .curious
        face.spin(0.8)
      }
      self.after(2.1) { [weak self] in
        guard let self else { return }
        let answer = self.label(Self.askAnswer, size: 56, fitting: 980)
        let said = answer.frame.width + self.space.v(250)
        pill.go(to: pillRect(said), radius: height / 2, response: 0.5, bounce: 0.1)
        face.fly(to: faceRect(said), response: 0.5, bounce: 0.1)
        answer.frame.origin = CGPoint(x: centre.x - said / 2 + self.space.v(182), y: centre.y - answer.frame.height / 2)
        answer.alphaValue = 0
        view.addSubview(answer)
        self.after(0.32) { [weak self] in self?.arrive(answer) }
        self.sound(.bell, 1)
      }
      self.after(2.5) { [weak self] in
        guard let self else { return }
        self.zoom(to: 1.14, at: self.space.point(900, 590), duration: 1.1)
        track.focus(true)
        track.circle()
      }
      self.after(3.4) { face.view.poke(.wink) }
      self.after(5.0) { [weak self] in
        guard let self else { return }
        self.zoom(to: 1, at: self.space.point(900, 584), duration: 0.5)
        self.leave(view)
        self.sunset?.field(Self.paper)
        self.after(0.1) { [weak self] in self?.onBeat { [weak self] in self?.sceneFinale() } }
      }
    }
  }

  // MARK: - Scene: the end

  private func sceneFinale() {
    guard let clock, let faces, let face else { return }
    clearCrowd()
    card(Self.closing) { [weak self] in
      guard let self else { return }
      let view = self.makeScene()
      let scale = min(1.25, max(1, self.screen.backingScaleFactor))
      var line: [AgentId?] = self.agents.map { $0 }
      line.insert(nil, at: line.count / 2)
      let step = min(270, 1500 / CGFloat(line.count))
      let side = step * 0.86
      let first = 900 - step * CGFloat(line.count - 1) / 2
      for (index, agent) in line.enumerated() {
        let rest = self.square(CGPoint(x: first + step * CGFloat(index), y: 584), side)
        let member: ShowFace
        if let agent {
          member = ShowFace(in: faces, look: faceLook(agent), side: self.space.v(side), sharpness: scale,
                            clock: clock)
          member.holder.alphaValue = 0
          member.place(at: rest.offsetBy(dx: 0, dy: -self.space.v(160)))
          self.crowd.append(member)
        } else {
          member = face
        }
        self.after(0.1 + 0.09 * Double(index)) { [weak self] in
          ShowClock.fade(member.holder, to: 1, duration: 0.15)
          member.fly(to: rest, response: 0.5, bounce: 0.24)
          self?.sound(.pop, index)
        }
        self.after(1.0 + 0.13 * Double(index)) { member.spin(0.8) }
      }
      let gone = 1.0 + 0.13 * Double(line.count) + 1.0
      self.after(gone) { [weak self] in
        guard let self else { return }
        self.gather(into: self.space.point(900, 584))
        face.fly(to: self.square(CGPoint(x: 900, y: 584), 380), response: 0.45, bounce: 0.2)
        face.spin(0.8)
        self.onEnding?()
      }
      self.after(gone + 0.75) { [weak self] in
        guard let self else { return }
        let word = self.words(of: "Boltty", size: 170, middle: CGPoint(x: 1020, y: 584), ink: Self.ink, in: view)[0]
        let mark = self.space.v(220)
        face.fly(to: CGRect(x: word.frame.minX - self.space.v(28) - mark, y: word.frame.midY - mark / 2,
                            width: mark, height: mark), response: 0.5, bounce: 0.1)
        self.arrive(word, from: CGPoint(x: -self.space.v(140), y: 0))
      }
      self.after(gone + 1.6) { face.view.poke(.wink) }
      self.after(gone + 2.9) { [weak self] in
        guard let self else { return }
        self.sunset?.field(nil)
        self.leave(view)
        face.leave(by: self.space.v(120))
        self.after(0.45) { [weak self] in self?.finish() }
      }
    }
  }

  // MARK: - The end

  private func finish() {
    guard !finished else { return }
    finished = true
    run += 1
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    clock?.stop()
    onMusic?(false)
    sunset?.ended()
    backdrop?.ignoresMouseEvents = true
    if let stage {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Motion.standard
        stage.animator().alphaValue = 0
      } completionHandler: {
        MainActor.assumeIsolated { stage.orderOut(nil) }
      }
    }
    let completion = self.completion
    self.completion = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(0.3)) { [weak self] in
      guard let self else { return }
      self.clearCrowd()
      self.face = nil
      self.pieces = []
      self.scene = nil
      self.faces = nil
      self.camera = nil
      self.stage = nil
      self.root = nil
      completion?()
    }
  }
}

// MARK: - The slides' space

struct ShowSpace {
  let bounds: CGRect
  static let size = CGSize(width: 1800, height: 1169)

  var scale: CGFloat {
    guard bounds.width > 0 else { return 1 }
    return min(bounds.width / Self.size.width, bounds.height / Self.size.height)
  }

  private var origin: CGPoint {
    CGPoint(x: bounds.midX - Self.size.width / 2 * scale, y: bounds.midY - Self.size.height / 2 * scale)
  }

  func v(_ units: CGFloat) -> CGFloat { units * scale }

  func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: origin.x + x * scale, y: origin.y + (Self.size.height - y - height) * scale,
           width: width * scale, height: height * scale)
  }

  func rect(_ r: CGRect) -> CGRect { rect(r.minX, r.minY, r.width, r.height) }

  func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: origin.x + x * scale, y: origin.y + (Self.size.height - y) * scale)
  }
}

// MARK: - The clock

@MainActor
final class ShowClock: NSObject {
  private struct Tween {
    let key: AnyHashable?
    let id: Int
    let start: CFTimeInterval
    let duration: CFTimeInterval
    let value: (CFTimeInterval) -> CGFloat
    let update: (CGFloat) -> Void
    let done: (() -> Void)?
  }

  private var link: CADisplayLink?
  private var tweens: [Tween] = []
  private var nextID = 0
  private weak var view: NSView?

  private func makeID() -> Int {
    nextID += 1
    return nextID
  }

  init(view: NSView) {
    self.view = view
  }

  func tween(_ duration: CFTimeInterval, curve: CAMediaTimingFunction = Motion.emphasizedCurve, key: AnyHashable? = nil,
             _ update: @escaping (CGFloat) -> Void, done: (() -> Void)? = nil) {
    let timing = TimingCurve(curve)
    let length = max(duration, 0.001)
    add(Tween(key: key, id: makeID(), start: Motion.now, duration: length,
              value: { timing.value(at: CGFloat(min(1, $0 / length))) }, update: update, done: done))
  }

  func spring(_ response: CFTimeInterval, bounce: Double = 0, key: AnyHashable? = nil,
              _ update: @escaping (CGFloat) -> Void, done: (() -> Void)? = nil) {
    let omega = 2 * Double.pi / max(response, 0.01)
    let zeta = max(0.05, 1 - min(bounce, 0.95))
    let settle = min(3, 7 / (zeta * omega))
    add(Tween(key: key, id: makeID(), start: Motion.now, duration: settle, value: { t in
      if t >= settle { return 1 }
      let decay = exp(-zeta * omega * t)
      if zeta >= 0.999 { return CGFloat(1 - decay * (1 + omega * t)) }
      let damped = omega * (1 - zeta * zeta).squareRoot()
      return CGFloat(1 - decay * (cos(damped * t) + zeta * omega / damped * sin(damped * t)))
    }, update: update, done: done))
  }

  func drive(key: AnyHashable, _ step: @escaping (CFTimeInterval) -> Bool) {
    var last: CFTimeInterval = 0
    add(Tween(key: key, id: makeID(), start: Motion.now, duration: .infinity, value: { CGFloat($0) },
              update: { [weak self] elapsed in
                let now = CFTimeInterval(elapsed)
                defer { last = now }
                if !step(max(0, now - last)) { self?.cancel(key) }
              }, done: nil))
  }

  func cancel(_ key: AnyHashable) {
    tweens.removeAll { $0.key == key }
  }

  private func add(_ tween: Tween) {
    if let key = tween.key { cancel(key) }
    tweens.append(tween)
    tween.update(0)
    guard link == nil, let view else { return }
    let link = view.displayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = MotionPreferences.highFrameRateRange
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
    tweens = []
  }

  @objc private func tick() {
    let now = Motion.now
    var finished: [Tween] = []
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for tween in tweens {
      guard tweens.contains(where: { $0.id == tween.id }) else { continue }
      let elapsed = now - tween.start
      tween.update(tween.value(elapsed))
      if elapsed >= tween.duration { finished.append(tween) }
    }
    let ended = Set(finished.map(\.id))
    tweens.removeAll { ended.contains($0.id) }
    CATransaction.commit()
    finished.forEach { $0.done?() }
    if tweens.isEmpty {
      link?.invalidate()
      link = nil
    }
  }

  static func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

  static func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: mix(a.x, b.x, t), y: mix(a.y, b.y, t))
  }

  static func mix(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: mix(a.minX, b.minX, t), y: mix(a.minY, b.minY, t),
           width: mix(a.width, b.width, t), height: mix(a.height, b.height, t))
  }

  static func transform(size: CGSize, translation: CGPoint, scale: CGFloat, rotation: CGFloat) -> CATransform3D {
    var t = CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0)
    t = CATransform3DConcat(t, CATransform3DMakeScale(scale, scale, 1))
    t = CATransform3DConcat(t, CATransform3DMakeRotation(rotation, 0, 0, 1))
    t = CATransform3DConcat(t, CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0))
    return CATransform3DConcat(t, CATransform3DMakeTranslation(translation.x, translation.y, 0))
  }

  static func fade(_ layer: CALayer?, to opacity: Float, duration: TimeInterval) {
    guard let layer else { return }
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = (layer.presentation() ?? layer).opacity
    animation.toValue = opacity
    animation.duration = duration
    animation.timingFunction = Motion.standardCurve
    layer.opacity = opacity
    layer.add(animation, forKey: "boltty.show.fade")
  }

  static func fade(_ view: NSView, to alpha: CGFloat, duration: TimeInterval) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      view.animator().alphaValue = alpha
    }
  }
}

// MARK: - Blur

@MainActor
enum ShowBlur {
  private static let key = "filters.blur.inputRadius"
  private static let token = "boltty.show.blurToken"

  static func set(_ view: NSView, radius: CGFloat, duration: TimeInterval = 0) {
    view.wantsLayer = true
    view.layerUsesCoreImageFilters = true
    guard let layer = view.layer else { return }
    if layer.filters?.isEmpty ?? true {
      let blur = CIFilter.gaussianBlur()
      blur.name = "blur"
      blur.radius = 0
      layer.filters = [blur]
    }
    let from = (layer.presentation() ?? layer).value(forKeyPath: key) as? CGFloat ?? 0
    layer.setValue(radius, forKeyPath: key)
    let turn = UUID()
    layer.setValue(turn, forKey: token)
    if duration > 0 {
      let animation = CABasicAnimation(keyPath: key)
      animation.fromValue = from
      animation.toValue = radius
      animation.duration = duration
      animation.timingFunction = Motion.emphasizedCurve
      layer.add(animation, forKey: "boltty.show.blur")
    }
    guard radius == 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(duration + 0.05)) {
      guard (layer.value(forKey: token) as? UUID) == turn else { return }
      layer.filters = nil
    }
  }
}

// MARK: - Pieces

final class ShowScene: NSView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerUsesCoreImageFilters = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
enum ShowText {
  static func label(_ string: String, size: CGFloat, ink: NSColor = .white, weight: NSFont.Weight = .regular)
    -> NSTextField {
    let label = NSTextField(labelWithString: string)
    label.font = roundedAppFont(size: size.rounded(), weight: weight)
    label.textColor = ink
    label.wantsLayer = true
    label.layerUsesCoreImageFilters = true
    return label
  }

  static func height(size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    let probe = label("Ag", size: size, weight: weight)
    probe.sizeToFit()
    return probe.frame.height
  }

  static func lines(_ text: String, width: CGFloat, size: CGFloat) -> [[Substring]] {
    let font = roundedAppFont(size: size.rounded())
    let space = (" " as NSString).size(withAttributes: [.font: font]).width
    var lines: [[Substring]] = [[]]
    var x: CGFloat = 0
    for word in text.split(separator: " ") {
      let wide = (String(word) as NSString).size(withAttributes: [.font: font]).width
      if x > 0, x + wide > width {
        lines.append([])
        x = 0
      }
      lines[lines.count - 1].append(word)
      x += wide + space
    }
    return lines
  }

  static func stream(_ text: String, into view: NSView, at origin: CGPoint, width: CGFloat, size: CGFloat,
                     clock: ShowClock, lineHeight: CGFloat, pinned: NSView.AutoresizingMask = []) {
    let font = roundedAppFont(size: size.rounded())
    let space = (" " as NSString).size(withAttributes: [.font: font]).width
    var index = 0
    for (line, words) in lines(text, width: width, size: size).enumerated() {
      var x: CGFloat = 0
      for word in words {
        let label = Self.label(String(word), size: size)
        label.sizeToFit()
        let end = CGPoint(x: origin.x + x, y: origin.y - CGFloat(line) * lineHeight - label.frame.height)
        label.frame.origin = CGPoint(x: end.x, y: end.y - 8)
        label.alphaValue = 0
        label.autoresizingMask = pinned
        view.addSubview(label)
        x += (String(word) as NSString).size(withAttributes: [.font: font]).width + space
        let delay = Motion.scaled(0.03 * Double(index))
        index += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          ShowBlur.set(label, radius: 12)
          ShowBlur.set(label, radius: 0, duration: 0.45)
          ShowClock.fade(label, to: 1, duration: 0.25)
          let start = label.frame.origin
          clock.spring(0.32, bounce: 0) { t in label.frame.origin = ShowClock.mix(start, end, t) }
        }
      }
    }
  }
}

@MainActor
final class ShowFace {
  let holder = NSView()
  let view: MascotNSView
  private let clock: ShowClock
  private var side: CGFloat

  private struct Pose {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var size: CGFloat = 0
    var angle: CGFloat = 0

    init() {}

    init(_ rect: CGRect, angle: CGFloat) {
      x = rect.midX
      y = rect.midY
      size = rect.width
      self.angle = angle
    }

    var rect: CGRect { CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size) }
  }

  private var pose = Pose()
  private var speed = Pose()
  private var goal = Pose()
  private var response: Double = 0.5
  private var bounce: Double = 0
  private var moving = false

  var lift: CGFloat = 0 {
    didSet { if lift != oldValue { apply() } }
  }

  var onMove: ((CGRect) -> Void)?
  var rect: CGRect { pose.rect.offsetBy(dx: 0, dy: lift) }

  init(in parent: NSView, look: MascotLook, side: CGFloat, sharpness: CGFloat, clock: ShowClock) {
    self.clock = clock
    self.side = side
    view = MascotNSView(conversationID: UUID(), look: look)
    view.ownsDisplayLink = true
    view.renderScale = sharpness
    holder.frame = CGRect(x: 0, y: 0, width: side, height: side)
    holder.wantsLayer = true
    holder.layer?.zPosition = 1000
    view.frame = holder.bounds
    view.autoresizingMask = [.width, .height]
    holder.addSubview(view)
    parent.addSubview(holder)
  }

  func place(at rect: CGRect, angle: CGFloat = 0) {
    stop()
    pose = Pose(rect, angle: angle)
    goal = pose
    speed = Pose()
    apply()
    DispatchQueue.main.async { [weak self] in self?.apply() }
  }

  func fly(to rect: CGRect, response: Double, bounce: Double = 0, angle: CGFloat = 0) {
    goal = Pose(rect, angle: angle)
    self.response = response
    self.bounce = bounce
    guard !moving else { return }
    moving = true
    clock.drive(key: ObjectIdentifier(self)) { [weak self] elapsed in self?.step(elapsed) ?? false }
  }

  /// Once round like a coin; `halfway` is while its back is to the viewer.
  func spin(_ duration: CFTimeInterval, from start: SIMD3<Double> = .zero, halfway: (() -> Void)? = nil) {
    var pending = halfway
    let key = AnyHashable(ObjectIdentifier(view))
    clock.tween(duration, curve: CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1), key: key) { [view] t in
      let t = Double(t)
      view.turn = start * (1 - t) + SIMD3(0, 2 * .pi * t, 0)
      if t >= 0.5, let act = pending {
        pending = nil
        act()
      }
    } done: { [view] in view.turn = .zero }
  }

  func resize(side: CGFloat, sharpness: CGFloat) {
    self.side = side
    view.renderScale = sharpness
    holder.layer?.transform = CATransform3DIdentity
    holder.frame = CGRect(x: 0, y: 0, width: side, height: side)
    view.frame = holder.bounds
    apply()
  }

  func hold(_ rect: CGRect) {
    guard moving else {
      pose = Pose(rect, angle: 0)
      goal = pose
      return apply()
    }
    goal = Pose(rect, angle: goal.angle)
  }

  func leave(by distance: CGFloat) {
    onMove = nil
    lift = 0
    fly(to: pose.rect.offsetBy(dx: 0, dy: distance).insetBy(dx: pose.size * 0.02, dy: pose.size * 0.02),
        response: 0.45)
    ShowClock.fade(holder, to: 0, duration: 0.35)
  }

  private func stop() {
    moving = false
    clock.cancel(ObjectIdentifier(self))
  }

  private func step(_ elapsed: CFTimeInterval) -> Bool {
    guard moving else { return false }
    let omega = 2 * Double.pi / max(response, 0.01)
    let zeta = max(0.05, 1 - min(bounce, 0.95))
    let steps = max(1, Int((elapsed / 0.004).rounded(.up)))
    let h = elapsed / Double(steps)
    func advance(_ x: inout CGFloat, _ v: inout CGFloat, to goal: CGFloat) {
      let pull = -omega * omega * Double(x - goal) - 2 * zeta * omega * Double(v)
      v += CGFloat(pull * h)
      x += v * CGFloat(h)
    }
    for _ in 0..<steps {
      advance(&pose.x, &speed.x, to: goal.x)
      advance(&pose.y, &speed.y, to: goal.y)
      advance(&pose.size, &speed.size, to: goal.size)
      advance(&pose.angle, &speed.angle, to: goal.angle)
    }
    let near = abs(pose.x - goal.x) < 0.3 && abs(pose.y - goal.y) < 0.3 && abs(pose.size - goal.size) < 0.3
      && abs(pose.angle - goal.angle) < 0.002
    let still = abs(speed.x) < 6 && abs(speed.y) < 6 && abs(speed.size) < 6 && abs(speed.angle) < 0.02
    if near && still {
      pose = goal
      speed = Pose()
      moving = false
    }
    apply()
    return moving
  }

  private func apply() {
    let rect = self.rect
    holder.frame = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    holder.layer?.transform = ShowClock.transform(size: holder.frame.size, translation: .zero,
                                                  scale: rect.width / side, rotation: pose.angle)
    onMove?(rect)
  }
}

@MainActor
enum ShowStill {
  static func face(_ look: MascotLook, in rect: CGRect) -> NSImageView {
    let view = NSImageView(frame: rect)
    view.imageScaling = .scaleProportionallyUpOrDown
    if let image = MascotSnapshotCache.image(look, size: rect.width, scale: 2) {
      view.image = NSImage(cgImage: image, size: rect.size)
    }
    return view
  }
}

/// The panel in one flat shape: black, its corner continuous.
@MainActor
final class ShowSlab {
  let view = NSView()
  private let clock: ShowClock
  private var radius: CGFloat
  private var frame: CGRect

  init(in parent: NSView, space: ShowSpace, clock: ShowClock, rect: CGRect, radius: CGFloat,
       fill: NSColor = .black, casts: Bool = true) {
    self.clock = clock
    self.radius = radius
    frame = rect
    view.wantsLayer = true
    view.alphaValue = 0
    view.layer?.cornerCurve = .continuous
    view.layer?.backgroundColor = fill.cgColor
    if casts {
      view.layer?.masksToBounds = false
      view.layer?.shadowColor = NSColor.black.cgColor
      view.layer?.shadowOpacity = 0.16
      view.layer?.shadowRadius = space.v(34)
      view.layer?.shadowOffset = CGSize(width: 0, height: -space.v(22))
    }
    parent.addSubview(view)
    apply(rect, radius)
  }

  private func apply(_ rect: CGRect, _ radius: CGFloat) {
    frame = rect
    self.radius = radius
    view.frame = rect
    view.layer?.applyCorner(min(radius, rect.width / 2, rect.height / 2))
  }

  func show() { ShowClock.fade(view, to: 1, duration: 0.15) }

  func go(to rect: CGRect, radius: CGFloat, response: CFTimeInterval, bounce: Double = 0) {
    let (from, corner) = (frame, self.radius)
    clock.spring(response, bounce: bounce, key: ObjectIdentifier(self)) { [weak self] t in
      self?.apply(ShowClock.mix(from, rect, t), max(0, ShowClock.mix(corner, radius, t)))
    }
  }
}

private extension CALayer {
  func applyCorner(_ radius: CGFloat) { cornerRadius = radius }
}

/// A round button with an icon, or a key with its name.
@MainActor
final class ShowDisc {
  private let view = NSView()
  private let clock: ShowClock

  init(in parent: NSView, space: ShowSpace, clock: ShowClock, icon: BolttyIcon,
       fill: NSColor = NSColor.white.withAlphaComponent(0.13), ink: NSColor = .white, rect: CGRect) {
    self.clock = clock
    stand(in: parent, frame: rect, radius: rect.height / 2, fill: fill)
    let side = rect.height * 0.42
    guard let image = icon.image(size: side) else { return }
    let glyph = NSImageView(image: image)
    glyph.contentTintColor = ink
    glyph.imageScaling = .scaleProportionallyUpOrDown
    glyph.frame = CGRect(x: (rect.width - side) / 2, y: (rect.height - side) / 2, width: side, height: side)
    view.addSubview(glyph)
  }

  init(in parent: NSView, space: ShowSpace, clock: ShowClock, words: String, middle: CGPoint, size: CGFloat = 46,
       fill: NSColor = .white, ink: NSColor = .black) {
    self.clock = clock
    let label = ShowText.label(words, size: space.v(size), ink: ink, weight: .medium)
    label.sizeToFit()
    let height = space.v(size * 2.1)
    let size = CGSize(width: label.frame.width + height * 0.75, height: height)
    stand(in: parent, frame: CGRect(x: middle.x - size.width / 2, y: middle.y - size.height / 2,
                                    width: size.width, height: size.height),
          radius: height * 0.31, fill: fill)
    label.frame.origin = CGPoint(x: (size.width - label.frame.width) / 2, y: (size.height - label.frame.height) / 2)
    view.addSubview(label)
  }

  private func stand(in parent: NSView, frame: CGRect, radius: CGFloat, fill: NSColor) {
    view.frame = frame
    view.wantsLayer = true
    view.layerUsesCoreImageFilters = true
    view.layer?.cornerCurve = .continuous
    view.layer?.applyCorner(radius)
    view.layer?.backgroundColor = fill.cgColor
    view.alphaValue = 0
    parent.addSubview(view)
  }

  private func scale(_ value: CGFloat) {
    view.layer?.transform = ShowClock.transform(size: view.frame.size, translation: .zero, scale: value, rotation: 0)
  }

  func pop() {
    ShowClock.fade(view, to: 1, duration: 0.15)
    clock.spring(0.45, bounce: 0.24, key: ObjectIdentifier(self)) { [weak self] t in self?.scale(0.4 + 0.6 * t) }
  }

  func press() {
    clock.tween(0.22, curve: Motion.standardCurve, key: ObjectIdentifier(self)) { [weak self] t in
      self?.scale(1 - 0.1 * sin(.pi * t))
    }
  }

  func vanish() {
    ShowClock.fade(view, to: 0, duration: 0.18)
    clock.tween(0.22, key: ObjectIdentifier(self)) { [weak self] t in self?.scale(1 - 0.4 * t) }
  }
}

/// A live face on a disc of its own colour, cut out of what it overlaps.
@MainActor
final class ShowCoin {
  let face: ShowFace
  private let view = NSView()
  private let disc = NSView()
  private let clock: ShowClock
  private var frame: CGRect
  private let full: CGFloat

  init(in parent: NSView, space: ShowSpace, clock: ShowClock, look: MascotLook, ring: NSColor, rect: CGRect,
       sharpness: CGFloat) {
    self.clock = clock
    frame = rect
    full = rect.width
    let rim = rect.width * 0.06
    view.frame = rect
    view.wantsLayer = true
    view.layer?.backgroundColor = ring.cgColor
    view.layer?.applyCorner(rect.width / 2)
    view.alphaValue = 0
    disc.frame = view.bounds.insetBy(dx: rim, dy: rim)
    disc.wantsLayer = true
    disc.layer?.applyCorner(disc.frame.width / 2)
    disc.layer?.backgroundColor = Oklab(
      hue: look.palette.stops[0].h, chroma: min(0.09, look.palette.stops[0].c), l: 0.87).color(fitting: true).cgColor
    view.addSubview(disc)
    parent.addSubview(view)
    let side = rect.width * 0.64
    face = ShowFace(in: view, look: look, side: side, sharpness: sharpness, clock: clock)
    face.place(at: CGRect(x: (rect.width - side) / 2, y: (rect.width - side) / 2, width: side, height: side))
  }

  private func stand(_ rect: CGRect) {
    frame = rect
    view.layer?.transform = ShowClock.transform(
      size: view.frame.size,
      translation: CGPoint(x: rect.midX - view.frame.midX, y: rect.midY - view.frame.midY),
      scale: rect.width / full, rotation: 0)
  }

  func pop() {
    ShowClock.fade(view, to: 1, duration: 0.15)
    let end = frame
    let start = end.insetBy(dx: end.width * 0.35, dy: end.width * 0.35).offsetBy(dx: -end.width * 0.3, dy: 0)
    clock.spring(0.5, bounce: 0.2, key: ObjectIdentifier(self)) { [weak self] t in
      self?.stand(ShowClock.mix(start, end, t))
    }
  }

  func go(to rect: CGRect, index: Int) {
    let start = frame
    view.layer?.backgroundColor = NSColor.clear.cgColor
    clock.spring(0.5 + 0.04 * Double(index), bounce: 0.1, key: ObjectIdentifier(self)) { [weak self] t in
      self?.stand(ShowClock.mix(start, rect, t))
    }
  }
}

/// A voice as it is heard.
@MainActor
final class ShowWave {
  private let clock: ShowClock
  private var bars: [CALayer] = []
  private let rect: CGRect
  private let width: CGFloat
  private let view: NSView

  init(in parent: NSView, space: ShowSpace, clock: ShowClock, colours: [NSColor], rect: CGRect) {
    self.clock = clock
    self.rect = rect
    width = space.v(14)
    view = NSView(frame: rect)
    view.wantsLayer = true
    view.alphaValue = 0
    parent.addSubview(view)
    let count = 17
    for index in 0..<count {
      let bar = CALayer()
      bar.applyCorner(width / 2)
      let place = CGFloat(index) / CGFloat(count - 1) * CGFloat(colours.count - 1)
      let low = min(Int(place), colours.count - 1)
      bar.backgroundColor = MascotPalette.mix(colours[low], colours[min(low + 1, colours.count - 1)],
                                              place - CGFloat(low)).cgColor
      view.layer?.addSublayer(bar)
      bars.append(bar)
    }
    draw(0, voice: 0)
  }

  private func draw(_ time: CGFloat, voice: CGFloat) {
    for (index, bar) in bars.enumerated() {
      let i = CGFloat(index)
      let x = i / CGFloat(bars.count - 1) * (rect.width - width)
      let envelope = sin(.pi * (i + 0.5) / CGFloat(bars.count))
      let beat = abs(sin(time * 7.3 + i * 1.7) * sin(time * 3.1 + i * 0.6))
      let height = max(width, rect.height * envelope * (0.3 + 0.7 * beat) * voice)
      bar.frame = CGRect(x: x, y: (rect.height - height) / 2, width: width, height: height)
    }
  }

  func start() {
    ShowClock.fade(view, to: 1, duration: 0.25)
    var time: CGFloat = 0
    clock.drive(key: ObjectIdentifier(self)) { [weak self] elapsed in
      time += CGFloat(elapsed)
      self?.draw(time, voice: min(1, time * 2.5))
      return self != nil
    }
  }

  func stop() {
    ShowClock.fade(view, to: 0, duration: 0.2)
    clock.cancel(ObjectIdentifier(self))
  }
}

/// A recording as its waveform, with a quiet stretch in it.
@MainActor
final class ShowTrack {
  let quiet: CGRect
  private let slab: ShowSlab
  private let space: ShowSpace
  private let clock: ShowClock
  private let view: NSView
  private let loop = CAShapeLayer()
  private let mark: ShowDisc
  private var bars: [(layer: CALayer, height: CGFloat, isQuiet: Bool)] = []
  private let middle: CGFloat
  private let thick: CGFloat
  private static let still = 33...44
  private static let count = 60

  init(in parent: NSView, space: ShowSpace, clock: ShowClock, name: String, rect: CGRect) {
    self.space = space
    self.clock = clock
    slab = ShowSlab(in: parent, space: space, clock: clock, rect: rect, radius: space.v(90), fill: .white)
    view = NSView(frame: parent.bounds)
    view.wantsLayer = true
    view.alphaValue = 0
    parent.addSubview(view)
    let inset = space.v(76)
    let top = rect.maxY - space.v(84)
    for (words, leading, alpha) in [(name, true, 1), ("2:16", false, 0.4)] as [(String, Bool, CGFloat)] {
      let label = ShowText.label(words, size: space.v(44), ink: NSColor.black.withAlphaComponent(alpha),
                                 weight: leading ? .semibold : .regular)
      label.sizeToFit()
      label.frame.origin = CGPoint(x: (leading ? rect.minX + inset : rect.maxX - inset - label.frame.width).rounded(),
                                   y: (top - label.frame.height / 2).rounded())
      view.addSubview(label)
    }
    thick = space.v(11)
    middle = rect.minY + space.v(160)
    let run = rect.width - inset * 2 - thick
    var area = CGRect.null
    let light = OKLCH(0.58, 0.19, 263.5).color
    for index in 0..<Self.count {
      let i = CGFloat(index)
      let isQuiet = Self.still.contains(index)
      let swell = 0.55 + 0.45 * sin(i * 0.31 + 0.8)
      let grain = 0.35 + 0.65 * abs(sin(i * 2.399) * cos(i * 0.83))
      let height = isQuiet ? thick : max(thick, space.v(210) * swell * grain)
      let bar = CALayer()
      bar.cornerCurve = .continuous
      bar.applyCorner(thick / 2)
      bar.backgroundColor = isQuiet
        ? OKLCH(0.82, 0.008, 264).cgColor
        : light.cgColor
      bar.frame = CGRect(x: rect.minX + inset + run * i / CGFloat(Self.count - 1), y: middle - thick / 2,
                         width: thick, height: thick)
      view.layer?.addSublayer(bar)
      bars.append((bar, height, isQuiet))
      if isQuiet { area = area.union(bar.frame) }
    }
    quiet = area.insetBy(dx: -space.v(10), dy: -space.v(112))

    let around = area.insetBy(dx: -space.v(26), dy: -space.v(66))
    let path = CGMutablePath()
    func turn(_ part: CGFloat) -> CGPoint {
      let angle = .pi / 2 + 0.35 - part * 2.2 * .pi
      let grow = space.v(-4 + 24 * part)
      let x = cos(angle) * (around.width / 2 + grow)
      let y = sin(angle) * (around.height / 2 + grow * 0.8)
      let tilt: CGFloat = 0.06
      return CGPoint(x: around.midX + x * cos(tilt) - y * sin(tilt), y: around.midY + x * sin(tilt) + y * cos(tilt))
    }
    path.move(to: turn(0))
    for step in 1...90 { path.addLine(to: turn(CGFloat(step) / 90)) }
    loop.path = path
    loop.fillColor = nil
    loop.strokeColor = OKLCH(0.66, 0.2, 32).cgColor
    loop.lineWidth = space.v(8)
    loop.lineCap = .round
    loop.lineJoin = .round
    loop.strokeEnd = 0
    view.layer?.addSublayer(loop)
    mark = ShowDisc(in: parent, space: space, clock: clock, words: String(localized: "12 s of silence"),
                    middle: CGPoint(x: around.midX, y: around.maxY + space.v(74)), size: 34,
                    fill: OKLCH(0.66, 0.2, 32).color, ink: .white)
  }

  private func draw(_ index: Int, _ t: CGFloat) {
    let bar = bars[index]
    let height = thick + (bar.height - thick) * t
    var frame = bar.layer.frame
    frame.size.height = height
    frame.origin.y = middle - height / 2
    bar.layer.frame = frame
  }

  func pop() {
    slab.show()
    ShowClock.fade(view, to: 1, duration: 0.2)
    clock.tween(1.1, curve: CAMediaTimingFunction(name: .linear), key: ObjectIdentifier(self)) { [weak self] t in
      guard let self else { return }
      for index in self.bars.indices {
        let part = max(0, min(1, (t * 1.6 - CGFloat(index) / CGFloat(Self.count)) / 0.6))
        let eased = 1 - pow(1 - part, 3)
        self.draw(index, eased + 0.12 * sin(.pi * part) * part)
      }
    }
  }

  /// Everything but the quiet stretch steps back.
  func focus(_ on: Bool) {
    for bar in bars where !bar.isQuiet { ShowClock.fade(bar.layer, to: on ? 0.22 : 1, duration: 0.4) }
  }

  func circle() {
    clock.tween(0.85, curve: CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1), key: "loop") { [weak self] t in
      self?.loop.strokeEnd = t
    } done: { [weak self] in self?.mark.pop() }
  }
}

@MainActor
final class ShowPointer {
  private let arrow = CALayer()
  private let hotSpot: CGPoint
  private let scale: CGFloat

  init(in view: NSView, space: ShowSpace) {
    let cursor = NSCursor.arrow
    let image = cursor.image
    scale = space.v(2.2)
    hotSpot = cursor.hotSpot
    let backing = view.window?.backingScaleFactor ?? 2
    arrow.contents = image.layerContents(forContentsScale: image.recommendedLayerContentsScale(backing * scale))
    arrow.contentsGravity = .resize
    arrow.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
    arrow.anchorPoint = .zero
    arrow.opacity = 0
    arrow.zPosition = 400
    view.layer?.addSublayer(arrow)
  }

  func move(to tip: CGPoint) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    arrow.position = CGPoint(x: tip.x - hotSpot.x * scale, y: tip.y + hotSpot.y * scale - arrow.bounds.height)
    CATransaction.commit()
  }

  func show(at tip: CGPoint) {
    move(to: tip)
    ShowClock.fade(arrow, to: 1, duration: 0.2)
  }

  func hide() { ShowClock.fade(arrow, to: 0, duration: 0.2) }
}

// MARK: - The sunset

final class SunsetView: NSView {
  var onSkip: (() -> Void)?

  static let colours = [
    OKLCH(0.411, 0.128, 262.5), OKLCH(0.532, 0.119, 256), OKLCH(0.622, 0.097, 252.3),
    OKLCH(0.72, 0.03, 305.9), OKLCH(0.779, 0.096, 53.3), OKLCH(0.778, 0.139, 63.7),
    OKLCH(0.613, 0.199, 35.2)
  ]
  static let locations: [NSNumber] = [0, 0.3, 0.46, 0.6, 0.72, 0.84, 1]
  static let drifted: [NSNumber] = [0, 0.25, 0.41, 0.55, 0.69, 0.82, 1]

  static func skyLocations(_ places: [NSNumber]) -> [NSNumber] {
    OklabGradient.numbers(places.map { CGFloat(truncating: $0) })
  }

  private let sky = CAGradientLayer()
  private let horizon = CAGradientLayer()
  private let night = CAGradientLayer()
  private var lights: [CAGradientLayer] = []
  private static let lightColours: [(colour: OKLCH, alpha: CGFloat, centre: CGPoint, period: Double)] = [
    (OKLCH(0.825, 0.125, 63.1), 0.38, CGPoint(x: 0.28, y: 0.3), 26),
    (OKLCH(0.765, 0.153, 359.3), 0.26, CGPoint(x: 0.74, y: 0.42), 33),
    (OKLCH(0.821, 0.091, 254.3), 0.30, CGPoint(x: 0.55, y: 0.78), 29),
  ]
  private var fieldLayer: CALayer?
  private let skip = NSTextField(labelWithString: String(localized: "Skip Intro"))
  private let palette: MascotPalette?
  private var backdrop: AgentBackdropView?

  /// `sky` draws a chat's Sky backdrop in that face's colours in place of the
  /// written gradient.
  init(frame: CGRect, sky palette: MascotPalette? = nil) {
    self.palette = palette
    super.init(frame: frame)
    wantsLayer = true
    build()
  }

  private static let chatHeight: CGFloat = 680

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if !skip.isHidden, skip.frame.insetBy(dx: -14, dy: -10).contains(point) { onSkip?() }
  }

  private static let dark = OKLCH(0.179, 0.026, 266.5).color.cgColor
  private static let ember = OKLCH(0.267, 0.054, 51.5).color.cgColor

  private func build() {
    guard let root = layer else { return }
    sky.frame = bounds
    sky.colors = OklabGradient.cgColors(Self.colours.map(\.color))
    sky.locations = Self.skyLocations(Self.locations)
    sky.startPoint = CGPoint(x: 0.5, y: 1)
    sky.endPoint = CGPoint(x: 0.5, y: 0)
    root.addSublayer(sky)

    if let palette {
      let backdrop = AgentBackdropView(frame: bounds)
      backdrop.sceneScale = max(1, bounds.height / Self.chatHeight)
      addSubview(backdrop)
      backdrop.layOut(in: bounds, corner: 0, curve: .continuous)
      backdrop.show(.sky, palette: palette)
      self.backdrop = backdrop
      night.zPosition = 5
      finishBuild(root)
      return
    }

    let ember = OKLCH(0.725, 0.182, 46.2).color.cgColor
    horizon.type = .radial
    horizon.frame = bounds
    horizon.colors = [ember, ember.copy(alpha: 0) ?? ember]
    horizon.startPoint = CGPoint(x: 0.5, y: 0)
    horizon.endPoint = CGPoint(x: 1.1, y: 0.5)
    horizon.opacity = 0.3
    horizon.compositingFilter = "screenBlendMode"
    root.addSublayer(horizon)

    for light in Self.lightColours {
      let glow = CAGradientLayer()
      glow.type = .radial
      let colour = light.colour.cgColor
      glow.colors = [colour.copy(alpha: light.alpha) ?? colour, colour.copy(alpha: 0) ?? colour]
      glow.startPoint = CGPoint(x: 0.5, y: 0.5)
      glow.endPoint = CGPoint(x: 1, y: 1)
      let side = max(bounds.width, bounds.height) * 0.75
      glow.bounds = CGRect(x: 0, y: 0, width: side, height: side)
      glow.position = CGPoint(x: bounds.width * light.centre.x, y: bounds.height * light.centre.y)
      glow.compositingFilter = "screenBlendMode"
      root.addSublayer(glow)
      lights.append(glow)
    }

    finishBuild(root)
  }

  private func finishBuild(_ root: CALayer) {
    night.frame = bounds
    night.colors = [Self.dark, Self.dark, Self.dark]
    night.locations = [0, 0.7, 1]
    night.startPoint = CGPoint(x: 0.5, y: 1)
    night.endPoint = CGPoint(x: 0.5, y: 0)
    root.addSublayer(night)

    skip.font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
    skip.textColor = PaletteInk.secondary
    skip.sizeToFit()
    skip.frame.origin = CGPoint(x: bounds.maxX - skip.frame.width - 28, y: 24)
    skip.wantsLayer = true
    skip.layer?.zPosition = 10
    addSubview(skip)
  }

  /// One flat colour over the sky; `nil` is the sky again.
  func field(_ colour: NSColor?) {
    let old = fieldLayer
    fieldLayer = nil
    skip.textColor = colour == nil ? PaletteInk.secondary : NSColor.black.withAlphaComponent(0.45)
    if let colour {
      let new = CALayer()
      new.frame = bounds
      new.backgroundColor = colour.cgColor
      new.zPosition = 6
      new.opacity = 0
      layer?.insertSublayer(new, below: skip.layer)
      fieldLayer = new
      ShowClock.fade(new, to: 1, duration: 0.3)
      if let old { DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(0.35)) { old.removeFromSuperlayer() } }
    } else if let old {
      ShowClock.fade(old, to: 0, duration: 0.5)
      DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(0.55)) { old.removeFromSuperlayer() }
    }
  }

  func dawn() {
    let now = CACurrentMediaTime()
    let warm = CABasicAnimation(keyPath: "colors")
    warm.fromValue = [Self.dark, Self.dark, Self.dark]
    warm.toValue = [Self.dark, Self.dark, Self.ember]
    warm.duration = 0.6
    warm.beginTime = now + 0.15
    warm.fillMode = .both
    warm.timingFunction = Motion.standardCurve
    night.colors = [Self.dark, Self.dark, Self.ember]
    night.add(warm, forKey: "boltty.sunset.warm")

    let lift = CABasicAnimation(keyPath: "opacity")
    lift.fromValue = 1
    lift.toValue = 0
    lift.duration = 0.9
    lift.beginTime = now + 0.75
    lift.fillMode = .both
    lift.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    night.opacity = 0
    night.add(lift, forKey: "boltty.sunset.dawn")
    guard backdrop == nil else { return }

    for (index, glow) in lights.enumerated() {
      let light = Self.lightColours[index]
      let centre = glow.position
      let reach = CGSize(width: bounds.width * 0.16, height: bounds.height * 0.12)
      let path = CGMutablePath()
      path.addEllipse(in: CGRect(x: centre.x - reach.width, y: centre.y - reach.height,
                                 width: reach.width * 2, height: reach.height * 2))
      let wander = CAKeyframeAnimation(keyPath: "position")
      wander.path = path
      wander.duration = light.period
      wander.repeatCount = .infinity
      wander.calculationMode = .paced
      wander.timeOffset = light.period * Double(index) / 3
      glow.add(wander, forKey: "boltty.sunset.wander")
      let breathe = CABasicAnimation(keyPath: "opacity")
      breathe.fromValue = 0.65
      breathe.toValue = 1
      breathe.duration = light.period / 3
      breathe.autoreverses = true
      breathe.repeatCount = .infinity
      breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      glow.add(breathe, forKey: "boltty.sunset.breathe")
    }

    let drift = CABasicAnimation(keyPath: "locations")
    drift.fromValue = Self.skyLocations(Self.locations)
    drift.toValue = Self.skyLocations(Self.drifted)
    drift.duration = 14
    drift.autoreverses = true
    drift.repeatCount = .infinity
    drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    sky.add(drift, forKey: "boltty.sunset.drift")
    let glow = CABasicAnimation(keyPath: "opacity")
    glow.fromValue = 0.22
    glow.toValue = 0.38
    glow.duration = 7
    glow.autoreverses = true
    glow.repeatCount = .infinity
    glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    horizon.add(glow, forKey: "boltty.sunset.glow")
  }

  func ended() {
    skip.isHidden = true
  }
}
