import Accelerate
import AppKit
import Metal
import MetalKit
import simd

@MainActor
final class MascotRenderer {
  struct Pose: Equatable {
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0
    var sx = 1.0
    var sy = 1.0
    var lift = 0.0
  }

  struct Eye: Equatable {
    var centre: CGPoint
    var turn: Double
    var shape: MascotEyeShape
  }

  struct Ink: Equatable {
    var eyesAreBlack: Bool
    var smileIsBlack: Bool

    static let white = Ink(eyesAreBlack: false, smileIsBlack: false)
    static let whiteEyesBlackSmile = Ink(eyesAreBlack: false, smileIsBlack: true)
    static let black = Ink(eyesAreBlack: true, smileIsBlack: true)

    static let standard = black
  }

  struct Frame: Equatable {
    var size: CGSize
    var pixelSize: CGFloat
    var pose: Pose
    var eyes: [Eye]
    var clock: Double
    var phase: Double
    var palette: MascotPalette
    var shape: MascotShape = .hex
    var overscan: CGFloat = 0
    var finish: MascotFinish = .velvet
    var ink: Ink = .standard
  }

  static let fill: CGFloat = 0.9

  static let shared: MascotRenderer? = MascotRenderer()

  static let pixelFormat = MTLPixelFormat.bgra8Unorm

  let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let fieldPipeline: MTLComputePipelineState
  private var fields: [Int32: MTLBuffer] = [:]

