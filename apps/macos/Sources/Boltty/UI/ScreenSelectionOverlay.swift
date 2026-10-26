import AppKit

final class ScreenSelectionOverlay: NSView {
  enum Handle: CaseIterable {
    case minXminY, midXminY, maxXminY, maxXmidY, maxXmaxY, midXmaxY, minXmaxY, minXmidY

    func point(on rect: CGRect) -> CGPoint {
      switch self {
      case .minXminY: CGPoint(x: rect.minX, y: rect.minY)
      case .midXminY: CGPoint(x: rect.midX, y: rect.minY)
      case .maxXminY: CGPoint(x: rect.maxX, y: rect.minY)
      case .maxXmidY: CGPoint(x: rect.maxX, y: rect.midY)
      case .maxXmaxY: CGPoint(x: rect.maxX, y: rect.maxY)
      case .midXmaxY: CGPoint(x: rect.midX, y: rect.maxY)
      case .minXmaxY: CGPoint(x: rect.minX, y: rect.maxY)
      case .minXmidY: CGPoint(x: rect.minX, y: rect.midY)
      }
    }

    var resizePosition: NSCursor.FrameResizePosition {
      switch self {
      case .minXminY: .bottomLeft
      case .midXminY: .bottom
      case .maxXminY: .bottomRight
      case .maxXmidY: .right
      case .maxXmaxY: .topRight
      case .midXmaxY: .top
      case .minXmaxY: .topLeft
      case .minXmidY: .left
      }
    }

    func resizing(_ rect: CGRect, to point: CGPoint, minimum: CGFloat) -> CGRect {
      var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
      switch self {
      case .minXminY, .minXmidY, .minXmaxY: minX = min(point.x, maxX - minimum)
      case .maxXminY, .maxXmidY, .maxXmaxY: maxX = max(point.x, minX + minimum)
      case .midXminY, .midXmaxY: break
      }
      switch self {
      case .minXminY, .midXminY, .maxXminY: minY = min(point.y, maxY - minimum)
      case .minXmaxY, .midXmaxY, .maxXmaxY: maxY = max(point.y, minY + minimum)
      case .minXmidY, .maxXmidY: break
      }
      return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
  }

  var palette: [NSColor] = [] {
    didSet { if palette != oldValue { redraw() } }
  }
  var frozen: (image: CGImage, frame: CGRect)? {
    didSet { redrawFrozen() }
  }
  var selection: CGRect? {
    didSet { if selection != oldValue { redraw() } }
  }
  var showsHandles = false {
    didSet { if showsHandles != oldValue { redraw() } }
  }
  var isDimmed = false {
    didSet { if isDimmed != oldValue { redrawDim(arriving: isDimmed) } }
  }
  var outlines: [CGRect] = [] {
    didSet { if outlines != oldValue { redraw() } }
  }

  private let frozenView = OverlayLayerView()
  private let dimView = OverlayLayerView()
  private let dimLayer = CAShapeLayer()
  private var glows: [ScreenSelectionGlowView] = []
  private var drawsGlows = true
  private let fallbackView = OverlayLayerView()
  private var borders: [CALayer] = []
  private let handlesView = OverlayLayerView()
  private var handleLayers: [CAShapeLayer] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    for view in [frozenView, dimView, fallbackView, handlesView] {
      addSubview(view)
    }
    frozenView.layer?.contentsGravity = .resize
    frozenView.isHidden = true
    dimLayer.fillRule = .evenOdd
    dimLayer.fillColor = NSColor.black.withAlphaComponent(AgentPaletteMetrics.screenSelectionDim).cgColor
    dimLayer.opacity = 0
    dimView.layer?.addSublayer(dimLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    for view in [dimView, fallbackView, handlesView] where view.frame != bounds {
      view.frame = bounds
    }
    redrawDim(arriving: false)
  }

  func handle(at point: CGPoint) -> Handle? {
    guard showsHandles, let selection else { return nil }
    let reach = AgentPaletteMetrics.screenSelectionHandleReach
    return Handle.allCases.first { handle in
      let spot = handle.point(on: selection)
      return hypot(spot.x - point.x, spot.y - point.y) <= reach
    }
  }

  var drawnRectsForTesting: [CGRect] { outlines + (selection.map { [$0] } ?? []) }
  var handleCountForTesting: Int { handleLayers.filter { !$0.isHidden }.count }
  var isFrozenForTesting: Bool { !frozenView.isHidden }
  var glowRegionsForTesting: [CGRect] {
    glows.map { $0.region.offsetBy(dx: $0.frame.minX, dy: $0.frame.minY) }
  }

