import AppKit
import XCTest
@testable import Boltty

@MainActor
final class MascotDetailContactSheet: XCTestCase {
  func testRenderAndTimeTheDetailLevels() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let renderer = try XCTUnwrap(MascotRenderer.shared)
    let sizes: [CGFloat] = [60, 38, 26, 22]
    let finishes: [MascotFinish] = [.velvet, .fur]
    let shapes = MascotShape.allCases
    let cell: CGFloat = 70
    let label: CGFloat = 150
    let rows = finishes.count * 2
    let width = label + CGFloat(shapes.count * sizes.count) * cell + 12
    let height = CGFloat(rows) * cell + 12
    var report: [String] = []
    let context = try XCTUnwrap(CGContext(
      data: nil, width: Int(width * 2), height: Int(height * 2), bitsPerComponent: 8, bytesPerRow: 0,
      space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: 2, y: 2)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.current = previous }
    NSColor(white: 0.08, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    var row = 0
    for finish in finishes {
      for rays in [4, 2] {
        let y = height - CGFloat(row + 1) * cell
        row += 1
        NSAttributedString(string: "\(finish.displayName), \(rays) rays", attributes: [
          .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: 10, y: y + cell / 2 - 8))
        for (sizeIndex, size) in sizes.enumerated() {
          var total: CFTimeInterval = 0
          var frames = 0
          for (shapeIndex, shape) in shapes.enumerated() {
            let view = MascotNSView(
              conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
              palette: MascotPalette.catalog[shapeIndex % MascotPalette.catalog.count], shape: shape)
            view.frame = CGRect(x: 0, y: 0, width: size, height: size)
            view.reduceMotion = true
            view.layoutSubtreeIfNeeded()
            var frame = try XCTUnwrap(view.lastFrame)
            frame.overscan = 0
            frame.finish = finish
            let uniforms = MascotRenderer.uniforms(for: frame, rays: rays)
            _ = renderer.image(of: uniforms, scale: 2)
            var image: CGImage?
            for _ in 0..<10 {
              image = renderer.image(of: uniforms, scale: 2)
              total += renderer.lastImageGPUTime
              frames += 1
            }
            let x = label + CGFloat(shapeIndex * sizes.count + sizeIndex) * cell
            if let image {
              NSImage(cgImage: image, size: NSSize(width: size, height: size)).draw(
                in: NSRect(x: x + (cell - size) / 2, y: y + (cell - size) / 2, width: size, height: size),
                from: .zero, operation: .sourceOver, fraction: 1)
            }
          }
          report.append(String(format: "%@ %d rays %2.0fpt: %.3f ms GPU a frame",
                               finish.displayName, rays, size, total / Double(frames) * 1000))
        }
      }
    }
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
      .representation(using: .png, properties: [:]))
    let url = URL(fileURLWithPath: dir).appendingPathComponent("mascot-detail.png")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try png.write(to: url)
    let text = report.joined(separator: "\n")
    try text.write(to: URL(fileURLWithPath: dir).appendingPathComponent("mascot-detail.txt"),
                   atomically: true, encoding: .utf8)
    print("BOLTTY_SHEET \(url.path)\n\(text)")
  }
}

/// The five agents in a pile on black, like a poster of plush faces, each
/// going through its emotions. 2000 × 2000.
/// `BOLTTY_POSTER=<dir>`; `BOLTTY_POSTER_STILLS=0,6.5` writes stills at
/// those seconds, `BOLTTY_POSTER_VIDEO=1` pipes every frame to ffmpeg.
/// `BOLTTY_POSTER_FUR=<agent>` dresses one in fur (Grok by default),
/// `BOLTTY_POSTER_SS` supersamples each face (2 by default).
@MainActor
final class MascotPosterRender: XCTestCase {
  private struct Cue {
    var at: Double
    var emotion: MascotEmotion?
    var poke: MascotReaction?
    var watch: AgentId?
    var watchFor = 1.6
  }

  private struct Player {
    let agent: AgentId
    let look: MascotLook
    let center: CGPoint
    let side: CGFloat
    let tilt: Double
    let cues: [Cue]
    let phase: Double
    var motion: MascotMotion
    var played = 0
    var watching: (agent: AgentId, until: Double)?
  }

  private static let width: CGFloat = 1080
  private static let height: CGFloat = 1920
  private static let fps = 60.0
  private static let duration = 6.0
  /// The last stretch crossfades into the first, so the film loops.
  private static let loopFade = 0.8
  private static let warmUp = 2.0

