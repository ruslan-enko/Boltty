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

@MainActor
final class MascotStillsRender: XCTestCase {
  func testRenderEveryChosenFace() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let dir = environment["BOLTTY_MASCOT_STILLS"] else {
      throw XCTSkip("set BOLTTY_MASCOT_STILLS to render")
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let renderer = try XCTUnwrap(MascotRenderer.shared)
    let finish = MascotFinish(rawValue: environment["BOLTTY_MASCOT_STILLS_FINISH"] ?? "fur") ?? .fur
    let side = CGFloat(Double(environment["BOLTTY_MASCOT_STILLS_SIDE"] ?? "") ?? 1600)
    let stored = UserDefaults.standard.persistentDomain(forName: "com.boltty.app")?[MascotRoster.storageKey] as? Data
    let selections = try stored.map { try JSONDecoder().decode([String: MascotSelection].self, from: $0) } ?? [:]
    let looks = MascotRoster(selections: selections).looks()

    for agent in AgentId.adapterCases {
      let look = try XCTUnwrap(looks[agent])
      let view = MascotNSView(
        conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
        palette: look.palette, shape: look.shape)
      view.frame = CGRect(x: 0, y: 0, width: side, height: side)
      view.reduceMotion = true
      view.layoutSubtreeIfNeeded()
      var frame = try XCTUnwrap(view.lastFrame)
      frame.size = CGSize(width: side, height: side)
      frame.overscan = MascotNSView.overscan
      frame.finish = finish
      let large = try XCTUnwrap(renderer.image(of: MascotRenderer.uniforms(for: frame, rays: 4), scale: 2))
      let width = large.width / 2, height = large.height / 2
      let context = try XCTUnwrap(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.interpolationQuality = .high
      context.draw(large, in: CGRect(x: 0, y: 0, width: width, height: height))
      let picture = try XCTUnwrap(context.makeImage())
      let png = try XCTUnwrap(NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]))
      let name = "\(agent.rawValue)-\(look.shape.rawValue)-\(look.palette.id)-\(finish.rawValue).png"
      try png.write(to: directory.appendingPathComponent(name))
      print("BOLTTY_MASCOT_STILL \(name) \(width)x\(height) GPU \(renderer.lastImageGPUTime)s")
    }
  }
}

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
  private static let loopFade = 0.8
  private static let warmUp = 2.0

  private func look(_ shape: MascotShape, _ palette: String, fur: Bool) throws -> MascotLook {
    MascotLook(shape: shape, palette: try XCTUnwrap(MascotPalette.palette(withID: palette)),
               finish: fur ? .fur : .velvet)
  }

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

  private func sunset(in space: CGColorSpace) throws -> CGImage {
    let width = Int(Self.width), height = Int(Self.height)
    let context = try XCTUnwrap(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let colours = OklabGradient.cgColors(SunsetView.colours.map(\.color)) as CFArray
    let locations = SunsetView.skyLocations(SunsetView.locations).map { CGFloat(truncating: $0) }
    let gradient = try XCTUnwrap(CGGradient(
      colorsSpace: space, colors: colours, locations: locations))
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: Self.height), end: CGPoint(x: 0, y: 0), options: [])
    context.setBlendMode(.screen)
    let lights: [(OKLCH, CGFloat, CGPoint)] = [
      (OKLCH(0.825, 0.125, 63.1), 0.38, CGPoint(x: 0.28, y: 0.3)),
      (OKLCH(0.765, 0.153, 359.3), 0.26, CGPoint(x: 0.74, y: 0.42)),
      (OKLCH(0.821, 0.091, 254.3), 0.30, CGPoint(x: 0.55, y: 0.78)),
    ]
    for (stop, alpha, centre) in lights {
      let colour = stop.cgColor
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

@MainActor
final class MascotLineupRender: XCTestCase {
  private struct Cue {
    var at: Double
    var emotion: MascotEmotion?
    var poke: MascotReaction?
    var watch: Int?
    var watchFor = 1.0
  }

  private struct Player {
    let look: MascotLook
    let center: CGPoint
    let arrives: Double
    let cues: [Cue]
    let phase: Double
    var motion: MascotMotion
    var played = 0
    var watching: (index: Int, until: Double)?
  }

  private static let width: CGFloat = 1920
  private static let height: CGFloat = 1080
  private static let fps = 60.0
  private static let tile: CGFloat = 340
  private static let gap: CGFloat = 14
  private static let face: CGFloat = 264

  private static func centre(_ index: Int) -> CGPoint {
    let row = 5 * tile + 4 * gap
    return CGPoint(x: (width - row) / 2 + tile / 2 + CGFloat(index) * (tile + gap), y: height / 2)
  }

  private static let scripts: [[Cue]] = [
    [Cue(at: 1.6, emotion: .listening), Cue(at: 2.5, poke: .wink), Cue(at: 3.4, emotion: .thinking),
     Cue(at: 4.7, emotion: .curious, watch: 1), Cue(at: 5.8, emotion: .sad), Cue(at: 6.9, emotion: .curious, poke: .doubleHop)],
    [Cue(at: 1.7, poke: .spinHop), Cue(at: 2.8, emotion: .focused), Cue(at: 3.9, emotion: .concerned),
     Cue(at: 4.8, emotion: .curious, watch: 0), Cue(at: 5.9, emotion: .sleeping), Cue(at: 7.0, emotion: .curious)],
    [Cue(at: 1.8, emotion: .thinking), Cue(at: 3.0, emotion: .curious, poke: .flip), Cue(at: 4.0, emotion: .sad),
     Cue(at: 5.2, emotion: .listening), Cue(at: 6.3, emotion: .curious, poke: .boing)],
    [Cue(at: 1.9, emotion: .concerned), Cue(at: 2.9, emotion: .sleeping), Cue(at: 4.1, emotion: .curious, poke: .cartwheel),
     Cue(at: 5.3, emotion: .focused), Cue(at: 6.4, emotion: .curious, poke: .wink)],
    [Cue(at: 2.0, emotion: .sad), Cue(at: 3.1, emotion: .curious, poke: .doubleHop), Cue(at: 4.3, watch: 2, watchFor: 1.2),
     Cue(at: 5.5, emotion: .thinking), Cue(at: 6.6, emotion: .curious, poke: .spinHop)],
  ]

  private func cast() throws -> [Player] {
    let stored = UserDefaults.standard.persistentDomain(forName: "com.boltty.app")?[MascotRoster.storageKey] as? Data
    let selections = try stored.map { try JSONDecoder().decode([String: MascotSelection].self, from: $0) } ?? [:]
    let roster = MascotRoster(selections: selections).looks()
    let hex = MascotLook(shape: .hex, palette: try XCTUnwrap(MascotPalette.palette(withID: "daybreak")))
    var looks = try [AgentId.opencode, .claude, .codex, .grok].map { try XCTUnwrap(roster[$0]) }
    looks.insert(hex, at: 2)
    return looks.enumerated().map { index, look in
      var stream = MascotRandom(seed: MascotSpec.seed &+ UInt32(index + 3) &* 971)
      let phase = stream.next() * 90
      let arrives = 0.25 + Double(index) * 0.13
      let wake = Cue(at: arrives + 0.35, emotion: .curious)
      return Player(
        look: look, center: Self.centre(index), arrives: arrives,
        cues: [wake] + Self.scripts[index], phase: phase,
        motion: MascotMotion(random: stream, emotion: .sleeping))
    }
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
      if let watching = players[index].watching, watching.until > time {
        let dx = players[watching.index].center.x - players[index].center.x
        players[index].motion.setPointer(x: dx < 0 ? -1 : 1, y: 0.1, strength: 1)
      } else {
        players[index].watching = nil
        players[index].motion.setPointer(x: 0, y: 0, strength: 0)
      }
    }
  }

  private func frame(of player: Player, clock: Double) -> MascotRenderer.Frame {
    let pose = player.motion.pose
    let bridgeY = MascotSpec.designBox / 2 - MascotSpec.eyeBridge.y
    let eyes = (0..<2).map { index -> MascotRenderer.Eye in
      let side = index == 0 ? -1.0 : 1.0
      return MascotRenderer.Eye(
        centre: CGPoint(x: side * MascotSpec.eyeSpacing / 2 + pose.gazeX, y: bridgeY + pose.gazeY),
        turn: 0, shape: pose.eyes[index])
    }
    return MascotRenderer.Frame(
      size: CGSize(width: Self.face, height: Self.face), pixelSize: 1,
      pose: MascotRenderer.Pose(yaw: pose.yaw, pitch: pose.pitch, roll: pose.roll,
                                sx: pose.sx, sy: pose.sy, lift: -pose.rise),
      eyes: eyes, clock: clock, phase: player.phase,
      palette: player.look.palette, shape: player.look.shape,
      overscan: MascotNSView.overscan, finish: player.look.finish)
  }

  private func ground(in space: CGColorSpace) throws -> CGImage {
    let context = try XCTUnwrap(CGContext(
      data: nil, width: Int(Self.width), height: Int(Self.height), bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(gray: 0.972, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
    for index in 0..<5 {
      let c = Self.centre(index)
      let rect = CGRect(x: c.x - Self.tile / 2, y: Self.height - c.y - Self.tile / 2, width: Self.tile, height: Self.tile)
      context.addPath(Self.continuousRect(rect, radius: 52))
      context.setFillColor(gray: 0.93, alpha: 1)
      context.fillPath()
    }
    return try XCTUnwrap(context.makeImage())
  }

  private static func continuousRect(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let corners: [(CGPoint, CGVector, CGVector)] = [
      (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
      (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
      (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
      (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    for (index, (c, u, v)) in corners.enumerated() {
      func p(_ back: CGFloat, _ on: CGFloat) -> CGPoint {
        CGPoint(x: c.x - u.dx * back * r + v.dx * on * r, y: c.y - u.dy * back * r + v.dy * on * r)
      }
      if index == 0 { path.move(to: p(1.52866483, 0)) } else { path.addLine(to: p(1.52866483, 0)) }
      path.addCurve(to: p(0.63149399, 0.07491100), control1: p(1.08849323, 0), control2: p(0.86840689, 0))
      path.addCurve(to: p(0.07491100, 0.63149399), control1: p(0.37282392, 0.16905899),
                    control2: p(0.16905899, 0.37282392))
      path.addCurve(to: p(0, 1.52866483), control1: p(0, 0.86840689), control2: p(0, 1.08849323))
    }
    path.closeSubpath()
    return path
  }

  private func opacity(_ image: CIImage, _ k: CGFloat) -> CIImage {
    image.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
      "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
      "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: k),
    ])
  }

  private static func arrival(_ t: Double) -> (scale: Double, alpha: Double) {
    guard t > 0 else { return (0.001, 0) }
    let spring = 1 - exp(-7 * t) * cos(13 * t)
    let x = min(1, t / 0.22)
    return (max(0.001, 0.35 + 0.65 * spring), x * x * (3 - 2 * x))
  }

  func testRenderTheLineup() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let dir = environment["BOLTTY_LINEUP"] else { throw XCTSkip("set BOLTTY_LINEUP to render") }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let duration = Double(environment["BOLTTY_LINEUP_SECONDS"] ?? "") ?? 8
    let stills = (environment["BOLTTY_LINEUP_STILLS"] ?? "").split(separator: ",").compactMap { Double($0) }
    let video = environment["BOLTTY_LINEUP_VIDEO"] == "1"
    let supersample: CGFloat = 2
    let renderer = try XCTUnwrap(MascotRenderer.shared)
    let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = CIContext(options: [
      .workingColorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB)),
      .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false,
    ])
    let extent = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
    let base = CIImage(cgImage: try ground(in: sRGB))
    var players = try cast()
    let step = 1 / Self.fps
    for _ in 0..<Int(2 * Self.fps) { for i in players.indices { players[i].motion.update(step) } }

    var ffmpeg: Process?
    var input: FileHandle?
    let output = directory.appendingPathComponent("boltty-agents-lineup.mp4")
    if video {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
      process.arguments = [
        "-y", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(Int(Self.width))x\(Int(Self.height))",
        "-framerate", "\(Int(Self.fps))", "-i", "-",
        "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=spline+accurate_rnd+full_chroma_int,format=yuv420p",
        "-c:v", "libx264", "-preset", "slow", "-crf", "14", "-profile:v", "high", "-r", "60",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
        "-movflags", "+faststart", output.path,
      ]
      let pipe = Pipe()
      process.standardInput = pipe
      let log = directory.appendingPathComponent("ffmpeg.log")
      FileManager.default.createFile(atPath: log.path, contents: nil)
      let handle = try FileHandle(forWritingTo: log)
      process.standardOutput = handle
      process.standardError = handle
      try process.run()
      ffmpeg = process
      input = pipe.fileHandleForWriting
    }

    var pending = stills.sorted()
    let frames = Int((duration * Self.fps).rounded())
    for index in 0..<frames {
      let time = Double(index) / Self.fps
      play(&players, until: time)
      for i in players.indices { players[i].motion.update(step) }
      let wantsStill = pending.first.map { time + step / 2 >= $0 } ?? false
      if !video && pending.isEmpty { break }
      guard video || wantsStill else { continue }

      var picture = base
      for player in players {
        let (scale, alpha) = Self.arrival(time - player.arrives)
        guard alpha > 0 else { continue }
        let clock = player.phase + (2 + time) * MascotSpec.speed * MascotSpec.gradientRate
        let uniforms = MascotRenderer.uniforms(for: frame(of: player, clock: clock), rays: 4)
        var face = CIImage(cgImage: try XCTUnwrap(renderer.image(of: uniforms, scale: supersample)))
        let k = CGFloat(scale) / supersample
        face = face.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let centre = CGPoint(x: player.center.x, y: Self.height - player.center.y)
        face = face.transformed(by: CGAffineTransform(translationX: centre.x - face.extent.midX,
                                                      y: centre.y - face.extent.midY))
        face = opacity(face, CGFloat(alpha))
        let shadow = face
          .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.16),
          ])
          .clampedToExtent().applyingGaussianBlur(sigma: Double(Self.face) * 0.04)
          .transformed(by: CGAffineTransform(translationX: 0, y: -Self.face * 0.05))
          .cropped(to: extent)
        picture = face.composited(over: shadow.composited(over: picture))
      }
      let image = try XCTUnwrap(context.createCGImage(
        picture.cropped(to: extent), from: extent, format: .BGRA8, colorSpace: sRGB))
      if wantsStill {
        let still = pending.removeFirst()
        let url = directory.appendingPathComponent(String(format: "lineup-%05.2fs.png", still))
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
        print("BOLTTY_LINEUP_STILL \(url.path)")
      }
      if let input {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let rowBytes = Int(Self.width) * 4
        var packed = Data(capacity: rowBytes * image.height)
        for row in 0..<image.height {
          packed.append(data[row * image.bytesPerRow ..< row * image.bytesPerRow + rowBytes])
        }
        try input.write(contentsOf: packed)
      }
    }
    if let input, let ffmpeg {
      try input.close()
      ffmpeg.waitUntilExit()
      XCTAssertEqual(ffmpeg.terminationStatus, 0)
      print("BOLTTY_LINEUP_VIDEO \(output.path)")
    }
  }
}
