import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import Boltty

@MainActor
final class MascotShapeContactSheet: XCTestCase {
  private func palette(_ id: String) throws -> MascotPalette {
    try XCTUnwrap(MascotPalette.palette(withID: id))
  }

  private func face(_ shape: MascotShape, _ palette: MascotPalette, size: CGFloat) -> MascotNSView {
    let view = MascotNSView(
      conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
      palette: palette,
      shape: shape
    )
    view.frame = CGRect(x: 0, y: 0, width: size, height: size)
    view.reduceMotion = true
    view.layoutSubtreeIfNeeded()
    return view
  }

  private func image(
    _ view: MascotNSView, yaw: Double = 0, pitch: Double = 0,
    eyeShape: MascotEyeShape? = nil
  ) throws -> NSImage {
    var frame = try XCTUnwrap(view.lastFrame)
    frame.overscan = 0
    frame.pose.yaw = yaw
    frame.pose.pitch = pitch
    if let eyeShape {
      for index in frame.eyes.indices { frame.eyes[index].shape = eyeShape }
    }
    let cg = try XCTUnwrap(
      MascotRenderer.shared?.image(of: MascotRenderer.uniforms(for: frame), scale: 2)
    )
    return NSImage(cgImage: cg, size: view.bounds.size)
  }

  func testRenderTheGradientFlow() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let faces: [(MascotShape, String)] = [
      (.bloom, "daybreak"), (.capsule, "ember"), (.daisy, "aurora"),
      (.hex, "solar"), (.orb, "rose"), (.triangle, "lagoon"),
    ]
    let views = try faces.map { try face($0.0, palette($0.1), size: 96) }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("mascot-gradient-flow.gif")
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 90, nil))
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let rate = MascotSpec.speed * MascotSpec.gradientRate
    for index in 0..<90 {
      let seconds = Double(index) / 15
      let width = Double(views.count * 110 + 10)
      let bitmap = try drawInSRGB(width: width, height: 116) {
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: 116).fill()
        for (column, view) in views.enumerated() {
          var frame = try XCTUnwrap(view.lastFrame)
          frame.overscan = 0
          frame.clock = frame.phase + seconds * rate
          let cg = try XCTUnwrap(MascotRenderer.shared?.image(of: MascotRenderer.uniforms(for: frame), scale: 2))
          NSImage(cgImage: cg, size: NSSize(width: 96, height: 96)).draw(
            in: NSRect(x: 10 + column * 110, y: 10, width: 96, height: 96),
            from: .zero, operation: .sourceOver, fraction: 1)
        }
      }
      CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.cgImage), [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 15]
      ] as CFDictionary)
      if index % 15 == 0 {
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: directory.appendingPathComponent("mascot-gradient-flow-\(index / 15).png"))
      }
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }

  func testRenderTheShapes() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let palettes = try ["daybreak", "ember", "lagoon", "orchid"].map(palette)
    let big: CGFloat = 96
    let gap: CGFloat = 12
    let label: CGFloat = 70
    let columns = palettes.count + 3
    let width = label + CGFloat(columns) * (big + gap) + gap
    let rowHeight = big + gap
    let height = CGFloat(MascotShape.allCases.count) * rowHeight + gap

    let bitmap = try drawInSRGB(width: width, height: height) {
      NSColor(white: 0.10, alpha: 1).setFill()
      NSRect(x: 0, y: 0, width: width, height: height).fill()
      for (row, shape) in MascotShape.allCases.enumerated() {
        let y = height - gap - CGFloat(row + 1) * rowHeight + gap
        NSAttributedString(string: shape.displayName, attributes: [
          .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white
        ]).draw(at: NSPoint(x: 10, y: y + big / 2 - 7))
        var x = label
        for palette in palettes {
          try image(face(shape, palette, size: big)).draw(
            in: NSRect(x: x, y: y, width: big, height: big),
            from: .zero, operation: .sourceOver, fraction: 1)
          x += big + gap
        }
        try image(face(shape, palettes[0], size: big), yaw: 0.55, pitch: 0.18).draw(
          in: NSRect(x: x, y: y, width: big, height: big),
          from: .zero, operation: .sourceOver, fraction: 1)
        x += big + gap
        for size: CGFloat in [38, 26] {
          try image(face(shape, palettes[1], size: size)).draw(
            in: NSRect(x: x + (big - size) / 2, y: y + (big - size) / 2, width: size, height: size),
            from: .zero, operation: .sourceOver, fraction: 1)
          x += (big + gap) / 2
        }
      }
    }
    try write(bitmap, named: "mascot-shapes.png", in: dir)
  }

  func testRenderTheReferenceRow() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let color = try palette(ProcessInfo.processInfo.environment["BOLTTY_REFERENCE_PALETTE"] ?? "daybreak")
    try renderReferenceRow(color, named: "mascot-reference-shapes.png", in: dir)
  }

  func testRenderUpdatedReferenceCatalog() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    for color in MascotPalette.catalog {
      try renderReferenceRow(color, named: "mascot-reference-\(color.id).png", in: dir)
    }
  }

  private func renderReferenceRow(_ color: MascotPalette, named name: String, in dir: String) throws {
    let shapes = MascotShape.allCases
    let big: CGFloat = 160
    let turned: CGFloat = 88
    let panelSizes: [(CGFloat, CGFloat)] = [(38, 24), (26, 104)]
    let gap: CGFloat = 20
    let margin: CGFloat = 16
    let columnWidth = big + gap
    let width = margin * 2 + CGFloat(shapes.count) * columnWidth - gap
    let height: CGFloat = 370
    let bitmap = try drawInSRGB(width: width, height: height) {
      NSColor(white: 0.065, alpha: 1).setFill()
      NSRect(x: 0, y: 0, width: width, height: height).fill()
      for (column, shape) in shapes.enumerated() {
        let x = margin + CGFloat(column) * columnWidth
        try image(face(shape, color, size: big)).draw(
          in: NSRect(x: x, y: height - big - 12, width: big, height: big),
          from: .zero, operation: .sourceOver, fraction: 1)
        let label = NSAttributedString(string: shape.displayName, attributes: [
          .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white
        ])
        label.draw(at: NSPoint(x: x + (big - label.size().width) / 2, y: height - big - 36))
        try image(face(shape, color, size: turned), yaw: 0.55, pitch: 0.18).draw(
          in: NSRect(x: x + (big - turned) / 2, y: 82, width: turned, height: turned),
          from: .zero, operation: .sourceOver, fraction: 1)
        for (size, offset) in panelSizes {
          try image(face(shape, color, size: size)).draw(
            in: NSRect(x: x + offset, y: 22 + (38 - size) / 2, width: size, height: size),
            from: .zero, operation: .sourceOver, fraction: 1)
        }
      }
    }
    try write(bitmap, named: name, in: dir)
  }

  func testRenderTheRoundedBodyAndSolidEyes() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let color = try palette(ProcessInfo.processInfo.environment["BOLTTY_REFERENCE_PALETTE"] ?? "daybreak")
    let shapes: [MascotShape] = [.bloom, .daisy, .hex]
    let big: CGFloat = 160
    let columnWidth: CGFloat = 180
    let labelWidth: CGFloat = 100
    let width = labelWidth + CGFloat(shapes.count) * columnWidth + 12
    let height: CGFloat = 882
    let angles: [(String, Double, Double)] = [
      ("Front", 0, 0), ("3/4", 0.65, 0.12), ("Near profile", 1.2, 0),
    ]
    let closed: [(String, MascotEyeShape)] = [
      ("Sleeping", MascotEyeShape(open: 0, sleepy: 1)),
      ("Blink", MascotEyeShape(open: 0)),
    ]
    let panelSizes: [(CGFloat, CGFloat)] = [(38, 24), (26, 104)]
    let bitmap = try drawInSRGB(width: width, height: height) {
      NSColor(white: 0.12, alpha: 1).setFill()
      NSRect(x: 0, y: 0, width: width, height: height).fill()
      for (column, shape) in shapes.enumerated() {
        let x = labelWidth + CGFloat(column) * columnWidth
        let heading = NSAttributedString(string: shape.displayName, attributes: [
          .font: NSFont.systemFont(ofSize: 13, weight: .medium),
          .foregroundColor: NSColor.white,
        ])
        heading.draw(at: NSPoint(x: x + (big - heading.size().width) / 2, y: height - 23))
        for (row, angle) in angles.enumerated() {
          let y = height - 36 - big - CGFloat(row) * columnWidth
          try image(face(shape, color, size: big), yaw: angle.1, pitch: angle.2).draw(
            in: NSRect(x: x, y: y, width: big, height: big),
            from: .zero, operation: .sourceOver, fraction: 1)
        }
        for (size, offset) in panelSizes {
          try image(face(shape, color, size: size)).draw(
            in: NSRect(x: x + offset, y: 264 + (38 - size) / 2, width: size, height: size),
            from: .zero, operation: .sourceOver, fraction: 1)
        }
        for (row, state) in closed.enumerated() {
          let size: CGFloat = 96
          let y = 138 - CGFloat(row) * 112
          try image(face(shape, color, size: size), eyeShape: state.1).draw(
            in: NSRect(x: x + (big - size) / 2, y: y, width: size, height: size),
            from: .zero, operation: .sourceOver, fraction: 1)
        }
      }
      let labels = angles.enumerated().map { row, angle in
        (angle.0, height - 36 - big / 2 - CGFloat(row) * columnWidth)
      } + [("38 / 26pt", 279), ("Sleeping", 181), ("Blink", 69)]
      for (title, y) in labels {
        NSAttributedString(string: title, attributes: [
          .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: 12, y: y))
      }
    }
    try write(bitmap, named: "mascot-rounded-3d.png", in: dir)
  }

  func testRenderTheInks() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let inks: [(String, MascotRenderer.Ink)] = [
      ("White", .white), ("White + black smile", .whiteEyesBlackSmile), ("Black", .black),
    ]
    let shapes = MascotShape.allCases
    let palettes = MascotPalette.catalog
    let size: CGFloat = 150
    let gap: CGFloat = 18
    let label: CGFloat = 150
    let width = label + CGFloat(shapes.count) * (size + gap) + gap
    let height = CGFloat(inks.count) * (size + gap) + gap
    let bitmap = try drawInSRGB(width: width, height: height) {
      NSColor(white: 0.08, alpha: 1).setFill()
      NSRect(x: 0, y: 0, width: width, height: height).fill()
      for (row, ink) in inks.enumerated() {
        let y = height - CGFloat(row + 1) * (size + gap)
        NSAttributedString(string: ink.0, attributes: [
          .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: 14, y: y + size / 2 - 9))
        for (column, shape) in shapes.enumerated() {
          var frame = try XCTUnwrap(face(shape, palettes[column % palettes.count], size: size).lastFrame)
          frame.overscan = 0
          frame.ink = ink.1
          let cg = try XCTUnwrap(MascotRenderer.shared?.image(of: MascotRenderer.uniforms(for: frame), scale: 2))
          NSImage(cgImage: cg, size: NSSize(width: size, height: size)).draw(
            in: NSRect(x: label + CGFloat(column) * (size + gap), y: y, width: size, height: size),
            from: .zero, operation: .sourceOver, fraction: 1)
        }
      }
    }
    try write(bitmap, named: "mascot-inks.png", in: dir)
  }

  func testRenderTheFinishes() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let materials = MascotFinish.allCases.map { ($0.displayName, $0) }
    let shapes = MascotShape.allCases
    let palettes = MascotPalette.catalog
    let size: CGFloat = 150
    let gap: CGFloat = 18
    let label: CGFloat = 118
    let width = label + CGFloat(shapes.count) * (size + gap) + gap
    let height = CGFloat(materials.count) * (size + gap) + gap
    for (name, yaw, pitch) in [("mascot-finishes.png", 0.35, 0.1), ("mascot-finishes-front.png", 0.0, 0.0)] {
      let bitmap = try drawInSRGB(width: width, height: height) {
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (row, material) in materials.enumerated() {
          let y = height - CGFloat(row + 1) * (size + gap)
          NSAttributedString(string: material.0, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white,
          ]).draw(at: NSPoint(x: 14, y: y + size / 2 - 9))
          for (column, shape) in shapes.enumerated() {
            var frame = try XCTUnwrap(face(shape, palettes[column % palettes.count], size: size).lastFrame)
            frame.overscan = 0
            frame.pose.yaw = yaw
            frame.pose.pitch = pitch
            frame.finish = material.1
            let cg = try XCTUnwrap(MascotRenderer.shared?.image(of: MascotRenderer.uniforms(for: frame), scale: 2))
            NSImage(cgImage: cg, size: NSSize(width: size, height: size)).draw(
              in: NSRect(x: label + CGFloat(column) * (size + gap), y: y, width: size, height: size),
              from: .zero, operation: .sourceOver, fraction: 1)
          }
        }
      }
      try write(bitmap, named: name, in: dir)
    }
  }

  func testRenderTheFinishesAtPanelSizes() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let materials = MascotFinish.allCases.map { ($0.displayName, $0) }
    let shapes = MascotShape.allCases
    let palettes = MascotPalette.catalog
    let sizes: [CGFloat] = [60, 38, 26]
    let cell: CGFloat = 66
    let label: CGFloat = 70
    let width = label + CGFloat(shapes.count * sizes.count) * cell + 12
    let height = CGFloat(materials.count) * cell + 12
    let bitmap = try drawInSRGB(width: width, height: height) {
      NSColor(white: 0.08, alpha: 1).setFill()
      NSRect(x: 0, y: 0, width: width, height: height).fill()
      for (row, material) in materials.enumerated() {
        let y = height - CGFloat(row + 1) * cell
        NSAttributedString(string: material.0, attributes: [
          .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: 10, y: y + cell / 2 - 8))
        for (column, shape) in shapes.enumerated() {
          for (index, size) in sizes.enumerated() {
            var frame = try XCTUnwrap(face(shape, palettes[column % palettes.count], size: size).lastFrame)
            frame.overscan = 0
            frame.finish = material.1
            let cg = try XCTUnwrap(MascotRenderer.shared?.image(of: MascotRenderer.uniforms(for: frame), scale: 2))
            let x = label + CGFloat(column * sizes.count + index) * cell
            NSImage(cgImage: cg, size: NSSize(width: size, height: size)).draw(
              in: NSRect(x: x + (cell - size) / 2, y: y + (cell - size) / 2, width: size, height: size),
              from: .zero, operation: .sourceOver, fraction: 1)
          }
        }
      }
    }
    try write(bitmap, named: "mascot-finishes-small.png", in: dir)
  }

  func testRenderEveryShapeInEveryGradient() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let shapes = MascotShape.allCases
    let palettes = MascotPalette.catalog
    let size: CGFloat = 150
    let gap: CGFloat = 18
    let label: CGFloat = 96
    let header: CGFloat = 34
    let width = label + CGFloat(shapes.count) * (size + gap) + gap
    let height = header + CGFloat(palettes.count) * (size + gap) + gap
    let text: (CGFloat) -> [NSAttributedString.Key: Any] = { size in
      [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white]
    }
    for (name, yaw, pitch) in [("mascot-all.png", 0.0, 0.0), ("mascot-all-turned.png", 0.6, 0.12)] {
      let bitmap = try drawInSRGB(width: width, height: height) {
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (column, shape) in shapes.enumerated() {
          let x = label + CGFloat(column) * (size + gap)
          let title = NSAttributedString(string: shape.displayName, attributes: text(14))
          title.draw(at: NSPoint(x: x + (size - title.size().width) / 2, y: height - header + 4))
        }
        for (row, palette) in palettes.enumerated() {
          let y = height - header - CGFloat(row + 1) * (size + gap) + gap / 2
          NSAttributedString(string: palette.displayName, attributes: text(14))
            .draw(at: NSPoint(x: 14, y: y + size / 2 - 9))
          for (column, shape) in shapes.enumerated() {
            let x = label + CGFloat(column) * (size + gap)
            try image(face(shape, palette, size: size), yaw: yaw, pitch: pitch).draw(
              in: NSRect(x: x, y: y, width: size, height: size),
              from: .zero, operation: .sourceOver, fraction: 1)
          }
        }
      }
      try write(bitmap, named: name, in: dir)
    }
  }

  func testRenderThePlushBody() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let color = try palette(ProcessInfo.processInfo.environment["BOLTTY_REFERENCE_PALETTE"] ?? "daybreak")
    let variants: [(String, (Float, Float)?)] = (ProcessInfo.processInfo.environment["BOLTTY_PLUSH"] ?? "")
      .split(separator: ",")
      .compactMap { pair -> (String, (Float, Float)?)? in
        let numbers = pair.split(separator: ":").compactMap { Float($0) }
        guard numbers.count == 2 else { return nil }
        return ("mascot-plush-\(pair).png", (numbers[0], numbers[1]))
      }
    for (name, build) in variants.isEmpty ? [("mascot-plush.png", nil)] : variants {
      let views: [(String, Double, Double)] = [
        ("Front", 0, 0), ("3/4", 0.65, 0.12), ("Profile", .pi / 2, 0), ("Above", 0.25, -1.15),
      ]
      let size: CGFloat = 120
      let gap: CGFloat = 16
      let label: CGFloat = 80
      let width = label + CGFloat(MascotShape.allCases.count) * (size + gap) + gap
      let height = CGFloat(views.count) * (size + gap) + gap + 24
      let bitmap = try drawInSRGB(width: width, height: height) {
        NSColor(white: 0.10, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (column, shape) in MascotShape.allCases.enumerated() {
          let x = label + CGFloat(column) * (size + gap)
          let heading = NSAttributedString(string: shape.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
          ])
          heading.draw(at: NSPoint(x: x + (size - heading.size().width) / 2, y: height - 22))
          for (row, view) in views.enumerated() {
            var frame = try XCTUnwrap(face(shape, color, size: size).lastFrame)
            frame.overscan = 0
            frame.pose.yaw = view.1
            frame.pose.pitch = view.2
            var uniforms = MascotRenderer.uniforms(for: frame)
            if let build { uniforms.build.x = build.0; uniforms.build.y = build.1 }
            let cg = try XCTUnwrap(MascotRenderer.shared?.image(of: uniforms, scale: 2))
            NSImage(cgImage: cg, size: NSSize(width: size, height: size)).draw(
              in: NSRect(x: x, y: height - 30 - CGFloat(row + 1) * (size + gap) + gap, width: size, height: size),
              from: .zero, operation: .sourceOver, fraction: 1)
          }
        }
        for (row, view) in views.enumerated() {
          NSAttributedString(string: view.0, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white,
          ]).draw(at: NSPoint(x: 12, y: height - 30 - CGFloat(row + 1) * (size + gap) + gap + size / 2 - 7))
        }
      }
      try write(bitmap, named: name, in: dir)
    }
  }

  func testRenderTheGradients() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let wanted = ProcessInfo.processInfo.environment["BOLTTY_GRADIENTS"]?
      .split(separator: ",").map(String.init)
    let palettes = MascotPalette.catalog.filter { palette in
      if let wanted { return wanted.contains(palette.id) }
      return true
    }
    let shapes = MascotShape.allCases
    let size: CGFloat = 80
    let gap: CGFloat = 10
    let label: CGFloat = 86
    let columns = shapes.count + 2
    let width = label + CGFloat(columns) * (size + gap) + gap
    let rowHeight = size + gap
    let height = CGFloat(palettes.count) * rowHeight + gap

    let bitmap = try drawInSRGB(width: width, height: height) {
      NSColor(white: 0.10, alpha: 1).setFill()
      NSRect(x: 0, y: 0, width: width, height: height).fill()
      for (row, palette) in palettes.enumerated() {
        let y = height - gap - CGFloat(row + 1) * rowHeight + gap
        NSAttributedString(string: palette.displayName, attributes: [
          .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white
        ]).draw(at: NSPoint(x: 10, y: y + size / 2 - 7))
        var x = label
        for shape in shapes {
          try image(face(shape, palette, size: size)).draw(
            in: NSRect(x: x, y: y, width: size, height: size),
            from: .zero, operation: .sourceOver, fraction: 1)
          x += size + gap
        }
        try image(face(.orb, palette, size: size), yaw: 0.55, pitch: 0.18).draw(
          in: NSRect(x: x, y: y, width: size, height: size),
          from: .zero, operation: .sourceOver, fraction: 1)
        x += size + gap
        try image(face(.hex, palette, size: 32), yaw: 0, pitch: 0).draw(
          in: NSRect(x: x + (size - 32) / 2, y: y + (size - 32) / 2, width: 32, height: 32),
          from: .zero, operation: .sourceOver, fraction: 1)
      }
    }
    try write(bitmap, named: "mascot-gradients.png", in: dir)
  }

  private func write(_ bitmap: NSBitmapImageRep, named name: String, in dir: String) throws {
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try png.write(to: url)
    print("BOLTTY_SHEET \(url.path)")
  }

  private func drawInSRGB(
    width: Double, height: Double, _ body: () throws -> Void
  ) throws -> NSBitmapImageRep {
    let scale = 2.0
    let context = try XCTUnwrap(CGContext(
      data: nil, width: Int(width * scale), height: Int(height * scale),
      bitsPerComponent: 8, bytesPerRow: 0,
      space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.scaleBy(x: scale, y: scale)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.current = previous }
    try body()
    return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
  }
}

@MainActor
final class MascotPickerContactSheet: XCTestCase {
  private func makeModel() -> BolttyAISettingsModel {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-picker-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = isolatedDefaults("boltty.tests.picker")
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    let engine = ConversationEngine(store: store, registry: AgentRegistry(clients: []))
    return BolttyAISettingsModel(
      appModel: AppModel(settings: AppSettings(), defaults: defaults), engine: engine
    )
  }

  func testRenderThePicker() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let model = makeModel()
    let popover = MascotPickerView(model: model, agent: .codex)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, .dark)
    let row = MascotPickerButton(model: model, agent: .codex)
      .padding(16)
      .frame(width: 560)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, .dark)

    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, content) in [("mascot-picker.png", AnyView(popover)), ("mascot-row.png", AnyView(row))] {
      let renderer = ImageRenderer(content: content)
      renderer.scale = 2
      let image = try XCTUnwrap(renderer.cgImage)
      let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
      let url = directory.appendingPathComponent(name)
      try png.write(to: url)
      print("BOLTTY_SHEET \(url.path)")
    }
  }
}
