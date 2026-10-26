import Foundation

struct MascotMotion {
  private(set) var pose = MascotMotionPose()
  private(set) var mood: MascotMood

  private var random: MascotRandom
  private var t = 0.0

  private var yaw = Spring(frequency: 2.2, damping: 0.68)
  private var pitch = Spring(frequency: 2.2, damping: 0.75)
  private var roll = Spring(frequency: 1.6, damping: 0.8)
  private var rest = Spring(frequency: 1.4, damping: 1)
  private var gazeX = Spring(frequency: 9, damping: 1)
  private var gazeY = Spring(frequency: 9, damping: 1)
  private var openness = Spring(frequency: 5, damping: 1)
  private var sleepiness = Spring(frequency: 1.2, damping: 1)
  private var droop = Spring(frequency: 2.5, damping: 1)
  private var eyeScale = Spring(frequency: 4, damping: 1)
  private var happiness = Spring(frequency: 8, damping: 1)

  private var focus = SIMD2<Double>(0, 0)
  private var nextGlance = 0.0
  private var scan = 0.0
  private var scanLine = 0.0
  private var pointer = SIMD2<Double>(0, 0)
  private var pointerWeight = 0.0
  private var pointerTarget = SIMD3<Double>(0, 0, 0)

  private var blinkStart = -10.0
  private var nextBlink = 0.0
  private var blinkAgain = false

  private var breathTurns = 0.0
  private var hoverTurns = 0.0

  private var action: Action?
  var isActing: Bool { action != nil }
  private var nextAction = 0.0
  private var bopCount = 0
  private(set) var beats = 0
  private(set) var lastBeatIsBig = false
  private var nextSquint = 0.0
  private var squintUntil = -1.0
  private(set) var lastReaction: MascotReaction?
  private var effect = Action.Effect()

  init(random seed: MascotRandom, emotion: MascotEmotion) {
    random = seed
    mood = MascotMood(emotion)
    t = random.next() * 8
    breathTurns = random.next()
    hoverTurns = random.next()
    nextGlance = t + 0.3 + random.next()
    nextBlink = t + 1 + random.next() * 2
    nextSquint = t + 1 + random.next() * 2
    nextAction = mood.actions == .bops ? t : t + 2 + random.next() * 4
    settle()
  }

  mutating func setEmotion(_ emotion: MascotEmotion) {
    let next = MascotMood(emotion)
    guard next != mood else { return }
    mood = next
    nextGlance = t
    if let action, !action.kind.survivesMoodChange { self.action = nil }
    nextAction = t + draw(mood.actionEvery ?? 3...5)
  }

  mutating func settle() {
    yaw.snap(mood.yaw)
    pitch.snap(mood.pitch)
    roll.snap(mood.roll)
    rest.snap(mood.rise)
    gazeX.snap(mood.gaze.x)
    gazeY.snap(mood.gaze.y)
    openness.snap(mood.open)
    sleepiness.snap(mood.sleepy)
    droop.snap(mood.droop)
    eyeScale.snap(mood.eyeScale)
    happiness.snap(0)
    action = nil
    effect = Action.Effect()
    compose(stretch: .init(1, 1), rise: 0, spin: 0, lean: 0, happy: 0, blink: 1)
  }

  mutating func setPointer(x: Double, y: Double, strength: Double) {
    let weight = mood.followsPointer ? max(0, min(1, strength)) : 0
    pointerTarget = SIMD3(max(-1, min(1, x)), max(-1, min(1, y)), weight)
  }

  mutating func poke(_ reaction: MascotReaction? = nil) {
    if let action, action.progress(at: t) < 0.5 { return }
    let chosen = reaction ?? {
      let pool = MascotReaction.allCases.filter { $0 != lastReaction }
      return pool[min(pool.count - 1, Int(random.next() * Double(pool.count)))]
    }()
    lastReaction = chosen
    action = Action(kind: .reaction(chosen), start: t, side: random.next() < 0.5 ? -1 : 1)
  }

