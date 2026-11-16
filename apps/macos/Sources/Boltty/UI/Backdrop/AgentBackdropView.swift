import AppKit
import Metal
import MetalKit
import simd

@MainActor
final class AgentBackdropView: MTKView, MTKViewDelegate {
  private let renderer: AgentBackdropRenderer?
  private var palette: MascotPalette? = .standard
  private var backdrop = ChatBackdrop.standard
  private var ramp = AgentBackdropSky.slots(for: .standard)
  private var blend: (from: [AgentBackdropSky.Tone], to: [AgentBackdropSky.Tone], start: CFTimeInterval)?
  private var clock: CGFloat = 0
  private var targetOpacity: CGFloat = 0
  private var lastTick: CFTimeInterval = 0
  private var link: CADisplayLink?

  var morphingTo: CGSize?
  private var sceneSize: CGSize?

  var sceneScale: CGFloat = 1

  init(frame frameRect: NSRect) {
    let renderer = AgentBackdropRenderer(pixelFormat: .bgra8Unorm)
    self.renderer = renderer
    super.init(frame: frameRect, device: renderer?.device)
    isPaused = true
    enableSetNeedsDisplay = false
    autoResizeDrawable = false
    delegate = self
    colorPixelFormat = .bgra8Unorm
    framebufferOnly = true
    clearColor = MTLClearColorMake(0, 0, 0, 0)
    wantsLayer = true
    layer?.isOpaque = false
    layer?.masksToBounds = true
    isHidden = true
    alphaValue = 0
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var allowsVibrancy: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    if let window {
      NotificationCenter.default.addObserver(
        self, selector: #selector(occlusionChanged),
        name: NSWindow.didChangeOcclusionStateNotification, object: window
      )
    }
    syncClock()
  }

  @objc private func occlusionChanged() { syncClock() }

  private func syncClock() {
    let onScreen = window?.occlusionState.contains(.visible) == true
    if onScreen, !isHidden { startClock() } else { stopClock() }
  }

  /// How much faster than the scene's own seconds the sky drifts.
  static let pace: CGFloat = 1.6
  static let paletteBlend: CFTimeInterval = 0.6

  /// A `nil` palette is the neutral sky, worn where no one face is shown.
  func show(_ backdrop: ChatBackdrop, palette: MascotPalette?) {
    let target: CGFloat = backdrop == .standard ? 0 : 1
    if backdrop != .standard {
      let recolours = palette != self.palette
      let showing = !isHidden && targetOpacity > 0 && backdrop == self.backdrop
      if backdrop != self.backdrop || recolours {
        self.backdrop = backdrop
        self.palette = palette
        let next = AgentBackdropSky.slots(for: palette)
        if recolours, showing, !MotionPreferences.reduceMotion {
          blend = (ramp, next, Motion.now)
          startClock()
        } else {
          blend = nil
          ramp = next
          if !isHidden { draw() }
        }
      }
    }
    guard target != targetOpacity else { return }
    targetOpacity = target
    if target > 0, isHidden {
      isHidden = false
      if morphingTo == nil { draw() }
    }
    fade(to: target)
    syncClock()
  }

  private func fade(to target: CGFloat) {
    guard let layer else { return }
    let from = layer.presentation()?.opacity ?? layer.opacity
    layer.removeAnimation(forKey: "fade")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { [weak self] in
      guard let self, self.targetOpacity <= 0, self.layer?.animation(forKey: "fade") == nil else { return }
      self.isHidden = true
      self.stopClock()
    }
    alphaValue = target
    if !MotionPreferences.reduceMotion {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = from
      fade.toValue = Float(target)
      fade.duration = Motion.scaled(Motion.standard)
      fade.timingFunction = Motion.standardCurve
      layer.add(fade, forKey: "fade")
    }
    CATransaction.commit()
  }

