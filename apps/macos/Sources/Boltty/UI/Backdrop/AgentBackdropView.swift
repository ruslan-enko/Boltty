import AppKit
import Metal
import MetalKit
import simd

/// What an open chat wears behind its transcript (`ChatBackdrop`), in the
/// colours of the agent it belongs to.
///
/// Stands over the shell's glass and under the transcript, at the shell's
/// frame. **The corner is the layer's**, set from the glass's rendered corner
/// and curve: a continuous corner drawn by a formula in the shader parted
/// company with the glass's own. A Metal layer with no sublayers is clipped by
/// the compositor, so this costs no offscreen pass. Drawn at 20 frames a
/// second: nothing in it moves fast, and each frame costs a third less.
@MainActor
final class AgentBackdropView: MTKView, MTKViewDelegate {
  private let renderer: AgentBackdropRenderer?
  private var palette = MascotPalette.standard
  private var backdrop = ChatBackdrop.standard
  private var clock: CGFloat = 0
  private var opacity: CGFloat = 0
  private var targetOpacity: CGFloat = 0
  private var lastTick: CFTimeInterval = 0
  private var link: CADisplayLink?

  /// Points of scene per point of view. Below 1 a small view shows more of
  /// the scene rather than a crop of it (Settings' thumbnails).
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
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var allowsVibrancy: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// The clock runs only while there is something to show **and** the window
  /// is on screen. Hiding the panel orders its window out but leaves this view
  /// in it, and a display link does not stop for that by itself: an open chat
  /// hidden with ⌥Space would go on drawing its sky, unseen, for as long as
  /// Boltty ran. The faces stop the same way (`MascotNSView.updateMembership`).
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
    if onScreen, targetOpacity > 0 || opacity > 0 { startClock() } else { stopClock() }
  }

  /// Shows `backdrop` in `palette`; `.standard` fades the last scene out.
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
    if target > 0 { isHidden = false }
    syncClock()
  }

  /// Called by whoever moves the shell, once per frame of its spring, with the
  /// corner the glass actually drew.
  func layOut(in rect: CGRect, corner: CGFloat, curve: CALayerCornerCurve) {
    frame = rect
    if let layer {
      layer.applyPaletteCorner(radius: corner)
      layer.cornerCurve = curve
    }
    let scale = backdrop.drawsAtFullScale ? (window?.backingScaleFactor ?? 2) : 1
    let size = CGSize(width: max(1, (rect.width * scale).rounded()), height: max(1, (rect.height * scale).rounded()))
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
    if !MotionPreferences.reduceMotion { clock += dt }
    let fade = MotionPreferences.reduceMotion ? 1 : dt / 0.35
    opacity += max(-fade, min(fade, targetOpacity - opacity))
    if opacity <= 0, targetOpacity <= 0 {
      isHidden = true
      stopClock()
      return
    }
    // Still, once faded in under Reduce Motion: one frame says it all.
    if MotionPreferences.reduceMotion, opacity == targetOpacity { stopClock() }
    draw()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    renderer?.render(uniforms, in: view)
  }

  var uniforms: AgentBackdropUniforms {
    AgentBackdropRenderer.uniforms(
      size: CGSize(width: bounds.width / sceneScale, height: bounds.height / sceneScale),
      pixelSize: bounds.width > 0 ? bounds.width / sceneScale / max(1, drawableSize.width) : 1,
      backdrop: backdrop,
      clock: clock,
      opacity: opacity,
      colors: palette.colors
    )
  }
}

/// The GPU half of `AgentBackdropView`, apart so a still can be drawn into an
/// image without a window (`image(of:)`).
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
    // Premultiplied source-over, as the voice glow.
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

  /// One renderer for every still, made on first use.
  private static let shared = AgentBackdropRenderer(pixelFormat: .bgra8Unorm)
  private static var stills: [String: CGImage] = [:]

  /// A still of `backdrop` for a chooser: the lower half of a `scene`-point
  /// wide, twice as tall scene, drawn into `pixels` pixels square — the half
  /// where each scene keeps its colour; the top is dark on purpose, for the
  /// prose, and a thumbnail of it read as a black disc. Cached by scene,
  /// colours and size.
  static func still(
    of backdrop: ChatBackdrop, palette: MascotPalette, scene: CGFloat, pixels: CGFloat
  ) -> CGImage? {
    guard backdrop != .standard else { return nil }
    let key = "\(backdrop.rawValue).\(palette.id).\(Int(scene)).\(Int(pixels))"
    if let cached = stills[key] { return cached }
    let u = uniforms(
      size: CGSize(width: scene, height: scene * 2), pixelSize: scene / pixels, backdrop: backdrop,
      clock: 24, opacity: 1, colors: palette.colors
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
    clock: CGFloat, opacity: CGFloat, colors: [NSColor]
  ) -> AgentBackdropUniforms {
    var u = AgentBackdropUniforms()
    u.size = simd_float2(Float(size.width), Float(size.height))
    u.pixelSize = Float(max(0.25, pixelSize))
    u.scene = backdrop.sceneIndex
    u.clock = Float(clock)
    u.opacity = Float(min(1, max(0, opacity)))
    let stops = colors.isEmpty ? [NSColor.white] : colors
    let count = Int(AGENT_BACKDROP_COLOR_COUNT)
    withUnsafeMutableBytes(of: &u.colors) { raw in
      let slots = raw.bindMemory(to: simd_float4.self)
      for index in 0..<count {
        let source = stops.count == 1
          ? 0
          : Int((CGFloat(index) / CGFloat(count - 1) * CGFloat(stops.count - 1)).rounded())
        let raw = stops[min(source, stops.count - 1)]
        let color = raw.usingColorSpace(.sRGB) ?? raw
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

  /// One still, for judging the look by eye without the panel.
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
