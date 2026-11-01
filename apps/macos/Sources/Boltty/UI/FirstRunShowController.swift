import AppKit
import CoreImage.CIFilterBuiltins

/// **The first run's show**, laid out from a storyboard of 23 slides:
/// before the setup card, Boltty plays itself once over a sunset
/// of its own. Night breaks into the sunset; the agents' faces gather in a
/// pile and pull faces; then Boltty AI is played on light glass, large, in
/// three beats each named by a caption — a question asked from anywhere and
/// answered in the panel under the notch, where it really stands; a chart
/// selected and asked about; and Ask Boltty answering beside the pointer in
/// an app's window, then flying to the menu its answer names and ringing it.
///
/// **All of it is made up.** Nothing here is the real panel: the words and
/// the faces are set by the script, nothing is sent and nothing is asked of
/// macOS. What can be the real thing is: the panel's glass, the selection's
/// overlay, Ask Boltty's line and its blips.
///
/// **One face from start to end** (`ShowFace`): the planned agent's face
/// arrives first in the pile, drops into the prompt and is carried through
/// every scene — two faces handing over show a jump in the pose and the
/// colours.
///
/// The slides are 1800 × 1169, a screen's size in points; `ShowSpace` maps
/// their numbers onto the screen it plays on.
///
/// Escape, or Skip Intro in the corner, goes straight to the end.
@MainActor
final class FirstRunShowController {
  // MARK: - What it says

  static let captions = [
    "Ask any agent, from anywhere.",
    "Every chat, by agent.",
    "Ask about what’s on your screen.",
    "Or hold ⌃⌥⌘ and just ask.",
    "Make each agent yours.",
  ]
  static let prompt = "Make this launch video small enough to email"
  static let answer = "Done — launch.mp4 is 18 MB, down from 240. It’s right next to the original."
  static let regionPrompt = "What does this chart say?"
  static let regionAnswer = "Sign-ups grew every month but April, when the launch slipped a week."
  static let askQuestion = "How do I export this?"
  static let askAnswer = "Up here: File › Export, then pick MP4."

  // MARK: - Timing

  /// Seconds between typed letters, on screen.
  static let perLetter: TimeInterval = 0.032
  /// Every beat of the script a little sooner than written: at its written
  /// pace the show drags.
  static let pace: TimeInterval = 0.82

  // MARK: - Geometry

  /// Where each face stands in the settings card's pile, in a square of
  /// side 1 (y up): centre, side and tilt in degrees.
  static let pile: [(center: CGPoint, side: CGFloat, tilt: CGFloat)] = [
    (CGPoint(x: 0.31, y: 0.64), 0.50, -9),
    (CGPoint(x: 0.71, y: 0.58), 0.44, 11),
    (CGPoint(x: 0.36, y: 0.24), 0.40, 7),
    (CGPoint(x: 0.75, y: 0.20), 0.33, -13),
    (CGPoint(x: 0.56, y: 0.90), 0.27, 5),
  ]

  /// The pile's frames for `count` faces, centred on `center` in a square
  /// of `side`, with their tilts in radians.
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

  /// The show's cluster, off slide 5, in slide units: the planned agent's
  /// face big in the middle and in front, the others round it.
  static let cluster: [(rect: CGRect, tilt: CGFloat)] = [
    (CGRect(x: 650, y: 425, width: 420, height: 360), -4),
    (CGRect(x: 935, y: 345, width: 255, height: 255), 8),
    (CGRect(x: 560, y: 360, width: 240, height: 240), -10),
    (CGRect(x: 545, y: 545, width: 240, height: 240), 12),
    (CGRect(x: 965, y: 560, width: 270, height: 200), -8),
  ]

  /// Between a chat card and the prompt under it, in slide units.
  static let cardGap: CGFloat = 24
  /// The panel's top under the notch, in slide units: where Boltty AI
  /// stands, locked to the top centre.
  static let panelTop: CGFloat = 56

  // MARK: - State

  private let agents: [AgentId]
  private let planned: AgentId
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
  /// The music on (as the show starts) and off (as it ends, fading).
  var onMusic: ((Bool) -> Void)?
  /// Ask Boltty's blips as its answer types out: Settings › General › Sounds.
  var makesBlips = true
  var isPlaying: Bool { stage != nil && !finished }

  init(agents: [AgentId], planned: AgentId?, on screen: NSScreen) {
    let agents = agents.isEmpty ? AgentHistory.tabOrder : agents
    self.agents = agents
    self.planned = planned.flatMap { agents.contains($0) ? $0 : nil } ?? agents.first ?? .claude
    self.screen = screen
  }

