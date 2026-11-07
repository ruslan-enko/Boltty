import AppKit
import CoreGraphics
import Metal
import MetalKit
import simd

@MainActor
final class VoiceGlowRenderer {
  struct Frame {
    var size: CGSize
    var pixelSize: CGFloat
    var cornerRadius: CGFloat
    var cornerIsContinuous: Bool
    var intensity: CGFloat
    var beam: CGFloat
    var clock: CGFloat
    var flow: CGFloat = 0
    var orb: CGFloat = 0
    var opacity: CGFloat
    var isLightAppearance: Bool
    var reduceMotion: Bool
    var colors: [NSColor]
  }

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let uniformBuffers: [MTLBuffer]
  private let inFlight = DispatchSemaphore(value: 3)
  private var bufferIndex = 0

  init?(pixelFormat: MTLPixelFormat) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let library = device.makeDefaultLibrary(),
          let vertexFunction = library.makeFunction(name: "voiceGlowVertex"),
          let fragmentFunction = library.makeFunction(name: "voiceGlowFragment")
    else { return nil }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.label = "VoiceGlow"
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    let attachment = descriptor.colorAttachments[0]
    attachment?.pixelFormat = pixelFormat
    // Premultiplied source-over: the shader writes colour already multiplied by
    // its coverage, so `.one` is the source factor, never `.sourceAlpha`.
    attachment?.isBlendingEnabled = true
    attachment?.rgbBlendOperation = .add
    attachment?.alphaBlendOperation = .add
    attachment?.sourceRGBBlendFactor = .one
    attachment?.sourceAlphaBlendFactor = .one
    attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha

    guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
      return nil
    }

    let length = MemoryLayout<VoiceGlowUniforms>.stride
    var buffers: [MTLBuffer] = []
    for index in 0..<3 {
      guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
        return nil
      }
      buffer.label = "VoiceGlow.uniforms.\(index)"
      buffers.append(buffer)
    }

    self.device = device
    self.queue = queue
    self.pipeline = pipeline
    self.uniformBuffers = buffers
  }

  var metalDevice: MTLDevice { device }

  // MARK: - The frame, as numbers

  static func uniforms(for frame: Frame) -> VoiceGlowUniforms {
    var u = VoiceGlowUniforms()
    let intensity = min(1, max(0, frame.intensity))
    let beam = min(1, max(0, frame.beam))

    u.size = simd_float2(Float(frame.size.width), Float(frame.size.height))
    u.pixelSize = Float(max(0.25, frame.pixelSize))
    u.cornerRadius = Float(max(0, frame.cornerRadius))
    u.cornerIsContinuous = frame.cornerIsContinuous ? 1 : 0
    u.intensity = Float(intensity)
    u.beam = Float(beam)
    u.opacity = Float(min(1, max(0, frame.opacity)))
    u.appearance = frame.isLightAppearance ? 1 : 0
    u.clock = frame.reduceMotion ? 0 : Float(frame.clock)
    u.flow = frame.reduceMotion ? 0 : Float(frame.flow)

    let origin = VoiceEdgeGlowLayout.rayOrigin(
      size: frame.size,
      intensity: intensity,
      beam: beam,
      clock: frame.clock,
      reduceMotion: frame.reduceMotion
    )
    u.origin = simd_float2(Float(origin.x), Float(origin.y))
    u.reach = Float(VoiceEdgeGlowLayout.reach(size: frame.size, intensity: intensity))
    u.orb = Float(min(1, max(0, frame.orb)))

    let stops = frame.colors.isEmpty ? [NSColor.white] : frame.colors
    for index in 0..<colorCount {
      let source = stops.count == 1
        ? 0
        : Int((CGFloat(index) / CGFloat(colorCount - 1) * CGFloat(stops.count - 1)).rounded())
      let raw = stops[min(source, stops.count - 1)]
      let color = raw.usingColorSpace(.sRGB) ?? raw
      setColor(
        &u,
        at: index,
        simd_float4(
          Float(color.redComponent),
          Float(color.greenComponent),
          Float(color.blueComponent),
          1
        )
      )
    }

    return u
  }

  static func setColor(_ uniforms: inout VoiceGlowUniforms, at index: Int, _ color: simd_float4) {
    guard index >= 0, index < colorCount else { return }
    withUnsafeMutableBytes(of: &uniforms.colors) { raw in
      raw.bindMemory(to: simd_float4.self)[index] = color
    }
  }

  static func color(_ uniforms: VoiceGlowUniforms, at index: Int) -> simd_float4 {
    guard index >= 0, index < colorCount else { return simd_float4() }
    return withUnsafeBytes(of: uniforms.colors) { raw in
      raw.bindMemory(to: simd_float4.self)[index]
    }
  }

  static let colorCount = Int(VOICE_GLOW_COLOR_COUNT)

  // MARK: - The frame, on the GPU

  func render(_ uniforms: VoiceGlowUniforms, in view: MTKView) {
    guard uniforms.opacity > 0,
          uniforms.size.x > 1,
          uniforms.size.y > 1,
          let drawable = view.currentDrawable,
          let descriptor = view.currentRenderPassDescriptor,
          let command = queue.makeCommandBuffer()
    else { return }

    inFlight.wait()
    bufferIndex = (bufferIndex + 1) % uniformBuffers.count
    let buffer = uniformBuffers[bufferIndex]
    var value = uniforms
    memcpy(buffer.contents(), &value, MemoryLayout<VoiceGlowUniforms>.stride)

    command.label = "VoiceGlow"
    let semaphore = inFlight
    command.addCompletedHandler { _ in semaphore.signal() }

    guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
      command.commit()
      return
    }
    encoder.label = "VoiceGlow"
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(buffer, offset: 0, index: Int(VoiceGlowBufferIndexUniforms.rawValue))
    encoder.setFragmentBuffer(buffer, offset: 0, index: Int(VoiceGlowBufferIndexUniforms.rawValue))
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()

    // Not through `presentsWithTransaction`: it starved the run loop.
    command.present(drawable)
    command.commit()
  }

  func image(of uniforms: VoiceGlowUniforms, scale: CGFloat = 2) -> CGImage? {
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

    var value = uniforms
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(
      &value,
      length: MemoryLayout<VoiceGlowUniforms>.stride,
      index: Int(VoiceGlowBufferIndexUniforms.rawValue)
    )
    encoder.setFragmentBytes(
      &value,
      length: MemoryLayout<VoiceGlowUniforms>.stride,
      index: Int(VoiceGlowBufferIndexUniforms.rawValue)
    )
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()

    guard let blit = command.makeBlitCommandEncoder() else { return nil }
    blit.synchronize(resource: texture)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()

    // A plain allocation: `withUnsafeMutableBytes` would capture the non-Sendable
    // `texture` in a closure leaving this actor, which Swift 6 rejects.
    let rowBytes = width * 4
    let count = rowBytes * height
    let raw = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
    defer { raw.deallocate() }
    texture.getBytes(
      raw,
      bytesPerRow: rowBytes,
      from: MTLRegionMake2D(0, 0, width, height),
      mipmapLevel: 0
    )

    let data = Data(bytes: raw, count: count)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: rowBytes,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        .union(.byteOrder32Little),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

}
