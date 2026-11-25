import AppKit
import CoreImage.CIFilterBuiltins

@MainActor
final class FirstRunShowController {
  static let captions = [
    String(localized: "Ask any agent, from anywhere."),
    String(localized: "Every chat, by agent."),
    String(localized: "Select anything, and ask out loud."),
  ]
  static let closing = String(localized: "Your agents, one key away.")
  static let placeholder = String(localized: "Ask anything")
  static let prompt = String(localized: "Make this launch video small enough to email")
  static let answer = String(localized: "Done — launch.mp4 is 18 MB, down from 240. It’s right next to the original.")
  static let askQuestion = String(localized: "How do I make this bigger?")
  static let askAnswer = String(localized: "Select the heading, then press ⌘T.")

  static let perLetter: TimeInterval = 0.018
  static let pace: TimeInterval = 0.355
  static let musicStart: TimeInterval = 7 * beat
  private static let walkStep: TimeInterval = 0.44 / pace

  static let beat: TimeInterval = 60.0 / 115
  static let musicDrop: TimeInterval = 14 * beat

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

  static let crowd: [(center: CGPoint, side: CGFloat, tilt: CGFloat)] = [
    (CGPoint(x: 1330, y: 350), 300, 10),
    (CGPoint(x: 1480, y: 700), 250, -9),
    (CGPoint(x: 330, y: 790), 270, 12),
    (CGPoint(x: 900, y: 890), 210, -6),
    (CGPoint(x: 900, y: 265), 190, 7),
  ]


