import AppKit
import Metal
import MetalKit
import QuartzCore
import simd

@MainActor
final class PaletteEffects {
  static let shared = PaletteEffects()

  let device: MTLDevice
  private let queue: MTLCommandQueue
  private let reveal: MTLRenderPipelineState
  private let whip: MTLRenderPipelineState
  private let selectionGlow: MTLRenderPipelineState

  private init?() {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let library = device.makeDefaultLibrary(),
          let reveal = Self.pipeline(
            device, library, vertex: "revealVertex", fragment: "revealFragment", label: "Reveal"),
          let whip = Self.pipeline(
            device, library, vertex: "whipVertex", fragment: "whipFragment", label: "Whip"),
          let selectionGlow = Self.pipeline(
            device, library, vertex: "selectionGlowVertex", fragment: "selectionGlowFragment",
            label: "Selection glow")
    else { return nil }
    self.device = device
    self.queue = queue
    self.reveal = reveal
    self.whip = whip
    self.selectionGlow = selectionGlow
  }

  private static func pipeline(
    _ device: MTLDevice, _ library: MTLLibrary, vertex: String, fragment: String, label: String
  ) -> MTLRenderPipelineState? {
    guard let vertexFunction = library.makeFunction(name: vertex),
          let fragmentFunction = library.makeFunction(name: fragment) else { return nil }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.label = label
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    let attachment = descriptor.colorAttachments[0]
    attachment?.pixelFormat = .bgra8Unorm
    attachment?.isBlendingEnabled = true
    attachment?.sourceRGBBlendFactor = .one
    attachment?.sourceAlphaBlendFactor = .one
    attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try? device.makeRenderPipelineState(descriptor: descriptor)
  }

  func texture(for image: CGImage) -> MTLTexture? {
    let width = max(1, min(image.width, 2048))
    let height = max(1, min(image.height, 2048))
    let rowBytes = width * 4
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let bytes = context.data else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    texture.replace(
      region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes,
      bytesPerRow: rowBytes)
    return texture
  }

  // MARK: - Frames, as numbers

  static func revealUniforms(
    progress: CGFloat, size: CGSize, imageAspect: CGFloat, pixelSize: CGFloat,
    cornerRadius: CGFloat, cornerIsContinuous: Bool
  ) -> PaletteRevealUniforms {
    let p = min(1, max(0, progress))
    let left = (1 - p) * (1 - p)
    let side = min(size.width, size.height)
    var u = PaletteRevealUniforms()
    u.size = simd_float2(Float(size.width), Float(size.height))
    u.imageAspect = Float(max(0.01, imageAspect))
    u.pixelSize = Float(max(0.25, pixelSize))
    u.cornerRadius = Float(max(0, cornerRadius))
    u.cornerIsContinuous = cornerIsContinuous ? 1 : 0
    u.progress = Float(p)
    u.blur = Float(left * side * AgentPaletteMetrics.revealBlurFraction)
    u.aberration = Float(left * side * AgentPaletteMetrics.revealAberrationFraction)
    u.zoom = Float(1 + left * AgentPaletteMetrics.revealZoom)
    u.opacity = Float(smoothstep(0, AgentPaletteMetrics.revealOpaqueAt, p))
    return u
  }

  static func whipUniforms(
    size: CGSize, frame: CGRect, velocity: CGVector, pixelSize: CGFloat, opacity: CGFloat
  ) -> PaletteWhipUniforms {
    let speed = hypot(velocity.dx, velocity.dy)
    let reach = AgentPaletteMetrics.whipMaxLagHeights * frame.height
    var u = PaletteWhipUniforms()
    u.size = simd_float2(Float(size.width), Float(size.height))
    u.frame = simd_float4(
      Float(frame.minX), Float(frame.minY), Float(frame.width), Float(frame.height))
    u.velocity = simd_float2(Float(velocity.dx), Float(velocity.dy))
    u.lag = Float(reach * (1 - exp(-speed * AgentPaletteMetrics.whipLagPerSpeed / max(reach, 1))))
    u.pixelSize = Float(max(0.25, pixelSize))
    u.cornerRadius = 0
    u.opacity = Float(min(1, max(0, opacity)))
    return u
  }

