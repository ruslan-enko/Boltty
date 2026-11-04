import SwiftUI

/// A `BolttyIcon` in SwiftUI, coloured by `foregroundStyle` as a symbol would
/// be. It takes a size rather than a font, since a symbol's font is what it
/// replaces. Kept per icon and size: a body runs on every hover.
struct BolttyIconView: View {
  let icon: BolttyIcon
  var size: CGFloat = 16

  @MainActor private static var images: [String: NSImage] = [:]

  @MainActor private var image: NSImage {
    let key = "\(icon.rawValue)-\(size)"
    if let kept = Self.images[key] { return kept }
    let made = icon.image(size: size) ?? NSImage(size: NSSize(width: size, height: size))
    Self.images[key] = made
    return made
  }

  var body: some View {
    Image(nsImage: image)
      .renderingMode(.template)
      .frame(width: size, height: size)
  }
}
