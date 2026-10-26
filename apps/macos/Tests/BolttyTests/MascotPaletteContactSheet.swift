import AppKit
import ImageIO
import XCTest
@testable import Boltty

@MainActor
final class MascotPaletteContactSheet: XCTestCase {
  func testRenderMotionStudy() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }
    let moods: [(String, MascotEmotion)] = [
      ("Curious", .curious), ("Listening", .listening), ("Thinking", .thinking),
      ("Focused", .focused), ("Concerned", .concerned), ("Sad", .sad),
      ("Sleeping", .sleeping)
    ]
    let views = moods.map { _, emotion in
      let view = MascotNSView(
        conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
        palette: .fallback
      )
      view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
      view.emotion = emotion
      view.layoutSubtreeIfNeeded()
      return view
    }
    let directory = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("mascot-motion.gif")
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 240, nil))
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for frame in 0..<240 {
      let bitmap = try drawInSRGB(width: 870, height: 200) {
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 870, height: 200).fill()
        for (index, view) in views.enumerated() {
          view.advance(1.0 / 60.0)
          view.advance(1.0 / 60.0)
          let snapshot = NSImage(
            cgImage: try XCTUnwrap(view.snapshot(scale: 2, overscan: true)),
            size: NSSize(width: 128, height: 128)
          )
          snapshot.draw(in: NSRect(x: 16 + index * 120, y: 48, width: 128, height: 128),
                        from: .zero, operation: .sourceOver, fraction: 1)
          NSAttributedString(string: moods[index].0, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white
          ]).draw(at: NSPoint(x: 50 + index * 120, y: 16))
        }
      }
      let cgImage = try XCTUnwrap(bitmap.cgImage)
      CGImageDestinationAddImage(destination, cgImage, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30.0]
      ] as CFDictionary)
      if frame % 30 == 0 {
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: directory.appendingPathComponent("mascot-emotions-\(frame / 30).png"))
      }
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    print("BOLTTY_MOTION \(url.path)")
  }

  func testRenderTheCatalog() throws {
    guard let dir = ProcessInfo.processInfo.environment["BOLTTY_CONTACT_SHEET"] else {
      throw XCTSkip("set BOLTTY_CONTACT_SHEET to render")
    }

    let cell = 64.0
    let pad = 14.0
    let columns = 4
    let perPalette = 3
    let rows = (MascotPalette.catalog.count + columns - 1) / columns
    let block = Double(perPalette) * (cell + 6)
    let width = Double(columns) * (block + pad) + pad
    let height = Double(rows) * (cell + pad + 18) + pad

    let bitmap = try drawInSRGB(width: width, height: height) {
      NSColor(white: 0.12, alpha: 1).setFill()
      NSRect(x: 0, y: 0, width: width, height: height).fill()

      for (index, palette) in MascotPalette.catalog.enumerated() {
        let column = index % columns
        let row = index / columns
        let x = pad + Double(column) * (block + pad)
        let y = height - pad - Double(row + 1) * (cell + pad + 18) + 18

        let faces: [(CGFloat, MascotEmotion, Int)] = [(64, .curious, 0), (64, .thinking, 40), (38, .curious, 0)]
        for (offset, face) in faces.enumerated() {
          let view = MascotNSView(conversationID: UUID(), palette: palette)
          view.frame = CGRect(x: 0, y: 0, width: face.0, height: face.0)
          view.emotion = face.1
          view.layoutSubtreeIfNeeded()
          for _ in 0..<face.2 { view.advance(1.0 / 30.0) }
          view.render()
          let snapshot = NSImage(cgImage: try XCTUnwrap(view.snapshot(scale: 2)), size: view.bounds.size)
          let left = x + Double(offset) * (cell + 6) + (cell - face.0) / 2
          snapshot.draw(in: NSRect(x: left, y: y + (cell - face.0) / 2, width: face.0, height: face.0),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }

        let label = NSAttributedString(
          string: palette.displayName,
          attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white
          ]
        )
        label.draw(at: NSPoint(x: x, y: y - 16))
      }
    }

    guard let png = bitmap.representation(using: .png, properties: [:])
    else { return XCTFail("could not encode") }

    let url = URL(fileURLWithPath: dir).appendingPathComponent("mascot-palettes.png")
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: dir), withIntermediateDirectories: true
    )
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