  /// Plays the show; `completion` runs once, when it has ended or been
  /// skipped, with the sunset still up.
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
    after(1.2) { [weak self] in self?.scenePile() }
  }

  /// Under `window` from here on, not over every app.
  func settle(under window: NSWindow) {
    guard let backdrop else { return }
    backdrop.level = .normal
    backdrop.order(.below, relativeTo: window.windowNumber)
  }

  /// Fades the sunset out once the setup window has closed.
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

  /// `body` after `delay` seconds of the show — slowed in slow motion,
  /// dropped once the show has ended.
  private func after(_ delay: TimeInterval, _ body: @escaping () -> Void) {
    let run = self.run
    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(delay * Self.pace)) { [weak self] in
      guard let self, self.run == run, !self.finished else { return }
      body()
    }
  }

  private func sound(_ kind: InterfaceSounds.FaceSound, _ index: Int) {
    onSound?(kind, index)
  }

  /// The script's seconds for typing `words`.
  private static func typing(_ words: String) -> TimeInterval {
    perLetter / pace * Double(words.count)
  }

  /// Types `words` into `prompt` from `start`, a letter at a time, each
  /// with its tap.
  private func typeOut(_ words: String, into prompt: ShowPrompt, from start: TimeInterval, maxWidth: CGFloat) {
    for (index, letter) in words.enumerated() {
      after(start + Self.perLetter / Self.pace * Double(index)) { [weak self] in
        prompt.type(String(letter), maxWidth: maxWidth)
        self?.sound(.tap, index)
      }
    }
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
    // The sunset is a window of its own, under the setup card's glass:
    // glass bends only what is behind its window.
    let backdrop = panel(level: .statusBar)
    let sunset = SunsetView(frame: CGRect(origin: .zero, size: frame.size))
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
    // The face's own layer, over every scene: it stays when a scene leaves.
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

  // MARK: - Scene: the pile

  private struct PileFace {
    let holder: NSView
    let face: MascotNSView
    let tilt: CGFloat
  }

  /// The faces round the first, which go back behind it and are gone.
  private var pileFaces: [PileFace] = []
  private var flash: CAGradientLayer?

  /// Slides 3–6: the planned
  /// agent's face arrives alone, softly, with a whoosh; the others come out
  /// from behind it to their places round it, pull a face each — once,
  /// gently — and all go back behind it together; then it flies into the
  /// prompt and is the prompt's.
  private func scenePile() {
    guard let root, let clock, let faces else { return }
    let order = [planned] + agents.filter { $0 != planned }
    let scale = min(1.25, max(1, screen.backingScaleFactor))

    let glow = CAGradientLayer()
    glow.type = .radial
    let warm = CGColor(red: 1, green: 0.93, blue: 0.82, alpha: 0.85)
    glow.colors = [warm, warm.copy(alpha: 0) ?? warm]
    glow.startPoint = CGPoint(x: 0.5, y: 0.5)
    glow.endPoint = CGPoint(x: 1, y: 1)
    glow.frame = space.rect(300, 120, 1200, 900)
    glow.opacity = 0
    // Under the faces.
    root.layer?.insertSublayer(glow, at: 0)
    flash = glow

    func square(_ rect: CGRect) -> CGRect {
      let side = max(rect.width, rect.height)
      return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    // The first is the show's one face, from here to the end.
    let home = square(space.rect(Self.cluster[0].rect))
    let tilt = Self.cluster[0].tilt * .pi / 180
    let face = ShowFace(in: faces, agent: planned, side: home.width, sharpness: scale, clock: clock)
    face.holder.alphaValue = 0
    face.place(at: home, angle: tilt)
    self.face = face

    for (index, agent) in order.prefix(Self.cluster.count).enumerated().dropFirst() {
      let spot = Self.cluster[index]
      let frame = square(space.rect(spot.rect))
      let holder = NSView(frame: frame)
      holder.wantsLayer = true
      // Nothing of it shows before its turn.
      holder.alphaValue = 0
      holder.layer?.zPosition = frame.width
      let view = MascotNSView(conversationID: UUID(), look: MascotLook.face(for: agent))
      view.frame = holder.bounds
      view.autoresizingMask = [.width, .height]
      view.ownsDisplayLink = true
      view.renderScale = scale
      holder.addSubview(view)
      faces.addSubview(holder, positioned: .below, relativeTo: face.holder)
      pileFaces.append(PileFace(holder: holder, face: view, tilt: spot.tilt * .pi / 180))
    }
    let middle = centre(home)

    // The first, alone: up a little out of nothing, settling.
    after(0.1) { [weak self] in
      guard let self else { return }
      let small = home.width * 0.6
      face.place(at: CGRect(x: home.midX - small / 2, y: home.midY - small / 2 - self.space.v(36),
                            width: small, height: small))
      ShowClock.fade(face.holder, to: 1, duration: 0.3)
      face.fly(to: home, response: 0.85, bounce: 0.12, angle: tilt)
      self.sound(.whoosh, 0)
    }
    after(0.45) { [weak self] in self?.flashLight() }
    // The others, out from behind it.
    for (index, pile) in pileFaces.enumerated() {
      after(0.85 + 0.08 * Double(index)) { [weak self] in
        guard let self else { return }
        self.move(pile, from: self.tucked(pile, behind: middle), to: pile.tilt, response: 0.6, bounce: 0.16)
      }
    }
    if !pileFaces.isEmpty { after(0.85) { [weak self] in self?.sound(.whoosh, 1) } }
    // A face each, once, gently.
    let reactions: [MascotReaction] = [.wink, .boing, .doubleHop, .wink, .boing]
    let emotions: [MascotEmotion] = [.curious, .listening, .curious, .focused, .curious]
    after(1.55) { [weak self] in
      guard let self else { return }
      let views = [face.view] + self.pileFaces.map(\.face)
      for (index, view) in views.enumerated() {
        view.emotion = emotions[index % emotions.count]
        view.poke(reactions[index % reactions.count])
        self.after(0.1 * Double(index)) { [weak self] in self?.sound(.hum, index) }
      }
    }
    // All back behind it, at once.
    after(2.7) { [weak self] in
      guard let self else { return }
      for pile in self.pileFaces { self.tuck(pile, behind: middle) }
      if !self.pileFaces.isEmpty { self.sound(.whoosh, 2) }
    }
    after(3.05) { [weak self] in self?.scenePrompt() }
  }

  /// Where a face stands while it is hidden behind the first: on its
  /// middle, smaller.
  private func tucked(_ pile: PileFace, behind middle: CGPoint) -> CATransform3D {
    let own = centre(pile.holder.frame)
    return ShowClock.transform(size: pile.holder.frame.size,
                               translation: CGPoint(x: middle.x - own.x, y: middle.y - own.y), scale: 0.45, rotation: 0)
  }

  /// In from `from` to its place, fading in as it comes.
  private func move(_ pile: PileFace, from: CATransform3D, to tilt: CGFloat, response: Double, bounce: Double) {
    guard let layer = pile.holder.layer else { return }
    let to = ShowClock.transform(size: pile.holder.frame.size, translation: .zero, scale: 1, rotation: tilt)
    layer.transform = to
    let spring = CASpringAnimation(perceptualDuration: response, bounce: bounce)
    spring.keyPath = "transform"
    spring.fromValue = NSValue(caTransform3D: from)
    spring.toValue = NSValue(caTransform3D: to)
    spring.duration = spring.settlingDuration
    layer.add(spring.preferringHighFrameRate(), forKey: "boltty.show.in")
    ShowClock.fade(pile.holder, to: 1, duration: 0.3)
  }

  /// Back behind the first, fading as it goes.
  private func tuck(_ pile: PileFace, behind middle: CGPoint) {
    guard let layer = pile.holder.layer else { return }
    let from = (layer.presentation() ?? layer).transform
    let to = tucked(pile, behind: middle)
    layer.transform = to
    let move = CABasicAnimation(keyPath: "transform")
    move.fromValue = NSValue(caTransform3D: from)
    move.toValue = NSValue(caTransform3D: to)
    move.duration = 0.42
    move.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0.4)
    layer.add(move.preferringHighFrameRate(), forKey: "boltty.show.back")
    after(0.22) { ShowClock.fade(pile.holder, to: 0, duration: 0.2) }
  }

  private func flashLight() {
    guard let flash else { return }
    let pulse = CAKeyframeAnimation(keyPath: "opacity")
    pulse.values = [0, 0.7, 0.18]
    pulse.keyTimes = [0, 0.2, 1]
    pulse.duration = 1.2
    pulse.timingFunctions = [Motion.emphasizedCurve, Motion.standardCurve]
    flash.opacity = 0.18
    flash.add(pulse, forKey: "boltty.show.flash")
  }

  private func clearPile() {
    for pile in pileFaces { pile.holder.removeFromSuperview() }
    pileFaces = []
    flash?.removeFromSuperlayer()
    flash = nil
  }

  // MARK: - The caption

  private var caption: NSTextField?

  /// The line under the scene: the old one blurs away up, the new one
  /// blurs in from under it.
  private func say(_ line: String?, middle: CGFloat = 1057) {
    guard let root else { return }
    if let old = caption {
      let start = old.frame
      clock?.tween(0.3) { t in old.frame = start.offsetBy(dx: 0, dy: 14 * t) }
      ShowBlur.set(old, radius: 10, duration: 0.3)
      ShowClock.fade(old, to: 0, duration: 0.25)
      after(0.35) { old.removeFromSuperview() }
    }
    caption = nil
    guard let line else { return }
    let label = ShowText.label(line, size: space.v(36), weight: .medium)
    label.sizeToFit()
    let end = CGRect(x: (root.bounds.midX - label.frame.width / 2).rounded(),
                     y: space.point(0, middle).y - label.frame.height / 2,
                     width: label.frame.width, height: label.frame.height)
    label.frame = end.offsetBy(dx: 0, dy: -18)
    label.alphaValue = 0
    root.addSubview(label)
    caption = label
    ShowBlur.set(label, radius: 30)
    ShowBlur.set(label, radius: 0, duration: 0.6)
    clock?.spring(0.4, bounce: 0.1) { t in label.frame = ShowClock.mix(end.offsetBy(dx: 0, dy: -18), end, t) }
    ShowClock.fade(label, to: 1, duration: 0.25)
  }

  // MARK: - The camera

  /// Everything a scene shows sits in the camera, which leans in to where
  /// something is being typed or shown and back out — slowly, as a camera
  /// is moved. The captions stand outside it.
  private var camera: NSView?
  private var lens: (scale: CGFloat, focus: CGPoint) = (1, .zero)

  private func zoom(to scale: CGFloat, at focus: CGPoint, duration: CFTimeInterval = 1.6) {
    guard let camera, let clock else { return }
    let from = lens
    lens = (scale, focus)
    clock.tween(duration, curve: CAMediaTimingFunction(controlPoints: 0.45, 0, 0.15, 1), key: "camera") { t in
      let s = ShowClock.mix(from.scale, scale, t)
      let p = ShowClock.mix(from.focus == .zero ? focus : from.focus, focus, t)
      // About `p`: a layer's anchor is its corner in AppKit.
      camera.layer?.transform = CATransform3DConcat(
        CATransform3DMakeScale(s, s, 1), CATransform3DMakeTranslation((1 - s) * p.x, (1 - s) * p.y, 0))
    }
  }

  private func centre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

  // MARK: - Scenes

  private var scene: NSView?
  /// The face's layer, over the scenes.
  private var faces: NSView?
  /// The show's one face.
  private var face: ShowFace?
  /// The prompt the face stands in, while it does.
  private var prompt: ShowPrompt?
  private var ask: ShowAsk?
  /// The scene's pieces, held while it plays: their tweens hold them only
  /// weakly, and a piece nothing else held stopped where it stood.
  private var pieces: [AnyObject] = []

  @discardableResult
  private func keep<T: AnyObject>(_ piece: T) -> T {
    pieces.append(piece)
    return piece
  }

  /// A layer for one scene's things, which leaves as one — under the face.
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

  /// The face out of the prompt it stood in, free to fly.
  private func undock() {
    prompt?.face = nil
    prompt = nil
  }

  /// The scene leaves: up a little, a little smaller, fading out — quick,
  /// so the next has the screen. No blur: blurring a layer with clear parts
  /// in it fringes what it holds dark.
  private func leave(_ view: NSView) {
    guard let clock else { return }
    sound(.whoosh, 2)
    let size = view.bounds.size
    let lift = space.v(120)
    clock.tween(0.45, curve: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)) { t in
      view.layer?.transform = ShowClock.transform(size: size, translation: CGPoint(x: 0, y: lift * t),
                                                  scale: 1 - 0.04 * t, rotation: 0)
    }
    ShowClock.fade(view, to: 0, duration: 0.35)
    after(0.55) { view.removeFromSuperview() }
  }

  // MARK: - Scene one: ask anything

  /// Slides 7–9, where the panel really stands: the prompt drips out of
  /// the notch, the face flies up into it, the question types itself as
  /// the camera leans in; sent, the shell grows down into the chat — the
  /// question on top, the answer under it, the composer at its foot.
  private func scenePrompt() {
    guard let clock, let face else { return }
    let view = makeScene()
    // Under the panel, not at the screen's foot: beside what it names.
    say(Self.captions[0], middle: Self.panelTop + 410)
    let prompt = keep(ShowPrompt(in: view, space: space, clock: clock,
                                 frame: space.rect(683, Self.panelTop, 434, 92),
                                 placeholder: "Ask \(planned.shortDisplayName)"))
    self.prompt = prompt
    after(0.1) { [weak self] in
      guard let self else { return }
      prompt.appear(from: self.space.rect(820, -40, 160, 40))
    }
    sound(.run, 0)

    // The pile's face, into the prompt: it goes where the prompt goes now.
    face.fly(to: prompt.faceSlot, response: 0.6, bounce: 0.08)
    prompt.face = face
    if let flash { ShowClock.fade(flash, to: 0, duration: 0.5) }
    after(0.7) { [weak self] in
      face.view.poke(.boing)
      prompt.showCaret()
      self?.clearPile()
    }

    var t = 0.75
    // ⇧Tab walks the ready agents, each face in turn, and comes back to
    // the planned one: one prompt, any agent.
    let walk = Self.walk(from: planned, through: agents)
    if !walk.isEmpty {
      let keycap = keep(ShowKeycap(in: view, space: space, clock: clock, keys: "⇧ Tab", under: prompt.frame))
      after(0.85) { keycap.show() }
      for (index, agent) in walk.enumerated() {
        after(1.1 + 0.42 * Double(index)) { [weak self] in
          keycap.press()
          face.view.apply(look: MascotLook.face(for: agent))
          prompt.placeholder("Ask \(agent.shortDisplayName)")
          self?.sound(.tap, index)
        }
      }
      t = 1.1 + 0.42 * Double(walk.count) + 0.3
      after(t - 0.25) { keycap.hide() }
    }
    after(t - 0.1) { [weak self] in
      guard let self else { return }
      self.zoom(to: 1.12, at: self.centre(self.space.rect(470, Self.panelTop, 860, 92)), duration: 2.2)
    }
    // The capsule grows with the words, as far as slide 8's.
    typeOut(Self.prompt, into: prompt, from: t, maxWidth: space.v(860))
    t += Self.typing(Self.prompt) + 0.35
    after(t) { [weak self] in
      guard let self else { return }
      self.onSend?()
      self.zoom(to: 1, at: self.centre(prompt.frame), duration: 1.2)
      // The chat takes the prompt's place under the notch; the prompt
      // drops to its foot.
      let top = prompt.frame.maxY
      let width = prompt.frame.width
      let height = ShowChatCard.height(answer: Self.answer, width: width, space: self.space)
      let card = self.keep(ShowChatCard(
        in: view, space: self.space, clock: clock, question: Self.prompt, answer: Self.answer,
        x: prompt.frame.minX, bottom: top - height, width: width))
      let typed = prompt.frame
      prompt.slide(to: typed.offsetBy(dx: 0, dy: -(height + self.space.v(Self.cardGap))))
      card.grow(from: typed)
      self.after(0.12) { [weak self] in
        // The words leave the field as the question: at the field's size,
        // shrinking to the bubble's on the way up.
        card.ask(from: prompt.textFrame, size: prompt.fontSize)
        prompt.clear(placeholder: "Ask anything")
        self?.sound(.whoosh, 3)
      }
      // No "Thinking": the answer as the question lands, to keep it brisk.
      self.after(0.85) {
        face.view.poke(.wink)
        card.answer()
      }
      self.after(3.4) { [weak self] in self?.sceneList(card: card, prompt: prompt) }
    }
  }

  /// The agents ⇧Tab walks from `planned`, ending back on it; none when
  /// there is only the one.
  static func walk(from planned: AgentId, through agents: [AgentId]) -> [AgentId] {
    guard agents.count > 1, let start = agents.firstIndex(of: planned) else { return [] }
    return Array(agents[(start + 1)...]) + Array(agents[..<start]) + [planned]
  }

  // MARK: - The chat list

  /// ↓ on the open chat: the panel becomes the list of every chat, by
  /// day, a tab per agent; the face goes to its own tab, and choosing it
  /// keeps only its chats.
  private func sceneList(card: ShowChatCard, prompt: ShowPrompt) {
    guard let clock, let view = scene, let face else { return }
    let keycap = keep(ShowKeycap(in: view, space: space, clock: clock, keys: "↓", under: prompt.frame))
    keycap.show()
    after(0.3) { [weak self] in
      keycap.press()
      self?.sound(.tap, 0)
    }
    let from = card.frame.union(prompt.frame)
    let list = keep(ShowChatList(in: view, space: space, clock: clock, agents: agents, planned: planned,
                                 frame: space.rect((1800 - ShowChatList.width) / 2, Self.panelTop,
                                                   ShowChatList.width, ShowChatList.height)))
    after(0.5) { [weak self] in
      guard let self else { return }
      keycap.hide()
      card.vanish()
      prompt.vanish()
      self.undock()
      list.grow(from: from)
      face.fly(to: list.liveSlot, response: 0.6, bounce: 0.1)
      self.say(Self.captions[1], middle: Self.panelTop + ShowChatList.height + 70)
      self.sound(.whoosh, 3)
    }
    after(2.0) { [weak self] in
      list.choose()
      face.view.poke(.wink)
      self?.sound(.tap, 1)
    }
    after(3.9) { [weak self] in self?.sceneRegion() }
  }

  // MARK: - Scene two: ask about the screen

  /// Slides 10–15: the chat leaves up; a chart window rises; the face, as
  /// the pointer, drags a selection over it — the screen dims, the border
  /// is the agent's light, as Boltty draws one; the window steps aside, the
  /// prompt opens beside it, the face drops in, and it is answered.
  private func sceneRegion() {
    guard let clock, let old = scene, let face else { return }
    undock()
    leave(old)
    let view = makeScene()
    let window = keep(ShowChartWindow(in: view, space: space, clock: clock, frame: space.rect(526, 346, 749, 477)))
    window.rise(from: space.v(-217))
    sound(.run, 1)
    after(0.4) { [weak self] in self?.say(Self.captions[2]) }

    // The real selection's overlay: the dim, the border's light, the
    // handles — over the window, under the prompt and the chat.
    let overlay = ScreenSelectionOverlay(frame: view.bounds)
    overlay.palette = MascotLook.face(for: planned).palette.light(atLeast: AgentPaletteMetrics.screenSelectionLightness)
    view.addSubview(overlay)
    let margin = space.v(8)
    window.onFrame = { frame in
      if overlay.selection != nil, overlay.showsHandles { overlay.selection = frame.insetBy(dx: -margin, dy: -margin) }
    }

    // The face leaves the old prompt for the chart's corner, as the pointer,
    // and drags the selection open from there.
    let size = space.v(64)
    let corner = CGPoint(x: window.frame.minX - margin, y: window.frame.maxY + margin)
    func pointer(at point: CGPoint) -> CGRect {
      CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }
    after(0.15) { [weak self] in
      face.fly(to: pointer(at: corner), response: 0.7, bounce: 0.1)
      face.view.emotion = .curious
      self?.sound(.whoosh, 4)
    }
    after(0.95) { [weak self] in
      guard let self else { return }
      face.view.emotion = .focused
      overlay.selection = CGRect(origin: CGPoint(x: corner.x, y: corner.y - 1), size: CGSize(width: 1, height: 1))
      overlay.isDimmed = true
      self.zoom(to: 1.08, at: self.centre(window.frame), duration: 1.5)
      let full = window.frame.insetBy(dx: -margin, dy: -margin)
      clock.tween(0.9, curve: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1), key: "drag") { t in
        let reach = CGPoint(x: ShowClock.mix(corner.x, full.maxX, t), y: ShowClock.mix(corner.y, full.minY, t))
        overlay.selection = CGRect(x: corner.x, y: reach.y, width: max(1, reach.x - corner.x),
                                   height: max(1, corner.y - reach.y))
        // A stiff spring, not a jump: it takes over whatever the face was
        // still doing.
        face.fly(to: pointer(at: reach), response: 0.1)
      } done: {
        overlay.showsHandles = true
      }
      self.sound(.whoosh, 1)
    }
    // Selected: the window steps left, the prompt opens beside it and the
    // face drops in.
    let promptAt = space.rect(986, 436, 603, 112)
    let prompt = keep(ShowPrompt(in: view, space: space, clock: clock, frame: promptAt, placeholder: "Ask anything"))
    after(2.0) { [weak self] in
      guard let self else { return }
      self.zoom(to: 1, at: self.centre(window.frame), duration: 1.2)
      window.move(to: self.space.rect(211, 344, 749, 477))
    }
    after(2.15) {
      prompt.appear()
      prompt.showCaret()
    }
    after(2.3) { [weak self] in
      face.fly(to: prompt.faceSlot, response: 0.55, bounce: 0.15)
      face.view.emotion = .curious
      prompt.face = face
      self?.prompt = prompt
    }
    after(2.6) { [weak self] in
      guard let self else { return }
      self.zoom(to: 1.1, at: self.centre(promptAt), duration: 1.8)
    }
    let typing = 2.8
    typeOut(Self.regionPrompt, into: prompt, from: typing, maxWidth: promptAt.width)
    after(typing + Self.typing(Self.regionPrompt) + 0.35) { [weak self] in
      guard let self else { return }
      self.onSend?()
      self.zoom(to: 1, at: self.centre(self.space.rect(211, 344, 1378, 418)), duration: 1.2)
      // Slide 15: the prompt drops under the chat that grows above it.
      let under = self.space.rect(986, 650, 603, 112)
      prompt.slide(to: under)
      let card = self.keep(ShowChatCard(
        in: view, space: self.space, clock: clock, question: Self.regionPrompt, answer: Self.regionAnswer,
        x: under.minX, bottom: under.maxY + self.space.v(Self.cardGap), width: under.width))
      card.grow(from: promptAt)
      self.after(0.12) { [weak self] in
        card.ask(from: prompt.textFrame, size: prompt.fontSize)
        prompt.clear(placeholder: "Ask anything")
        self?.sound(.whoosh, 3)
      }
      self.after(0.85) {
        card.answer()
        face.view.poke(.spinHop)
      }
      self.after(3.7) { [weak self] in self?.sceneAsk() }
    }
  }

  // MARK: - Scene three: Ask Boltty

  /// Slides 16–22, as Ask Boltty really draws itself: an app's window
  /// rises; the arrow comes, the face rides
  /// beside it; the chord is held — Listening — and the pointer circles the
  /// video, leaving the real line, soft and gone a moment later; the words
  /// heard; let go, the answer types itself out beside the face.
  private func sceneAsk() {
    guard let clock, let old = scene, let face else { return }
    undock()
    leave(old)
    let view = makeScene()
    let window = keep(ShowAppWindow(in: view, space: space, clock: clock, frame: space.rect(368, 263, 1064, 642)))
    window.rise(from: space.v(-177))
    // The app's menus, where the answer points.
    let menus = ShowMenuBar(in: view, space: space, app: "Clips")
    menus.appear()
    sound(.run, 2)
    after(0.4) { [weak self] in self?.say(Self.captions[3]) }

    let ask = keep(ShowAsk(in: view, face: face, agent: planned, space: space, clock: clock,
                           blips: makesBlips ? AskBolttyBlips() : nil))
    self.ask = ask
    // Round the video: a hand's loop, a little past once, closing in.
    let middle = space.point(1003, 509)
    let reach = CGSize(width: space.v(350), height: space.v(165))
    let loop = { (u: CGFloat) -> CGPoint in
      let angle = CGFloat.pi * 0.8 + u * 2.15 * .pi
      let shrink = 1 - 0.18 * u
      let wobble = 1 + 0.05 * sin(u * 9)
      return CGPoint(x: middle.x + reach.width * shrink * wobble * cos(angle),
                     y: middle.y + reach.height * shrink * sin(angle))
    }
    after(0.15) { [weak self] in
      ask.appear(at: loop(0))
      self?.sound(.whoosh, 4)
    }
    after(0.85) { ask.listen() }
    after(1.05) { [weak self] in
      guard let self else { return }
      self.zoom(to: 1.06, at: middle, duration: 1.8)
      ask.trace(duration: 1.75, along: loop)
    }
    let words = Self.askQuestion.split(separator: " ")
    for count in 1...words.count {
      after(1.35 + 0.3 * Double(count - 1)) {
        ask.heard(words.prefix(count).joined(separator: " "))
      }
    }
    // Let go: the answer, typed out; the camera steps back and the face
    // flies to File, which a ring marks.
    let answerAt = 3.35
    after(answerAt) { [weak self] in
      guard let self else { return }
      ask.answer(Self.askAnswer)
      self.zoom(to: 1, at: middle, duration: 0.9)
    }
    after(answerAt + 0.45) { [weak self] in
      ask.point(at: menus.file)
      self?.sound(.whoosh, 1)
    }
    // And a board beside the answer, drawn as an answer draws one: the
    // menu, Export in it, an arrow to MP4.
    let boardAt = answerAt + 1.3
    after(boardAt) { ask.board(Self.boardShapes) }
    let typed = answerAt + Double(Self.askAnswer.count) / AskBolttyOverlayController.typingSpeed / Self.pace
    // Held long enough to read and follow, then on to Settings.
    after(max(typed + 2.6, boardAt + 4.6)) { [weak self] in
      guard let self else { return }
      self.zoom(to: 1, at: self.space.point(900, 584), duration: 0.9)
      ask.end()
      self.sceneSettings()
    }
  }

  /// What the answer draws on its board, in its 0–1000.
  static let boardShapes: [AskBolttyShape] = [
    AskBolttyShape(kind: .box(CGRect(x: 70, y: 230, width: 440, height: 540)), label: nil),
    AskBolttyShape(kind: .label(at: CGPoint(x: 290, y: 370)), label: "Open…"),
    AskBolttyShape(kind: .label(at: CGPoint(x: 290, y: 630)), label: "Export"),
    AskBolttyShape(kind: .arrow(from: CGPoint(x: 540, y: 630), to: CGPoint(x: 740, y: 630)), label: nil),
    AskBolttyShape(kind: .label(at: CGPoint(x: 850, y: 630)), label: "MP4"),
    AskBolttyShape(kind: .circle(center: CGPoint(x: 850, y: 630), radius: 125), label: nil),
  ]

  // MARK: - Scene four: each agent yours

  /// Settings as its pages stand: the face flies into its agent's page and
  /// tries two shapes before its own; the chat's backdrop goes to Sky, live
  /// over a mock chat; then Usage, each plan's window filling in its
  /// agent's own gradient. Then out, and the setup card follows.
  private func sceneSettings() {
    guard let clock, let old = scene, let face else { return }
    leave(old)
    let view = makeScene()
    let window = keep(ShowSettingsWindow(in: view, space: space, clock: clock, agents: agents, planned: planned,
                                         frame: space.rect(338, 300, 1124, 520)))
    window.rise(from: space.v(-177))
    sound(.run, 2)
    after(0.3) {
      face.view.emotion = .curious
      face.fly(to: window.faceSlot, response: 0.7, bounce: 0.1)
    }
    after(0.4) { [weak self] in self?.say(Self.captions[4]) }
    let own = MascotLook.face(for: planned)
    for (index, shape) in window.tries.enumerated() {
      after(1.4 + 0.6 * Double(index)) { [weak self] in
        window.pick(shape: shape)
        face.view.apply(look: MascotLook(shape: shape, palette: own.palette, finish: own.finish))
        face.view.poke(.boing)
        self?.sound(.tap, index)
      }
    }
    let sky = 1.4 + 0.6 * Double(window.tries.count) + 0.3
    after(sky) { [weak self] in
      window.pick(backdrop: .sky)
      self?.sound(.tap, 4)
    }
    after(sky + 1.5) { [weak self] in
      guard let self else { return }
      window.showUsage()
      face.fly(to: window.usageFaceSlot, response: 0.6, bounce: 0.1)
      self.sound(.whoosh, 1)
    }
    after(sky + 4.3) { [weak self] in
      guard let self else { return }
      self.leave(view)
      face.leave(by: self.space.v(120))
      self.say(nil)
      self.sound(.run, 3)
      self.after(0.45) { [weak self] in self?.finish() }
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
    ask?.end()
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
      self.clearPile()
      self.face = nil
      self.prompt = nil
      self.ask = nil
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

/// The slides' 1800 × 1169 units, y down, mapped onto a screen: one scale
/// for both axes, centred.
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

/// The show's own tweens, on the stage's display link and `Motion.now`, so
/// `-boltty.slowMotion` slows them with everything else. A tween is a curve
/// over a duration, or a spring, which may overshoot past 1.
@MainActor
final class ShowClock: NSObject {
  private struct Tween {
    /// A new tween with the same key replaces this one: two tweens setting
    /// one frame fight, and the frame jitters between them.
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

  /// A spring of `response` seconds and `bounce` (0 is critically damped),
  /// as `CASpringAnimation(perceptualDuration:bounce:)` states one.
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

  /// `step` every frame with the seconds since the one before, for as long
  /// as it answers true: a motion with no length set beforehand — a spring
  /// that may be given a new goal on the way.
  func drive(key: AnyHashable, _ step: @escaping (CFTimeInterval) -> Bool) {
    var last: CFTimeInterval = 0
    add(Tween(key: key, id: makeID(), start: Motion.now, duration: .infinity, value: { CGFloat($0) },
              update: { [weak self] elapsed in
                let now = CFTimeInterval(elapsed)
                defer { last = now }
                if !step(max(0, now - last)) { self?.cancel(key) }
              }, done: nil))
  }

  /// Stops the tween with `key`, where it stands.
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
    // A step may start or stop a tween — a face docked in a growing prompt
    // stops its own flight — so the list is walked as it stood, and one
    // stopped meanwhile is skipped.
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

  /// A move, a scale and a turn about the middle of a view's layer, whose
  /// anchor AppKit keeps at its corner.
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

/// A Gaussian blur on a view's layer, animated — the show's depth of field
/// and motion smear. Not glass: the glass here is drawn (`ShowGlass`), so a
/// filter over it costs nothing live. Once it has settled at nothing the
/// filter comes off, so a layer at rest is drawn as it would be without it.
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

/// A scene's layer: everything in it moves, blurs and fades as one.
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

/// The show's glass: the panel's own (`PaletteGlassHost`, the system's
/// regular glass), light, as the slides draw it.
final class ShowGlass: NSView {
  private let host: PaletteGlassHost
  /// What stands on the glass, **inside it** — the glass's own content.
  /// Laid over the glass as a sibling, anything white on it makes the glass
  /// darken round it, a grey shadow that blinks each time the caret redraws
  /// the window. The glass does not darken round its own content. A
  /// sublayer of the glass view's own layer goes under the material and
  /// shows blurred through it.
  let content = ShowGlassContent()
  /// A hairline of light round it, over the system glass's own darker edge.
  private let rim = CALayer()
  /// Boltty's own glass stands forward of the apps behind it: the shell's
  /// two shadows, a tight contact one and the broad pool a window casts,
  /// each with the glass's shape cut out so neither darkens it from inside.
  private let contact = CALayer()
  private let pool = CALayer()
  private let casts: Bool
  var radius: CGFloat {
    get { host.cornerRadius }
    set {
      host.cornerRadius = newValue
      content.radius = newValue
      needsLayout = true
    }
  }

  init(frame: CGRect, radius: CGFloat, casts: Bool = false) {
    host = PaletteGlassHost(content: content, cornerRadius: radius, style: .bolttyAI, hostsContentInGlass: true)
    self.casts = casts
    super.init(frame: frame)
    wantsLayer = true
    if casts {
      let shadows: [(CALayer, Float, CGFloat, CGSize)] = [
        (pool, PaletteGlassHost.ambientShadowOpacity * Self.shadowStrength, PaletteGlassHost.ambientShadowRadius,
         PaletteGlassHost.ambientShadowOffset),
        (contact, PaletteGlassHost.floatingShadowOpacity * Self.shadowStrength, PaletteGlassHost.floatingShadowRadius,
         PaletteGlassHost.floatingShadowOffset),
      ]
      for (shadow, opacity, blur, offset) in shadows {
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = opacity
        shadow.shadowRadius = blur * Self.shadowScale
        shadow.shadowOffset = CGSize(width: offset.width, height: offset.height * Self.shadowScale)
        let cutout = CAShapeLayer()
        cutout.fillRule = .evenOdd
        shadow.mask = cutout
        layer?.addSublayer(shadow)
      }
    }
    appearance = NSAppearance(named: Self.light ? .aqua : .darkAqua)
    host.translatesAutoresizingMaskIntoConstraints = true
    host.frame = bounds
    host.autoresizingMask = [.width, .height]
    addSubview(host)
    content.radius = radius
    content.shades = Self.light
    rim.borderColor = CGColor(gray: 1, alpha: 0.42)
    rim.borderWidth = 1.5
    rim.cornerCurve = .continuous
    rim.zPosition = 3
    layer?.addSublayer(rim)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rim.frame = bounds.insetBy(dx: -0.5, dy: -0.5)
    rim.cornerRadius = min(radius, bounds.height / 2) + 0.5
    if casts, !bounds.isEmpty {
      let corner = min(radius, bounds.height / 2)
      let shape = CGPath(roundedRect: bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
      let reach = PaletteGlassHost.ambientShadowRadius * Self.shadowScale * 3
        + abs(PaletteGlassHost.ambientShadowOffset.height) * Self.shadowScale
      let cutout = CGMutablePath()
      cutout.addRect(bounds.insetBy(dx: -reach, dy: -reach))
      cutout.addPath(shape)
      for shadow in [pool, contact] {
        shadow.frame = bounds
        shadow.shadowPath = shape
        (shadow.mask as? CAShapeLayer)?.frame = bounds
        (shadow.mask as? CAShapeLayer)?.path = cutout
      }
    }
    CATransaction.commit()
  }

  /// The shell's shadows at the show's size, and lighter: the sunset is a
  /// bright page, and at full strength they read as a smudge on it.
  private static let shadowScale: CGFloat = 1.5
  private static let shadowStrength: Float = 0.6

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// Light glass, as the slides draw it, or the panel's own dark.
  /// `-boltty.show.glass dark` in a Debug build, to compare.
  static let light: Bool = {
    #if DEBUG
    return UserDefaults.standard.string(forKey: "boltty.show.glass") != "dark"
    #else
    return true
    #endif
  }()
}

/// The inside of a `ShowGlass`: the light glass a shade down, under
/// whatever stands on it — on its own it reads too white, and white words
/// on it faint.
final class ShowGlassContent: NSView {
  private let shade = CALayer()
  var shades = false {
    didSet { shade.isHidden = !shades }
  }
  var radius: CGFloat = 0 {
    didSet { needsLayout = true }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    wantsLayer = true
    shade.backgroundColor = CGColor(gray: 0, alpha: 0.13)
    shade.cornerCurve = .continuous
    shade.zPosition = -1
    shade.isHidden = true
    layer?.addSublayer(shade)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shade.frame = bounds
    shade.cornerRadius = min(radius, bounds.height / 2)
    CATransaction.commit()
  }

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

  /// One line of words at `size`, as a label sets it.
  static func height(size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    let probe = label("Ag", size: size, weight: weight)
    probe.sizeToFit()
    return probe.frame.height
  }

  /// `text`'s lines in `width`, wrapped at its spaces as `stream` wraps it.
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

  /// `text` set a word at a time into `view`, each word rising out of a
  /// blur a beat after the one before it.
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

/// The planned agent's face, carried through the whole show — one face from
/// the pile to the last scene, so nothing about it changes under the eye.
/// Drawn at one size and scaled, so its drawable never reallocates.
///
/// It moves on a spring of its own, stepped frame by frame: a new goal
/// mid-flight keeps the speed it has, where a tween started over from rest
/// and the face lurched — a face flying into a prompt that still moved, a
/// drag taking over a landing.
@MainActor
final class ShowFace {
  let holder = NSView()
  let view: MascotNSView
  private let clock: ShowClock
  private let side: CGFloat

  /// Centre, size and turn.
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

  /// Up off its place — a bob while it speaks.
  var lift: CGFloat = 0 {
    didSet { if lift != oldValue { apply() } }
  }

  /// Told where the face stands, every frame it moves.
  var onMove: ((CGRect) -> Void)?
  /// Where it stands this frame.
  var rect: CGRect { pose.rect.offsetBy(dx: 0, dy: lift) }

  init(in parent: NSView, agent: AgentId, side: CGFloat, sharpness: CGFloat, clock: ShowClock) {
    self.clock = clock
    self.side = side
    view = MascotNSView(conversationID: UUID(), look: MascotLook.face(for: agent))
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

  /// There, at once.
  func place(at rect: CGRect, angle: CGFloat = 0) {
    stop()
    pose = Pose(rect, angle: angle)
    goal = pose
    speed = Pose()
    apply()
    // AppKit sets a new view's layer up once more before it is drawn, and
    // that takes the scale back off: a face placed and left there would
    // stand at its full size.
    DispatchQueue.main.async { [weak self] in self?.apply() }
  }

  /// On a spring of `response` and `bounce` to `rect`, from wherever it is
  /// and however fast it is going.
  func fly(to rect: CGRect, response: Double, bounce: Double = 0, angle: CGFloat = 0) {
    goal = Pose(rect, angle: angle)
    self.response = response
    self.bounce = bounce
    guard !moving else { return }
    moving = true
    clock.drive(key: ObjectIdentifier(self)) { [weak self] elapsed in self?.step(elapsed) ?? false }
  }

  /// Kept on `rect`, which moves — a prompt's slot: on it once the face
  /// has landed there, still flying to it until then.
  func hold(_ rect: CGRect) {
    guard moving else {
      pose = Pose(rect, angle: 0)
      goal = pose
      return apply()
    }
    goal = Pose(rect, angle: goal.angle)
  }

  /// Up and away with the scene, fading.
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

/// The prompt: a capsule of glass, the face at its leading end, the words
/// beside it, and Boltty's caret in the face's light — solid while keys
/// come, blinking once they stop, always at the end of the words.
@MainActor
final class ShowPrompt {
  private let space: ShowSpace
  private let clock: ShowClock
  private let glass: ShowGlass
  private let text: NSTextField
  private let hint: NSTextField
  private let caret = CAGradientLayer()
  private var typed = ""
  private var typing = 0
  private(set) var frame: CGRect
  /// Where the capsule stands this frame.
  private var shown: CGRect = .zero
  /// The face standing in the prompt, which goes where the prompt goes.
  var face: ShowFace?

  let fontSize: CGFloat
  var faceSlot: CGRect { slot(in: frame) }
  var textFrame: CGRect { text.frame }

  /// The face's box: a face draws its body inside the box with room to
  /// hop, so the box is larger than the slide's 64 to look as large.
  private func slot(in rect: CGRect) -> CGRect {
    CGRect(x: rect.minX + space.v(8), y: rect.midY - space.v(38), width: space.v(76), height: space.v(76))
  }

  private var textLeading: CGFloat { space.v(90) }

  init(in parent: NSView, space: ShowSpace, clock: ShowClock, frame: CGRect, placeholder: String = "") {
    self.space = space
    self.clock = clock
    self.frame = frame
    // Under the slides' 36, which reads too big on a real screen.
    fontSize = space.v(28)
    glass = ShowGlass(frame: frame, radius: frame.height / 2, casts: true)
    glass.alphaValue = 0
    parent.addSubview(glass)
    text = ShowText.label("", size: fontSize)
    hint = ShowText.label(placeholder, size: fontSize, ink: NSColor.white.withAlphaComponent(0.55))
    hint.alphaValue = 0
    parent.addSubview(hint)
    parent.addSubview(text)
    caret.colors = [HexColor.nsColor("#7fb2ff").cgColor, CGColor(gray: 1, alpha: 1),
                    HexColor.nsColor("#ffc24f").cgColor]
    caret.cornerRadius = space.v(1.5)
    caret.opacity = 0
    parent.layer?.addSublayer(caret)
    shown = frame
    layoutText(in: frame)
  }

  /// Out of a blur, a little small — or, given `start`, out of there: the
  /// panel drips out of the notch.
  func appear(from start: CGRect? = nil) {
    let end = frame
    let start = start ?? end.insetBy(dx: end.width * 0.12, dy: end.height * 0.12)
    ShowClock.fade(glass, to: 1, duration: 0.25)
    ShowClock.fade(hint, to: 1, duration: 0.35)
    clock.spring(0.45, bounce: 0.08, key: ObjectIdentifier(self)) { [weak self] t in
      self?.setFrame(ShowClock.mix(start, end, t))
    }
  }

  func showCaret() {
    caret.opacity = 1
    blink()
  }

  private func blink() {
    let blink = CAKeyframeAnimation(keyPath: "opacity")
    blink.values = [1, 1, 0, 0]
    blink.keyTimes = [0, 0.5, 0.55, 1]
    blink.duration = 1
    blink.repeatCount = .infinity
    caret.add(blink, forKey: "boltty.show.caret")
  }

  /// One more letter. The caret stays lit while keys come; the capsule
  /// widens to the words, chasing them smoothly rather than stepping.
  func type(_ letter: String, maxWidth: CGFloat) {
    typed += letter
    hint.alphaValue = 0
    text.stringValue = typed
    caret.removeAnimation(forKey: "boltty.show.caret")
    caret.opacity = 1
    typing += 1
    let turn = typing
    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(0.6)) { [weak self] in
      guard let self, self.typing == turn else { return }
      self.blink()
    }
    text.sizeToFit()
    let needed = textLeading + text.frame.width + space.v(44)
    let width = min(maxWidth, max(frame.width, needed))
    if width > frame.width + 0.5 {
      frame = CGRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: frame.height)
      follow()
    }
    layoutText(in: shown)
  }

  /// The capsule chases `frame` frame by frame, eased, however often it
  /// moves — a new spring per letter started from rest each time, and the
  /// words and the caret on it lurched.
  private func follow() {
    var last = Motion.now
    clock.tween(0.9, key: ObjectIdentifier(self)) { [weak self] _ in
      guard let self else { return }
      let now = Motion.now
      let step = 1 - exp(-(now - last) / 0.07)
      last = now
      self.setFrame(ShowClock.mix(self.shown, self.frame, CGFloat(step)))
    } done: { [weak self] in
      guard let self else { return }
      self.setFrame(self.frame)
    }
  }

  /// The words the empty prompt shows: the agent it will ask.
  func placeholder(_ words: String) {
    hint.stringValue = words
    layoutText(in: shown)
  }

  /// Gone into what comes next: the list.
  func vanish() {
    ShowClock.fade(glass, to: 0, duration: 0.25)
    ShowClock.fade(text, to: 0, duration: 0.2)
    ShowClock.fade(hint, to: 0, duration: 0.2)
    caret.removeAllAnimations()
    caret.opacity = 0
  }

  func clear(placeholder: String = "") {
    typed = ""
    text.stringValue = ""
    hint.stringValue = placeholder
    ShowClock.fade(hint, to: placeholder.isEmpty ? 0 : 1, duration: 0.3)
    layoutText(in: shown)
  }

  func slide(to rect: CGRect, duration: CFTimeInterval = 0.55) {
    let from = shown
    frame = rect
    clock.spring(duration, bounce: 0.06, key: ObjectIdentifier(self)) { [weak self] t in
      self?.setFrame(ShowClock.mix(from, rect, t))
    }
  }

  private func setFrame(_ rect: CGRect) {
    shown = rect
    glass.frame = rect
    glass.radius = rect.height / 2
    face?.hold(slot(in: rect))
    layoutText(in: rect)
  }

  private func layoutText(in rect: CGRect) {
    text.sizeToFit()
    hint.sizeToFit()
    let x = rect.minX + textLeading
    text.frame.origin = CGPoint(x: x, y: rect.midY - text.frame.height / 2)
    hint.frame.origin = CGPoint(x: x + space.v(6), y: rect.midY - hint.frame.height / 2)
    let end = typed.isEmpty ? x : text.frame.maxX + space.v(2)
    let height = space.v(32)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    caret.frame = CGRect(x: end, y: rect.midY - height / 2, width: space.v(3), height: height)
    CATransaction.commit()
  }
}

/// The chat card: grows up out of the prompt; the words leave the prompt
/// as its question and shrink into the white bubble on the way; the answer
/// a word at a time. As tall as the two need, with one inset round them.
@MainActor
final class ShowChatCard {
  private let space: ShowSpace
  private let clock: ShowClock
  private let parent: NSView
  private let glass: ShowGlass
  private let question: String
  private let reply: String
  let frame: CGRect
  private var bubbleBottom: CGFloat = 0

  /// In slide units: round the card's insides, between the question and
  /// the answer, the bubble's own padding, the type.
  private static let inset: CGFloat = 28
  private static let gap: CGFloat = 20
  private static let bubblePadding = CGSize(width: 18, height: 10)
  private static let questionSize: CGFloat = 24
  private static let answerSize: CGFloat = 26
  private static let lineHeight: CGFloat = 35

  /// A card `width` wide standing on `bottom`, its left edge at `x`.
  init(in parent: NSView, space: ShowSpace, clock: ShowClock, question: String, answer: String,
       x: CGFloat, bottom: CGFloat, width: CGFloat) {
    self.space = space
    self.clock = clock
    self.parent = parent
    self.question = question
    reply = answer
    frame = CGRect(x: x, y: bottom, width: width, height: Self.height(answer: answer, width: width, space: space))
    glass = ShowGlass(frame: frame, radius: space.v(52), casts: true)
    glass.alphaValue = 0
    parent.addSubview(glass)
  }

  /// How tall a card `width` wide is for `answer`: as tall as the question
  /// and the answer need.
  static func height(answer: String, width: CGFloat, space: ShowSpace) -> CGFloat {
    let lines = ShowText.lines(answer, width: width - space.v(inset * 2), size: space.v(answerSize)).count
    let bubble = ShowText.height(size: space.v(questionSize)) + space.v(bubblePadding.height * 2)
    let words = CGFloat(lines - 1) * space.v(lineHeight) + ShowText.height(size: space.v(answerSize))
    return space.v(inset * 2 + gap) + bubble + words
  }

  func grow(from rect: CGRect) {
    let end = frame
    ShowClock.fade(glass, to: 1, duration: 0.2)
    clock.spring(0.45, bounce: 0.05) { [weak self] t in
      guard let self else { return }
      self.glass.frame = ShowClock.mix(rect, end, t)
    }
  }

  func vanish() {
    ShowClock.fade(glass, to: 0, duration: 0.25)
  }

  /// The question: its words leave the prompt at the prompt's size, white,
  /// and land in the corner as the bubble — black on white, at its own size.
  func ask(from start: CGRect, size startSize: CGFloat) {
    let size = space.v(Self.questionSize)
    let ink = ShowText.label(question, size: size, ink: .black)
    ink.sizeToFit()
    let paper = ShowText.label(question, size: size)
    paper.sizeToFit()
    let pad = CGSize(width: space.v(Self.bubblePadding.width), height: space.v(Self.bubblePadding.height))
    let box = CGSize(width: ink.frame.width + pad.width * 2, height: ink.frame.height + pad.height * 2)
    let bubble = NSView(frame: CGRect(origin: .zero, size: box))
    bubble.wantsLayer = true
    bubble.layer?.backgroundColor = CGColor(gray: 1, alpha: 0)
    bubble.layer?.cornerRadius = box.height / 2
    bubble.layer?.cornerCurve = .continuous
    for label in [ink, paper] {
      label.frame.origin = CGPoint(x: pad.width, y: pad.height)
      bubble.addSubview(label)
    }
    ink.alphaValue = 0
    let inset = space.v(Self.inset)
    let end = CGRect(x: frame.maxX - inset - box.width, y: frame.maxY - inset - box.height,
                     width: box.width, height: box.height)
    bubbleBottom = end.minY
    // Where the bubble would stand for its words to be the prompt's, at
    // the prompt's size.
    let grown = startSize / size
    let begin = CGRect(x: start.minX - pad.width * grown, y: start.midY - box.height / 2,
                       width: box.width, height: box.height)
    // The words fly over the glass; landed, they go into it and the white
    // comes. White over the glass, not in it, darkens the glass round it
    // and blinks (see `ShowGlass.content`).
    parent.addSubview(bubble)
    clock.tween(0.48, curve: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.15, 1)) { t in
      let scale = ShowClock.mix(grown, 1, t)
      let place = ShowClock.mix(begin, end, t)
      // Scaled about its leading edge's middle, so the words start where
      // the prompt's did.
      bubble.frame = place
      var transform = CATransform3DMakeTranslation(0, -box.height / 2, 0)
      transform = CATransform3DConcat(transform, CATransform3DMakeScale(scale, scale, 1))
      transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(0, box.height / 2, 0))
      bubble.layer?.transform = transform
    } done: { [weak self] in
      if let self {
        let inside = self.glass.content
        let place = inside.convert(bubble.frame, from: self.parent)
        bubble.removeFromSuperview()
        bubble.layer?.transform = CATransform3DIdentity
        bubble.frame = place
        // Held to the card's top right while it settles.
        bubble.autoresizingMask = [.minXMargin, .minYMargin]
        inside.addSubview(bubble)
      }
      self?.clock.tween(0.2, curve: Motion.standardCurve) { t in
        bubble.layer?.backgroundColor = CGColor(gray: 1, alpha: t)
        paper.alphaValue = 1 - t
        ink.alphaValue = t
      }
    }
  }

  /// The answer, on the glass: inside it, as the bubble is.
  func answer() {
    let inset = space.v(Self.inset)
    let inside = glass.content
    let origin = inside.convert(CGPoint(x: frame.minX + inset, y: bubbleBottom - space.v(Self.gap)), from: parent)
    ShowText.stream(reply, into: inside, at: origin, width: frame.width - inset * 2, size: space.v(Self.answerSize),
                    clock: clock, lineHeight: space.v(Self.lineHeight), pinned: [.maxXMargin, .minYMargin])
  }
}

/// Drawing a made-up window's insides on its glass, in slide units from
/// its top left: blocks, words, a bar, a play button.
@MainActor
struct ShowSketch {
  let view: NSView
  let space: ShowSpace
  let size: CGSize

  private func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: space.v(x), y: size.height - space.v(y + h), width: space.v(w), height: space.v(h))
  }

  @discardableResult
  func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, alpha: CGFloat = 0.3,
             ink: CGColor? = nil, radius: CGFloat) -> CALayer {
    let layer = CALayer()
    layer.frame = frame(x, y, w, h)
    layer.cornerRadius = space.v(radius)
    layer.cornerCurve = .continuous
    layer.backgroundColor = ink ?? CGColor(gray: 1, alpha: alpha)
    view.layer?.addSublayer(layer)
    return layer
  }

  /// A bar of a chart: brighter at its top, as light falls on it.
  func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
    let layer = CAGradientLayer()
    layer.frame = frame(x, y, w, h)
    layer.cornerRadius = space.v(14)
    layer.cornerCurve = .continuous
    layer.colors = [CGColor(gray: 1, alpha: 0.6), CGColor(gray: 1, alpha: 0.22)]
    layer.startPoint = CGPoint(x: 0.5, y: 1)
    layer.endPoint = CGPoint(x: 0.5, y: 0)
    view.layer?.addSublayer(layer)
  }

  /// Words whose middle stands on `y`, from x — or centred in `width` from x.
  func text(_ string: String, at x: CGFloat, middle y: CGFloat, size: CGFloat, ink: NSColor = .white,
            alpha: CGFloat, weight: NSFont.Weight = .regular, width: CGFloat? = nil) {
    let label = ShowText.label(string, size: space.v(size), ink: ink.withAlphaComponent(alpha), weight: weight)
    label.sizeToFit()
    let left = width.map { space.v(x) + (space.v($0) - label.frame.width) / 2 } ?? space.v(x)
    label.frame.origin = CGPoint(x: left.rounded(), y: (self.size.height - space.v(y) - label.frame.height / 2).rounded())
    view.addSubview(label)
  }

  /// A block filled top to foot through `colours`.
  func gradient(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, colours: [CGColor], opacity: Float = 1,
                radius: CGFloat) {
    let layer = CAGradientLayer()
    layer.frame = frame(x, y, w, h)
    layer.cornerRadius = space.v(radius)
    layer.cornerCurve = .continuous
    layer.colors = colours
    layer.startPoint = CGPoint(x: 0.5, y: 1)
    layer.endPoint = CGPoint(x: 0.5, y: 0)
    layer.opacity = opacity
    view.layer?.addSublayer(layer)
  }

  /// An SF Symbol, white, `side` tall, its middle on (x, y).
  func symbol(_ name: String, at x: CGFloat, _ y: CGFloat, side: CGFloat, alpha: CGFloat) {
    let configuration = NSImage.SymbolConfiguration(pointSize: space.v(side), weight: .medium)
      .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration) else { return }
    let icon = NSImageView(image: image)
    icon.frame = CGRect(x: space.v(x) - image.size.width / 2, y: size.height - space.v(y) - image.size.height / 2,
                        width: image.size.width, height: image.size.height).integral
    view.addSubview(icon)
  }

  func play(at x: CGFloat, _ y: CGFloat, side: CGFloat) {
    block(x - side / 2, y - side / 2, side, side, alpha: 0.88, radius: side / 2)
    let triangle = CAShapeLayer()
    let box = frame(x - side * 0.14, y - side * 0.2, side * 0.36, side * 0.4)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: box.minX, y: box.minY))
    path.addLine(to: CGPoint(x: box.maxX, y: box.midY))
    path.addLine(to: CGPoint(x: box.minX, y: box.maxY))
    path.closeSubpath()
    triangle.path = path
    triangle.fillColor = CGColor(gray: 0, alpha: 0.7)
    view.layer?.addSublayer(triangle)
  }
}