  // MARK: - Time

  mutating func update(_ elapsed: Double) {
    let dt = max(0, min(elapsed, 1.0 / 20))
    guard dt > 0 else { return }
    t += dt

    pointer += (SIMD2(pointerTarget.x, pointerTarget.y) - pointer) * (1 - exp(-12 * dt))
    pointerWeight += (pointerTarget.z - pointerWeight) * (1 - exp(-6 * dt))
    if mood.scans {
      readAcross(dt)
    } else if t >= nextGlance, let every = mood.glanceEvery {
      glance()
      nextGlance = t + draw(every)
    }
    let aim = focus * (1 - pointerWeight) + SIMD2(pointer.x, -pointer.y) * pointerWeight
    gazeX.target = mood.gaze.x + aim.x * mood.gazeReach.x
    gazeY.target = mood.gaze.y + aim.y * mood.gazeReach.y
    yaw.target = mood.yaw + aim.x * mood.turnReach.x
    pitch.target = mood.pitch + aim.y * mood.turnReach.y
    roll.target = mood.roll + aim.x * mood.turnReach.x * 0.22
    rest.target = mood.rise
    openness.target = mood.open
    sleepiness.target = mood.sleepy
    droop.target = mood.droop
    eyeScale.target = mood.eyeScale

    for spring in [\Self.yaw, \.pitch, \.roll, \.rest, \.gazeX, \.gazeY, \.openness,
                   \.sleepiness, \.droop, \.eyeScale] as [WritableKeyPath<Self, Spring>] {
      self[keyPath: spring].advance(dt)
    }
    breathTurns += dt / mood.breathPeriod
    hoverTurns += dt / 3.9

    if mood.blinks, t >= nextBlink {
      blinkStart = t
      blinkAgain = !blinkAgain && random.next() < 0.16
      nextBlink = t + (blinkAgain ? 0.26 : draw(mood.blinkEvery))
    }
    let blink = Self.lid(t - blinkStart)

    if action == nil || action!.finished(at: t) {
      action = nil
      if t >= nextAction, let kind = nextActionKind() {
        action = Action(kind: kind, start: t, side: random.next() < 0.5 ? -1 : 1)
        nextAction = t + draw(mood.actionEvery ?? 3...5)
      }
    }
    var stretch = SIMD2<Double>(1, 1), rise = 0.0, spin = 0.0, lean = 0.0, happy = 0.0
    effect = action?.effect(at: t) ?? Action.Effect()
    if action != nil {
      stretch += effect.stretch
      rise += effect.rise
      spin += effect.spin
      lean += effect.lean
      happy = max(happy, effect.happy)
    }

    if mood.squints {
      if t >= nextSquint {
        squintUntil = t + 0.45 + random.next() * 0.45
        nextSquint = t + 2.2 + random.next() * 2.6
      }
      if t < squintUntil { happy = max(happy, 1) }
    }
    happiness.target = happy
    happiness.advance(dt)

    compose(stretch: stretch, rise: rise, spin: spin, lean: lean, happy: happiness.value, blink: blink)
  }

