import AppKit

@MainActor
enum StatusBarIconRenderer {
  static let size = NSSize(width: 20, height: 18)

  static func image(state _: StatusBarIconState, bundle _: Bundle = .main) -> NSImage {
    let image = NSImage(size: size, flipped: false) { rect in
      NSColor.black.setStroke()
      NSColor.black.setFill()
      NSBezierPath.bolttyBrandOutline(in: rect).stroke()
      NSBezierPath.bolttyBrandEyes(in: rect).fill()
      return true
    }
    image.isTemplate = true
    return image
  }


}