/// A window of some app, on the slides' glass, with a chart in it whose
/// fourth bar is short. One inset round everything in it.
@MainActor
final class ShowChartWindow {
  private let clock: ShowClock
  private let glass: ShowGlass
  private(set) var frame: CGRect
  /// Told the window's frame every frame it moves — the selection round it
  /// follows.
  var onFrame: ((CGRect) -> Void)?

  init(in parent: NSView, space: ShowSpace, clock: ShowClock, frame: CGRect) {
    self.clock = clock
    self.frame = frame
    glass = ShowGlass(frame: frame, radius: space.v(52))
    glass.alphaValue = 0
    parent.addSubview(glass, positioned: .below, relativeTo: nil)
    // A sign-ups chart, drawn as a dashboard draws one: its title and the
    // range, a Week/Month switch, the grid, six months of bars — April's
    // the short one — their names under them and the best one's value.
    // 749 × 477, 44 in from every edge.
    let sketch = ShowSketch(view: glass.content, space: space, size: frame.size)
    let inset: CGFloat = 44
    let wide = 749 - inset * 2
    sketch.text("Sign-ups", at: inset, middle: 58, size: 26, alpha: 0.95, weight: .semibold)
    sketch.text("Last 6 months  ·  +18%", at: inset, middle: 92, size: 16, alpha: 0.6)
    let switchX = 749 - inset - 152
    sketch.block(switchX, 39, 152, 38, alpha: 0.16, radius: 19)
    // Month chosen: the bars are months.
    sketch.block(switchX + 76, 43, 72, 30, alpha: 0.34, radius: 15)
    sketch.text("Week", at: switchX + 4, middle: 58, size: 14, alpha: 0.6, width: 72)
    sketch.text("Month", at: switchX + 76, middle: 58, size: 14, alpha: 0.9, weight: .medium, width: 72)
    let foot: CGFloat = 403
    for y: CGFloat in [163, 243, 323] { sketch.block(inset, y, wide, 1.5, alpha: 0.14, radius: 0) }
    let bars: [(height: CGFloat, month: String)] = [
      (118, "Jan"), (150, "Feb"), (184, "Mar"), (72, "Apr"), (198, "May"), (232, "Jun"),
    ]
    let barWidth: CGFloat = 92
    let step = (wide - barWidth) / CGFloat(bars.count - 1)
    for (index, bar) in bars.enumerated() {
      let x = inset + step * CGFloat(index)
      sketch.bar(x, foot - bar.height, barWidth, bar.height)
      sketch.text(bar.month, at: x, middle: foot + 17, size: 14, alpha: 0.6, width: barWidth)
    }
    let best = inset + step * CGFloat(bars.count - 1) + (barWidth - 80) / 2
    let top = foot - bars[bars.count - 1].height - 12 - 30
    sketch.block(best, top, 80, 30, alpha: 0.9, radius: 15)
    sketch.text("4.2k", at: best, middle: top + 15, size: 15, ink: .black, alpha: 0.85, weight: .semibold, width: 80)
  }