  func layOut(in rect: CGRect, corner: CGFloat, curve: CALayerCornerCurve) {
    frame = rect
    if let layer {
      layer.applyPaletteCorner(radius: corner)
      layer.cornerCurve = curve
    }
    let scale = backdrop.pixelsPerPoint(backing: window?.backingScaleFactor ?? 2)
    if layer?.contentsScale != scale { layer?.contentsScale = scale }
    func pixels(_ size: CGSize) -> CGSize {
      CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }
    if let destination = morphingTo {
      cover(rect.size, with: destination)
      guard !isHidden, targetOpacity > 0 else { return }
      let size = pixels(destination)
      if drawableSize != size || sceneSize != destination {
        drawableSize = size
        sceneSize = destination
        draw()
      }
      return
    }
    layer?.contentsGravity = .resize
    if layer?.contentsRect != CGRect(x: 0, y: 0, width: 1, height: 1) {
      layer?.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }
    sceneSize = nil
    let size = pixels(rect.size)
    if drawableSize != size { drawableSize = size }
    if !isHidden { draw() }
  }

  /// While the shell morphs, the sky drawn at the size it is going to is shown
  /// 1:1 from its top; where the shell is still wider or taller than that, it is
  /// scaled up just enough to cover, so no edge goes bare. The scale reaches 1 as
  /// the shell arrives, and the live sky takes over on the same frame.
  private func cover(_ shown: CGSize, with destination: CGSize) {
    guard let layer, destination.width > 0, destination.height > 0 else { return }
    layer.contentsGravity = .resize
    let scale = max(1, shown.width / destination.width, shown.height / destination.height)
    let width = min(1, shown.width / scale / destination.width)
    let height = min(1, shown.height / scale / destination.height)
    let top = layer.contentsAreFlipped() ? 0 : 1 - height
    layer.contentsRect = CGRect(x: (1 - width) / 2, y: top, width: width, height: height)
  }

  private func startClock() {
    guard link == nil, window != nil, renderer != nil, !isHidden else { return }
    lastTick = Motion.now
    let link = displayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 20, preferred: 20)
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  private func stopClock() {
    link?.invalidate()
    link = nil
  }

  @objc private func tick() {
    let now = Motion.now
    let dt = CGFloat(min(now - lastTick, 0.1))
    lastTick = now
    let blending = stepBlend(at: now)
    guard morphingTo == nil || blending else { return }
    if !MotionPreferences.reduceMotion, morphingTo == nil { clock += dt * Self.pace }
    draw()
    if MotionPreferences.reduceMotion, blend == nil { stopClock() }
  }

  private func stepBlend(at now: CFTimeInterval) -> Bool {
    guard let blend else { return false }
    let linear = min(1, max(0, (now - blend.start) / Motion.scaled(Self.paletteBlend)))
    let t = linear * linear * (3 - 2 * linear)
    ramp = zip(blend.from, blend.to).map { from, to in
      AgentBackdropSky.Tone(l: from.l + (to.l - from.l) * t, a: from.a + (to.a - from.a) * t, b: from.b + (to.b - from.b) * t)
    }
    if linear >= 1 { self.blend = nil }
    return true
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    renderer?.render(uniforms, in: view)
  }

  var uniforms: AgentBackdropUniforms {
    let scene = sceneSize ?? CGSize(width: bounds.width / sceneScale, height: bounds.height / sceneScale)
    return AgentBackdropRenderer.uniforms(
      size: scene,
      pixelSize: scene.width > 0 ? scene.width / max(1, drawableSize.width) : 1,
      backdrop: backdrop,
      clock: clock,
      opacity: 1,
      ramp: ramp
    )
  }
}

@MainActor
final class AgentBackdropRenderer {
  let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState

