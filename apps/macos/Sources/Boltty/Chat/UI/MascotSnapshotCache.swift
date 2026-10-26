import AppKit

@MainActor
enum MascotSnapshotCache {
  static let identity = UUID(uuidString: "3E0C5C3B-7B62-4C06-9A4E-2D8E0F6B1A11")!

  private static var images: [String: CGImage] = [:]

  static func image(_ look: MascotLook, size: CGFloat, scale: CGFloat) -> CGImage? {
    let key = "\(look.id)@\(Int(size * 10))x\(Int(scale * 10))"
    if let cached = images[key] { return cached }
    let view = MascotNSView(conversationID: identity, look: look)
    view.frame = CGRect(x: 0, y: 0, width: size, height: size)
    view.reduceMotion = true
    view.layoutSubtreeIfNeeded()
    guard let image = view.snapshot(scale: scale) else { return nil }
    images[key] = image
    return image
  }
}