  // MARK: - Drawing

  private func redrawFrozen() {
    frozenView.layer?.contents = frozen?.image
    frozenView.frame = frozen?.frame ?? .zero
    frozenView.isHidden = frozen == nil
  }

  private func redrawDim(arriving: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let path = CGMutablePath()
    path.addRect(bounds)
    if let selection {
      path.addPath(Self.roundedPath(selection))
    }
    dimLayer.frame = bounds
    dimLayer.path = path
    CATransaction.commit()
    let target: Float = isDimmed ? 1 : 0
    guard dimLayer.opacity != target else { return }
    if arriving, !MotionPreferences.reduceMotion {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = dimLayer.presentation()?.opacity ?? dimLayer.opacity
      fade.toValue = target
      fade.duration = Motion.scaled(Motion.quick)
      dimLayer.add(fade, forKey: "fade")
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dimLayer.opacity = target
    CATransaction.commit()
  }

  private func redraw() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    redrawDim(arriving: false)

    let rects = outlines + (selection.map { [$0] } ?? [])
    if drawsGlows { placeGlows(around: rects) }
    borders.forEach { $0.removeFromSuperlayer() }
    borders = drawsGlows ? [] : rects.flatMap { rect in
      [
        border(around: rect, width: AgentPaletteMetrics.screenSelectionGlowWidth, opacity: 0.35),
        border(around: rect, width: AgentPaletteMetrics.screenSelectionLineWidth, opacity: 1),
      ]
    }
    borders.forEach { fallbackView.layer?.addSublayer($0) }

    let handles = showsHandles ? selection.map { rect in Handle.allCases.map { $0.point(on: rect) } } ?? [] : []
    while handleLayers.count < Handle.allCases.count {
      let dot = Self.makeHandle()
      handlesView.layer?.addSublayer(dot)
      handleLayers.append(dot)
    }
    let side = AgentPaletteMetrics.screenSelectionHandleDiameter
    for (index, dot) in handleLayers.enumerated() {
      guard index < handles.count else {
        dot.isHidden = true
        continue
      }
      dot.isHidden = false
      dot.frame = CGRect(
        x: handles[index].x - side / 2, y: handles[index].y - side / 2, width: side, height: side)
    }
  }

  private func placeGlows(around rects: [CGRect]) {
    while glows.count > rects.count {
      glows.removeLast().removeFromSuperview()
    }
    while glows.count < rects.count {
      guard let glow = ScreenSelectionGlowView.make() else {
        drawsGlows = false
        glows.forEach { $0.removeFromSuperview() }
        glows = []
        return
      }
      addSubview(glow, positioned: .below, relativeTo: fallbackView)
      glows.append(glow)
    }
    let margin = ScreenSelectionGlowView.margin
    for (glow, rect) in zip(glows, rects) {
      glow.frame = rect.insetBy(dx: -margin, dy: -margin)
      glow.region = CGRect(x: margin, y: margin, width: rect.width, height: rect.height)
      glow.palette = palette
    }
  }

  private func border(around rect: CGRect, width: CGFloat, opacity: Float) -> CALayer {
    let room = width
    let frame = rect.insetBy(dx: -room, dy: -room)
    let gradient = CAGradientLayer()
    gradient.type = .conic
    gradient.frame = frame
    gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
    gradient.endPoint = CGPoint(x: 0.5, y: 0)
    let colors = palette.isEmpty ? [NSColor.white] : palette
    gradient.colors = (colors + [colors[0]]).map(\.cgColor)
    gradient.opacity = opacity
    let stroke = CAShapeLayer()
    stroke.frame = gradient.bounds
    stroke.path = Self.roundedPath(CGRect(origin: CGPoint(x: room, y: room), size: rect.size))
    stroke.lineWidth = width
    stroke.fillColor = nil
    stroke.strokeColor = NSColor.black.cgColor
    gradient.mask = stroke
    return gradient
  }

  private static func roundedPath(_ rect: CGRect) -> CGPath {
    let corner = min(AgentPaletteMetrics.screenSelectionCornerRadius, rect.width / 2, rect.height / 2)
    return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
  }

  private static func makeHandle() -> CAShapeLayer {
    let dot = CAShapeLayer()
    let side = AgentPaletteMetrics.screenSelectionHandleDiameter
    dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: side, height: side), transform: nil)
    dot.fillColor = NSColor.white.cgColor
    dot.shadowColor = NSColor.black.cgColor
    dot.shadowOpacity = 0.35
    dot.shadowRadius = 2
    dot.shadowOffset = .zero
    dot.isHidden = true
    return dot
  }
}

private final class OverlayLayerView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
