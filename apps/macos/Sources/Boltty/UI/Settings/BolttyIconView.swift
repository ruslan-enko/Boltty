import SwiftUI

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

struct Keycap: NSViewRepresentable {
  let key: String
  var side: CGFloat = AgentPaletteMetrics.helpKeycapSize

  func makeNSView(context: Context) -> PaletteKeycapView {
    PaletteKeycapView(key: key, side: side, ink: PaletteInk.primary)
  }

  func updateNSView(_ view: PaletteKeycapView, context: Context) {}

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: PaletteKeycapView, context: Context) -> CGSize? {
    nsView.fittingSize
  }
}