  private mutating func compose(
    stretch: SIMD2<Double>, rise: Double, spin: Double, lean: Double, happy: Double, blink: Double
  ) {
    let breath = sin(breathTurns * 2 * .pi)
    let hover = sin(hoverTurns * 2 * .pi)
    var sx = stretch.x - breath * mood.breathDepth * 0.5
    var sy = stretch.y + breath * mood.breathDepth
    let turnSpeed = abs(yaw.velocity)
    sx += min(0.05, 0.018 * turnSpeed)
    sy -= min(0.03, 0.01 * turnSpeed)

    pose.yaw = yaw.value + spin
    pose.pitch = pitch.value + effect.pitch
    pose.roll = roll.value + lean
    pose.rise = rest.value + rise + hover * mood.hover + breath * mood.breathDepth * 5
    pose.sx = sx
    pose.sy = sy
    pose.gazeX = gazeX.value
    pose.gazeY = gazeY.value
    let open = max(0, openness.value) * blink
    let asymmetry = mood.asymmetry
    let wink = (left: effect.side > 0 ? effect.wink : 0, right: effect.side > 0 ? 0 : effect.wink)
    pose.eyes = [
      MascotEyeShape(
        open: open * (1 - asymmetry) * (1 - wink.left), happy: max(happy, wink.right),
        sleepy: sleepiness.value, droop: droop.value, scale: eyeScale.value
      ),
      MascotEyeShape(
        open: open * (1 - wink.right), happy: max(happy, wink.left),
        sleepy: sleepiness.value, droop: droop.value, scale: eyeScale.value
      ),
    ]
  }

  // MARK: - Attention

  private mutating func glance() {
    let back = random.next() < 0.22
    let angle = random.next() * 2 * .pi
    let reach = back ? 0 : random.next().squareRoot()
    let next = SIMD2(cos(angle) * reach, sin(angle) * reach * 0.8)
    let jump = ((next - focus) * (next - focus)).sum().squareRoot()
    if jump > 0.9, mood.blinks, random.next() < 0.55, t - blinkStart > 0.4 {
      blinkStart = t
    }
    focus = next
  }

  private mutating func readAcross(_ dt: Double) {
    scan += dt / 1.15
    if scan >= 1 {
      scan = 0
      scanLine = scanLine >= 3 ? 0 : scanLine + 1
    }
    let x = scan < 0.86 ? -1 + 2 * (scan / 0.86) : 1 - 2 * ((scan - 0.86) / 0.14)
    focus = SIMD2(x, 0.45 - scanLine * 0.3)
  }

  // MARK: - Actions

  private mutating func nextActionKind() -> Action.Kind? {
    switch mood.actions {
    case .none:
      return nil
    case .hops:
      return .hop(height: 6.5, spin: random.next() < 0.7)
    case .bops:
      bopCount += 1
      let big = bopCount % 4 == 0
      beats += 1
      lastBeatIsBig = big
      return .bop(height: big ? 5.5 : 3, spin: big, side: bopCount % 2 == 0 ? 1 : -1)
    case .sighs:
      return .sigh
    case .settles:
      return .settle
    }
  }

  static func lid(_ since: Double) -> Double {
    guard since >= 0 else { return 1 }
    if since < 0.06 { return 1 - smoothstep(since / 0.06) }
    if since < 0.2 { return smoothstep((since - 0.06) / 0.14) }
    return 1
  }

  private mutating func draw(_ range: ClosedRange<Double>) -> Double {
    range.lowerBound + random.next() * (range.upperBound - range.lowerBound)
  }
}

// MARK: - The pose

struct MascotMotionPose: Equatable {
  var yaw = 0.0, pitch = 0.0, roll = 0.0
  var rise = 0.0
  var sx = 1.0, sy = 1.0
  var gazeX = 0.0, gazeY = 0.0
  var eyes = [MascotEyeShape(), MascotEyeShape()]
}

struct MascotEyeShape: Equatable {
  var open = 1.0
  var happy = 0.0
  var sleepy = 0.0
  var droop = 0.0
  var scale = 1.0
}

extension MascotMotionPose {
  /// `rest` at 0, `live` at 1 — a face going back to its standard pose, or
  /// out of it, passes through every pose between.
  static func blend(_ rest: MascotMotionPose, _ live: MascotMotionPose, _ t: Double) -> MascotMotionPose {
    func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
    var pose = MascotMotionPose()
    pose.yaw = mix(rest.yaw, live.yaw)
    pose.pitch = mix(rest.pitch, live.pitch)
    pose.roll = mix(rest.roll, live.roll)
    pose.rise = mix(rest.rise, live.rise)
    pose.sx = mix(rest.sx, live.sx)
    pose.sy = mix(rest.sy, live.sy)
    pose.gazeX = mix(rest.gazeX, live.gazeX)
    pose.gazeY = mix(rest.gazeY, live.gazeY)
    pose.eyes = zip(rest.eyes, live.eyes).map { a, b in
      MascotEyeShape(
        open: mix(a.open, b.open), happy: mix(a.happy, b.happy),
        sleepy: mix(a.sleepy, b.sleepy), droop: mix(a.droop, b.droop),
        scale: mix(a.scale, b.scale))
    }
    return pose
  }
}