  static func selectionGlowUniforms(
    size: CGSize, region: CGRect, pixelSize: CGFloat, clock: Double, colors: [SIMD4<Float>]
  ) -> PaletteSelectionGlowUniforms {
    var u = PaletteSelectionGlowUniforms()
    u.size = simd_float2(Float(size.width), Float(size.height))
    u.region = simd_float4(
      Float(region.minX), Float(region.minY), Float(region.width), Float(region.height))
    u.pixelSize = Float(max(0.25, pixelSize))
    u.cornerRadius = Float(AgentPaletteMetrics.screenSelectionCornerRadius)
    u.lineWidth = Float(AgentPaletteMetrics.screenSelectionLineWidth)
    u.glowDepth = Float(AgentPaletteMetrics.screenSelectionInnerGlowDepth)
    u.glowStrength = Float(AgentPaletteMetrics.screenSelectionInnerGlowStrength)
    u.haloReach = Float(AgentPaletteMetrics.screenSelectionHaloReach)
    u.haloStrength = Float(AgentPaletteMetrics.screenSelectionHaloStrength)
    u.clock = Float(clock.truncatingRemainder(dividingBy: 2 * .pi * 100))
    u.waveAmplitude = Float(AgentPaletteMetrics.screenSelectionWaveAmplitude)
    u.driftAmplitude = Float(AgentPaletteMetrics.screenSelectionDriftAmplitude)
    withUnsafeMutableBytes(of: &u.colors) { raw in
      let slots = raw.bindMemory(to: SIMD4<Float>.self)
      for index in slots.indices {
        slots[index] = colors.isEmpty ? SIMD4(1, 1, 1, 1) : colors[min(index, colors.count - 1)]
      }
    }
    return u
  }

  static func glowColors(_ palette: [NSColor]) -> [SIMD4<Float>] {
    let count = Int(PaletteSelectionGlowStops)
    guard let first = palette.first else { return Array(repeating: SIMD4(1, 1, 1, 1), count: count) }
    return (0..<count).map { index in
      let t = CGFloat(index) / CGFloat(count - 1) * CGFloat(max(palette.count - 1, 0))
      let lower = min(Int(t), palette.count - 1)
      let upper = min(lower + 1, palette.count - 1)
      let colour = palette.count == 1
        ? first : MascotPalette.mix(palette[lower], palette[upper], t - CGFloat(lower))
      let srgb = colour.usingColorSpace(.sRGB) ?? colour
      return SIMD4(Float(srgb.redComponent), Float(srgb.greenComponent), Float(srgb.blueComponent), 1)
    }
  }