  private init?() {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let library = device.makeDefaultLibrary(),
          let vertexFunction = library.makeFunction(name: "mascotVertex"),
          let fragmentFunction = library.makeFunction(name: "mascotFragment"),
          let fieldFunction = library.makeFunction(name: "mascotPlushField"),
          let fieldPipeline = try? device.makeComputePipelineState(function: fieldFunction)
    else { return nil }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.label = "Mascot"
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
      return nil
    }
    self.device = device
    self.queue = queue
    self.pipeline = pipeline
    self.fieldPipeline = fieldPipeline
  }

  // MARK: - The frame, as numbers

  static let largeFaceSide: CGFloat = 48

  static func rays(for frame: Frame) -> Int {
    #if DEBUG
    if let forced = forcedRays { return forced }
    #endif
    // Two at every size. Four on a big face cost two and a half times the
    // GPU of two (the first run's five faces drew at 52 frames a second
    // with four, 62 with two) and the eye finds no difference.
    // A still picture (`snapshot`) still takes four.
    return 2
  }

  #if DEBUG
  private static let forcedRays: Int? = {
    let value = UserDefaults.standard.integer(forKey: "boltty.mascot.rays")
    return value > 0 ? value : nil
  }()
  #endif

  static func uniforms(for frame: Frame, rays: Int? = nil) -> MascotUniforms {
    var u = MascotUniforms()
    let side = min(frame.size.width, frame.size.height)
    let room = side * frame.overscan * 2
    u.frame = simd_float4(
      Float(frame.size.width + room),
      Float(frame.size.height + room),
      Float(max(0.25, frame.pixelSize)),
      Float(max(0.01, side / MascotSpec.designBox * fill))
    )

    let turn = rotation(for: frame.pose)
    u.axisX = simd_float4(turn.columns.0, Float(-frame.pose.lift))
    u.axisY = simd_float4(turn.columns.1, 0)
    u.axisZ = simd_float4(turn.columns.2, 0)
    u.body = simd_float4(
      Float(max(0.3, frame.pose.sx)), Float(max(0.3, frame.pose.sy)),
      Float(frame.clock), Float(frame.phase)
    )

    let stops = oklabStops(for: frame.palette)
    for (index, stop) in stops.enumerated() {
      setStop(&u, at: index, stop)
    }
    for (index, eye) in frame.eyes.prefix(2).enumerated() {
      setEye(&u.eyes, at: index, simd_float4(
        Float(eye.centre.x), Float(eye.centre.y), Float(eye.turn), Float(eye.shape.scale)
      ))
      setEye(&u.looks, at: index, simd_float4(
        Float(eye.shape.open), Float(eye.shape.happy), Float(eye.shape.sleepy), Float(eye.shape.droop)
      ))
    }
    let build = frame.shape.build
    u.shape = simd_float4(
      Float(stops.count),
      Float(frame.shape.shaderID.rawValue),
      Float(frame.palette.style.shaderID.rawValue),
      Float(frame.palette.style.turn)
    )
    u.build = simd_float4(Float(build.thickness), Float(build.profile), 0, 0)
    u.face = simd_float4(
      Float(build.eyeOffset.x), Float(build.eyeOffset.y), Float(build.eyeScale), Float(MascotSpec.eyeSize)
    )
    u.extent = simd_float4(
      Float(build.top), Float(build.bottom), Float(build.halfWidth), Float(build.step)
    )
    u.finish = simd_float4(
      frame.finish == .velvet ? 1 : 0, frame.finish == .fur ? 1 : 0,
      Float(rays ?? Self.rays(for: frame)), 0
    )
    u.ink = simd_float4(frame.ink.eyesAreBlack ? 1 : 0, frame.ink.smileIsBlack ? 1 : 0, 0, 0)
    return u
  }

  static func rotation(for pose: Pose) -> simd_float3x3 {
    let yaw = Float(pose.yaw)
    let pitch = Float(-pose.pitch)
    let roll = Float(-pose.roll)
    let aboutX = simd_float3x3(columns: (
      simd_float3(1, 0, 0),
      simd_float3(0, cos(pitch), sin(pitch)),
      simd_float3(0, -sin(pitch), cos(pitch))
    ))
    let aboutY = simd_float3x3(columns: (
      simd_float3(cos(yaw), 0, -sin(yaw)),
      simd_float3(0, 1, 0),
      simd_float3(sin(yaw), 0, cos(yaw))
    ))
    let aboutZ = simd_float3x3(columns: (
      simd_float3(cos(roll), sin(roll), 0),
      simd_float3(-sin(roll), cos(roll), 0),
      simd_float3(0, 0, 1)
    ))
    return aboutZ * aboutY * aboutX
  }

  // MARK: - Palette

  private static var stopCache: [String: [simd_float4]] = [:]

  static func oklabStops(for palette: MascotPalette) -> [simd_float4] {
    if let cached = stopCache[palette.id], cached.count == palette.hexes.count {
      return cached
    }
    let stops = zip(palette.colors, palette.stopPlaces)
      .prefix(Int(MASCOT_STOP_COUNT))
      .map { color, position in simd_float4(oklab(color), Float(position)) }
    stopCache[palette.id] = stops
    return stops
  }

  static func oklab(_ color: NSColor) -> simd_float3 {
    let srgb = color.usingColorSpace(.sRGB) ?? color
    func linear(_ c: CGFloat) -> Float {
      let v = Float(c)
      return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    let r = linear(srgb.redComponent)
    let g = linear(srgb.greenComponent)
    let b = linear(srgb.blueComponent)
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return simd_float3(
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    )
  }

  private static func setStop(_ uniforms: inout MascotUniforms, at index: Int, _ value: simd_float4) {
    guard index >= 0, index < Int(MASCOT_STOP_COUNT) else { return }
    withUnsafeMutableBytes(of: &uniforms.stops) { raw in
      raw.bindMemory(to: simd_float4.self)[index] = value
    }
  }

  private static func setEye(
    _ pair: inout (simd_float4, simd_float4), at index: Int, _ value: simd_float4
  ) {
    if index == 0 { pair.0 = value } else if index == 1 { pair.1 = value }
  }

  // MARK: - The frame, on the GPU

  func draw(_ uniforms: MascotUniforms, in view: MTKView) {
    guard let drawable = view.currentDrawable,
          let pass = view.currentRenderPassDescriptor,
          let command = queue.makeCommandBuffer()
    else { return }
    command.label = "Mascot"
    guard encode(uniforms, into: command, pass: pass) else {
      command.commit()
      return
    }
    // Never presentsWithTransaction: it stalls the main thread every frame.
    command.present(drawable)
    #if DEBUG
    if Self.logsTiming {
      let pixels = Int(view.drawableSize.width) * Int(view.drawableSize.height)
      let rays = Int(uniforms.finish.z)
      command.addCompletedHandler { done in
        MascotTimingLog.shared.add(gpu: done.gpuEndTime - done.gpuStartTime, pixels: pixels, rays: rays)
      }
    }
    #endif
    command.commit()
  }

  #if DEBUG
  static let logsTiming = UserDefaults.standard.bool(forKey: "boltty.mascot.timing")
  #endif

  private(set) var lastImageGPUTime: CFTimeInterval = 0

  func image(of uniforms: MascotUniforms, scale: CGFloat = 2) -> CGImage? {
    guard let job = imageJob(uniforms, scale: scale) else { return nil }
    job.command.commit()
    job.command.waitUntilCompleted()
    lastImageGPUTime = job.command.gpuEndTime - job.command.gpuStartTime
    return job.readback.image()
  }

  /// The same picture without holding the main thread while the GPU draws
  /// it: encoded here, read back on Metal's completion thread. A big face
  /// (the first run's, ~600 pixels square) is tens of milliseconds of GPU.
  func render(_ uniforms: MascotUniforms, scale: CGFloat = 2) async -> CGImage? {
    guard let job = imageJob(uniforms, scale: scale) else { return nil }
    let readback = job.readback
    return await withCheckedContinuation { continuation in
      job.command.addCompletedHandler { _ in continuation.resume(returning: readback.image()) }
      job.command.commit()
    }
  }

  private func imageJob(
    _ uniforms: MascotUniforms, scale: CGFloat
  ) -> (command: MTLCommandBuffer, readback: MascotReadback)? {
    let width = Int((CGFloat(uniforms.frame.x) * scale).rounded())
    let height = Int((CGFloat(uniforms.frame.y) * scale).rounded())
    guard width > 0, height > 0 else { return nil }

    var value = uniforms
    value.frame.z = Float(1 / scale)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false
    )
    descriptor.usage = [.renderTarget]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor),
          let command = queue.makeCommandBuffer()
    else { return nil }

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    guard encode(value, into: command, pass: pass) else { return nil }
    return (command, MascotReadback(texture: texture, width: width, height: height))
  }

  private func encode(
    _ uniforms: MascotUniforms,
    into command: MTLCommandBuffer,
    pass: MTLRenderPassDescriptor
  ) -> Bool {
    guard let field = field(for: Int32(uniforms.shape.y.rounded())),
          let encoder = command.makeRenderCommandEncoder(descriptor: pass)
    else { return false }
    var value = uniforms
    let length = MemoryLayout<MascotUniforms>.stride
    let index = Int(MascotBufferIndexUniforms.rawValue)
    encoder.label = "Mascot"
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(&value, length: length, index: index)
    encoder.setFragmentBytes(&value, length: length, index: index)
    encoder.setFragmentBuffer(field, offset: 0, index: Int(MascotBufferIndexField.rawValue))
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    return true
  }

  func field(for shapeID: Int32) -> MTLBuffer? {
    if let cached = fields[shapeID] { return cached }
    let size = Int(MASCOT_FIELD_SIZE)
    let count = 1 + size * size
    guard let buffer = device.makeBuffer(
            length: count * MemoryLayout<Float>.stride, options: .storageModeShared),
          let command = queue.makeCommandBuffer(),
          let encoder = command.makeComputeCommandEncoder()
    else { return nil }
    buffer.label = "Mascot field \(shapeID)"
    var shape = shapeID
    encoder.setComputePipelineState(fieldPipeline)
    encoder.setBuffer(buffer, offset: 0, index: Int(MascotBufferIndexField.rawValue))
    encoder.setBytes(&shape, length: MemoryLayout<Int32>.stride, index: Int(MascotBufferIndexUniforms.rawValue))
    let group = MTLSize(width: 16, height: 16, depth: 1)
    encoder.dispatchThreadgroups(
      MTLSize(width: (size + 15) / 16, height: (size + 15) / 16, depth: 1),
      threadsPerThreadgroup: group
    )
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { return nil }

    let values = buffer.contents().bindMemory(to: Float.self, capacity: count)
    var lowest: Float = 0
    vDSP_minv(values + 1, 1, &lowest, vDSP_Length(count - 1))
    values[0] = max(0, -lowest)
    fields[shapeID] = buffer
    return buffer
  }
}