  func rise(from distance: CGFloat) {
    let end = frame
    let start = end.offsetBy(dx: 0, dy: distance)
    ShowClock.fade(glass, to: 1, duration: 0.25)
    clock.spring(0.7, bounce: 0.05, key: ObjectIdentifier(self)) { [weak self] t in
      self?.place(ShowClock.mix(start, end, t))
    }
  }

  func move(to rect: CGRect) {
    let from = glass.frame
    frame = rect
    clock.spring(0.6, bounce: 0.05, key: ObjectIdentifier(self)) { [weak self] t in
      self?.place(ShowClock.mix(from, rect, t))
    }
  }

  private func place(_ rect: CGRect) {
    glass.frame = rect
    onFrame?(rect)
  }
}

/// An app's window on the slides' glass: a video editor — the clips down
/// its side, the one open playing in the middle, its timeline under it,
/// the app the question is asked in. 36 in from every edge, 16 between
/// its panes.
@MainActor
final class ShowAppWindow {
  private let clock: ShowClock
  private let glass: ShowGlass
  private let frame: CGRect

  init(in parent: NSView, space: ShowSpace, clock: ShowClock, frame: CGRect) {
    self.clock = clock
    self.frame = frame
    glass = ShowGlass(frame: frame, radius: space.v(64))
    glass.alphaValue = 0
    parent.addSubview(glass, positioned: .below, relativeTo: nil)
    let sketch = ShowSketch(view: glass.content, space: space, size: frame.size)
    sketch.text("launch.mov — Clips", at: 0, middle: 38, size: 17, alpha: 0.85, weight: .medium, width: 1064)
    // The library, each clip with its kind's symbol.
    sketch.block(36, 76, 190, 530, alpha: 0.2, radius: 28)
    sketch.text("Library", at: 58, middle: 106, size: 14, alpha: 0.55, weight: .semibold)
    let clips = [("launch.mov", "film"), ("intro.mov", "film"), ("demo-v2.mov", "film"),
                 ("voiceover.m4a", "waveform"), ("music.m4a", "music.note"), ("logo.png", "photo")]
    for (index, clip) in clips.enumerated() {
      let row = 126 + CGFloat(index) * 46
      if index == 0 { sketch.block(46, row, 170, 40, alpha: 0.28, radius: 12) }
      sketch.symbol(clip.1, at: 70, row + 20, side: 15, alpha: index == 0 ? 0.95 : 0.6)
      sketch.text(clip.0, at: 92, middle: row + 20, size: 15, alpha: index == 0 ? 0.95 : 0.7)
    }
    // The clip, playing: a recording of a screen — this sunset, a window
    // on it, the Dock — letterboxed, its time and how far through.
    sketch.block(242, 76, 786, 380, alpha: 0.18, radius: 28)
    sketch.block(258, 92, 754, 312, ink: CGColor(gray: 0, alpha: 0.32), radius: 12)
    sketch.gradient(390, 100, 490, 296, colours: Self.wallpaper, radius: 6)
    sketch.block(390, 100, 490, 10, ink: CGColor(gray: 0, alpha: 0.18), radius: 0)
    sketch.block(442, 140, 250, 168, alpha: 0.72, radius: 10)
    for (index, width) in [150, 196, 120, 172].enumerated() {
      sketch.block(462, 176 + CGFloat(index) * 26, CGFloat(width), 8, ink: CGColor(gray: 0, alpha: 0.14), radius: 4)
    }
    sketch.block(458, 152, 60, 8, ink: CGColor(gray: 0, alpha: 0.28), radius: 4)
    sketch.block(640, 196, 206, 132, alpha: 0.5, radius: 10)
    sketch.block(548, 366, 174, 18, alpha: 0.34, radius: 7)
    sketch.play(at: 635, 248, side: 66)
    sketch.text("00:42 / 02:16", at: 262, middle: 430, size: 14, alpha: 0.75)
    sketch.block(384, 429, 624, 3, alpha: 0.2, radius: 1.5)
    sketch.block(384, 429, 192, 3, alpha: 0.8, radius: 1.5)
    // The timeline: the clip's frames, its sound under them, the playhead
    // on the third.
    sketch.block(242, 472, 786, 134, alpha: 0.14, radius: 28)
    for index in 0..<8 {
      sketch.gradient(260 + CGFloat(index) * 94.5, 494, 84, 52, colours: Self.wallpaper,
                      opacity: index == 2 ? 0.95 : 0.6, radius: 10)
    }
    for index in 0..<106 {
      let level = 0.35 + 0.65 * abs(sin(CGFloat(index) * 0.37) * cos(CGFloat(index) * 0.11))
      let height = 4 + 24 * level
      sketch.block(262 + CGFloat(index) * 7, 574 - height / 2, 3, height, alpha: 0.32, radius: 1.5)
    }
    sketch.block(478, 486, 2.5, 106, alpha: 0.95, radius: 1)
    sketch.block(471, 482, 16, 10, alpha: 0.95, radius: 5)
  }

