import AppKit
import XCTest
@testable import Boltty

@MainActor
final class NotchRowContactSheet: XCTestCase {
  private let band: CGFloat = 38
  private let agents: [AgentId] = AgentHistory.tabOrder

  private struct Variant {
    let name: String
    let faces: Int
    var rim = false
    var line: String?
    var badge: (index: Int, count: Int)?
  }

  func testRenderTheRowOfFaces() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    var variants: [Variant] = (1...4).map { Variant(name: "\($0) як у кадрі", faces: $0) }
    variants += (2...4).map { Variant(name: "\($0) з обідком", faces: $0, rim: true) }
    variants.append(Variant(name: "3 з рядком", faces: 3, line: "Needs your approval · Codex"))
    variants.append(Variant(name: "3 з бейджем", faces: 3, badge: (index: 0, count: 2)))
    for zoom in [1.0, 4.0] {
      let rowWidth: CGFloat = 420 * zoom
      let rowHeight = (band + 14) * zoom
      let label: CGFloat = 130
      let width = label + rowWidth + 12
      let height = CGFloat(variants.count) * rowHeight + 12
      let bitmap = try drawInSRGB(width: width, height: height) {
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, variant) in variants.enumerated() {
          let y = height - CGFloat(index + 1) * rowHeight
          NSAttributedString(string: variant.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
          ]).draw(at: NSPoint(x: 10, y: y + rowHeight / 2 - 8))
          try drawRow(variant, origin: NSPoint(x: label, y: y + 7 * zoom), width: rowWidth, zoom: zoom)
        }
      }
      try write(bitmap, named: zoom == 1 ? "notch-row.png" : "notch-row-4x.png", in: dir)
    }
  }

  func testRenderTheLiveRow() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let dock = NotchMascotController()
    dock.geometryProvider = {
      NotchMascotGeometry(
        screen: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 38,
        left: CGRect(x: 0, y: 944, width: 660, height: 38),
        right: CGRect(x: 852, y: 944, width: 660, height: 38))
    }
    defer { dock.shutdown() }
    dock.setPanelVisible(false, screen: nil, conversationID: nil)
    for count in 1...4 {
      let chats = agents.prefix(count).map {
        Conversation(providerID: $0.rawValue, title: "Task", workingDirectory: "/tmp", lastKnownState: .working)
      }
      dock.update(conversations: chats, roster: MascotRoster.load(defaults: .standard))
      let image = try XCTUnwrap(dock.snapshotForTesting())
      let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
      let url = URL(fileURLWithPath: dir).appendingPathComponent("notch-live-\(count).png")
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try png.write(to: url)
      print("BOLTTY_SHEET \(url.path)")
    }
  }

  private func drawRow(_ variant: Variant, origin: NSPoint, width: CGFloat, zoom: CGFloat) throws {
    let h = band * zoom
    NSColor(white: 0.23, alpha: 1).setFill()
    NSRect(x: origin.x, y: origin.y, width: width, height: h).fill()
    let notch = NSRect(x: origin.x + width - 110 * zoom, y: origin.y, width: 110 * zoom, height: h)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: notch, xRadius: 9 * zoom, yRadius: 9 * zoom).fill()
    notch.insetBy(dx: 0, dy: 0).divided(atDistance: h / 2, from: .maxYEdge).slice.fill()

    let capsuleHeight = (band - NotchMascotGeometry.inset * 2) * zoom
    let d = (capsuleHeight * 0.66).rounded()
    let margin = (capsuleHeight - d) / 2
    let step = d * 0.49
    let facesWidth = d + step * CGFloat(variant.faces - 1)
    var words: NSAttributedString?
    var wordsWidth: CGFloat = 0
    if let line = variant.line {
      let text = NSAttributedString(string: line, attributes: [
        .font: roundedAppFont(size: AgentPaletteMetrics.typeMeta * zoom, weight: .medium),
        .foregroundColor: NSColor(white: 1, alpha: 0.85),
      ])
      words = text
      wordsWidth = ceil(text.size().width) + NotchMascotGeometry.linePadding * zoom
    }
    let capsuleWidth = margin * 2 + facesWidth + wordsWidth
    let capsule = NSRect(
      x: notch.minX - NotchMascotGeometry.gap * zoom - capsuleWidth,
      y: origin.y + NotchMascotGeometry.inset * zoom,
      width: capsuleWidth, height: capsuleHeight)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: capsule, xRadius: capsuleHeight / 2, yRadius: capsuleHeight / 2).fill()
    if let words {
      let size = words.size()
      words.draw(at: NSPoint(x: capsule.minX + NotchMascotGeometry.linePadding * zoom,
                             y: capsule.midY - size.height / 2))
    }

    let firstX = capsule.maxX - margin - facesWidth
    for slot in 0..<variant.faces {
      let agent = agents[slot % agents.count]
      let rect = NSRect(x: firstX + step * CGFloat(slot), y: capsule.midY - d / 2, width: d, height: d)
      let face = try faceImage(agent, size: d)
      if variant.rim {
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.setShadow(
          offset: .zero, blur: 1.5 * zoom, color: NSColor.black.cgColor)
        for _ in 0..<3 { face.draw(in: rect) }
        NSGraphicsContext.current?.cgContext.restoreGState()
      }
      face.draw(in: rect)
      if let badge = variant.badge, badge.index == slot {
        let side = (d * 0.46).rounded()
        let disc = NSRect(x: rect.maxX - side * 0.75, y: rect.minY - side * 0.15, width: side, height: side)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: disc.insetBy(dx: -1.5 * zoom, dy: -1.5 * zoom)).fill()
        NSColor(white: 0.28, alpha: 1).setFill()
        NSBezierPath(ovalIn: disc).fill()
        let number = NSAttributedString(string: "\(badge.count)", attributes: [
          .font: roundedAppFont(size: side * 0.68, weight: .bold), .foregroundColor: NSColor.white,
        ])
        let size = number.size()
        number.draw(at: NSPoint(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2))
      }
    }
  }

  private func faceImage(_ agent: AgentId, size: CGFloat) throws -> NSImage {
    let view = MascotNSView(conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
                            look: MascotLook.face(for: agent))
    view.frame = CGRect(x: 0, y: 0, width: size, height: size)
    view.reduceMotion = true
    view.layoutSubtreeIfNeeded()
    var frame = try XCTUnwrap(view.lastFrame)
    frame.overscan = 0
    let cg = try XCTUnwrap(MascotRenderer.shared?.image(of: MascotRenderer.uniforms(for: frame), scale: 2))
    return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
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