  init?(pixelFormat: MTLPixelFormat) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let library = device.makeDefaultLibrary(),
          let vertex = library.makeFunction(name: "agentBackdropVertex"),
          let fragment = library.makeFunction(name: "agentBackdropFragment")
    else { return nil }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.label = "AgentBackdrop"
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    let attachment = descriptor.colorAttachments[0]
    attachment?.pixelFormat = pixelFormat
    attachment?.isBlendingEnabled = true
    attachment?.sourceRGBBlendFactor = .one
    attachment?.sourceAlphaBlendFactor = .one
    attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
    self.device = device
    self.queue = queue
    self.pipeline = pipeline
  }

  private static let shared = AgentBackdropRenderer(pixelFormat: .bgra8Unorm)
  private static var stills: [String: CGImage] = [:]

  static func still(
    of backdrop: ChatBackdrop, palette: MascotPalette, scene: CGFloat, pixels: CGFloat
  ) -> CGImage? {
    guard backdrop != .standard else { return nil }
    let key = "\(backdrop.rawValue).\(palette.id).\(Int(scene)).\(Int(pixels))"
    if let cached = stills[key] { return cached }
    let u = uniforms(
      size: CGSize(width: scene, height: scene * 2), pixelSize: scene / pixels, backdrop: backdrop,
      clock: 24, opacity: 1, ramp: AgentBackdropSky.slots(for: palette)
    )
    let side = pixels.rounded()
    guard let whole = shared?.image(of: u, scale: pixels / scene),
          let image = whole.cropping(to: CGRect(x: 0, y: CGFloat(whole.height) - side, width: side, height: side))
    else { return nil }
    stills[key] = image
    return image
  }

  static func uniforms(
    size: CGSize, pixelSize: CGFloat, backdrop: ChatBackdrop,
    clock: CGFloat, opacity: CGFloat, ramp: [AgentBackdropSky.Tone]
  ) -> AgentBackdropUniforms {
    var u = AgentBackdropUniforms()
    u.size = simd_float2(Float(size.width), Float(size.height))
    u.pixelSize = Float(max(0.25, pixelSize))
    u.scene = backdrop.sceneIndex
    u.clock = Float(clock)
    u.opacity = Float(min(1, max(0, opacity)))
    withUnsafeMutableBytes(of: &u.sky) { raw in
      let slots = raw.bindMemory(to: simd_float4.self)
      for (index, tone) in ramp.enumerated() {
        slots[index] = simd_float4(Float(tone.l), Float(tone.a), Float(tone.b), 1)
      }
    }
    return u
  }

  func render(_ uniforms: AgentBackdropUniforms, in view: MTKView) {
    guard uniforms.opacity > 0,
          let drawable = view.currentDrawable,
          let pass = view.currentRenderPassDescriptor,
          let command = queue.makeCommandBuffer()
    else { return }
    encode(uniforms, pass: pass, command: command)
    command.present(drawable)
    command.commit()
  }

  func image(of uniforms: AgentBackdropUniforms, scale: CGFloat = 2) -> CGImage? {
    let width = Int((CGFloat(uniforms.size.x) * scale).rounded())
    let height = Int((CGFloat(uniforms.size.y) * scale).rounded())
    guard width > 0, height > 0 else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .managed
    guard let texture = device.makeTexture(descriptor: descriptor),
          let command = queue.makeCommandBuffer()
    else { return nil }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    var still = uniforms
    still.pixelSize = Float(1 / scale)
    encode(still, pass: pass, command: command)
    guard let blit = command.makeBlitCommandEncoder() else { return nil }
    blit.synchronize(resource: texture)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()

    let rowBytes = width * 4
    let raw = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 16)
    defer { raw.deallocate() }
    texture.getBytes(raw, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let data = Data(bytes: raw, count: rowBytes * height)
    guard let provider = CGDataProvider(data: data as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
      space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        .union(.byteOrder32Little),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )
  }

  private func encode(_ uniforms: AgentBackdropUniforms, pass: MTLRenderPassDescriptor, command: MTLCommandBuffer) {
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
    var value = uniforms
    let length = MemoryLayout<AgentBackdropUniforms>.stride
    let index = Int(AgentBackdropBufferIndexUniforms.rawValue)
    encoder.label = "AgentBackdrop"
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(&value, length: length, index: index)
    encoder.setFragmentBytes(&value, length: length, index: index)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
  }
}

