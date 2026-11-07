import AppKit
import Metal
import MetalKit
import simd

@MainActor
final class AgentBackdropView: MTKView, MTKViewDelegate {
  private let renderer: AgentBackdropRenderer?
  private var palette = MascotPalette.standard
  private var backdrop = ChatBackdrop.standard
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

  func show(_ backdrop: ChatBackdrop, palette: MascotPalette) {
    let target: CGFloat = backdrop == .standard ? 0 : 1
    if backdrop != .standard {
      if backdrop != self.backdrop || palette != self.palette {
        self.backdrop = backdrop
        self.palette = palette
        if !isHidden { draw() }
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
    if target <= 0, !MotionPreferences.reduceMotion {
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
      layer?.contentsGravity = .top
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
    sceneSize = nil
    let size = pixels(rect.size)
    if drawableSize != size { drawableSize = size }
    if !isHidden { draw() }
  }

  private func startClock() {
    guard link == nil, window != nil, renderer != nil else { return }
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
    guard morphingTo == nil else { return }
    if !MotionPreferences.reduceMotion { clock += dt }
    draw()
    if MotionPreferences.reduceMotion { stopClock() }
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
      palette: palette
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
      clock: 24, opacity: 1, palette: palette
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
    clock: CGFloat, opacity: CGFloat, palette: MascotPalette
  ) -> AgentBackdropUniforms {
    var u = AgentBackdropUniforms()
    u.size = simd_float2(Float(size.width), Float(size.height))
    u.pixelSize = Float(max(0.25, pixelSize))
    u.scene = backdrop.sceneIndex
    u.clock = Float(clock)
    u.opacity = Float(min(1, max(0, opacity)))
    withUnsafeMutableBytes(of: &u.sky) { raw in
      let slots = raw.bindMemory(to: simd_float4.self)
      for (index, color) in AgentBackdropSky.ramp(for: palette).enumerated() {
        let color = color.usingColorSpace(.sRGB) ?? color
        slots[index] = simd_float4(
          Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent), 1
        )
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
  static func ramp(for palette: MascotPalette) -> [NSColor] {
    if let hexes = presets[palette.id] { return hexes.map(HexColor.nsColor) }
    let stops = palette.colors.map { $0.usingColorSpace(.sRGB) ?? $0 }
    guard stops.count >= 5, let first = stops.first, let last = stops.last else {
      return (presets["lagoon"] ?? []).map(HexColor.nsColor)
    }
    return [
      first.blended(withFraction: 0.75, of: .black) ?? first,
      last.blended(withFraction: 0.45, of: .black) ?? last,
      stops[2].blended(withFraction: 0.4, of: .white) ?? stops[2],
      first.blended(withFraction: 0.6, of: .black) ?? first,
      stops[1].blended(withFraction: 0.6, of: .black) ?? stops[1],
      stops[4].blended(withFraction: 0.25, of: .black) ?? stops[4]
    ]
  }

  private static let presets: [String: [String]] = [
    "daybreak": ["#0e3c94", "#d07c48", "#fff2cc", "#34569e", "#2f6ccc", "#f6bc48"],
    "citrus": ["#063a3c", "#b2741a", "#ffe08a", "#1c5040", "#1c6a4c", "#e29a28"],
    "candy": ["#0a4250", "#b4687a", "#ffa8b8", "#2a4470", "#3c6478", "#d68a70"],
    "ember": ["#2a0c28", "#a8443c", "#ffc49a", "#5a1c3a", "#5e1c40", "#d8784a"],
    "lagoon": ["#0a3888", "#3c80cc", "#f2f7ff", "#4c78bc", "#1c5cb4", "#8ab8e4"],
    "slate": ["#1a1240", "#7c5ca4", "#f2e6fc", "#3e3074", "#3e2c72", "#b480b4"]
  ]
}