// MARK: - Moods

struct MascotMood: Equatable {
  enum Actions: Equatable { case none, hops, bops, sighs, settles }

  var yaw = 0.0, pitch = 0.0, roll = 0.0
  var rise = 0.0
  var gaze = SIMD2<Double>(0, 0)
  var gazeReach = SIMD2<Double>(2.0, 1.3)
  var turnReach = SIMD2<Double>(0.42, 0.16)
  var glanceEvery: ClosedRange<Double>? = 0.9...2.8
  var scans = false
  var blinks = true
  var blinkEvery: ClosedRange<Double> = 2.4...5.2
  var actions = Actions.none
  var actionEvery: ClosedRange<Double>?
  var squints = false
  var open = 1.0
  var sleepy = 0.0
  var droop = 0.0
  var eyeScale = 1.0
  var asymmetry = 0.0
  var breathPeriod = 3.3
  var breathDepth = 0.018
  var hover = 0.35
  var followsPointer = true

  init(_ emotion: MascotEmotion) {
    switch emotion {
    case .curious:
      actions = .hops
      actionEvery = 6.5...11
    case .listening:
      pitch = 0.07
      gazeReach = SIMD2(0.8, 0.5)
      turnReach = SIMD2(0.12, 0.05)
      glanceEvery = 1.6...3.5
      eyeScale = 1.1
      breathPeriod = 3.0
    case .focused:
      pitch = -0.05
      scans = true
      glanceEvery = nil
      gazeReach = SIMD2(2.3, 1.1)
      turnReach = SIMD2(0.1, 0.05)
      blinkEvery = 3.2...6
    case .thinking:
      actions = .bops
      actionEvery = 0.0...0.0
      squints = true
      glanceEvery = 0.7...1.8
      gazeReach = SIMD2(1.4, 0.8)
      turnReach = SIMD2(0.25, 0.08)
      hover = 0
    case .concerned:
      roll = -0.17
      glanceEvery = 0.5...1.4
      gazeReach = SIMD2(1.8, 0.6)
      turnReach = SIMD2(0.15, 0.06)
      droop = 0.18
      asymmetry = 0.22
    case .sad:
      pitch = -0.24
      roll = 0.07
      rise = -1
      gaze = SIMD2(0, -1.3)
      glanceEvery = 3...6
      gazeReach = SIMD2(0.6, 0.3)
      turnReach = SIMD2(0.08, 0.03)
      blinkEvery = 3.5...7
      actions = .sighs
      actionEvery = 6...10
      open = 0.9
      droop = 0.45
      breathPeriod = 4.4
      breathDepth = 0.028
      hover = 0
      followsPointer = false
    case .sleeping:
      pitch = -0.3
      roll = 0.09
      rise = -1.2
      glanceEvery = nil
      blinks = false
      actions = .settles
      actionEvery = 5...9
      open = 0
      sleepy = 1
      breathPeriod = 5
      breathDepth = 0.04
      hover = 0
      followsPointer = false
    }
  }
}

// MARK: - Pieces

private struct Spring {
  var value = 0.0
  var velocity = 0.0
  var target = 0.0
  let frequency: Double
  let damping: Double

  init(frequency: Double, damping: Double) {
    self.frequency = frequency
    self.damping = damping
  }

  mutating func snap(_ v: Double) {
    value = v
    target = v
    velocity = 0
  }

