import AppKit

@MainActor
final class ComputerUseIndicator {
  private var panel: PassivePanel?
  private let hints = PaletteKeyHints()
  private static let gap: CGFloat = 10

  func show(words: String, stops: Bool) {
    let panel = panel ?? make()
    hints.setHints([PaletteKeyHints.Hint(key: nil, words: words)]
      + (stops ? [PaletteKeyHints.Hint(key: "esc", words: String(localized: "Stop"))] : []))
    let size = hints.size
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: (screen.visibleFrame.minY + Self.gap).rounded(),
                       width: size.width, height: size.height)
    panel.setFrame(frame, display: true)
    hints.frame = NSRect(origin: .zero, size: size)
    hints.show()
    panel.orderFrontRegardless()
  }

  func hide() {
    hints.hide()
    panel?.orderOut(nil)
  }

  private func make() -> PassivePanel {
    let panel = PassivePanel(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.appearance = NSAppearance(named: .darkAqua)
    let root = NSView()
    root.addSubview(hints)
    hints.shadesRim = false
    panel.contentView = root
    self.panel = panel
    return panel
  }
}
