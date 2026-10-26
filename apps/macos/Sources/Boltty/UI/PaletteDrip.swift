import AppKit

enum PaletteDrip {
  @MainActor
  static func source(on screen: NSScreen, around midX: CGFloat) -> CGRect {
    if let notch = NotchMascotGeometry.notch(on: screen) {
      return notch.insetBy(dx: 1, dy: 0)
    }
    let width = AgentPaletteMetrics.promptSize.height * AgentPaletteMetrics.dripFallWidth * 1.6
    let height = AgentPaletteMetrics.dripEdgeSliver
    return CGRect(x: midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
  }

  static func stations(
    source: CGRect, shell: CGRect
  ) -> (seed: CGRect, fallen: CGRect, shell: CGRect) {
    let unit = min(shell.height, AgentPaletteMetrics.promptSize.height)
    let side = unit * AgentPaletteMetrics.dripSeed
    let seed = CGRect(x: source.midX - side / 2, y: source.minY + side * 0.1, width: side, height: side)
    let fallW = min(shell.width, unit * AgentPaletteMetrics.dripFallWidth)
    let fallH = unit * AgentPaletteMetrics.dripFallHeight
    let fallen = CGRect(x: shell.midX - fallW / 2, y: shell.maxY - fallH, width: fallW, height: fallH)
    return (seed, fallen, shell)
  }
}