  private static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(1, max(0, (x - edge0) / max(edge1 - edge0, 0.0001)))
    return t * t * (3 - 2 * t)
  }

  // MARK: - Frames, on the GPU

  func render(_ uniforms: PaletteRevealUniforms, texture: MTLTexture, in view: MTKView) {
    encode(reveal, uniforms, texture: texture, in: view)
  }

  func render(_ uniforms: PaletteWhipUniforms, texture: MTLTexture, in view: MTKView) {
    encode(whip, uniforms, texture: texture, in: view)
  }

  func render(_ uniforms: PaletteSelectionGlowUniforms, in view: MTKView) {
    encode(selectionGlow, uniforms, texture: nil, in: view)
  }


  private func encode<U: BitwiseCopyable>(
    _ pipeline: MTLRenderPipelineState, _ uniforms: U, texture: MTLTexture?, in view: MTKView
  ) {
    guard let drawable = view.currentDrawable,
          let pass = view.currentRenderPassDescriptor,
          let command = queue.makeCommandBuffer(),
          let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
    draw(pipeline, uniforms, texture: texture, with: encoder)
    command.present(drawable)
    command.commit()
  }

  private func draw<U: BitwiseCopyable>(
    _ pipeline: MTLRenderPipelineState, _ uniforms: U, texture: MTLTexture?,
    with encoder: MTLRenderCommandEncoder
  ) {
    var value = uniforms
    let index = Int(PaletteEffectBufferIndexUniforms.rawValue)
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(&value, length: MemoryLayout<U>.stride, index: index)
    encoder.setFragmentBytes(&value, length: MemoryLayout<U>.stride, index: index)
    encoder.setFragmentTexture(texture, index: Int(PaletteEffectTextureIndexImage.rawValue))
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
  }

  func image(of uniforms: PaletteRevealUniforms, texture: MTLTexture, scale: CGFloat = 2) -> CGImage? {
    image(reveal, uniforms, size: CGSize(width: CGFloat(uniforms.size.x), height: CGFloat(uniforms.size.y)),
          texture: texture, scale: scale)
  }

  func image(of uniforms: PaletteWhipUniforms, texture: MTLTexture, scale: CGFloat = 2) -> CGImage? {
    image(whip, uniforms, size: CGSize(width: CGFloat(uniforms.size.x), height: CGFloat(uniforms.size.y)),
          texture: texture, scale: scale)
  }

  func image(of uniforms: PaletteSelectionGlowUniforms, scale: CGFloat = 2) -> CGImage? {
    image(selectionGlow, uniforms,
          size: CGSize(width: CGFloat(uniforms.size.x), height: CGFloat(uniforms.size.y)),
          texture: nil, scale: scale)
  }

  private func image<U: BitwiseCopyable>(
    _ pipeline: MTLRenderPipelineState, _ uniforms: U, size: CGSize, texture: MTLTexture?,
    scale: CGFloat
  ) -> CGImage? {
    let width = Int((size.width * scale).rounded())
    let height = Int((size.height * scale).rounded())
    guard width > 0, height > 0 else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .managed
    guard let target = device.makeTexture(descriptor: descriptor),
          let command = queue.makeCommandBuffer() else { return nil }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    draw(pipeline, uniforms, texture: texture, with: encoder)
    guard let blit = command.makeBlitCommandEncoder() else { return nil }
    blit.synchronize(resource: target)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()

    let rowBytes = width * 4
    let count = rowBytes * height
    let raw = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
    defer { raw.deallocate() }
    target.getBytes(
      raw, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let data = Data(bytes: raw, count: count)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        .union(.byteOrder32Little),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}

struct TimingCurve {
  private let c1: CGPoint
  private let c2: CGPoint

  init(_ function: CAMediaTimingFunction) {
    var a: [Float] = [0, 0]
    var b: [Float] = [0, 0]
    function.getControlPoint(at: 1, values: &a)
    function.getControlPoint(at: 2, values: &b)
    c1 = CGPoint(x: CGFloat(a[0]), y: CGFloat(a[1]))
    c2 = CGPoint(x: CGFloat(b[0]), y: CGFloat(b[1]))
  }

  func value(at time: CGFloat) -> CGFloat {
    let x = min(1, max(0, time))
    var t = x
    for _ in 0..<8 {
      let error = Self.bezier(t, c1.x, c2.x) - x
      let slope = Self.slope(t, c1.x, c2.x)
      guard abs(error) > 1e-6 else { break }
      guard abs(slope) > 1e-6 else { break }
      t = min(1, max(0, t - error / slope))
    }
    if abs(Self.bezier(t, c1.x, c2.x) - x) > 1e-4 {
      var low: CGFloat = 0
      var high: CGFloat = 1
      for _ in 0..<30 {
        t = (low + high) / 2
        if Self.bezier(t, c1.x, c2.x) < x { low = t } else { high = t }
      }
    }
    return Self.bezier(t, c1.y, c2.y)
  }

  private static func bezier(_ t: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat {
    let u = 1 - t
    return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
  }

  private static func slope(_ t: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat {
    let u = 1 - t
    return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
  }
}

@MainActor
class PaletteEffectView: MTKView, MTKViewDelegate {
  let effects: PaletteEffects
  let texture: MTLTexture
  let duration: TimeInterval
  var finished: (() -> Void)?
  private var link: CADisplayLink?
  private var startedAt: CFTimeInterval?
  private(set) var elapsed: CGFloat = 0

  static func resources(for image: CGImage) -> (PaletteEffects, MTLTexture)? {
    guard let effects = PaletteEffects.shared, let texture = effects.texture(for: image) else {
      return nil
    }
    return (effects, texture)
  }

  init(effects: PaletteEffects, texture: MTLTexture, duration: TimeInterval) {
    self.effects = effects
    self.texture = texture
    self.duration = duration
    super.init(frame: .zero, device: effects.device)
    isPaused = true
    enableSetNeedsDisplay = false
    delegate = self
    colorPixelFormat = .bgra8Unorm
    framebufferOnly = true
    clearColor = MTLClearColorMake(0, 0, 0, 0)
    wantsLayer = true
    layer?.isOpaque = false
    layer?.masksToBounds = false
    (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var allowsVibrancy: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func start() {
    guard link == nil, !isDone, window != nil else { return }
    startedAt = Motion.now
    let link = displayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = MotionPreferences.highFrameRateRange
    link.add(to: .main, forMode: .common)
    self.link = link
    draw()
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Motion.scaled(duration + Motion.standard)
    ) { [weak self] in
      MainActor.assumeIsolated { self?.finish() }
    }
  }

  private var isDone = false

  private func finish() {
    guard !isDone else { return }
    isDone = true
    elapsed = 1
    stop()
    finished?()
  }

  func stop() {
    link?.invalidate()
    link = nil
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { stop() }
  }

  @objc private func tick() {
    guard let startedAt else { return }
    elapsed = min(1, CGFloat((Motion.now - startedAt) / max(duration, 0.001)))
    draw()
    if elapsed >= 1 { finish() }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    render(at: elapsed)
  }

  func render(at time: CGFloat) {}

  var pixelSize: CGFloat { 1 / max(1, window?.backingScaleFactor ?? 2) }
}

@MainActor
final class PaletteRevealView: PaletteEffectView {
  private let imageAspect: CGFloat
  private let cornerRadius: CGFloat
  private let curve = TimingCurve(Motion.emphasizedCurve)

  static func make(image: CGImage, cornerRadius: CGFloat) -> PaletteRevealView? {
    resources(for: image).map { effects, texture in
      PaletteRevealView(
        effects: effects, texture: texture,
        imageAspect: CGFloat(image.width) / CGFloat(max(1, image.height)),
        cornerRadius: cornerRadius)
    }
  }

  private init(effects: PaletteEffects, texture: MTLTexture, imageAspect: CGFloat, cornerRadius: CGFloat) {
    self.imageAspect = imageAspect
    self.cornerRadius = cornerRadius
    super.init(effects: effects, texture: texture, duration: AgentPaletteMetrics.revealDuration)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func render(at time: CGFloat) {
    guard bounds.width > 1, bounds.height > 1 else { return }
    let uniforms = PaletteEffects.revealUniforms(
      progress: curve.value(at: time), size: bounds.size, imageAspect: imageAspect,
      pixelSize: pixelSize, cornerRadius: cornerRadius,
      cornerIsContinuous: AgentPaletteMetrics.cornerCurve(
        radius: cornerRadius, shorterSide: min(bounds.width, bounds.height)) == .continuous)
    effects.render(uniforms, texture: texture, in: self)
  }
}

@MainActor
final class PaletteWhipView: PaletteEffectView {
  private let from: CGRect
  private let to: CGRect
  private let curve = TimingCurve(Motion.emphasizedCurve)
  private var lastFrame: CGRect?
  private var lastTime: CFTimeInterval?

  static func make(image: CGImage, from: CGRect, to: CGRect, duration: TimeInterval) -> PaletteWhipView? {
    resources(for: image).map { effects, texture in
      PaletteWhipView(effects: effects, texture: texture, from: from, to: to, duration: duration)
    }
  }

  private init(
    effects: PaletteEffects, texture: MTLTexture, from: CGRect, to: CGRect, duration: TimeInterval
  ) {
    self.from = from
    self.to = to
    super.init(effects: effects, texture: texture, duration: duration)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func flight(at time: CGFloat) -> (frame: CGRect, velocity: CGVector) {
    func frame(_ t: CGFloat) -> CGRect {
      let p = curve.value(at: t)
      return CGRect(
        x: from.minX + (to.minX - from.minX) * p, y: from.minY + (to.minY - from.minY) * p,
        width: from.width + (to.width - from.width) * p,
        height: from.height + (to.height - from.height) * p)
    }
    let here = frame(time)
    let step: CGFloat = 1 / 120
    let ahead = frame(min(1, time + step))
    let behind = frame(max(0, time - step))
    let span = (min(1, time + step) - max(0, time - step)) * CGFloat(duration)
    guard span > 0 else { return (here, .zero) }
    return (here, CGVector(
      dx: (ahead.midX - behind.midX) / span, dy: (ahead.midY - behind.midY) / span))
  }

  override func render(at time: CGFloat) {
    guard bounds.width > 1, bounds.height > 1 else { return }
    let (frame, velocity) = flight(at: time)
    let opacity = 1 - min(1, time / AgentPaletteMetrics.whipFadeOutAt)
    let uniforms = PaletteEffects.whipUniforms(
      size: bounds.size, frame: frame, velocity: velocity, pixelSize: pixelSize,
      opacity: opacity)
    effects.render(uniforms, texture: texture, in: self)
  }
}

@MainActor
final class ScreenSelectionGlowView: MTKView, MTKViewDelegate {
  static var margin: CGFloat {
    AgentPaletteMetrics.screenSelectionHaloReach + AgentPaletteMetrics.screenSelectionLineWidth
  }

  private let effects: PaletteEffects
  private var colors: [SIMD4<Float>] = []
  private var link: CADisplayLink?
  private var occlusion: NSObjectProtocol?

  var region: CGRect = .zero {
    didSet { if region != oldValue { drawIfStill() } }
  }

  var palette: [NSColor] = [] {
    didSet {
      guard palette != oldValue else { return }
      colors = PaletteEffects.glowColors(palette)
      drawIfStill()
    }
  }

  static func make() -> ScreenSelectionGlowView? {
    PaletteEffects.shared.map(ScreenSelectionGlowView.init(effects:))
  }

  private init(effects: PaletteEffects) {
    self.effects = effects
    super.init(frame: .zero, device: effects.device)
    isPaused = true
    enableSetNeedsDisplay = false
    delegate = self
    colorPixelFormat = .bgra8Unorm
    framebufferOnly = true
    clearColor = MTLClearColorMake(0, 0, 0, 0)
    wantsLayer = true
    layer?.isOpaque = false
    layer?.masksToBounds = false
    (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var allowsVibrancy: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  var isRunningForTesting: Bool { link != nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    occlusion = nil
    guard let window else {
      stop()
      return
    }
    occlusion = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.syncRunning() }
    }
    syncRunning()
  }

  override func viewDidHide() {
    super.viewDidHide()
    syncRunning()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    syncRunning()
  }

  private func syncRunning() {
    let seen = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
    if seen, !isHiddenOrHasHiddenAncestor, !MotionPreferences.reduceMotion {
      guard link == nil else { return }
      let link = displayLink(target: self, selector: #selector(tick))
      link.preferredFrameRateRange = MotionPreferences.highFrameRateRange
      link.add(to: .main, forMode: .common)
      self.link = link
      draw()
    } else {
      stop()
      if seen { draw() }
    }
  }

  private func stop() {
    link?.invalidate()
    link = nil
  }

  @objc private func tick() {
    draw()
  }

  private func drawIfStill() {
    guard link == nil, window != nil else { return }
    draw()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard bounds.width > 1, bounds.height > 1, region.width > 1, region.height > 1 else { return }
    let clock = MotionPreferences.reduceMotion
      ? 0 : Motion.now * MascotSpec.speed * MascotSpec.gradientRate
    effects.render(PaletteEffects.selectionGlowUniforms(
      size: bounds.size, region: region,
      pixelSize: 1 / max(1, window?.backingScaleFactor ?? 2), clock: clock, colors: colors),
      in: self)
  }

  isolated deinit {
    link?.invalidate()
    if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
  }
}
