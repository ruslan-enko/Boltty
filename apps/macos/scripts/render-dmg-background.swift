#!/usr/bin/env swift
// Draws the DMG window's background: the first run's sunset, Boltty on the
// left, an arrow, Applications on the right. A stand-in until a drawn one
// replaces Resources/DMG/background.png and background@2x.png — the release
// reads those two files, not this script.
//
//   swift scripts/render-dmg-background.swift
//
// The window is 660 × 400 points; release.sh puts the icons at (170, 190)
// and (490, 190), so the arrow runs between them.

import AppKit

let size = CGSize(width: 660, height: 400)
let out = URL(fileURLWithPath: CommandLine.arguments.first.map { _ in
  FileManager.default.currentDirectoryPath } ?? ".")
  .appendingPathComponent("Resources/DMG")

func colour(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
  var v: UInt64 = 0
  Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
  return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                 blue: CGFloat(v & 0xff) / 255, alpha: alpha)
}

func render(scale: CGFloat) -> Data {
  let w = Int(size.width * scale), h = Int(size.height * scale)
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  cg.scaleBy(x: scale, y: scale)

  // The sky: SunsetView's stops, top to bottom (y is up here).
  let stops = ["#22468f", "#3a6db0", "#5a8ac0", "#a9a0b4", "#e8a67c", "#f4a24e", "#e2461b"]
  let locations: [CGFloat] = [0, 0.3, 0.46, 0.6, 0.72, 0.84, 1].map { 1 - $0 }.reversed()
  let sky = CGGradient(colorsSpace: space, colors: stops.reversed().map { colour($0) } as CFArray,
                       locations: locations)!
  cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

  // Its soft lights, held still.
  for (hex, alpha, x, y, r) in [("#ffb36b", 0.38, 0.28, 0.7, 260.0),
                                ("#ff86b0", 0.26, 0.74, 0.58, 220.0),
                                ("#9cc8ff", 0.30, 0.55, 0.22, 240.0)] {
    let glow = CGGradient(colorsSpace: space, colors: [colour(hex, alpha), colour(hex, 0)] as CFArray,
                          locations: [0, 1])!
    let c = CGPoint(x: x * size.width, y: y * size.height)
    cg.setBlendMode(.screen)
    cg.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
  }
  cg.setBlendMode(.normal)

  // A shade where the icons and their names stand, so white type reads.
  let band = CGGradient(colorsSpace: space, colors: [colour("#000000", 0), colour("#000000", 0.18),
                                                     colour("#000000", 0)] as CFArray,
                        locations: [0, 0.5, 1])!
  cg.drawLinearGradient(band, start: CGPoint(x: 0, y: 90), end: CGPoint(x: 0, y: 330), options: [])

  // The arrow: a soft arc from Boltty to Applications.
  let from = CGPoint(x: 252, y: 214), to = CGPoint(x: 408, y: 214)
  let arc = CGMutablePath()
  arc.move(to: from)
  arc.addQuadCurve(to: to, control: CGPoint(x: 330, y: 246))
  cg.setStrokeColor(colour("#ffffff", 0.85))
  cg.setLineWidth(3.5)
  cg.setLineCap(.round)
  cg.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: colour("#000000", 0.25))
  cg.addPath(arc)
  cg.strokePath()
  let head = CGMutablePath()
  head.move(to: CGPoint(x: to.x - 13, y: to.y + 11))
  head.addLine(to: to)
  head.addLine(to: CGPoint(x: to.x - 15, y: to.y - 6))
  cg.setLineJoin(.round)
  cg.addPath(head)
  cg.strokePath()

  // The one sentence.
  let ctx = NSGraphicsContext(cgContext: cg, flipped: false)
  NSGraphicsContext.current = ctx
  let font = NSFont.systemFont(ofSize: 15, weight: .medium)
  let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 15) } ?? font
  let shadow = NSShadow()
  shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
  shadow.shadowBlurRadius = 4
  shadow.shadowOffset = NSSize(width: 0, height: -1)
  let text = NSAttributedString(string: "Drag Boltty into Applications", attributes: [
    .font: rounded, .foregroundColor: NSColor(white: 1, alpha: 0.9), .shadow: shadow,
  ])
  let t = text.size()
  text.draw(at: CGPoint(x: (size.width - t.width) / 2, y: 58))
  NSGraphicsContext.current = nil

  let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
  rep.size = size
  return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
print("wrote \(out.path)/background.png and background@2x.png")