  private func look(_ shape: MascotShape, _ palette: String, fur: Bool) throws -> MascotLook {
    MascotLook(shape: shape, palette: try XCTUnwrap(MascotPalette.palette(withID: palette)),
               finish: fur ? .fur : .velvet)
  }

  /// Back to front, one roster of looks.
  private func cast(fur: AgentId) throws -> [Player] {
    func player(
      _ agent: AgentId, _ shape: MascotShape, _ palette: String, _ x: CGFloat, _ y: CGFloat,
      side: CGFloat, tilt: Double, seed: UInt32, _ cues: [Cue]
    ) throws -> Player {
      var stream = MascotRandom(seed: MascotSpec.seed &+ seed &* 971)
      let phase = stream.next() * 90
      let first = cues.first(where: { $0.at <= 0 })?.emotion ?? .curious
      return Player(
        agent: agent, look: try look(shape, palette, fur: agent == fur),
        center: CGPoint(x: x, y: y), side: side, tilt: tilt * .pi / 180,
        cues: cues, phase: phase, motion: MascotMotion(random: stream, emotion: first)
      )
    }
    let calm = [Cue(at: 0.01, emotion: .listening), Cue(at: 0.01, emotion: .curious)]
    return [
      try player(.claude, .bloom, "ember", 379, 762, side: 560, tilt: -5, seed: 23, calm + [
        Cue(at: 0.9, emotion: .thinking),
        Cue(at: 2.2, emotion: .curious),
        Cue(at: 2.4, watch: .opencode, watchFor: 1.1),
        Cue(at: 3.7, watch: .antigravity, watchFor: 1.1),
      ]),
      try player(.opencode, .hex, "daybreak", 770, 935, side: 624, tilt: 8, seed: 37, calm + [
        Cue(at: 1.0, watch: .claude, watchFor: 1.2),
        Cue(at: 2.4, poke: .spinHop),
        Cue(at: 3.7, watch: .antigravity, watchFor: 1.1),
      ]),
      try player(.antigravity, .triangle, "candy", 465, 1176, side: 585, tilt: 0, seed: 53, calm + [
        Cue(at: 1.0, watch: .claude, watchFor: 1.2),
        Cue(at: 2.4, watch: .opencode, watchFor: 1.1),
        Cue(at: 3.7, poke: .flip),
      ]),
    ]
  }

  private func play(_ players: inout [Player], until time: Double) {
    for index in players.indices {
      while players[index].played < players[index].cues.count,
            players[index].cues[players[index].played].at <= time {
        let cue = players[index].cues[players[index].played]
        players[index].played += 1
        if let emotion = cue.emotion { players[index].motion.setEmotion(emotion) }
        if let poke = cue.poke { players[index].motion.poke(poke) }
        if let watch = cue.watch { players[index].watching = (watch, time + cue.watchFor) }
      }
    }
    // Watch whoever is named: a direction in the picture, y down, as the
    // view's pointer would read it.
    for index in players.indices {
      guard let watching = players[index].watching, watching.until > time,
            let target = players.first(where: { $0.agent == watching.agent })
      else {
        players[index].watching = nil
        players[index].motion.setPointer(x: 0, y: 0, strength: 0)
        continue
      }
      let dx = target.center.x - players[index].center.x
      let dy = target.center.y - players[index].center.y
      let length = max(1, (dx * dx + dy * dy).squareRoot())
      players[index].motion.setPointer(x: dx / length, y: dy / length, strength: 1)
    }
  }

  private func frame(of player: Player, clock: Double, pose: MascotMotionPose) -> MascotRenderer.Frame {
    let bridgeY = MascotSpec.designBox / 2 - MascotSpec.eyeBridge.y
    let eyes = (0..<2).map { index -> MascotRenderer.Eye in
      let side = index == 0 ? -1.0 : 1.0
      return MascotRenderer.Eye(
        centre: CGPoint(x: side * MascotSpec.eyeSpacing / 2 + pose.gazeX, y: bridgeY + pose.gazeY),
        turn: 0, shape: pose.eyes[index])
    }
    return MascotRenderer.Frame(
      size: CGSize(width: player.side, height: player.side),
      pixelSize: 1,
      pose: MascotRenderer.Pose(
        yaw: pose.yaw, pitch: pose.pitch, roll: pose.roll + player.tilt,
        sx: pose.sx, sy: pose.sy, lift: -pose.rise),
      eyes: eyes, clock: clock, phase: player.phase,
      palette: player.look.palette, shape: player.look.shape,
      overscan: MascotNSView.overscan, finish: player.look.finish)
  }