@MainActor
final class MascotCanvas: MTKView, MTKViewDelegate {
  private var uniforms = MascotUniforms()
  private var hasUniforms = false
  /// Pixels per point, when not the screen's — a big face that has to keep
  /// its frame rate asks for fewer.
  var scaleOverride: CGFloat?

  init() {
    super.init(frame: .zero, device: MascotRenderer.shared?.device)
    isPaused = true
    enableSetNeedsDisplay = false
    delegate = self
    colorPixelFormat = MascotRenderer.pixelFormat
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

  var avoidsOffscreenPassForTesting: Bool {
    guard let layer else { return true }
    return !layer.shouldRasterize
      && layer.filters == nil
      && layer.backgroundFilters == nil
      && layer.mask == nil
      && !layer.masksToBounds
  }

  func show(_ uniforms: MascotUniforms) {
    self.uniforms = uniforms
    hasUniforms = true
    redraw()
  }

  private func redraw() {
    if let window, let layer {
      let scale = scaleOverride ?? max(1, window.backingScaleFactor)
      if layer.contentsScale != scale { layer.contentsScale = scale }
      if scaleOverride != nil {
        autoResizeDrawable = false
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if drawableSize != size { drawableSize = size }
      }
    }
    guard hasUniforms, window != nil, drawableSize.width >= 1, drawableSize.height >= 1 else {
      return
    }
    draw()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    redraw()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    redraw()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    drawnTopStopForTesting = uniforms.stops.0
    MascotRenderer.shared?.draw(uniforms, in: self)
  }

  private(set) var drawnTopStopForTesting = simd_float4()
}

/// A rendered texture read back into a picture, on whatever thread the GPU
/// finished on. The texture is not touched again once handed over.
final class MascotReadback: @unchecked Sendable {
  private let texture: MTLTexture
  private let width: Int
  private let height: Int