  /// The recording's wallpaper: the show's own sunset, top to foot.
  private static let wallpaper = [
    HexColor.nsColor("#3a5aa6").cgColor, HexColor.nsColor("#8ea3d0").cgColor,
    HexColor.nsColor("#f1b97c").cgColor, HexColor.nsColor("#e4744a").cgColor,
  ]

  func rise(from distance: CGFloat) {
    let end = frame
    let start = end.offsetBy(dx: 0, dy: distance)
    ShowClock.fade(glass, to: 1, duration: 0.25)
    clock.spring(0.75, bounce: 0.05) { [weak self] t in self?.glass.frame = ShowClock.mix(start, end, t) }
  }
}

/// The menu bar of the app the question is asked in, across the top of
/// the screen as the Mac draws it: the Apple menu, the app's name, its
/// menus, the clock. Where the answer points.
@MainActor
final class ShowMenuBar {
  private var labels: [NSView] = []
  /// The File menu's title, where the answer points.
  private(set) var file: CGRect = .zero

  init(in view: NSView, space: ShowSpace, app: String) {
    let size: CGFloat = 20
    let middle = space.point(0, 20).y
    var x = space.point(42, 0).x
    if let apple = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: space.v(size), weight: .medium)
        .applying(.init(paletteColors: [.white]))) {
      let icon = NSImageView(image: apple)
      icon.frame = CGRect(x: x, y: middle - apple.size.height / 2, width: apple.size.width,
                          height: apple.size.height).integral
      view.addSubview(icon)
      labels.append(icon)
      x = icon.frame.maxX + space.v(30)
    }
    for (index, title) in [app, "File", "Edit", "View", "Clip", "Window", "Help"].enumerated() {
      let label = ShowText.label(title, size: space.v(size), weight: index == 0 ? .bold : .medium)
      label.sizeToFit()
      label.frame.origin = CGPoint(x: x.rounded(), y: (middle - label.frame.height / 2).rounded())
      view.addSubview(label)
      labels.append(label)
      if title == "File" { file = label.frame }
      x = label.frame.maxX + space.v(30)
    }
    let clock = ShowText.label("Fri 9:41", size: space.v(size), weight: .medium)
    clock.sizeToFit()
    clock.frame.origin = CGPoint(x: (space.point(1800 - 42, 0).x - clock.frame.width).rounded(),
                                 y: (middle - clock.frame.height / 2).rounded())
    view.addSubview(clock)
    labels.append(clock)
    for label in labels { label.alphaValue = 0 }
  }

  func appear() {
    for label in labels { ShowClock.fade(label, to: 1, duration: 0.4) }
  }
}

