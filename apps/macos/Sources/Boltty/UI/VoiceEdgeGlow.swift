import AppKit
import MetalKit
import QuartzCore

enum VoiceEdgeGlowLayout {
  static let authoredHeight: CGFloat = 74.5

  static func reach(size: CGSize, intensity: CGFloat) -> CGFloat {
    let level = min(1, max(0, intensity))
    guard size.height > authoredHeight else { return size.height }
    return authoredHeight * (1.05 + 0.5 * level)
  }

  static func approach(
    _ current: CGFloat,
    toward target: CGFloat,
    dt: CGFloat,
    attack: CGFloat,
    release: CGFloat
  ) -> CGFloat {
    let tau = target > current ? attack : release
    let alpha = 1 - exp(-dt / max(0.001, tau))
    return current + (target - current) * alpha
  }

  static func intensity(
    level: CGFloat,
    idle: CGFloat,
    breathe: CGFloat
  ) -> CGFloat {
    let clamped = min(1, max(0, level))
    return min(1, max(0, clamped + (1 - clamped) * idle * breathe))
  }

  static func breathe(at time: CGFloat, period: CGFloat, reduceMotion: Bool) -> CGFloat {
    guard !reduceMotion, period > 0 else { return 1 }
    return 0.5 + 0.5 * sin(2 * .pi * time / period)
  }

  static func flowSpeed(level: CGFloat, processing: CGFloat) -> CGFloat {
    let level = min(1, max(0, level))
    let processing = min(1, max(0, processing))
    let listening = AgentPaletteMetrics.voiceGlowFlowRest
      + AgentPaletteMetrics.voiceGlowFlowVoice * level
    return listening + (AgentPaletteMetrics.voiceGlowFlowProcessing - listening) * processing
  }

  static func rayOrigin(
    size: CGSize,
    intensity: CGFloat,
    beam: CGFloat,
    clock: CGFloat,
    reduceMotion: Bool
  ) -> CGPoint {
    let level = min(1, max(0, intensity))
    let beam = min(1, max(0, beam))
    let sway = reduceMotion ? 0 : 0.6 * sin(clock * AgentPaletteMetrics.voiceGlowSwayRate + 0.6)
      + 0.4 * sin(clock * AgentPaletteMetrics.voiceGlowSwayRate * 0.41 + 2.0)
    let reach = size.width * (0.10 + 0.22 * level) * (1 - beam)
    let x = size.width / 2 + sway * reach
    let listening = size.height * (-0.40 + 0.62 * level)
    let processing = size.height * 0.5
    return CGPoint(x: x, y: listening + (processing - listening) * beam)
  }

  static func rayColors(from palette: MascotPalette) -> [NSColor] {
    palette.light(atLeast: AgentPaletteMetrics.voiceGlowLightness)
  }
}

final class VoiceEdgeGlowView: MTKView, MTKViewDelegate {
  private(set) var phase: VoiceGlowPhase = .idle
  private var envelope = VoiceLevelEnvelope()
  private var targetLevel: CGFloat = 0
  private var palette = MascotPalette.standard
  private var clock: CGFloat = 0
  private var flow: CGFloat = 0
  private var beamMorph: CGFloat = 0
  private var opacity: CGFloat = 0
  private var targetOpacity: CGFloat = 0
  private var fadeRate: CGFloat = 0
  private var lastTick: CFTimeInterval = 0
  private var link: CADisplayLink?
  private let glowRenderer: VoiceGlowRenderer?
  private var lastUniforms = VoiceGlowUniforms()
  private var orbIsClear = false
  var surfaceCornerRadius: CGFloat = 0 {
    didSet { needsLayout = true }
  }
  var surfaceCornerCurve: CALayerCornerCurve = .continuous {
    didSet { needsLayout = true }
  }
  var fillsShell = false {
    didSet { if fillsShell != oldValue { refresh() } }
  }

  // MARK: - Testing seams

  var isListeningForTesting: Bool { phase == .listening }
  var smoothedLevelForTesting: CGFloat { envelope.level }
  var displayedLevelForTesting: CGFloat { displayedIntensity }
  var paletteIDForTesting: String { palette.id }
  var uniformsForTesting: VoiceGlowUniforms { lastUniforms }

  var rayColorsForTesting: [NSColor] {
    (0..<VoiceGlowRenderer.colorCount).map { index in
      let color = VoiceGlowRenderer.color(lastUniforms, at: index)
      return NSColor(
        srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1
      )
    }
  }

  var avoidsOffscreenPassForTesting: Bool {
    guard let layer else { return true }
    return !layer.shouldRasterize
      && layer.filters == nil
      && layer.backgroundFilters == nil
      && !layer.masksToBounds
  }

  // MARK: - Life

  init(frame frameRect: NSRect) {
    let renderer = VoiceGlowRenderer(pixelFormat: .bgra8Unorm)
    glowRenderer = renderer
    super.init(frame: frameRect, device: renderer?.metalDevice)

    isPaused = true
    enableSetNeedsDisplay = false
    delegate = self
    colorPixelFormat = .bgra8Unorm
    framebufferOnly = true
    clearColor = MTLClearColorMake(0, 0, 0, 0)
    layer?.isOpaque = false
    wantsLayer = true
    layer?.masksToBounds = false
    isHidden = true
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var allowsVibrancy: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { stopClock() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      stopClock()
    } else if needsClock {
      startClock()
    }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    refresh()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refresh()
  }

  override func layout() {
    super.layout()
    refresh()
  }

  // MARK: - Input

  func apply(palette: MascotPalette) {
    guard palette != self.palette else { return }
    self.palette = palette
    refresh()
  }

  func setListening(_ listening: Bool) {
    setPhase(listening ? .listening : .completed)
  }