  mutating func advance(_ dt: Double) {
    let omega = 2 * .pi * frequency
    let steps = max(1, Int((dt / 0.008).rounded(.up)))
    let h = dt / Double(steps)
    for _ in 0..<steps {
      velocity += (omega * omega * (target - value) - 2 * damping * omega * velocity) * h
      value += velocity * h
    }
  }
}

private struct Action {
  enum Kind: Equatable {
    case hop(height: Double, spin: Bool)
    case bop(height: Double, spin: Bool, side: Double)
    case sigh
    case settle
    case reaction(MascotReaction)

    var survivesMoodChange: Bool {
      switch self {
      case .hop, .reaction: return true
      default: return false
      }
    }
  }

  struct Effect {
    var stretch = SIMD2<Double>(0, 0)
    var rise = 0.0
    var spin = 0.0
    var lean = 0.0
    var pitch = 0.0
    var happy = 0.0
    var wink = 0.0
    var side = 1.0
  }

  let kind: Kind
  let start: Double
  let side: Double

  private var phases: (crouch: Double, air: Double, land: Double) {
    switch kind {
    case .hop: return (0.14, 0.56, 0.55)
    case .bop(let height, _, _): return (0.07, height > 4 ? 0.46 : 0.36, 0.3)
    case .sigh: return (0, 2.6, 0)
    case .settle: return (0, 2.2, 0)
    case .reaction(.spinHop): return (0.14, 0.56, 0.55)
    case .reaction(.doubleHop): return (0.12, 0.86, 0.5)
    case .reaction(.flip): return (0.16, 0.62, 0.55)
    case .reaction(.cartwheel): return (0.14, 0.6, 0.55)
    case .reaction(.boing): return (0.2, 0.34, 0.9)
    case .reaction(.wink): return (0, 1.1, 0)
    }
  }

  var duration: Double { phases.crouch + phases.air + phases.land }
  func finished(at t: Double) -> Bool { t - start >= duration }
  func progress(at t: Double) -> Double { min(1, max(0, (t - start) / duration)) }

  func effect(at t: Double) -> Effect {
    var e = Effect()
    e.side = side
    let local = t - start
    let p = phases
    switch kind {
    case .reaction(let reaction):
      reactionEffect(reaction, local: local, into: &e)
    case .hop(let height, let spin), .bop(let height, let spin, _):
      let sideLean: Double
      if case .bop(_, _, let s) = kind { sideLean = s * 0.07 } else { sideLean = side * 0.1 }
      if local < p.crouch {
        let u = smoothstep(local / p.crouch)
        e.stretch = SIMD2(0.13 * u, -0.12 * u)
        e.rise = -0.9 * u
      } else if local < p.crouch + p.air {
        let u = (local - p.crouch) / p.air
        e.rise = height * 4 * u * (1 - u)
        let speed = abs(1 - 2 * u)
        e.stretch = SIMD2(-0.06 * speed, 0.1 * speed)
        e.lean = sideLean * sin(.pi * u)
        if spin {
          e.spin = 2 * .pi * smootherstep(u)
          e.happy = sin(.pi * u)
        }
      } else {
        let u = local - p.crouch - p.air
        let wobble = 0.15 * exp(-8 * u) * cos(2 * .pi * 3.4 * u)
        e.stretch = SIMD2(wobble, -wobble)
      }
    case .sigh:
      let u = local / p.air
      let rise = u < 0.35 ? smoothstep(u / 0.35) : 1 - 1.4 * smoothstep((u - 0.35) / 0.4)
      let recover = u > 0.75 ? smoothstep((u - 0.75) / 0.25) : 0
      e.rise = (rise * 0.8) * (1 - recover)
      e.stretch = SIMD2(-0.02 * rise, 0.035 * rise) * (1 - recover)
      e.pitch = 0.06 * rise * (1 - recover)
    case .settle:
      let u = local / p.air
      let slump = u < 0.3 ? smoothstep(u / 0.3) : 1 - smoothstep((u - 0.3) / 0.7)
      e.stretch = SIMD2(0.035 * slump, -0.05 * slump)
      e.rise = -0.7 * slump
      e.pitch = -0.07 * slump
    }
    return e
  }