enum AgentBackdropSky {
  typealias Tone = Oklab

  /// A `nil` palette is the neutral sky.
  static func slots(for palette: MascotPalette?) -> [Tone] {
    palette.map(ramp(for:)) ?? neutral.map(\.oklab)
  }

  /// Greys, faintly cool, for the list's All tab: every face is there, so none colours it.
  private static let neutral = [
    OKLCH(0.205, 0.008, 258), OKLCH(0.43, 0.017, 258), OKLCH(0.93, 0.007, 258),
    OKLCH(0.28, 0.013, 258), OKLCH(0.31, 0.014, 258), OKLCH(0.57, 0.018, 258)
  ]

  /// Zenith, horizon, cloud light, cloud shade, middle, glow.
  static func ramp(for palette: MascotPalette) -> [Tone] {
    if let preset = presets[palette.id] { return preset.map(\.oklab) }
    let stops = palette.colors.map(Tone.init)
    guard stops.count >= 5, let first = stops.first, let last = stops.last else {
      return (presets["lagoon"] ?? []).map(\.oklab)
    }
    return [
      darker(first, 0.36), darker(last, 0.65), lighter(stops[2], 0.4),
      darker(first, 0.5), darker(stops[1], 0.5), darker(stops[4], 0.8)
    ]
  }

  /// Lightness alone goes down, so a dark sky keeps its colour.
  private static func darker(_ tone: Tone, _ scale: Double) -> Tone {
    Tone(l: tone.l * scale, a: tone.a, b: tone.b)
  }

  private static func lighter(_ tone: Tone, _ amount: Double) -> Tone {
    Tone(l: tone.l + (1 - tone.l) * amount, a: tone.a * (1 - amount), b: tone.b * (1 - amount))
  }

  private static let presets: [String: [OKLCH]] = [
    // Blue and orange mix through grey, so violet stands between them and the cloud light is rose.
    "daybreak": [
      OKLCH(0.412, 0.176, 262.8), OKLCH(0.686, 0.171, 36.2), OKLCH(0.796, 0.117, 29.5),
      OKLCH(0.473, 0.159, 283.7), OKLCH(0.545, 0.183, 285.2), OKLCH(0.755, 0.158, 46.6)
    ],
    "citrus": [
      OKLCH(0.318, 0.051, 198.9), OKLCH(0.610, 0.124, 69.8), OKLCH(0.914, 0.111, 90.3),
      OKLCH(0.391, 0.062, 169.7), OKLCH(0.469, 0.089, 163.1), OKLCH(0.740, 0.146, 72.8)
    ],
    "candy": [
      OKLCH(0.352, 0.059, 219.4), OKLCH(0.607, 0.099, 5.2), OKLCH(0.821, 0.104, 7.6),
      OKLCH(0.388, 0.082, 260.4), OKLCH(0.482, 0.055, 231.2), OKLCH(0.705, 0.101, 39.6)
    ],
    "ember": [
      OKLCH(0.217, 0.066, 330.2), OKLCH(0.519, 0.134, 27.2), OKLCH(0.864, 0.087, 56.7),
      OKLCH(0.334, 0.097, 353.7), OKLCH(0.343, 0.104, 350.3), OKLCH(0.671, 0.134, 45.3)
    ],
    "lagoon": [
      OKLCH(0.367, 0.142, 261.0), OKLCH(0.593, 0.136, 253.2), OKLCH(0.975, 0.012, 259.8),
      OKLCH(0.572, 0.116, 258.8), OKLCH(0.486, 0.154, 257.8), OKLCH(0.766, 0.080, 247.8)
    ],
    "slate": [
      OKLCH(0.225, 0.083, 285.5), OKLCH(0.538, 0.114, 303.3), OKLCH(0.941, 0.032, 309.9),
      OKLCH(0.363, 0.112, 289.1), OKLCH(0.354, 0.115, 291.2), OKLCH(0.669, 0.095, 326.6)
    ]
  ]
}