  func setPhase(_ next: VoiceGlowPhase) {
    guard next != phase else { return }
    let previous = phase
    phase = next

    switch next {
    case .listening:
      envelope.settle(at: AgentPaletteMetrics.voiceGlowIdle)
      targetLevel = AgentPaletteMetrics.voiceGlowIdle
      if !previous.isVisible {
        clock = 0
        flow = 0
        beamMorph = 0
      }
      isHidden = false
      targetOpacity = 1
      fadeRate = rate(for: next.fadeDuration)
      startClock()

    case .processing:
      isHidden = false
      targetOpacity = 1
      fadeRate = rate(for: next.fadeDuration)
      startClock()

    case .completed:
      targetOpacity = 0
      fadeRate = rate(for: fillsShell ? AgentPaletteMetrics.voiceGlowOrbReleaseDuration : next.fadeDuration)
      if opacity <= 0 { settleIdle() } else { startClock() }

    case .cancelled, .failed:
      envelope.reset()
      targetLevel = 0
      targetOpacity = 0
      fadeRate = rate(for: next.fadeDuration)
      if opacity <= 0 { settleIdle() } else { startClock() }

    case .idle:
      settleIdle()
    }
    refresh()
  }

  func setAudioLevel(_ level: CGFloat) {
    guard phase == .listening else { return }
    targetLevel = min(1, max(0, level))
    envelope.accept(targetLevel, dt: 1 / 47)
    if link == nil { refresh() }
  }

  // MARK: - The clock

  private var needsClock: Bool {
    phase.isAnimating || opacity > 0.001
  }

  private var displayedIntensity: CGFloat {
    switch phase {
    case .idle, .cancelled, .failed:
      return 0
    case .processing:
      return AgentPaletteMetrics.voiceGlowBeamLevel
    case .listening, .completed:
      return VoiceEdgeGlowLayout.intensity(
        level: envelope.level,
        idle: AgentPaletteMetrics.voiceGlowIdle,
        breathe: VoiceEdgeGlowLayout.breathe(
          at: clock,
          period: AgentPaletteMetrics.voiceGlowBreatheDuration,
          reduceMotion: MotionPreferences.reduceMotion
        )
      )
    }
  }

  private func rate(for duration: TimeInterval) -> CGFloat {
    duration <= 0 ? .greatestFiniteMagnitude : 1 / CGFloat(duration)
  }

  private func startClock() {
    guard link == nil else { return }
    lastTick = Motion.now
    guard window != nil, glowRenderer != nil else { return }
    let link = displayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = MotionPreferences.highFrameRateRange
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  private func stopClock() {
    link?.invalidate()
    link = nil
  }

  private func settleIdle() {
    phase = .idle
    stopClock()
    envelope.reset()
    targetLevel = 0
    opacity = 0
    targetOpacity = 0
    clock = 0
    flow = 0
    beamMorph = 0
    isHidden = true
    lastUniforms = VoiceGlowUniforms()
  }

  @objc private func tick() {
    let now = Motion.now
    let dt = CGFloat(min(now - lastTick, 0.05))
    lastTick = now

    if phase == .listening {
      envelope.accept(targetLevel, dt: dt)
    } else if phase == .processing {
      envelope.accept(AgentPaletteMetrics.voiceGlowBeamLevel, dt: dt)
    }

    clock += dt
    beamMorph = VoiceEdgeGlowLayout.approach(
      beamMorph,
      toward: phase.beamMorph,
      dt: dt,
      attack: AgentPaletteMetrics.voiceGlowBeamGatherDuration,
      release: AgentPaletteMetrics.voiceGlowBeamGatherDuration
    )

    flow += dt * VoiceEdgeGlowLayout.flowSpeed(level: displayedIntensity, processing: beamMorph)

    if opacity != targetOpacity {
      let step = fadeRate * dt
      opacity = targetOpacity > opacity
        ? min(targetOpacity, opacity + step)
        : max(targetOpacity, opacity - step)
    }

    refresh()

    if !phase.isAnimating, opacity <= 0.001 {
      settleIdle()
    }
  }

  // MARK: - The frame

  private func refresh() {
    let size = bounds.size
    guard size.width > 1, size.height > 1 else { return }
    lastUniforms = VoiceGlowRenderer.uniforms(for: makeFrame(size: size))
    let visible = !isHidden && opacity > 0
    guard visible else { return }
    if fillsShell, orbIsClear { return }
    orbIsClear = fillsShell
    draw()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    glowRenderer?.render(lastUniforms, in: view)
  }

  private func makeFrame(size: CGSize) -> VoiceGlowRenderer.Frame {
    let colors = VoiceEdgeGlowLayout.rayColors(from: palette)
    var resolved: [NSColor] = colors
    effectiveAppearance.performAsCurrentDrawingAppearance {
      resolved = colors.map { $0.usingColorSpace(.sRGB) ?? $0 }
    }
    let scale = window?.backingScaleFactor ?? 2

    return VoiceGlowRenderer.Frame(
      size: size,
      pixelSize: 1 / max(1, scale),
      cornerRadius: surfaceCornerRadius,
      cornerIsContinuous: surfaceCornerCurve == .continuous,
      intensity: displayedIntensity,
      beam: beamMorph,
      clock: clock,
      flow: flow,
      orb: fillsShell ? 1 : 0,
      opacity: shownOpacity,
      isLightAppearance: isLightAppearance,
      reduceMotion: MotionPreferences.reduceMotion,
      colors: resolved
    )
  }

  private var shownOpacity: CGFloat {
    let o = min(1, max(0, opacity))
    return targetOpacity > o ? o * o * (3 - 2 * o) : o * o
  }

  private var isLightAppearance: Bool {
    effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
  }
}