  private let agents: [AgentId]
  private let planned: AgentId
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
    after(0.15) { [weak self] in self?.sceneRise() }
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
    face.fly(to: square(CGPoint(x: 900, y: 1060), 2150), response: 1.05, angle: -0.12)
    clock.tween(1.6, key: "rise") { t in
      face.view.turn = SIMD3(0.1 - 0.14 * Double(t), 0.5 - 0.6 * Double(t), 0)
    }
    after(1.8) { [weak self] in
      face.view.lookAtWindowPoint = nil
      face.view.emotion = .curious
      self?.sound(.pop, 0)
    }
    after(2.4) { face.view.poke(.wink) }
    after(3.4) { [weak self] in self?.sceneTitle() }
  }

  private func sceneTitle() {
    guard let clock, let faces, let face else { return }
    clock.cancel("rise")
    let view = makeScene()
    let scale = min(1.25, max(1, screen.backingScaleFactor))
    face.view.lookAtWindowPoint = nil
    face.spin(0.95) { [weak self] in
      guard let self else { return }
      face.resize(side: self.space.v(420), sharpness: scale)
    }
    face.fly(to: square(CGPoint(x: 560, y: 345), 340), response: 0.7, angle: -0.08)
    sound(.run, 1)

    let words = words(of: String(localized: "This is Boltty"), size: 150, middle: CGPoint(x: 900, y: 584), in: view)
    for (index, word) in words.enumerated() {
      after(0.3 + 0.16 * Double(index)) { [weak self] in
        self?.arrive(word)
        self?.sound(.tap, index)
      }
    }

    let out = 0.3
    for (index, pair) in zip(agents, Self.crowd).enumerated() {
      let (agent, spot) = pair
      let member = ShowFace(in: faces, look: faceLook(agent), side: space.v(spot.side), sharpness: scale,
                            clock: clock)
      member.holder.layer?.zPosition = 900
      member.holder.alphaValue = 0
      let from = CGPoint(x: spot.center.x + (900 - spot.center.x) * 0.35, y: spot.center.y + (584 - spot.center.y) * 0.35)
      member.place(at: square(from, spot.side * 0.5))
      crowd.append(member)
      after(out + 0.08 * Double(index)) { [weak self] in
        guard let self else { return }
        member.fly(to: self.square(spot.center, spot.side), response: 0.5, angle: spot.tilt * .pi / 180, fade: .come)
        member.spin(0.85)
        self.sound(.pop, index)
      }
      after(out + 2.2 + 0.16 * Double(index)) { member.spin(0.85) }
    }
    after(out + 2.1) { face.spin(0.9) }
    let reactions: [MascotReaction] = [.boing, .wink, .doubleHop, .boing, .wink]
    for index in crowd.indices {
      after(out + 3.6 + 0.08 * Double(index)) { [weak self] in
        guard let self, self.crowd.indices.contains(index) else { return }
        self.crowd[index].view.poke(reactions[index % reactions.count])
      }
    }
    let gone = out + 4.6
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
    after(gone + 0.75) { [weak self] in
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
        member.fly(to: CGRect(x: middle.x - 20, y: middle.y - 20, width: 40, height: 40), response: 0.45, fade: .go)
      }
    }
  }

  private func clearCrowd() {
    for member in crowd { member.holder.removeFromSuperview() }
    crowd = []
  }

  private func words(of line: String, size: CGFloat, middle: CGPoint, ink: NSColor = .white,
                     fitting room: CGFloat = 1560, in view: NSView) -> [NSTextField] {
    var size = size
    let whole = ShowText.label(line, size: space.v(size), weight: .semibold)
    whole.sizeToFit()
    size = min(size, size * space.v(room) / max(1, whole.frame.width))
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
    ShowBlur.set(label, radius: 0, duration: 0.6)
    ShowClock.fade(label, to: 1, duration: 0.4)
    clock?.tween(0.45 * ShowGlide.perResponse) { t in label.frame.origin = ShowClock.mix(start, end, t) }
  }

  private var camera: NSView?
  private var lens: ShowGlide?
  private var lensNow: [CGFloat] = [1, 0, 0]

  private func zoom(to scale: CGFloat, at focus: CGPoint, place: CGPoint? = nil, duration: CFTimeInterval = 1.6,
                    curve: CAMediaTimingFunction = ShowClock.curve) {
    guard let camera, let clock else { return }
    let place = place ?? focus
    let glide = ShowGlide(
      from: lensNow, velocity: lens?.velocity(at: Motion.now),
      to: [scale, place.x - scale * focus.x, place.y - scale * focus.y], over: duration, curve: curve)
    lens = glide
    clock.drive(key: "camera") { [weak self] _ in
      let now = Motion.now
      let v = glide.value(at: now)
      self?.lensNow = v
      camera.layer?.transform = CATransform3DConcat(
        CATransform3DMakeScale(v[0], v[0], 1), CATransform3DMakeTranslation(v[1], v[2], 0))
      return !glide.isOver(at: now)
    }
  }

  private static let drift = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.7, 1)

  private func centre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

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
    clock.tween(0.5) { t in
      view.layer?.transform = ShowClock.transform(size: size, translation: CGPoint(x: 0, y: lift * t),
                                                  scale: 1 - 0.04 * t, rotation: 0)
    }
    ShowClock.fade(view, to: 0, duration: 0.35)
    after(0.95) { view.removeFromSuperview() }
  }

  private static func tint(_ palette: MascotPalette, l: Double = 0.957, c: Double = 0.05) -> NSColor {
    Oklab(hue: palette.stops[0].h, chroma: c, l: l).color(fitting: true)
  }

  private static let paper = OKLCH(0.985, 0.002, 264).color
  private static let ink = NSColor.black

  private func field(_ look: MascotLook) { sunset?.field(Self.tint(look.palette)) }

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

  private func put(_ label: NSTextField, x: CGFloat, middle: CGFloat, in view: NSView) {
    let at = space.point(x, middle)
    label.frame.origin = CGPoint(x: at.x.rounded(), y: (at.y - label.frame.height / 2).rounded())
    view.addSubview(label)
  }

  private func centreSpeck(_ face: ShowFace) -> CGRect {
    let middle = centre(face.rect)
    return CGRect(x: middle.x - 10, y: middle.y - 10, width: 20, height: 20)
  }

  private var cards = 0

  private func fadeOut(_ view: NSView, _ duration: TimeInterval = 0.25) {
    ShowBlur.set(view, radius: 14, duration: duration)
    ShowClock.fade(view, to: 0, duration: duration)
  }

  private func card(_ line: String, then next: @escaping () -> Void) {
    guard let face else { return }
    sound(.boom, cards)
    cards += 1
    let view = makeScene()
    let words = words(of: line, size: 92, middle: CGPoint(x: 900, y: 640), ink: Self.ink, in: view)
    face.fly(to: square(CGPoint(x: 900, y: 450), 170), response: 0.6)
    face.spin(0.75)
    for (index, word) in words.enumerated() {
      after(0.25 + 0.13 * Double(index)) { [weak self] in
        self?.arrive(word)
        self?.sound(.tap, index)
      }
    }
    let gone = 0.25 + 0.13 * Double(words.count) + 2.0
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

  private func sceneWords() {
    sunset?.field(Self.paper)
    card(Self.captions[0]) { [weak self] in self?.sceneAsk() }
  }

  private func sceneAsk() {
    guard let clock, let face else { return }
    field(hero)
    clearCrowd()
    let view = makeScene()
    let slab = keep(ShowSlab(in: view, space: space, clock: clock, rect: centreSpeck(face), radius: 10))
    slab.show()
    let wide = space.rect(275, 469, 1250, 230)
    slab.go(to: wide, radius: space.v(115), response: 0.6)
    face.fly(to: square(CGPoint(x: 398, y: 584), 176), response: 0.6)
    sound(.pop, 2)

    let hint = label(Self.placeholder, size: 74, ink: NSColor.white.withAlphaComponent(0.5))
    put(hint, x: 520, middle: 584, in: view)
    hint.alphaValue = 0
    after(0.7) { [weak self] in self?.arrive(hint) }
    let discs = [(BolttyIcon.folder, CGFloat(1262)), (.mic, 1414)].map { icon, x in
      keep(ShowDisc(in: view, space: space, clock: clock, icon: icon, rect: square(CGPoint(x: x, y: 584), 132)))
    }
    for (index, disc) in discs.enumerated() { after(0.75 + 0.08 * Double(index)) { disc.pop() } }

    var t = 1.2
    let walk = agents.count > 1 ? agents : []
    if !walk.isEmpty {
      let cap = keep(ShowDisc(in: view, space: space, clock: clock, words: "⇧ Tab", middle: space.point(900, 820)))
      after(t) { cap.pop() }
      t += 0.45
      for (index, look) in (walk.map { faceLook($0) } + [hero]).enumerated() {
        let words = index < walk.count ? String(localized: "Ask \(walk[index].shortDisplayName)") : Self.placeholder
        after(t + Self.walkStep * Double(index)) { [weak self] in
          cap.press()
          self?.sound(.pop, index)
          face.spin(0.8) {
            face.view.apply(look: look)
            self?.field(look)
            hint.stringValue = words
            hint.sizeToFit()
          }
        }
      }
      t += Self.walkStep * Double(walk.count + 1) + 0.45
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
      self.zoom(to: 2.1, at: self.space.point(690, 584), place: self.space.point(900, 584), duration: 0.75)
    }
    for (index, letter) in Self.prompt.enumerated() {
      after(start + 0.35 + Self.perLetter / Self.pace * Double(index)) { [weak self] in
        typed.stringValue += String(letter)
        if index.isMultiple(of: 2) { self?.sound(.tap, index / 2) }
      }
    }
    after(start + 1.2) { [weak self] in
      guard let self else { return }
      let end = CGPoint(x: typed.frame.maxX - self.space.v(150), y: wide.midY)
      self.zoom(to: 2.1, at: end, place: self.space.point(900, 584), duration: max(0.4, typing * Self.pace),
                curve: CAMediaTimingFunction(controlPoints: 0.3, 0.1, 0.5, 1))
    }
    after(start + 1.2 + typing + 0.35) { [weak self] in self?.sceneAnswer(slab: slab, typed: typed) }
  }

  private func sceneAnswer(slab: ShowSlab, typed: NSTextField) {
    guard let clock, let face, let view = scene else { return }
    onSend?()
    zoom(to: 1, at: space.point(900, 584), duration: 0.6)
    slab.go(to: space.rect(275, 339, 1250, 490), radius: space.v(96), response: 0.4)

    let words = label(Self.prompt, size: 52, ink: Self.ink, fitting: 1020)
    let size = CGSize(width: words.frame.width + space.v(96), height: space.v(124))
    let corner = space.point(1525 - 56, 339 + 56)
    let end = CGRect(x: corner.x - size.width, y: corner.y - size.height, width: size.width, height: size.height)
    let bubble = keep(ShowSlab(in: view, space: space, clock: clock, rect: typed.frame.insetBy(dx: -20, dy: -10),
                               radius: space.v(62), fill: .white, casts: false))
    bubble.show()
    bubble.go(to: end, radius: size.height / 2, response: 0.4)
    fadeOut(typed, 0.18)
    words.frame.origin = CGPoint(x: (end.midX - words.frame.width / 2).rounded(),
                                 y: (end.midY - words.frame.height / 2).rounded())
    words.alphaValue = 0
    view.addSubview(words)
    after(0.45) { [weak self] in self?.arrive(words) }

    face.fly(to: square(CGPoint(x: 405, y: 674), 132), response: 0.4)
    face.spin(0.7)
    after(0.95) { [weak self] in
      guard let self else { return }
      face.view.poke(.wink)
      let height = ShowText.height(size: self.space.v(52))
      ShowText.stream(Self.answer, into: view, at: self.space.point(510, 608), width: self.space.v(930),
                      size: self.space.v(52), clock: clock, lineHeight: height * 1.12)
    }
    after(3.9) { [weak self] in
      guard let self else { return }
      self.leave(view)
      self.sunset?.field(Self.paper)
      self.after(0.1) { [weak self] in
        self?.onBeat { [weak self] in self?.card(Self.captions[1]) { [weak self] in self?.sceneList() } }
      }
    }
  }

  private func sceneList() {
    guard let clock, let face else { return }
    let look = faceLook(planned)
    field(look)
    let view = makeScene()
    face.fly(to: square(CGPoint(x: 900, y: 584), 30), response: 0.4, fade: .go)
    face.spin(0.4)

    let scale = min(1.25, max(1, screen.backingScaleFactor))
    let ring = Self.tint(look.palette)
    let step: CGFloat = 220
    let width = step * CGFloat(agents.count) + 280
    let first = 900 - width / 2 + 140
    let slab = keep(ShowSlab(in: view, space: space, clock: clock, rect: square(CGPoint(x: 900, y: 584), 20),
                             radius: space.v(10)))
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
      slab.go(to: self.space.rect(275, 214, 1250, 740), radius: self.space.v(96), response: 0.6)
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
      after(t + 1.0 + 0.12 * Double(index)) { [weak self] in
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
    after(t + 1.8) { [weak self] in
      coins.first?.face.view.poke(.wink)
      self?.zoom(to: 1.08, at: self?.space.point(900, 530) ?? .zero, duration: 2.6, curve: Self.drift)
    }
    after(t + 3.3) { [weak self] in
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

  private func sceneVoice() {
    guard let clock, let face else { return }
    sunset?.field(Self.paper)
    let view = makeScene()
    face.fly(to: square(CGPoint(x: 900, y: 450), 30), response: 0.35, fade: .go)

    let page = keep(ShowPage(in: view, space: space))
    ShowBlur.set(page.view, radius: 16)
    ShowBlur.set(page.view, radius: 0, duration: 0.8)
    ShowClock.fade(page.view, to: 1, duration: 0.5)
    page.move(from: 1.1, to: 1, about: space.point(900, 584), over: 0.95, clock: clock)
    sound(.run, 2)

    let overlay = ScreenSelectionOverlay(frame: view.bounds)
    overlay.palette = hero.palette.colors.map { colour in
      let lab = Oklab(colour)
      return Oklab(hue: lab.hue, chroma: max(0.13, lab.chroma), l: min(0.7, lab.l)).color(fitting: true)
    }
    page.view.addSubview(overlay)
    let whole = space.rect(281, 444, 1406, 394)
    let from = CGPoint(x: whole.minX, y: whole.maxY)
    let to = CGPoint(x: whole.maxX, y: whole.minY)
    let pointer = keep(ShowPointer(in: view, space: space))
    let rest = space.point(1240, 1120)
    after(0.9) {
      pointer.show(at: rest)
      clock.tween(0.75, key: "pointer") { t in pointer.move(to: ShowClock.mix(rest, from, t)) }
    }
    after(2.4) {
      clock.tween(0.85, key: "pointer") { t in
        let tip = ShowClock.mix(from, to, t)
        overlay.selection = CGRect(x: from.x, y: tip.y, width: max(1, tip.x - from.x), height: max(1, from.y - tip.y))
        pointer.move(to: tip)
      } done: { overlay.showsHandles = true }
    }

    let orbMiddle = CGPoint(x: 1491, y: 969)
    let orb = square(orbMiddle, 188)
    let pill = keep(ShowSlab(in: view, space: space, clock: clock, rect: CGRect(x: to.x - 4, y: to.y - 4, width: 8, height: 8),
                             radius: 4))
    let wide = space.rect(375, 313, 1050, 450)
    after(4.15) { [weak self] in
      guard let self else { return }
      pointer.hide()
      pill.show()
      pill.go(to: orb, radius: orb.width / 2, response: 0.5)
      face.place(at: CGRect(x: to.x - 15, y: to.y - 15, width: 30, height: 30))
      face.view.emotion = .listening
      face.fly(to: self.square(orbMiddle, 135), response: 0.5, fade: .come)
      self.sound(.pop, 0)
    }
    after(5.4) { [weak self] in
      guard let self else { return }
      overlay.showsHandles = false
      page.move(from: 1, to: 1.4, about: self.space.point(orbMiddle.x, orbMiddle.y), over: 0.9, clock: clock)
      ShowBlur.set(page.view, radius: 18, duration: 0.7)
      ShowClock.fade(page.view, to: 0, duration: 0.6)
      self.sunset?.field(OKLCH(0.957, 0.034, 62).color)
      pill.go(to: wide, radius: self.space.v(150), response: 0.62)
      face.fly(to: self.square(CGPoint(x: 900, y: 462), 220), response: 0.62)
      self.sound(.run, 3)
    }
    let said = words(of: Self.askQuestion, size: 76, middle: CGPoint(x: 900, y: 645), fitting: 900, in: view)
    let light = hero.palette.arrivalLight
    let tinted = said.enumerated().map { index, word -> NSTextField in
      let label = ShowText.label(word.stringValue, size: word.font?.pointSize ?? 10,
                                 ink: light[index * (light.count - 1) / max(1, said.count - 1)], weight: .semibold)
      label.frame = word.frame
      label.alphaValue = 0
      view.addSubview(label)
      return label
    }
    let beat = min(0.34, 1.7 / Double(max(1, said.count)))
    for index in said.indices {
      after(6.6 + beat * Double(index)) { [weak self] in
        self?.arrive(said[index])
        self?.arrive(tinted[index])
        self?.sound(.tap, index)
      }
      after(7.4 + beat * Double(index)) { ShowClock.fade(tinted[index], to: 0, duration: 0.5) }
    }

    let spot = CGPoint(x: 1010, y: 446)
    after(10.2) { [weak self] in
      guard let self else { return }
      self.onSend?()
      for label in said + tinted { self.fadeOut(label, 0.25) }
      pill.go(to: self.square(CGPoint(x: 960, y: 420), 20), radius: 10, response: 0.5)
      self.after(0.45) { pill.hide() }
      self.sunset?.field(Self.paper)
      face.view.emotion = .curious
      let start = face.rect
      let end = self.square(spot, 136)
      let lift = self.space.v(150)
      clock.tween(1.0, key: "arc") { t in
        let arc = sin(.pi * t)
        face.place(at: ShowClock.mix(start, end, t).offsetBy(dx: self.space.v(90) * arc, dy: lift * arc),
                   angle: -0.22 * arc - 0.08 * t)
      }
    }
    after(10.4) { [weak self] in
      guard let self else { return }
      ShowBlur.set(page.view, radius: 0, duration: 0.7)
      ShowClock.fade(page.view, to: 1, duration: 0.6)
      ShowClock.fade(overlay, to: 0, duration: 0.01)
      page.move(from: 1.06, to: 1, about: self.space.point(900, 584), over: 0.9, clock: clock)
    }
    let mark = keep(ShowMark(in: view, space: space, clock: clock))
    after(12.1) { [weak self] in
      guard let self else { return }
      mark.draw()
      let speck = self.space.rect(1092, 436, 20, 20)
      let bubble = self.keep(ShowSlab(in: view, space: self.space, clock: clock, rect: speck, radius: 10))
      bubble.show()
      var size: CGFloat = 46
      while size > 24, ShowText.lines(Self.askAnswer, width: self.space.v(550), size: self.space.v(size)).count > 2 { size -= 2 }
      let lines = ShowText.lines(Self.askAnswer, width: self.space.v(550), size: self.space.v(size)).count
      bubble.go(to: self.space.rect(1098, 366, 650, 160), radius: self.space.v(66), response: 0.5)
      self.sound(.bell, 1)
      self.after(0.9) { [weak self] in
        guard let self else { return }
        let height = ShowText.height(size: self.space.v(size)) * 1.04
        let middle = self.space.point(1154, 446)
        ShowText.stream(Self.askAnswer, into: view, at: CGPoint(x: middle.x, y: middle.y + height * CGFloat(lines) / 2),
                        width: self.space.v(550), size: self.space.v(size), clock: clock, lineHeight: height)
      }
      self.zoom(to: 1.05, at: self.space.point(960, 450), duration: 2.6, curve: Self.drift)
    }
    after(14.2) { face.view.poke(.wink) }
    after(16.2) { [weak self] in
      guard let self else { return }
      self.zoom(to: 1, at: self.space.point(900, 584), duration: 0.5)
      self.leave(view)
      self.after(0.1) { [weak self] in self?.onBeat { [weak self] in self?.sceneFinale() } }
    }
  }

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
          member.place(at: rest.insetBy(dx: rest.width * 0.3, dy: rest.width * 0.3).offsetBy(dx: 0, dy: -self.space.v(90)))
          self.crowd.append(member)
        } else {
          member = face
        }
        self.after(0.1 + 0.09 * Double(index)) { [weak self] in
          member.fly(to: rest, response: 0.5, fade: .come)
          self?.sound(.pop, index)
        }
        self.after(1.0 + 0.13 * Double(index)) { member.spin(0.8) }
      }
      let gone = 1.0 + 0.13 * Double(line.count) + 0.7
      self.after(gone) { [weak self] in
        guard let self else { return }
        self.gather(into: self.space.point(900, 584))
        face.fly(to: self.square(CGPoint(x: 900, y: 584), 380), response: 0.45)
        face.spin(0.8)
        self.onEnding?()
      }
      self.after(gone + 1.15) { [weak self] in
        guard let self else { return }
        let word = self.words(of: "Boltty", size: 170, middle: CGPoint(x: 1020, y: 584), ink: Self.ink, in: view)[0]
        let mark = self.space.v(220)
        face.fly(to: CGRect(x: word.frame.minX - self.space.v(28) - mark, y: word.frame.midY - mark / 2,
                            width: mark, height: mark), response: 0.5)
        self.arrive(word, from: CGPoint(x: -self.space.v(140), y: 0))
      }
      self.after(gone + 2.5) { face.view.poke(.wink) }
      self.after(gone + 3.9) { [weak self] in
        guard let self else { return }
        self.sunset?.field(nil)
        self.leave(view)
        face.leave(by: self.space.v(120))
        self.after(0.8) { [weak self] in self?.finish() }
      }
    }
  }

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

  static let curve = CAMediaTimingFunction(controlPoints: 0.62, 0, 0.06, 1)
  static let timing = TimingCurve(curve)
  static let quick: CFTimeInterval = 0.76

  func tween(_ duration: CFTimeInterval, curve: CAMediaTimingFunction = ShowClock.curve, key: AnyHashable? = nil,
             _ update: @escaping (CGFloat) -> Void, done: (() -> Void)? = nil) {
    let timing = TimingCurve(curve)
    let length = max(duration * Self.quick, 0.001)
    add(Tween(key: key, id: makeID(), start: Motion.now, duration: length,
              value: { timing.value(at: CGFloat(min(1, $0 / length))) }, update: update, done: done))
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
    animation.duration = duration * 1.3 * quick
    animation.timingFunction = curve
    layer.opacity = opacity
    layer.add(animation, forKey: "boltty.show.fade")
  }

  static func fade(_ view: NSView, to alpha: CGFloat, duration: TimeInterval) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration * 1.3 * quick
      context.timingFunction = curve
      view.animator().alphaValue = alpha
    }
  }
}