  init(texture: MTLTexture, width: Int, height: Int) {
    self.texture = texture
    self.width = width
    self.height = height
  }

  func image() -> CGImage? {
    let rowBytes = width * 4
    let count = rowBytes * height
    let raw = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
    defer { raw.deallocate() }
    texture.getBytes(
      raw, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
    )
    guard let provider = CGDataProvider(data: Data(bytes: raw, count: count) as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: rowBytes,
      space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        .union(.byteOrder32Little),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent
    )
  }
}

#if DEBUG
/// `-boltty.mascot.timing YES`: GPU time per face frame, printed each second.
final class MascotTimingLog: @unchecked Sendable {
  static let shared = MascotTimingLog()
  private let lock = NSLock()
  private var frames: [String: (count: Int, gpu: Double, max: Double)] = [:]
  private var last = CFAbsoluteTimeGetCurrent()

  func add(gpu: Double, pixels: Int, rays: Int) {
    lock.lock()
    defer { lock.unlock() }
    let key = "\(Int(Double(pixels).squareRoot()))px² r\(rays)"
    var entry = frames[key] ?? (0, 0, 0)
    entry.count += 1
    entry.gpu += gpu
    entry.max = max(entry.max, gpu)
    frames[key] = entry
    let now = CFAbsoluteTimeGetCurrent()
    guard now - last >= 1 else { return }
    let total = frames.values.reduce(0) { $0 + $1.gpu }
    let line = frames.sorted { $0.key < $1.key }.map {
      "\($0.key): \($0.value.count)f avg \(String(format: "%.1f", $0.value.gpu / Double($0.value.count) * 1000))ms max \(String(format: "%.1f", $0.value.max * 1000))ms"
    }.joined(separator: " | ")
    FileHandle.standardError.write(Data("[mascot] gpu busy \(String(format: "%.0f", total / (now - last) * 100))% — \(line)\n".utf8))
    frames = [:]
    last = now
  }
}
#endif