  private func scaled(_ image: CIImage, _ k: CGFloat, alpha: CGFloat? = nil) -> CIImage {
    image.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
      "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
      "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha ?? k),
    ])
  }

  private func picture(
    of players: [Player], time: Double, supersample: CGFloat, context: CIContext,
    poses: [MascotMotionPose]? = nil, loop: Double? = nil
  ) throws -> CGImage {
    let renderer = try XCTUnwrap(MascotRenderer.shared)
    let extent = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
    let clear = CIImage(color: .clear).cropped(to: extent)
    var faces = clear
    for (index, player) in players.enumerated() {
      // A looping film sways its colours on the loop's own period.
      let clock = loop.map { player.phase + 4 * sin(time * 2 * .pi / $0) }
        ?? player.phase + (Self.warmUp + time) * MascotSpec.speed * MascotSpec.gradientRate
      let pose = poses?[index] ?? player.motion.pose
      let uniforms = MascotRenderer.uniforms(for: frame(of: player, clock: clock, pose: pose), rays: 4)
      let cg = try XCTUnwrap(renderer.image(of: uniforms, scale: supersample))
      var face = CIImage(cgImage: cg)
      if supersample != 1 {
        face = face.applyingFilter("CILanczosScaleTransform", parameters: [
          kCIInputScaleKey: 1 / supersample, kCIInputAspectRatioKey: 1,
        ])
      }
      let width = face.extent.width
      let origin = CGPoint(x: player.center.x - width / 2, y: Self.height - player.center.y - width / 2)
      face = face.transformed(by: CGAffineTransform(translationX: origin.x - face.extent.minX,
                                                    y: origin.y - face.extent.minY))
      // A soft shadow on whoever stands behind — invisible on the black.
      let shadow = face
        .applyingFilter("CIColorMatrix", parameters: [
          "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.3),
        ])
        .clampedToExtent().applyingGaussianBlur(sigma: Double(player.side) * 0.05)
        .transformed(by: CGAffineTransform(translationX: 0, y: -player.side * 0.04))
        .cropped(to: extent)
      faces = face.composited(over: shadow.composited(over: faces))
    }
    faces = faces.cropped(to: extent)

    func blurred(_ sigma: Double) -> CIImage {
      faces.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
    }
    let glow = scaled(blurred(10), 0.12)
      .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: scaled(blurred(34), 0.1)])
    let outerGlow = glow.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: faces])
    let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    // Brighter and more contrasty than the first run's own sky.
    let black = CIImage(cgImage: try sunset(in: sRGB))
      .applyingFilter("CIColorControls", parameters: [
        kCIInputSaturationKey: 1.45, kCIInputContrastKey: 1.18, kCIInputBrightnessKey: 0.04,
      ])
      .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.35])
    let ground = outerGlow.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: black])
    let final = faces.composited(over: ground).cropped(to: extent)
    return try XCTUnwrap(context.createCGImage(
      final, from: extent, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
  }

  /// The first run's sky (`SunsetView`): its stops top to bottom, and its
  /// three soft lights screened over it, held still so the film loops.
  private func sunset(in space: CGColorSpace) throws -> CGImage {
    let width = Int(Self.width), height = Int(Self.height)
    let context = try XCTUnwrap(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let colours = SunsetView.colours.map { HexColor.nsColor($0).cgColor } as CFArray
    let locations = SunsetView.locations.map { CGFloat(truncating: $0) }
    let gradient = try XCTUnwrap(CGGradient(
      colorsSpace: space, colors: colours, locations: locations))
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: Self.height), end: CGPoint(x: 0, y: 0), options: [])
    context.setBlendMode(.screen)
    let lights: [(String, CGFloat, CGPoint)] = [
      ("#ffb36b", 0.38, CGPoint(x: 0.28, y: 0.3)),
      ("#ff86b0", 0.26, CGPoint(x: 0.74, y: 0.42)),
      ("#9cc8ff", 0.30, CGPoint(x: 0.55, y: 0.78)),
    ]
    for (hex, alpha, centre) in lights {
      let colour = HexColor.nsColor(hex).cgColor
      let glow = try XCTUnwrap(CGGradient(
        colorsSpace: space,
        colors: [colour.copy(alpha: alpha)!, colour.copy(alpha: 0)!] as CFArray,
        locations: [0, 1]))
      let point = CGPoint(x: centre.x * Self.width, y: (1 - centre.y) * Self.height)
      context.drawRadialGradient(glow, startCenter: point, startRadius: 0, endCenter: point,
                                 endRadius: Self.width * 0.75, options: [])
    }
    return try XCTUnwrap(context.makeImage())
  }

  func testRenderThePoster() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let dir = environment["BOLTTY_POSTER"] else {
      throw XCTSkip("set BOLTTY_POSTER to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fur = environment["BOLTTY_POSTER_FUR"].flatMap(AgentId.init(rawValue:)) ?? .claude
    let supersample = CGFloat(Double(environment["BOLTTY_POSTER_SS"] ?? "") ?? 2)
    let stills = (environment["BOLTTY_POSTER_STILLS"] ?? "")
      .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    let video = environment["BOLTTY_POSTER_VIDEO"] == "1"
    let duration = Double(environment["BOLTTY_POSTER_SECONDS"] ?? "") ?? Self.duration

    let context = CIContext(options: [
      .workingColorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB)),
      .workingFormat: CIFormat.RGBAh,
      .cacheIntermediates: false,
    ])
    var players = try cast(fur: fur)
    let step = 1 / Self.fps
    play(&players, until: 0)
    for _ in 0..<Int(Self.warmUp * Self.fps) {
      for index in players.indices { players[index].motion.update(step) }
    }

    var ffmpeg: Process?
    var input: FileHandle?
    if video {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
      let size = "\(Int(Self.width))x\(Int(Self.height))"
      process.arguments = [
        "-y", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", size, "-framerate", "\(Int(Self.fps))",
        "-i", "-",
        "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=spline+accurate_rnd+full_chroma_int,format=yuv420p",
        "-c:v", "libx264", "-preset", "slow", "-crf", "12", "-profile:v", "high", "-tune", "film",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
        "-movflags", "+faststart",
        directory.appendingPathComponent("boltty-agents.mp4").path,
      ]
      let pipe = Pipe()
      process.standardInput = pipe
      let log = directory.appendingPathComponent("ffmpeg.log")
      FileManager.default.createFile(atPath: log.path, contents: nil)
      let logHandle = try FileHandle(forWritingTo: log)
      process.standardOutput = logHandle
      process.standardError = logHandle
      try process.run()
      ffmpeg = process
      input = pipe.fileHandleForWriting
    }

    let fadeFrames = video ? Int((Self.loopFade * Self.fps).rounded()) : 0
    let loopFrames = Int((duration * Self.fps).rounded())
    let frames = loopFrames + fadeFrames
    var head: [[MascotMotionPose]] = []
    let lastStill = stills.max() ?? -1
    let started = CFAbsoluteTimeGetCurrent()
    var pendingStills = stills.sorted()
    for index in 0..<frames {
      let time = Double(index) / Self.fps
      if !video, time > lastStill + step { break }
      play(&players, until: time)
      for player in players.indices { players[player].motion.update(step) }
      let wantsStill = pendingStills.first.map { time + step / 2 >= $0 } ?? false
      guard video || wantsStill else { continue }
      // The tail walks each face's pose into the head's, so the last frame
      // is the first again.
      if video, index < fadeFrames {
        head.append(players.map(\.motion.pose))
        continue
      }
      var poses: [MascotMotionPose]?
      if video, index >= loopFrames {
        let x = Double(index - loopFrames + 1) / Double(fadeFrames)
        let weight = x * x * (3 - 2 * x)
        poses = zip(players, head[index - loopFrames]).map {
          MascotMotionPose.blend($0.motion.pose, $1, weight)
        }
      }
      let image = try picture(
        of: players, time: time, supersample: supersample, context: context,
        poses: poses, loop: video ? duration : nil)
      if wantsStill {
        let still = pendingStills.removeFirst()
        let url = directory.appendingPathComponent(String(format: "boltty-agents-%05.2fs.png", still))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url)
        print("BOLTTY_POSTER_STILL \(url.path)")
      }
      if let input {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let rowBytes = Int(Self.width) * 4
        if image.bytesPerRow == rowBytes {
          try input.write(contentsOf: data)
        } else {
          for row in 0..<image.height {
            try input.write(contentsOf: data[row * image.bytesPerRow ..< row * image.bytesPerRow + rowBytes])
          }
        }
      }
      if index % 60 == 0 {
        print(String(format: "BOLTTY_POSTER frame %d/%d, %.1f s", index, frames, CFAbsoluteTimeGetCurrent() - started))
      }
    }
    if let input, let ffmpeg {
      try input.close()
      ffmpeg.waitUntilExit()
      XCTAssertEqual(ffmpeg.terminationStatus, 0)
      print("BOLTTY_POSTER_VIDEO \(directory.appendingPathComponent("boltty-agents.mp4").path)")
    }
  }
}