/// Ask Boltty as the screen draws it (`AskBolttyOverlayController`), at the
/// show's size: the arrow, the face riding just past it, the line the
/// pointer leaves — the real one, `AskBolttyTrailLayer`, soft and gone a
/// moment after it is drawn — and the bubble beside the face: dark glass
/// under the same shade, its words a step up, the answer typed out a
/// letter at a time with a blip every other one while the face bobs.
@MainActor
final class ShowAsk {
  /// The overlay's points in slide units: as much larger as the show draws
  /// the panel.
  static let size: CGFloat = 1.5

  private let space: ShowSpace
  private let clock: ShowClock
  private let face: ShowFace
  private let agent: AgentId
  private let arrow = CALayer()
  private let hotSpot: CGPoint
  private let trail = AskBolttyTrailLayer()
  /// The real answer's drawing, for the ring round what it points at.
  private let drawing = AskBolttyDrawingLayer()
  /// The answer's board and what it draws on it.
  private let boardDrawing = AskBolttyDrawingLayer()
  /// Smaller than the overlay's 320: at the show's size the board stood
  /// over most of the app's window.
  static let boardSide: CGFloat = 240
  static let drawingLightness = 0.88
  private let bubble: PaletteGlassHost
  private let shade = NSView()
  private let label = NSTextField(wrappingLabelWithString: "")
  private let font: NSFont
  private let lineHeight: CGFloat
  private let blips: AskBolttyBlips?
  private var text = ""
  /// The bubble's size now, chasing the size its words need.
  private var shownSize: CGSize = .zero

  /// `points` of the overlay, here.
  private func pt(_ points: CGFloat) -> CGFloat { space.v(points * Self.size) }

  init(in view: NSView, face: ShowFace, agent: AgentId, space: ShowSpace, clock: ShowClock, blips: AskBolttyBlips?) {
    self.space = space
    self.clock = clock
    self.face = face
    self.agent = agent
    self.blips = blips
    let backing = view.window?.backingScaleFactor ?? 2
    let scale = space.v(Self.size)

    trail.frame = view.bounds
    trail.contentsScale = backing
    trail.colours = MascotLook.face(for: agent).palette.light(atLeast: AgentPaletteMetrics.screenSelectionLightness)
    trail.lineScale = scale
    trail.zPosition = 300
    view.layer?.addSublayer(trail)
    // Lighter than the trail, and over a soft dark shadow: the gradient's
    // blue top read as nothing on the dark sky at the screen's top.
    let ink = MascotLook.face(for: agent).palette.light(atLeast: Self.drawingLightness)
    for layer in [drawing, boardDrawing] {
      layer.contentsScale = backing
      layer.colours = ink
      layer.scale = scale
      layer.shadowColor = NSColor.black.cgColor
      layer.shadowOpacity = 0.45
      layer.shadowRadius = 3 * scale
      layer.shadowOffset = .zero
    }
    drawing.frame = view.bounds
    drawing.zPosition = 290
    view.layer?.addSublayer(drawing)

    font = roundedAppFont(size: (AgentPaletteMetrics.typePrimary * scale).rounded(), weight: .medium)
    lineHeight = {
      let cell = NSTextFieldCell(textCell: "Ag")
      cell.font = roundedAppFont(size: (AgentPaletteMetrics.typePrimary * scale).rounded(), weight: .medium)
      return ceil(cell.cellSize.height)
    }()
    shade.wantsLayer = true
    shade.layer?.backgroundColor = AskBolttyOverlayController.bubbleShade.cgColor
    shade.layer?.cornerCurve = .continuous
    label.font = font
    label.isSelectable = false
    label.cell?.truncatesLastVisibleLine = true
    label.translatesAutoresizingMaskIntoConstraints = false
    shade.addSubview(label)
    let padding = AskBolttyOverlayController.bubblePadding
    // From the top: an answer typed out fills its first line, then the
    // next, and nothing above moves.
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: shade.leadingAnchor, constant: padding.width * scale),
      label.trailingAnchor.constraint(equalTo: shade.trailingAnchor, constant: -padding.width * scale),
      label.topAnchor.constraint(equalTo: shade.topAnchor, constant: padding.height * scale),
    ])
    bubble = PaletteGlassHost(content: shade, cornerRadius: AskBolttyOverlayController.bubbleCornerRadius * scale,
                              style: .bolttyAI)
    bubble.appearance = NSAppearance(named: .darkAqua)
    bubble.translatesAutoresizingMaskIntoConstraints = true
    bubble.alphaValue = 0
    view.addSubview(bubble)
    bubble.layer?.zPosition = 350

    let cursor = NSCursor.arrow
    let image = cursor.image
    hotSpot = cursor.hotSpot
    arrow.contents = image.layerContents(forContentsScale: image.recommendedLayerContentsScale(backing * scale))
    arrow.contentsGravity = .resize
    arrow.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
    arrow.anchorPoint = .zero
    arrow.opacity = 0
    arrow.zPosition = 400
    view.layer?.addSublayer(arrow)
  }

  /// Where the face rides for the pointer at `tip`: past the arrow, under it.
  private func beside(_ tip: CGPoint) -> CGRect {
    let offset = AskBolttyOverlayController.pointerOffset
    let side = pt(AskBolttyOverlayController.faceSide)
    return CGRect(x: tip.x + pt(offset.dx) - side / 2, y: tip.y + pt(offset.dy) - side / 2, width: side, height: side)
  }

  private func point(to tip: CGPoint) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let scale = space.v(Self.size)
    arrow.position = CGPoint(x: tip.x - hotSpot.x * scale, y: tip.y + hotSpot.y * scale - arrow.bounds.height)
    CATransaction.commit()
  }

  /// The arrow comes, and the face flies to its side.
  func appear(at tip: CGPoint) {
    point(to: tip)
    ShowClock.fade(arrow, to: 1, duration: 0.2)
    face.fly(to: beside(tip), response: 0.65, bounce: 0.1)
  }

  /// The chord is held.
  func listen() {
    face.onMove = { [weak self] rect in self?.layoutBubble(beside: rect) }
    face.view.emotion = .listening
    say("Listening…", quiet: true, lines: 1)
    ShowClock.fade(bubble, to: 1, duration: Motion.quick)
  }

  /// The words heard so far.
  func heard(_ words: String) {
    say(words, quiet: false, lines: 1)
  }

  /// The pointer along `path` (0 to 1) over `duration`, the line behind it,
  /// the face after it.
  func trace(duration: CFTimeInterval, along path: @escaping (CGFloat) -> CGPoint) {
    var last: CGFloat = 0
    clock.tween(duration, curve: CAMediaTimingFunction(controlPoints: 0.42, 0, 0.45, 1), key: "boltty.show.trace") {
      [weak self] t in
      guard let self else { return }
      // A few points a frame, as a hand's samples come.
      for part in 1...4 { self.trail.extend(to: path(last + (t - last) * CGFloat(part) / 4)) }
      last = t
      let tip = path(t)
      self.point(to: tip)
      self.face.fly(to: self.beside(tip), response: 0.18)
    } done: { [weak self] in
      guard let self else { return }
      self.trail.finish()
      self.clock.drive(key: "boltty.show.trail") { [weak self] _ in
        guard let self else { return false }
        self.trail.sweep()
        return !self.trail.isEmpty
      }
    }
  }

  /// Let go: the answer, typed out with its blips, the face bobbing.
  func answer(_ answer: String) {
    face.view.emotion = .focused
    say(answer, quiet: false, lines: AskBolttyOverlayController.bubbleMaxLines)
    label.stringValue = ""
    var typed: Double = 0
    var lastBlip = 0
    let pitch = AskBolttyOverlayController.basePitch(for: agent)
    clock.drive(key: "boltty.show.typing") { [weak self] elapsed in
      guard let self else { return false }
      typed = min(Double(answer.count), typed + elapsed * AskBolttyOverlayController.typingSpeed)
      let shown = Int(typed)
      self.label.stringValue = String(answer.prefix(shown))
      if shown - lastBlip >= 2 {
        lastBlip = shown
        let letter = answer[answer.index(answer.startIndex, offsetBy: shown - 1)]
        if letter.isLetter || letter.isNumber { self.blips?.blip(pitch: pitch * Double.random(in: 0.88...1.14)) }
      }
      let speaking = shown < answer.count
      self.face.lift = speaking
        ? self.pt(AskBolttyOverlayController.bobHeight) * CGFloat(abs(sin(Motion.now * 18))) : 0
      return speaking
    }
  }

  /// The answer points at `spot`: the face flies there and lands beside it,
  /// as the overlay's does, and a ring marks it once it has landed.
  func point(at spot: CGRect) {
    let target = CGPoint(x: spot.midX, y: spot.midY)
    let offset = AskBolttyOverlayController.landingOffset
    let side = pt(AskBolttyOverlayController.faceSide)
    face.view.emotion = .curious
    face.fly(to: CGRect(x: target.x + pt(offset.dx) - side / 2, y: target.y + pt(offset.dy) - side / 2,
                        width: side, height: side), response: 0.6, bounce: 0.12)
    let bounds = drawing.bounds
    guard bounds.width > 0, bounds.height > 0 else { return }
    let radius = max(spot.width, spot.height) / 2 + pt(8)
    let ring = AskBolttyShape(kind: .circle(
      center: CGPoint(x: (target.x - bounds.minX) / bounds.width * 1000,
                      y: (bounds.maxY - target.y) / bounds.height * 1000),
      radius: radius / bounds.width * 1000), label: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(0.45)) { [weak self] in
      self?.drawing.draw(ring, in: bounds)
    }
  }

  /// The board beside the bubble, as the overlay puts one up, and `shapes`
  /// drawn on it one after another.
  func board(_ shapes: [AskBolttyShape]) {
    guard let parent = bubble.superview else { return }
    let side = pt(Self.boardSide)
    let gap = pt(AskBolttyOverlayController.boardGap)
    let margin = pt(AskBolttyOverlayController.edgeMargin)
    let anchor = bubble.frame
    var x = anchor.maxX + gap
    if x + side > parent.bounds.maxX - margin { x = anchor.minX - gap - side }
    let y = min(max(anchor.midY - side / 2, margin), parent.bounds.maxY - margin - side)
    let corner = pt(AskBolttyOverlayController.boardCornerRadius)
    let content = NSView()
    content.wantsLayer = true
    content.layer?.backgroundColor = AskBolttyOverlayController.bubbleShade.cgColor
    content.layer?.cornerRadius = corner
    content.layer?.cornerCurve = .continuous
    content.layer?.addSublayer(boardDrawing)
    let host = PaletteGlassHost(content: content, cornerRadius: corner, style: .bolttyAI)
    host.appearance = NSAppearance(named: .darkAqua)
    host.translatesAutoresizingMaskIntoConstraints = true
    host.frame = CGRect(x: x, y: y, width: side, height: side)
    // A glass host takes its corner when it is set: again, now it has a size.
    host.cornerRadius = corner
    host.alphaValue = 0
    parent.addSubview(host)
    host.layer?.zPosition = 340
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    boardDrawing.frame = CGRect(origin: .zero, size: host.frame.size)
    CATransaction.commit()
    ShowClock.fade(host, to: 1, duration: Motion.standard)
    let inset = pt(AskBolttyOverlayController.boardInset)
    let surface = boardDrawing.bounds.insetBy(dx: inset, dy: inset)
    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(0.3)) { [weak self] in
      for shape in shapes { self?.boardDrawing.draw(shape, in: surface) }
    }
  }

  func end() {
    clock.cancel("boltty.show.typing")
    face.onMove = nil
    face.lift = 0
    blips?.stop()
  }

  // MARK: - The bubble

  /// Listening, the words still coming are what matter: one line, its start
  /// cut. The answer wraps.
  private func say(_ words: String, quiet: Bool, lines: Int) {
    text = words
    label.textColor = NSColor.white.withAlphaComponent(quiet ? 0.55 : 0.85)
    label.maximumNumberOfLines = lines
    label.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingHead
    label.stringValue = words
    let size = measure(words, lines: lines)
    // Wrapped at the bubble's own width, not the widest it may be: a line
    // that fitted the widest and not the bubble ended in "…".
    label.preferredMaxLayoutWidth = size.width - pt(AskBolttyOverlayController.bubblePadding.width) * 2
    let from = shownSize == .zero ? size : shownSize
    // Quick: a word heard widens it before the words are cut short.
    clock.spring(0.18, key: ObjectIdentifier(bubble)) { [weak self] t in
      guard let self else { return }
      self.shownSize = CGSize(width: ShowClock.mix(from.width, size.width, t),
                              height: ShowClock.mix(from.height, size.height, t))
      self.layoutBubble(beside: self.face.rect)
    }
  }

  /// The bubble round `text`, measured as the overlay measures its own.
  private func measure(_ text: String, lines: Int) -> CGSize {
    let cell = NSTextFieldCell(textCell: text)
    cell.font = font
    cell.wraps = lines > 1
    cell.isScrollable = false
    cell.truncatesLastVisibleLine = true
    cell.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingHead
    let widest = pt(AskBolttyOverlayController.bubbleMaxTextWidth)
    let measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: widest, height: .greatestFiniteMagnitude))
    let height = min(ceil(measured.height), lineHeight * CGFloat(lines))
    let padding = AskBolttyOverlayController.bubblePadding
    return CGSize(width: min(ceil(measured.width), widest) + pt(padding.width) * 2,
                  height: max(height, lineHeight) + pt(padding.height) * 2)
  }

  /// Beside the face: to its right where it fits, else to its left,
  /// centred on it.
  private func layoutBubble(beside face: CGRect) {
    guard shownSize != .zero, let bounds = bubble.superview?.bounds else { return }
    let gap = pt(AskBolttyOverlayController.bubbleGap)
    var x = face.maxX + gap
    if x + shownSize.width > bounds.maxX - pt(AskBolttyOverlayController.edgeMargin) {
      x = face.minX - gap - shownSize.width
    }
    let resized = bubble.frame.size != shownSize
    bubble.frame = CGRect(x: x, y: face.midY - shownSize.height / 2, width: shownSize.width, height: shownSize.height)
    // Set again whenever the size changes, the value the same or not: the
    // glass takes its corner from a set, and the one given while it had no
    // size leaves it square round a rounded shade.
    guard resized else { return }
    let corner = min(pt(AskBolttyOverlayController.bubbleCornerRadius), shownSize.height / 2)
    bubble.cornerRadius = corner
    shade.layer?.cornerRadius = corner
  }
}

