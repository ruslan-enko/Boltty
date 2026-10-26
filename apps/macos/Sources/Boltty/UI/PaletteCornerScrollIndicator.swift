import AppKit

@MainActor
final class PaletteCornerScrollIndicator: NSView {
  private let thumb = CAShapeLayer()
  private var fadeOut: DispatchWorkItem?
  private(set) var isShowing = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    thumb.fillColor = nil
    thumb.strokeColor = AgentPaletteMetrics.scrollIndicatorInk.cgColor
    thumb.lineWidth = AgentPaletteMetrics.scrollIndicatorWidth
    thumb.lineCap = .round
    thumb.opacity = 0
    layer?.addSublayer(thumb)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var allowsVibrancy: Bool { false }

  struct Reading: Equatable {
    var position: CGFloat
    var proportion: CGFloat
  }

  static func reading(of scroll: NSScrollView) -> Reading? {
    guard let document = scroll.documentView else { return nil }
    let clip = scroll.contentView
    let insets = scroll.contentInsets
    let visible = clip.bounds.height
    let whole = document.frame.height + insets.top + insets.bottom
    guard visible > 0, whole - visible > 1 else { return nil }
    let range = whole - visible
    var offset: CGFloat
    if clip.isFlipped {
      offset = clip.bounds.minY + insets.top
    } else {
      offset = document.frame.height + insets.bottom - clip.bounds.maxY
    }
    offset = min(max(offset, 0), range)
    return Reading(position: offset / range, proportion: visible / whole)
  }

  func place(in rect: CGRect, corner: CGFloat, reading: Reading, topClearance: CGFloat = 0) {
    let inset = AgentPaletteMetrics.scrollIndicatorInset
    let radius = max(0, min(corner, rect.height / 2, rect.width / 2) - inset)
    let centreX = rect.maxX - max(corner, inset)
    let top = CGPoint(x: centreX, y: rect.maxY - max(corner, inset))
    let foot = CGPoint(x: centreX, y: rect.minY + max(corner, inset))

    let path = CGMutablePath()
    var length: CGFloat
    if topClearance > 0 {
      let start = max(foot.y, min(top.y, rect.maxY - topClearance))
      path.move(to: CGPoint(x: foot.x + radius, y: start))
      length = .pi / 2 * radius + (start - foot.y)
    } else {
      path.move(to: CGPoint(x: top.x, y: top.y + radius))
      path.addArc(center: top, radius: radius, startAngle: .pi / 2, endAngle: 0, clockwise: true)
      length = .pi * radius + max(0, top.y - foot.y)
    }
    path.addLine(to: CGPoint(x: foot.x + radius, y: foot.y))
    path.addArc(center: foot, radius: radius, startAngle: 0, endAngle: -.pi / 2, clockwise: true)

    guard length > 1 else { return }
    // Half a corner's quarter circle, whatever the document's length: at
    // either end it
    // stands inside the corner and bends with it, on the wall a short
    // stroke. A thumb sized to the viewport, as a scroller's is, ran far
    // down the wall from the corner.
    let thumbLength = min(length, max(.pi / 4 * radius, AgentPaletteMetrics.scrollIndicatorMinimumLength))
    // At either end the thumb stops centred in the corner, on its diagonal
    // — not at the arc's end, where it would lie flat
    // along the foot. Under the history's tabs there is no top corner, so
    // there it stops at the track's start.
    let half = thumbLength / 2
    let diagonal = CGFloat.pi / 4 * radius
    let first = topClearance > 0 ? half : max(half, diagonal)
    let last = max(first, length - max(half, diagonal))
    let centre = first + (last - first) * min(max(reading.position, 0), 1)
    let start = max(0, (centre - half) / length)
    let span = min(1, thumbLength / length)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    thumb.frame = bounds
    thumb.path = path
    thumb.strokeStart = start
    thumb.strokeEnd = start + span
    CATransaction.commit()
  }

  func flash() {
    fadeOut?.cancel()
    if !isShowing {
      isShowing = true
      fade(to: 1, over: Motion.quick)
    }
    let work = DispatchWorkItem { [weak self] in self?.conceal() }
    fadeOut = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Motion.scaled(AgentPaletteMetrics.scrollIndicatorLinger),
      execute: work
    )
  }

  func conceal(animated: Bool = true) {
    fadeOut?.cancel()
    fadeOut = nil
    guard isShowing else { return }
    isShowing = false
    fade(to: 0, over: animated ? Motion.standard : 0)
  }

  private func fade(to opacity: Float, over duration: TimeInterval) {
    let from = thumb.presentation()?.opacity ?? thumb.opacity
    thumb.opacity = opacity
    guard duration > 0 else {
      thumb.removeAnimation(forKey: "fade")
      return
    }
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = from
    animation.toValue = opacity
    animation.duration = duration
    animation.timingFunction = Motion.standardCurve
    thumb.add(animation, forKey: "fade")
  }

  var thumbStrokeForTesting: (start: CGFloat, end: CGFloat) { (thumb.strokeStart, thumb.strokeEnd) }
  var thumbPathBoundsForTesting: CGRect { thumb.path?.boundingBox ?? .null }
}

final class PaletteInvisibleScroller: NSScroller {
  override class var isCompatibleWithOverlayScrollers: Bool { true }
  override func draw(_ dirtyRect: NSRect) {}
  override func drawKnob() {}
  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}