  private func reactionEffect(_ reaction: MascotReaction, local: Double, into e: inout Effect) {
    let p = phases
    let air = (local - p.crouch) / p.air
    switch reaction {
    case .boing:
      if local < p.crouch {
        let u = smoothstep(local / p.crouch)
        e.stretch = SIMD2(0.2 * u, -0.2 * u)
        e.rise = -1.4 * u
      } else if local < p.crouch + p.air {
        let u = sin(.pi * air)
        e.stretch = SIMD2(-0.12 * u, 0.24 * u)
        e.rise = 2.4 * u
        e.happy = u
      } else {
        let u = local - p.crouch - p.air
        let wobble = 0.2 * exp(-5 * u) * cos(2 * .pi * 3 * u)
        e.stretch = SIMD2(wobble, -wobble)
      }
      return
    case .wink:
      let u = local / p.air
      e.pitch = -0.2 * sin(.pi * min(1, u / 0.45)) + 0.08 * sin(.pi * max(0, (u - 0.45) / 0.55))
      e.lean = side * 0.12 * sin(.pi * u)
      e.wink = smoothstep(u / 0.15) * (1 - smoothstep((u - 0.7) / 0.3))
      e.rise = 0.6 * sin(.pi * u)
      return
    default:
      break
    }
    if local < p.crouch {
      let u = smoothstep(local / p.crouch)
      e.stretch = SIMD2(0.13 * u, -0.12 * u)
      e.rise = -0.9 * u
    } else if local < p.crouch + p.air {
      let speed: Double
      switch reaction {
      case .doubleHop:
        let first = 0.55
        if air < first {
          let u = air / first
          e.rise = 7 * 4 * u * (1 - u)
          speed = abs(1 - 2 * u)
        } else {
          let u = (air - first) / (1 - first)
          e.rise = 4 * 4 * u * (1 - u)
          speed = abs(1 - 2 * u)
          let squash = max(0, 1 - u / 0.18)
          e.stretch = SIMD2(0.1 * squash, -0.1 * squash)
        }
        e.lean = side * 0.08 * sin(2 * .pi * air)
        e.happy = sin(.pi * air)
      case .flip:
        e.rise = 8 * 4 * air * (1 - air)
        speed = abs(1 - 2 * air)
        e.pitch = -2 * .pi * smootherstep(air)
        e.happy = sin(.pi * air)
      case .cartwheel:
        e.rise = 7.5 * 4 * air * (1 - air)
        speed = abs(1 - 2 * air)
        e.lean = side * 2 * .pi * smootherstep(air)
        e.happy = sin(.pi * air)
      default:
        e.rise = 7.5 * 4 * air * (1 - air)
        speed = abs(1 - 2 * air)
        e.lean = side * 0.1 * sin(.pi * air)
        e.spin = 2 * .pi * smootherstep(air)
        e.happy = sin(.pi * air)
      }
      e.stretch += SIMD2(-0.06 * speed, 0.1 * speed)
    } else {
      let u = local - p.crouch - p.air
      let wobble = 0.15 * exp(-8 * u) * cos(2 * .pi * 3.4 * u)
      e.stretch = SIMD2(wobble, -wobble)
    }
  }
}

enum MascotReaction: CaseIterable, Equatable {
  case spinHop
  case doubleHop
  case flip
  case cartwheel
  case boing
  case wink
}

private func smoothstep(_ x: Double) -> Double {
  let u = max(0, min(1, x))
  return u * u * (3 - 2 * u)
}

private func smootherstep(_ x: Double) -> Double {
  let u = max(0, min(1, x))
  return u * u * u * (u * (u * 6 - 15) + 10)
}