// MARK: - More pieces

/// A face as a still picture, as the chat list and Settings draw the faces
/// that are not speaking.
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

/// A key being pressed, on a small glass cap under what it acts on.
@MainActor
final class ShowKeycap {
  private let glass: ShowGlass
  private let clock: ShowClock

  init(in parent: NSView, space: ShowSpace, clock: ShowClock, keys: String, under rect: CGRect) {
    self.clock = clock
    let label = ShowText.label(keys, size: space.v(20), weight: .semibold)
    label.sizeToFit()
    let size = CGSize(width: max(label.frame.width + space.v(32), space.v(48)), height: space.v(44))
    let frame = CGRect(x: rect.midX - size.width / 2, y: rect.minY - space.v(22) - size.height,
                       width: size.width, height: size.height).integral
    glass = ShowGlass(frame: frame, radius: frame.height / 2, casts: true)
    glass.alphaValue = 0
    label.frame.origin = CGPoint(x: ((frame.width - label.frame.width) / 2).rounded(),
                                 y: ((frame.height - label.frame.height) / 2).rounded())
    glass.content.addSubview(label)
    parent.addSubview(glass)
  }

  func show() { ShowClock.fade(glass, to: 1, duration: 0.2) }
  func hide() { ShowClock.fade(glass, to: 0, duration: 0.25) }

  /// Down and back up, about its middle.
  func press() {
    let size = glass.frame.size
    clock.tween(0.2, curve: Motion.standardCurve, key: ObjectIdentifier(self)) { [weak self] t in
      self?.glass.layer?.transform = ShowClock.transform(size: size, translation: .zero,
                                                         scale: 1 - 0.1 * sin(.pi * t), rotation: 0)
    }
  }
}

/// The chat list: a tab for all and one per agent, the chats by day, the
/// one just had chosen. Choosing the planned agent's tab keeps only its
/// chats, which close up under their days without their faces — the tab
/// already says whose they are.
@MainActor
final class ShowChatList {
  static let width: CGFloat = 760
  /// Five rows tall, as the list is: more chats run on under its foot.
  static let height: CGFloat = 460
  private static let inset: CGFloat = 20
  private static let tabsTop: CGFloat = 18
  private static let tabHeight: CGFloat = 56
  private static let listTop: CGFloat = 92
  private static let headingHeight: CGFloat = 38
  private static let rowHeight: CGFloat = 62
  private static let wordsLeading: CGFloat = 62
  private static let titles = [
    "Fix the flaky sign-up test", "Why is the build slow?", "Rename the pricing tiers",
    "Sort the screenshots by date",
  ]

  private struct Row {
    let agent: AgentId
    let view: NSView
    let face: NSView
    let words: NSView
    let day: Int
  }

  private let space: ShowSpace
  private let clock: ShowClock
  private let glass: ShowGlass
  private let planned: AgentId
  let frame: CGRect
  private let pill = NSView()
  /// The days and their chats, cut off straight above the glass's foot.
  private let rowsView = NSView()
  private var tabs: [AgentId?: CGRect] = [:]
  private var rows: [Row] = []
  private var headings: [NSView] = []
  /// Where the planned agent's live face stands, in the parent's space.
  private(set) var liveSlot: CGRect = .zero

  private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: space.v(x), y: frame.height - space.v(y + h), width: space.v(w), height: space.v(h))
  }

  /// `box` in the rows' own space.
  private func row(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    box(x, y, w, h).offsetBy(dx: 0, dy: -rowsView.frame.minY)
  }

  init(in parent: NSView, space: ShowSpace, clock: ShowClock, agents: [AgentId], planned: AgentId, frame: CGRect) {
    self.space = space
    self.clock = clock
    self.planned = planned
    self.frame = frame
    glass = ShowGlass(frame: frame, radius: space.v(40), casts: true)
    glass.alphaValue = 0
    parent.addSubview(glass)
    let content = glass.content

    pill.wantsLayer = true
    pill.layer?.backgroundColor = CGColor(gray: 1, alpha: 0.22)
    pill.layer?.cornerCurve = .continuous
    content.addSubview(pill)
    var x = Self.inset
    let all = box(x, Self.tabsTop, 84, Self.tabHeight)
    tabs[.none] = all
    let allLabel = ShowText.label("All", size: space.v(18), weight: .semibold)
    allLabel.sizeToFit()
    allLabel.frame.origin = CGPoint(x: (all.midX - allLabel.frame.width / 2).rounded(),
                                    y: (all.midY - allLabel.frame.height / 2).rounded())
    content.addSubview(allLabel)
    x += 84 + 6
    // The tabs share the strip.
    let tabWidth = min(120, (Self.width - Self.inset * 2 - 90) / CGFloat(max(1, agents.count)) - 6)
    for agent in agents {
      let tab = box(x, Self.tabsTop, tabWidth, Self.tabHeight)
      tabs[agent] = tab
      if agent == planned {
        // Room round the face to hop, as the prompt's slot has.
        let side = space.v(52)
        liveSlot = CGRect(x: frame.minX + tab.midX - side / 2, y: frame.minY + tab.midY - side / 2,
                          width: side, height: side)
      } else {
        let side = space.v(40)
        content.addSubview(ShowStill.face(MascotLook.face(for: agent), in: CGRect(
          x: tab.midX - side / 2, y: tab.midY - side / 2, width: side, height: side).integral))
      }
      x += tabWidth + 6
    }
    place(pill: all)

    rowsView.frame = box(0, Self.listTop, Self.width, Self.height - Self.listTop - 14)
    rowsView.wantsLayer = true
    rowsView.layer?.masksToBounds = true
    content.addSubview(rowsView)
    // The planned agent's chats among the others', so its tab still fills
    // the list once the others' have gone.
    let others = agents.filter { $0 != planned }
    let own: [(String, String?)] = [
      (FirstRunShowController.prompt, "Done — launch.mp4 is 18 MB"), ("Pick a thumbnail for the video", nil),
      ("Draft the launch post", nil), ("Check the press kit’s links", nil),
    ]
    var days: [[(AgentId, String, String?)]] = [[], []]
    for slot in 0..<8 {
      let day = slot / 4
      let index = slot % 4
      if index % 2 == 0 {
        let item = own[day * 2 + index / 2]
        days[day].append((planned, item.0, item.1))
      } else {
        let other = day * 2 + index / 2
        if other < others.count { days[day].append((others[other], Self.titles[other % Self.titles.count], nil)) }
      }
    }
    var y = Self.listTop
    let wide = Self.width - Self.inset * 2
    for (day, items) in days.enumerated() {
      let heading = ShowText.label(day == 0 ? "Today" : "Yesterday", size: space.v(15),
                                   ink: NSColor.white.withAlphaComponent(0.55), weight: .semibold)
      heading.sizeToFit()
      let line = row(Self.inset + 14, y, wide, Self.headingHeight)
      heading.frame.origin = CGPoint(x: line.minX.rounded(), y: (line.midY - heading.frame.height / 2).rounded())
      rowsView.addSubview(heading)
      headings.append(heading)
      y += Self.headingHeight
      for (index, item) in items.enumerated() {
        let view = NSView(frame: row(Self.inset, y, wide, Self.rowHeight))
        view.wantsLayer = true
        if day == 0, index == 0 {
          // The chosen row: a flat fill, no edge.
          view.layer?.backgroundColor = CGColor(gray: 1, alpha: 0.14)
          view.layer?.cornerRadius = space.v(16)
          view.layer?.cornerCurve = .continuous
        }
        let height = view.frame.height
        let side = space.v(34)
        let face = ShowStill.face(MascotLook.face(for: item.0), in: CGRect(
          x: space.v(14), y: (height - side) / 2, width: side, height: side).integral)
        view.addSubview(face)
        let words = NSView(frame: CGRect(x: space.v(Self.wordsLeading), y: 0,
                                         width: view.frame.width - space.v(Self.wordsLeading), height: height))
        let title = ShowText.label(item.1, size: space.v(17), weight: day == 0 && index == 0 ? .semibold : .regular)
        title.sizeToFit()
        title.frame.origin = CGPoint(x: 0, y: (height - space.v(22) - title.frame.height / 2).rounded())
        words.addSubview(title)
        if let note = item.2 {
          let label = ShowText.label(note, size: space.v(14), ink: NSColor.white.withAlphaComponent(0.6))
          label.sizeToFit()
          label.frame.origin = CGPoint(x: 0, y: (height - space.v(44) - label.frame.height / 2).rounded())
          words.addSubview(label)
        } else {
          let bar = NSView(frame: CGRect(x: 0, y: (height - space.v(46)).rounded(),
                                         width: space.v(CGFloat(150 + (index * 70) % 140)), height: space.v(8)))
          bar.wantsLayer = true
          bar.layer?.backgroundColor = CGColor(gray: 1, alpha: 0.16)
          bar.layer?.cornerRadius = bar.frame.height / 2
          words.addSubview(bar)
        }
        view.addSubview(words)
        rowsView.addSubview(view)
        rows.append(Row(agent: item.0, view: view, face: face, words: words, day: day))
        y += Self.rowHeight
      }
    }
  }

  private func place(pill rect: CGRect) {
    pill.frame = rect
    pill.layer?.cornerRadius = rect.height / 2
  }

  func grow(from rect: CGRect) {
    let end = frame
    ShowClock.fade(glass, to: 1, duration: 0.2)
    clock.spring(0.45, bounce: 0.05, key: ObjectIdentifier(self)) { [weak self] t in
      self?.glass.frame = ShowClock.mix(rect, end, t)
    }
  }

  /// The planned agent's tab: the pill goes there, the others' chats go,
  /// its own close up under their days.
  func choose() {
    guard let tab = tabs[planned] else { return }
    let from = pill.frame
    clock.spring(0.4, bounce: 0.1, key: ObjectIdentifier(pill)) { [weak self] t in
      self?.place(pill: ShowClock.mix(from, tab, t))
    }
    var y = Self.listTop
    let wide = Self.width - Self.inset * 2
    for day in 0..<2 {
      let heading = headings[day]
      let line = row(Self.inset + 14, y, wide, Self.headingHeight)
      let headingFrom = heading.frame.origin
      let headingTo = CGPoint(x: headingFrom.x, y: (line.midY - heading.frame.height / 2).rounded())
      clock.spring(0.45, bounce: 0.05, key: ObjectIdentifier(heading)) { t in
        heading.frame.origin = ShowClock.mix(headingFrom, headingTo, t)
      }
      y += Self.headingHeight
      for item in rows where item.day == day {
        guard item.agent == planned else {
          ShowClock.fade(item.view, to: 0, duration: 0.2)
          continue
        }
        ShowClock.fade(item.face, to: 0, duration: 0.2)
        let rowFrom = item.view.frame
        let rowTo = row(Self.inset, y, wide, Self.rowHeight)
        let wordsFrom = item.words.frame
        let wordsTo = wordsFrom.offsetBy(dx: space.v(14) - wordsFrom.minX + space.v(6), dy: 0)
        clock.spring(0.45, bounce: 0.05, key: ObjectIdentifier(item.view)) { t in
          item.view.frame = ShowClock.mix(rowFrom, rowTo, t)
          item.words.frame = ShowClock.mix(wordsFrom, wordsTo, t)
        }
        y += Self.rowHeight
      }
    }
  }
}

/// Settings, as its Agents and Usage pages stand: the sidebar of pages;
/// the agent's page with its face, the six shapes and the chat backdrops
/// beside a mock chat that wears the chosen one, live; then Usage, a meter
/// per agent in its own gradient.
@MainActor
final class ShowSettingsWindow {
  private static let pages: [(symbol: String, title: String)] = [
    ("gearshape", "General"), ("person.2", "Agents"), ("chart.bar", "Usage"), ("waveform", "Voice"),
    ("cursorarrow.rays", "Ask Boltty"), ("keyboard", "Shortcuts"),
  ]
  private static let backdrops: [ChatBackdrop] = [.standard, .sky, .space, .matrix]
  private static let usage: [(left: CGFloat, words: String)] = [
    (0.62, "62% left · back in 2 h"), (0.35, "35% left · back on Monday"), (0.81, "81% left · back in 5 h"),
  ]