@MainActor
struct ShowGlide {
  static let perResponse: CFTimeInterval = 1.5
  private static let carryLength: CFTimeInterval = 0.3

  private let from: [CGFloat]
  private let to: [CGFloat]
  private let carry: [CGFloat]
  private let start: CFTimeInterval
  private let length: CFTimeInterval
  private let timing: TimingCurve

  init(from: [CGFloat], velocity: [CGFloat]?, to: [CGFloat], over length: CFTimeInterval,
       curve: CAMediaTimingFunction? = nil) {
    timing = curve.map(TimingCurve.init) ?? ShowClock.timing
    self.from = from
    self.to = to
    self.length = max(0.01, length * ShowClock.quick)
    carry = velocity ?? from.map { _ in 0 }
    start = Motion.now
  }

  func isOver(at now: CFTimeInterval) -> Bool { now - start >= length }

  func progress(at now: CFTimeInterval) -> CGFloat {
    timing.value(at: CGFloat(min(1, max(0, (now - start) / length))))
  }

  func value(at now: CFTimeInterval) -> [CGFloat] {
    let x = CGFloat(min(1, max(0, (now - start) / length)))
    let eased = timing.value(at: x)
    let run = min(length, Self.carryLength), gone = min(run, max(0, now - start))
    let push = CGFloat(gone * pow(1 - gone / run, 3))
    return from.indices.map { from[$0] + (to[$0] - from[$0]) * eased + carry[$0] * push }
  }