  private let space: ShowSpace
  private let clock: ShowClock
  private let glass: ShowGlass
  private let frame: CGRect
  private let palette: MascotPalette
  private let sidebarPill = NSView()
  private let agentsPage = NSView()
  private let usagePage = NSView()
  private let shapePill = NSView()
  private let backdropPill = NSView()
  private var shapeCells: [MascotShape: CGRect] = [:]
  private var backdropCells: [ChatBackdrop: CGRect] = [:]
  private let preview = NSView()
  private let backdrop: AgentBackdropView
  private var meters: [(fill: CAGradientLayer, track: CGRect, left: CGFloat)] = []
  /// The shapes the face tries, its own last.
  let tries: [MascotShape]
  /// Where the live face stands on each page, in the parent's space.
  private(set) var faceSlot: CGRect = .zero
  private(set) var usageFaceSlot: CGRect = .zero

  /// In the window, y from its top.
  private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: space.v(x), y: frame.height - space.v(y + h), width: space.v(w), height: space.v(h))
  }

  private func parent(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: frame.minX, dy: frame.minY) }

  private func fill(_ view: NSView, alpha: CGFloat, radius: CGFloat) {
    view.wantsLayer = true
    view.layer?.backgroundColor = CGColor(gray: 1, alpha: alpha)
    view.layer?.cornerRadius = radius
    view.layer?.cornerCurve = .continuous
  }

  private func label(_ words: String, size: CGFloat, alpha: CGFloat = 0.95, weight: NSFont.Weight = .regular,
                     x: CGFloat, middle: CGFloat, in view: NSView) {
    let label = ShowText.label(words, size: space.v(size), ink: NSColor.white.withAlphaComponent(alpha),
                               weight: weight)
    label.sizeToFit()
    label.frame.origin = CGPoint(x: space.v(x).rounded(),
                                 y: (frame.height - space.v(middle) - label.frame.height / 2).rounded())
    view.addSubview(label)
  }

  init(in parent: NSView, space: ShowSpace, clock: ShowClock, agents: [AgentId], planned: AgentId, frame: CGRect) {
    self.space = space
    self.clock = clock
    self.frame = frame
    let own = MascotLook.face(for: planned)
    palette = own.palette
    let shapes = MascotShape.allCases
    let start = shapes.firstIndex(of: own.shape) ?? 0
    tries = [shapes[(start + 1) % shapes.count], shapes[(start + 2) % shapes.count], own.shape]
    glass = ShowGlass(frame: frame, radius: space.v(52), casts: true)
    glass.alphaValue = 0
    parent.addSubview(glass)
    let content = glass.content
    backdrop = AgentBackdropView(frame: .zero)

    // The sidebar.
    let sidebar = NSView(frame: box(20, 20, 250, 480))
    fill(sidebar, alpha: 0.12, radius: space.v(32))
    content.addSubview(sidebar)
    fill(sidebarPill, alpha: 0.22, radius: space.v(20))
    sidebarPill.frame = box(32, 34 + 50, 226, 40)
    content.addSubview(sidebarPill)
    let sketch = ShowSketch(view: content, space: space, size: frame.size)
    for (index, page) in Self.pages.enumerated() {
      let middle = 54 + CGFloat(index) * 50
      sketch.symbol(page.symbol, at: 62, middle, side: 16, alpha: 0.85)
      sketch.text(page.title, at: 86, middle: middle, size: 17, alpha: 0.9, weight: .medium)
    }

    // The agent's page.
    agentsPage.frame = CGRect(origin: .zero, size: frame.size)
    agentsPage.wantsLayer = true
    content.addSubview(agentsPage)
    faceSlot = self.parent(box(300, 34, 104, 104))
    label(planned.displayName, size: 30, weight: .semibold, x: 420, middle: 74, in: agentsPage)
    let tag = ShowText.label("Preferred", size: space.v(14), weight: .semibold)
    tag.sizeToFit()
    let name = ShowText.label(planned.displayName, size: space.v(30), weight: .semibold)
    name.sizeToFit()
    let tagBox = NSView(frame: CGRect(x: space.v(420 + 14) + name.frame.width, y: frame.height - space.v(74 + 14),
                                      width: tag.frame.width + space.v(20), height: space.v(28)).integral)
    fill(tagBox, alpha: 0.2, radius: tagBox.frame.height / 2)
    tag.frame.origin = CGPoint(x: space.v(10).rounded(), y: ((tagBox.frame.height - tag.frame.height) / 2).rounded())
    tagBox.addSubview(tag)
    agentsPage.addSubview(tagBox)
    let line = NSView(frame: box(420, 104, 220, 9))
    fill(line, alpha: 0.2, radius: line.frame.height / 2)
    agentsPage.addSubview(line)

    label("Face", size: 15, alpha: 0.55, weight: .semibold, x: 304, middle: 182, in: agentsPage)
    fill(shapePill, alpha: 0.22, radius: space.v(18))
    agentsPage.addSubview(shapePill)
    for (index, shape) in shapes.enumerated() {
      let cell = box(300 + CGFloat(index) * 80, 200, 70, 70)
      shapeCells[shape] = cell
      let side = space.v(54)
      agentsPage.addSubview(ShowStill.face(MascotLook(shape: shape, palette: own.palette, finish: own.finish),
                                           in: CGRect(x: cell.midX - side / 2, y: cell.midY - side / 2,
                                                      width: side, height: side).integral))
    }
    shapePill.frame = shapeCells[own.shape] ?? .zero

    label("Chat", size: 15, alpha: 0.55, weight: .semibold, x: 304, middle: 304, in: agentsPage)
    fill(backdropPill, alpha: 0.3, radius: space.v(22))
    agentsPage.addSubview(backdropPill)
    for (index, scene) in Self.backdrops.enumerated() {
      let x = 300 + CGFloat(index) * 118
      let cell = box(x, 322, 108, 108)
      backdropCells[scene] = cell.insetBy(dx: -space.v(5), dy: -space.v(5))
      let tile = NSImageView(frame: cell.insetBy(dx: space.v(4), dy: space.v(4)))
      fill(tile, alpha: 0.12, radius: space.v(18))
      tile.layer?.masksToBounds = true
      tile.imageScaling = .scaleAxesIndependently
      if let still = AgentBackdropRenderer.still(of: scene, palette: own.palette, scene: 200, pixels: tile.frame.width * 2) {
        tile.image = NSImage(cgImage: still, size: tile.frame.size)
      }
      agentsPage.addSubview(tile)
      label(scene.title, size: 14, alpha: 0.7, x: x + 4, middle: 450, in: agentsPage)
    }
    backdropPill.frame = backdropCells[.standard] ?? .zero

    // The mock chat that wears the choice.
    preview.frame = box(800, 182, 290, 290)
    fill(preview, alpha: 0.1, radius: space.v(30))
    agentsPage.addSubview(preview)
    preview.addSubview(backdrop)
    backdrop.layOut(in: preview.bounds, corner: space.v(30), curve: .continuous)
    let height = preview.frame.height
    func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, alpha: CGFloat) {
      let view = NSView(frame: CGRect(x: space.v(x), y: height - space.v(y + h), width: space.v(w), height: space.v(h)))
      fill(view, alpha: alpha, radius: view.frame.height / 2)
      preview.addSubview(view)
    }
    block(130, 26, 140, 30, alpha: 0.95)
    for (index, width) in [230, 200, 240, 120].enumerated() {
      block(20, 80 + CGFloat(index) * 22, CGFloat(width), 9, alpha: 0.7)
    }
    block(14, 234, 262, 42, alpha: 0.22)

    // Usage.
    usagePage.frame = CGRect(origin: .zero, size: frame.size)
    usagePage.wantsLayer = true
    usagePage.alphaValue = 0
    content.addSubview(usagePage)
    label("Usage", size: 28, weight: .semibold, x: 304, middle: 66, in: usagePage)
    let listed = ([planned] + agents.filter { $0 != planned }).prefix(Self.usage.count)
    for (index, agent) in listed.enumerated() {
      let top = 118 + CGFloat(index) * 124
      let faceBox = box(300, top, 64, 64)
      if agent == planned {
        usageFaceSlot = self.parent(faceBox.insetBy(dx: -space.v(6), dy: -space.v(6)))
      } else {
        usagePage.addSubview(ShowStill.face(MascotLook.face(for: agent), in: faceBox.insetBy(dx: space.v(6), dy: space.v(6))))
      }
      label(agent.displayName, size: 19, weight: .semibold, x: 384, middle: top + 18, in: usagePage)
      label(Self.usage[index].words, size: 14, alpha: 0.6, x: 384, middle: top + 46, in: usagePage)
      // A dark track, a thick meter: on light glass a light track and a
      // thin bar left the agent's gradient nothing to stand against.
      let track = box(384, top + 68, 690, 20)
      let trackView = NSView(frame: track)
      trackView.wantsLayer = true
      trackView.layer?.backgroundColor = CGColor(gray: 0, alpha: 0.18)
      trackView.layer?.cornerRadius = track.height / 2
      trackView.layer?.cornerCurve = .continuous
      usagePage.addSubview(trackView)
      let meter = CAGradientLayer()
      meter.colors = MascotPalette.face(for: agent).meterInk.map(\.cgColor)
      meter.startPoint = CGPoint(x: 0, y: 0.5)
      meter.endPoint = CGPoint(x: 1, y: 0.5)
      meter.cornerRadius = track.height / 2
      meter.frame = CGRect(x: track.minX, y: track.minY, width: 0, height: track.height)
      usagePage.layer?.addSublayer(meter)
      meters.append((meter, track, Self.usage[index].left))
    }
  }

  func rise(from distance: CGFloat) {
    let end = frame
    let start = end.offsetBy(dx: 0, dy: distance)
    ShowClock.fade(glass, to: 1, duration: 0.25)
    clock.spring(0.75, bounce: 0.05) { [weak self] t in self?.glass.frame = ShowClock.mix(start, end, t) }
  }

  func pick(shape: MascotShape) {
    guard let cell = shapeCells[shape] else { return }
    slide(shapePill, to: cell)
  }

  func pick(backdrop scene: ChatBackdrop) {
    guard let cell = backdropCells[scene] else { return }
    slide(backdropPill, to: cell)
    backdrop.show(scene, palette: palette)
  }

  /// The sidebar to Usage: the agent's page gives way to the meters, which
  /// fill one after another.
  func showUsage() {
    slide(sidebarPill, to: box(32, 34 + 100, 226, 40))
    ShowClock.fade(agentsPage, to: 0, duration: 0.25)
    ShowClock.fade(usagePage, to: 1, duration: 0.3)
    for (index, meter) in meters.enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(0.3 + 0.15 * Double(index))) { [weak self] in
        self?.clock.tween(0.9) { t in
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          meter.fill.frame = CGRect(x: meter.track.minX, y: meter.track.minY,
                                    width: max(meter.track.height, meter.track.width * meter.left * t),
                                    height: meter.track.height)
          CATransaction.commit()
        }
      }
    }
  }

  private func slide(_ view: NSView, to rect: CGRect) {
    let from = view.frame
    clock.spring(0.4, bounce: 0.1, key: ObjectIdentifier(view)) { t in view.frame = ShowClock.mix(from, rect, t) }
  }
}

// MARK: - The sunset

final class SunsetView: NSView {
  var onSkip: (() -> Void)?

  static let colours = ["#22468f", "#3a6db0", "#5a8ac0", "#a9a0b4", "#e8a67c", "#f4a24e", "#e2461b"]
  static let locations: [NSNumber] = [0, 0.3, 0.46, 0.6, 0.72, 0.84, 1]
  static let drifted: [NSNumber] = [0, 0.25, 0.41, 0.55, 0.69, 0.82, 1]

  private let sky = CAGradientLayer()
  private let horizon = CAGradientLayer()
  private let night = CAGradientLayer()
  /// Soft lights drifting over the sky, very slowly: warm, rose, pale blue.
  private var lights: [CAGradientLayer] = []
  private static let lightColours: [(hex: String, alpha: CGFloat, centre: CGPoint, period: Double)] = [
    ("#ffb36b", 0.38, CGPoint(x: 0.28, y: 0.3), 26),
    ("#ff86b0", 0.26, CGPoint(x: 0.74, y: 0.42), 33),
    ("#9cc8ff", 0.30, CGPoint(x: 0.55, y: 0.78), 29),
  ]
  private let skip = NSTextField(labelWithString: "Skip Intro")

  override init(frame: CGRect) {
    super.init(frame: frame)
    wantsLayer = true
    build()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if !skip.isHidden, skip.frame.insetBy(dx: -14, dy: -10).contains(point) { onSkip?() }
  }

  private static let dark = HexColor.nsColor("#0c111d").cgColor
  private static let ember = HexColor.nsColor("#3a1d0a").cgColor

  private func build() {
    guard let root = layer else { return }
    sky.frame = bounds
    sky.colors = Self.colours.map { HexColor.nsColor($0).cgColor }
    sky.locations = Self.locations
    // Top to bottom: a layer's y runs up.
    sky.startPoint = CGPoint(x: 0.5, y: 1)
    sky.endPoint = CGPoint(x: 0.5, y: 0)
    root.addSublayer(sky)

    let ember = HexColor.nsColor("#ff7a2e").cgColor
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
      let colour = HexColor.nsColor(light.hex).cgColor
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

    // Night, over all of it, until the dawn.
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
    addSubview(skip)
  }

  /// Slides 1–3: night, then a warm glow at the horizon, then the sunset —
  /// and from then on it lives a little.
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

    // Each light wanders round a slow loop of its own and breathes.
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
    drift.fromValue = Self.locations
    drift.toValue = Self.drifted
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