  func velocity(at now: CFTimeInterval) -> [CGFloat] {
    guard !isOver(at: now) else { return from.map { _ in 0 } }
    let h = 1.0 / 480
    return zip(value(at: now), value(at: now - h)).map { ($0 - $1) / CGFloat(min(h, max(1e-4, now - start))) }
  }
}

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
      animation.duration = duration * ShowClock.quick
      animation.timingFunction = ShowClock.curve
      layer.add(animation, forKey: "boltty.show.blur")
    }
    guard radius == 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(duration + 0.05)) {
      guard (layer.value(forKey: token) as? UUID) == turn else { return }
      layer.filters = nil
    }
  }
}

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
          ShowBlur.set(label, radius: 0, duration: 0.55)
          ShowClock.fade(label, to: 1, duration: 0.4)
          let start = label.frame.origin
          clock.tween(0.32 * ShowGlide.perResponse) { t in label.frame.origin = ShowClock.mix(start, end, t) }
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

    init(_ values: [CGFloat]) { (x, y, size, angle) = (values[0], values[1], values[2], values[3]) }

    var values: [CGFloat] { [x, y, size, angle] }
    var rect: CGRect { CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size) }
  }

  private var pose = Pose()
  private var goal = Pose()
  private var glide: ShowGlide?
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
    apply()
    DispatchQueue.main.async { [weak self] in self?.apply() }
  }

  enum Fade { case come, go }
  private var fade: Fade?

  func fly(to rect: CGRect, response: Double, angle: CGFloat = 0, fade: Fade? = nil) {
    if fade == nil, self.fade == .come { holder.alphaValue = 1 }
    self.fade = fade
    goal = Pose(rect, angle: angle)
    let next = ShowGlide(from: pose.values, velocity: moving ? glide?.velocity(at: Motion.now) : nil,
                         to: goal.values, over: response * ShowGlide.perResponse)
    glide = next
    guard !moving else { return }
    moving = true
    clock.drive(key: ObjectIdentifier(self)) { [weak self] _ in self?.step() ?? false }
  }

  func spin(_ duration: CFTimeInterval, edgeOn: (() -> Void)? = nil) {
    var pending = edgeOn
    let key = AnyHashable(ObjectIdentifier(view))
    var start = view.turn
    if start.y > .pi { start.y -= 2 * .pi }
    clock.tween(max(0.8, duration), key: key) { [view] t in
      let t = Double(t)
      view.turn = start * (1 - t) + SIMD3(0, 2 * .pi * t, 0)
      if t >= 0.25, let act = pending {
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
    fly(to: rect, response: 0.3, angle: goal.angle)
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

  private func step() -> Bool {
    guard moving, let glide else { return false }
    let now = Motion.now
    moving = !glide.isOver(at: now)
    pose = moving ? Pose(glide.value(at: now)) : goal
    if let fade {
      let part = moving ? glide.progress(at: now) : 1
      holder.alphaValue = fade == .come ? min(1, part / 0.3) : 1 - max(0, (part - 0.55) / 0.45)
      if !moving { self.fade = nil }
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
  func hide() { ShowClock.fade(view, to: 0, duration: 0.15) }

  private var glide: ShowGlide?

  func go(to rect: CGRect, radius: CGFloat, response: CFTimeInterval) {
    let now = Motion.now
    let glide = ShowGlide(
      from: [frame.minX, frame.minY, frame.width, frame.height, self.radius], velocity: self.glide?.velocity(at: now),
      to: [rect.minX, rect.minY, rect.width, rect.height, radius], over: response * ShowGlide.perResponse)
    self.glide = glide
    clock.drive(key: ObjectIdentifier(self)) { [weak self] _ in
      let now = Motion.now
      let v = glide.value(at: now)
      self?.apply(CGRect(x: v[0], y: v[1], width: max(0, v[2]), height: max(0, v[3])), max(0, v[4]))
      return !glide.isOver(at: now)
    }
  }
}

private extension CALayer {
  func applyCorner(_ radius: CGFloat) { cornerRadius = radius }
}

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

  private var now: CGFloat = 0.6

  private func scale(_ value: CGFloat) {
    now = value
    view.layer?.transform = ShowClock.transform(size: view.frame.size, translation: .zero, scale: value, rotation: 0)
  }

  func pop() {
    scale(0.6)
    ShowClock.fade(view, to: 1, duration: 0.4)
    clock.tween(0.6, key: ObjectIdentifier(self)) { [weak self] t in self?.scale(0.6 + 0.4 * t) }
  }

  func press() {
    let from = now
    clock.tween(0.32, curve: CAMediaTimingFunction(name: .easeInEaseOut), key: ObjectIdentifier(self)) { [weak self] t in
      self?.scale(from + (1 - from) * t - 0.1 * sin(.pi * t))
    }
  }

  func vanish() {
    let from = now
    ShowClock.fade(view, to: 0, duration: 0.3)
    clock.tween(0.4, key: ObjectIdentifier(self)) { [weak self] t in self?.scale(from * (1 - 0.3 * t)) }
  }
}

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
    ShowClock.fade(view, to: 1, duration: 0.4)
    let end = frame
    let start = end.insetBy(dx: end.width * 0.2, dy: end.width * 0.2).offsetBy(dx: -end.width * 0.25, dy: 0)
    clock.tween(0.5 * ShowGlide.perResponse, key: ObjectIdentifier(self)) { [weak self] t in
      self?.stand(ShowClock.mix(start, end, t))
    }
  }

  func go(to rect: CGRect, index: Int) {
    let start = frame
    view.layer?.backgroundColor = NSColor.clear.cgColor
    clock.tween((0.5 + 0.04 * Double(index)) * ShowGlide.perResponse, key: ObjectIdentifier(self)) { [weak self] t in
      self?.stand(ShowClock.mix(start, rect, t))
    }
  }
}

@MainActor
final class ShowPage {
  let view: ShowScene

  init(in parent: NSView, space: ShowSpace) {
    view = ShowScene(frame: parent.bounds)
    view.alphaValue = 0
    parent.addSubview(view)
    func place(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
      space.rect((x * 1.35 - 260) * 0.9375, (y * 1.35 - 60) * 0.9375 + 78, width * 1.2656, height * 1.2656)
    }
    let card = CALayer()
    card.frame = place(430, 340, 1080, 290)
    card.cornerCurve = .continuous
    card.applyCorner(space.v(30))
    card.backgroundColor = NSColor.black.withAlphaComponent(0.035).cgColor
    view.layer?.addSublayer(card)
    let path = CGMutablePath()
    func bar(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, corner: CGFloat? = nil) {
      let rect = place(x, y, width, height)
      let radius = corner.map(space.v) ?? rect.height / 2
      path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    }
    bar(430, 160, 520, 30)
    bar(430, 214, 640, 14)
    bar(1480, 160, 90, 24)
    bar(430, 290, 130, 14)
    bar(471, 390, 459, 33)
    for (y, width) in [(449, 800), (480, 874), (511, 637)] as [(CGFloat, CGFloat)] { bar(471, y, width, 15) }
    bar(471, 560, 148, 40)
    bar(635, 560, 148, 40)
    for (y, width) in [(690, 900), (722, 980), (754, 700)] as [(CGFloat, CGFloat)] { bar(430, y, width, 14) }
    bar(430, 820, 520, 220, corner: 30)
    bar(990, 820, 520, 220, corner: 30)
    for (index, width) in [90, 70, 110, 84, 60, 100, 76].enumerated() {
      bar(230, 215 + CGFloat(index) * 34, CGFloat(width), 10)
    }
    let bars = CAShapeLayer()
    bars.path = path
    bars.fillColor = NSColor.black.withAlphaComponent(0.085).cgColor
    view.layer?.addSublayer(bars)
  }

  func move(from: CGFloat, to: CGFloat, about point: CGPoint, over duration: CFTimeInterval, clock: ShowClock) {
    clock.tween(duration, key: ObjectIdentifier(self)) { [view] t in
      let scale = ShowClock.mix(from, to, t)
      view.layer?.transform = CATransform3DConcat(
        CATransform3DMakeScale(scale, scale, 1),
        CATransform3DMakeTranslation(point.x * (1 - scale), point.y * (1 - scale), 0))
    }
  }
}

@MainActor
final class ShowMark {
  private let loop = CAShapeLayer()
  private let tip = CAShapeLayer()
  private let clock: ShowClock
  private let space: ShowSpace
  private let rest: CGPoint

  init(in view: NSView, space: ShowSpace, clock: ShowClock) {
    self.clock = clock
    self.space = space
    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { space.point(x * 0.9375, y * 0.9375 + 78) }
    let path = CGMutablePath()
    path.move(to: at(300, 205))
    path.addCurve(to: at(800, 104), control1: at(280, 120), control2: at(560, 92))
    path.addCurve(to: at(1030, 222), control1: at(1030, 114), control2: at(1090, 170))
    path.addCurve(to: at(330, 246), control1: at(960, 280), control2: at(480, 290))
    path.addCurve(to: at(300, 160), control1: at(280, 224), control2: at(270, 190))
    path.addCurve(to: at(420, 116), control1: at(320, 140), control2: at(360, 126))
    loop.path = path
    loop.fillColor = nil
    loop.strokeColor = OKLCH(0.64, 0.19, 262).cgColor
    loop.lineWidth = space.v(12)
    loop.lineCap = .round
    loop.lineJoin = .round
    loop.strokeEnd = 0
    loop.isHidden = true
    view.layer?.addSublayer(loop)

    let arrow = CGMutablePath()
    let points = [(0, 0), (16, -6), (8.5, -8.5), (6, -16)] as [(CGFloat, CGFloat)]
    arrow.addLines(between: points.map { CGPoint(x: space.v($0.0 * 2.8), y: space.v($0.1 * 2.8)) })
    arrow.closeSubpath()
    tip.path = arrow
    tip.fillColor = OKLCH(0.69, 0.17, 262).cgColor
    tip.strokeColor = NSColor.white.cgColor
    tip.lineWidth = space.v(5)
    tip.lineJoin = .round
    tip.opacity = 0
    rest = at(978, 268)
    view.layer?.addSublayer(tip)
  }

  func draw() {
    ShowClock.fade(tip, to: 1, duration: 0.35)
    clock.tween(0.7, key: "tip") { [tip, rest, space] t in
      tip.position = CGPoint(x: rest.x + space.v(46) * (1 - t), y: rest.y - space.v(56) * (1 - t))
    }
    loop.isHidden = false
    clock.tween(1.0, key: "loop") { [loop] t in loop.strokeEnd = t }
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
    warm.duration = 0.4
    warm.beginTime = now
    warm.fillMode = .both
    warm.timingFunction = Motion.standardCurve
    night.colors = [Self.dark, Self.dark, Self.ember]
    night.add(warm, forKey: "boltty.sunset.warm")

    let lift = CABasicAnimation(keyPath: "opacity")
    lift.fromValue = 1
    lift.toValue = 0
    lift.duration = 0.7
    lift.beginTime = now + 0.2
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
