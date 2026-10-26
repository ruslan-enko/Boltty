import AppKit
import CoreImage
import QuartzCore

struct PaletteGlassGradientStop: Equatable {
  let color: NSColor
  let location: CGFloat

  init(color: NSColor, location: CGFloat) {
    self.color = color
    self.location = location
  }

  static func srgb(
    _ r: CGFloat,
    _ g: CGFloat,
    _ b: CGFloat,
    alpha: CGFloat,
    at location: CGFloat
  ) -> PaletteGlassGradientStop {
    PaletteGlassGradientStop(
      color: NSColor(srgbRed: r, green: g, blue: b, alpha: alpha),
      location: location
    )
  }
}

enum PaletteGlassRamp {
  static let resolution = 32

  static func resample(
    _ keyStops: [PaletteGlassGradientStop],
    count: Int = resolution
  ) -> [PaletteGlassGradientStop] {
    guard keyStops.count >= 2, count >= 2 else { return keyStops }
    let sorted = keyStops.sorted { $0.location < $1.location }

    let locations = sorted.map { $0.location }
    let srgb = sorted.map { $0.color.usingColorSpace(.sRGB) ?? $0.color }

    let alphas = srgb.map { $0.alphaComponent }
    let channels: [[CGFloat]] = [
      srgb.map { $0.redComponent * $0.alphaComponent },
      srgb.map { $0.greenComponent * $0.alphaComponent },
      srgb.map { $0.blueComponent * $0.alphaComponent },
    ]

    let alphaSpline = MonotoneSpline(x: locations, y: alphas)
    let channelSplines = channels.map { MonotoneSpline(x: locations, y: $0) }

    return (0..<count).map { index in
      let location = CGFloat(index) / CGFloat(count - 1)
      let alpha = min(max(alphaSpline.value(at: location), 0), 1)

      func unpremultiplied(_ spline: MonotoneSpline) -> CGFloat {
        guard alpha > 0 else { return 0 }
        return min(max(spline.value(at: location) / alpha, 0), 1)
      }

      return PaletteGlassGradientStop(
        color: NSColor(
          srgbRed: unpremultiplied(channelSplines[0]),
          green: unpremultiplied(channelSplines[1]),
          blue: unpremultiplied(channelSplines[2]),
          alpha: alpha
        ),
        location: location
      )
    }
  }

  struct MonotoneSpline {
    private let x: [CGFloat]
    private let y: [CGFloat]
    private let m: [CGFloat]

    init(x: [CGFloat], y: [CGFloat]) {
      self.x = x
      self.y = y

      let n = x.count
      guard n >= 2 else {
        self.m = Array(repeating: 0, count: n)
        return
      }

      var delta = [CGFloat](repeating: 0, count: n - 1)
      for i in 0..<(n - 1) {
        let h = x[i + 1] - x[i]
        delta[i] = h > 0 ? (y[i + 1] - y[i]) / h : 0
      }

      var tangents = [CGFloat](repeating: 0, count: n)
      tangents[0] = delta[0]
      tangents[n - 1] = delta[n - 2]
      for i in 1..<(n - 1) {
        tangents[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2
      }

      for i in 0..<(n - 1) {
        if delta[i] == 0 {
          tangents[i] = 0
          tangents[i + 1] = 0
          continue
        }
        let alpha = tangents[i] / delta[i]
        let beta = tangents[i + 1] / delta[i]
        let magnitude = alpha * alpha + beta * beta
        if magnitude > 9 {
          let scale = 3 / magnitude.squareRoot()
          tangents[i] = scale * alpha * delta[i]
          tangents[i + 1] = scale * beta * delta[i]
        }
      }

      self.m = tangents
    }

    func value(at location: CGFloat) -> CGFloat {
      guard let first = x.first, let last = x.last, x.count >= 2 else {
        return y.first ?? 0
      }
      if location <= first { return y[0] }
      if location >= last { return y[y.count - 1] }

      var index = 0
      for i in 0..<(x.count - 1) where location >= x[i] && location <= x[i + 1] {
        index = i
        break
      }

      let h = x[index + 1] - x[index]
      guard h > 0 else { return y[index] }
      let t = (location - x[index]) / h
      let t2 = t * t
      let t3 = t2 * t

      let h00 = 2 * t3 - 3 * t2 + 1
      let h10 = t3 - 2 * t2 + t
      let h01 = -2 * t3 + 3 * t2
      let h11 = t3 - t2

      return h00 * y[index]
        + h10 * h * m[index]
        + h01 * y[index + 1]
        + h11 * h * m[index + 1]
    }
  }
}

struct PaletteGlassBottomHighlight: Equatable {
  let stops: [PaletteGlassGradientStop]
  let compositingFilter: String?

  init(stops: [PaletteGlassGradientStop], compositingFilter: String?) {
    self.stops = stops
    self.compositingFilter = compositingFilter
  }

}

struct PaletteGlassVerticalOverlay: Equatable {
  let stops: [PaletteGlassGradientStop]
  let reducedTransparencyStops: [PaletteGlassGradientStop]
  let topColor: NSColor?
  let bottomColor: NSColor?
  let bottomOpacity: CGFloat
  let baseFillColor: NSColor?
  let usesSoftLightBlend: Bool
  let bottomHighlight: PaletteGlassBottomHighlight?

  let glassTintAlpha: CGFloat?

  static let bolttyAIPromptRamp = PaletteGlassVerticalOverlay.multiStop(
    PaletteGlassRamp.resample([
      .srgb(0, 0, 0, alpha: 1, at: 0),
      .srgb(0, 0, 0, alpha: 0, at: 1),
    ]),
    reducedTransparencyStops: PaletteGlassRamp.resample([
      .srgb(0, 0, 0, alpha: 1, at: 0),
      .srgb(0, 0, 0, alpha: 0.92, at: 1),
    ]),
    glassTintAlpha: 0
  )

  static func multiStop(
    _ stops: [PaletteGlassGradientStop],
    reducedTransparencyStops: [PaletteGlassGradientStop] = [],
    baseFillColor: NSColor? = nil,
    bottomHighlight: PaletteGlassBottomHighlight? = nil,
    glassTintAlpha: CGFloat? = nil
  ) -> PaletteGlassVerticalOverlay {
    PaletteGlassVerticalOverlay(
      stops: stops,
      reducedTransparencyStops: reducedTransparencyStops,
      topColor: stops.first?.color,
      bottomColor: stops.last?.color,
      bottomOpacity: 1,
      baseFillColor: baseFillColor,
      usesSoftLightBlend: false,
      bottomHighlight: bottomHighlight,
      glassTintAlpha: glassTintAlpha
    )
  }

  func stops(reduceTransparency: Bool) -> [PaletteGlassGradientStop] {
    guard reduceTransparency, !reducedTransparencyStops.isEmpty else { return stops }
    return reducedTransparencyStops
  }

  init(bottomOpacity: CGFloat) {
    self.stops = []
    self.reducedTransparencyStops = []
    self.topColor = nil
    self.bottomColor = nil
    self.bottomOpacity = bottomOpacity
    self.baseFillColor = nil
    self.usesSoftLightBlend = false
    self.bottomHighlight = nil
    self.glassTintAlpha = nil
  }

  init(
    topColor: NSColor?,
    bottomColor: NSColor?,
    bottomOpacity: CGFloat = 1,
    baseFillColor: NSColor? = nil,
    usesSoftLightBlend: Bool = false,
    bottomHighlight: PaletteGlassBottomHighlight? = nil,
    glassTintAlpha: CGFloat? = nil
  ) {
    self.stops = []
    self.reducedTransparencyStops = []
    self.topColor = topColor
    self.bottomColor = bottomColor
    self.bottomOpacity = bottomOpacity
    self.baseFillColor = baseFillColor
    self.usesSoftLightBlend = usesSoftLightBlend
    self.bottomHighlight = bottomHighlight
    self.glassTintAlpha = glassTintAlpha
  }

  private init(
    stops: [PaletteGlassGradientStop],
    reducedTransparencyStops: [PaletteGlassGradientStop],
    topColor: NSColor?,
    bottomColor: NSColor?,
    bottomOpacity: CGFloat,
    baseFillColor: NSColor?,
    usesSoftLightBlend: Bool,
    bottomHighlight: PaletteGlassBottomHighlight?,
    glassTintAlpha: CGFloat?
  ) {
    self.stops = stops
    self.reducedTransparencyStops = reducedTransparencyStops
    self.topColor = topColor
    self.bottomColor = bottomColor
    self.bottomOpacity = bottomOpacity
    self.baseFillColor = baseFillColor
    self.usesSoftLightBlend = usesSoftLightBlend
    self.bottomHighlight = bottomHighlight
    self.glassTintAlpha = glassTintAlpha
  }

}

private final class PaletteGlassOverlayView: NSView {
  override var allowsVibrancy: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

fileprivate final class PaletteGlassContentView: NSView {
  override var allowsVibrancy: Bool { false }
}

enum PaletteGlassMaterialStyle: Equatable, Sendable {
  case regular
  case clear
}

struct PaletteSurfaceStyle: Equatable {
  let material: PaletteGlassMaterialStyle
  let wash: PaletteGlassVerticalOverlay?
  let drawsOuterShadow: Bool
  let edgeAlpha: CGFloat
  let glassTintAlpha: CGFloat?

  init(
    material: PaletteGlassMaterialStyle,
    wash: PaletteGlassVerticalOverlay? = nil,
    drawsOuterShadow: Bool = true,
    edgeAlpha: CGFloat = PaletteGlassHost.edgeHighlightAlpha,
    glassTintAlpha: CGFloat? = nil
  ) {
    self.material = material
    self.wash = wash
    self.drawsOuterShadow = drawsOuterShadow
    self.edgeAlpha = edgeAlpha
    self.glassTintAlpha = glassTintAlpha
  }

  static let bolttyAI = PaletteSurfaceStyle(
    material: .regular,
    drawsOuterShadow: false,
    edgeAlpha: 0,
    glassTintAlpha: 0
  )

  static let bolttyAIPrompt = PaletteSurfaceStyle(
    material: .regular,
    wash: .bolttyAIPromptRamp,
    drawsOuterShadow: false,
    edgeAlpha: 0,
    glassTintAlpha: 0
  )

  static let bolttyAIControl = bolttyAI

  static let bolttyAIComposer = bolttyAI

  static let plain = PaletteSurfaceStyle(material: .regular)
}

final class PaletteGlassHost: NSView {
  var cornerRadius: CGFloat {
    didSet {
      applyCornerRadius()
      needsLayout = true
    }
  }

  private var effectiveCornerCurve: CALayerCornerCurve {
    guard !bounds.isEmpty else { return .continuous }
    return AgentPaletteMetrics.cornerCurve(
      radius: cornerRadius,
      shorterSide: min(bounds.width, bounds.height)
    )
  }

  var cornerCurveForTesting: CALayerCornerCurve { renderedCornerCurve }

  var renderedCornerRadius: CGFloat { effectiveCornerRadius }
  var renderedCornerCurve: CALayerCornerCurve { effectiveCornerCurve }

  var effectIsInteractive: Bool {
    didSet { applyInteractionState() }
  }

  private(set) var hostedContentView: NSView = PaletteGlassContentView()
  private let hostsContentInGlass: Bool
  var hostsContentInSystemGlassForTesting: Bool {
    guard let glass = effectView as? NSGlassEffectView else { return false }
    return glass.contentView === hostedContentView
  }

  var isUsingGlassForTesting: Bool {
    effectView?.isHidden == false && colorLayerView.isHidden
  }

  var usesSystemGlass: Bool {
    !isHidden && effectView is NSGlassEffectView && effectView?.isHidden == false
  }

  var effectViewClipsToCornerForTesting: Bool { effectView?.layer?.masksToBounds ?? false }

  var glassMaterialStyleForTesting: PaletteGlassMaterialStyle { glassStyle }

  var surfaceStyleForTesting: PaletteSurfaceStyle { style }

  /// The style the host wears now — what a caller compares a wanted one with.
  var currentSurfaceStyle: PaletteSurfaceStyle { style }

  var hasVerticalOverlayForTesting: Bool {
    verticalOverlay != nil && !verticalOverlayView.isHidden
  }

  var verticalOverlayColorsForTesting: [CGColor] {
    verticalOverlayGradientLayer.colors as? [CGColor] ?? []
  }

  var verticalOverlayLocationsForTesting: [CGFloat] {
    verticalOverlayGradientLayer.locations?.map { CGFloat($0.doubleValue) } ?? []
  }

  var usesBottomHighlightScreenBlendForTesting: Bool {
    bottomHighlightGradientLayer.compositingFilter as? String == "screenBlendMode"
  }

  var isBottomHighlightHiddenForTesting: Bool {
    bottomHighlightGradientLayer.isHidden
  }

  var glassTintAlphaForTesting: CGFloat {
    if let glass = effectView as? NSGlassEffectView {
      guard let tint = glass.tintColor else { return 0 }
      guard tint.type == .componentBased else { return .nan }
      return tint.usingColorSpace(.sRGB)?.alphaComponent ?? 0
    }
    return 0
  }

  var usesSoftLightWashForTesting: Bool {
    verticalOverlayGradientLayer.compositingFilter as? String == "softLightBlendMode"
  }

  var innerTopShadowColorsForTesting: [CGColor] {
    innerTopShadowLayer.colors as? [CGColor] ?? []
  }

  var innerTopShadowFrameForTesting: CGRect {
    innerTopShadowLayer.frame
  }

  /// Nothing over the glass may carry filters or rasterize: an offscreen pass turns the material opaque black.
  var overlayAvoidsOffscreenPassForTesting: Bool {
    guard let overlay = verticalOverlayView.layer else { return false }
    let layers = [overlay, verticalOverlayGradientLayer, innerTopShadowLayer]
    return layers.allSatisfy { $0.filters == nil && !$0.shouldRasterize }
  }

  var shadowOpacityForTesting: Float {
    layer?.shadowOpacity ?? 0
  }

  var shadowRadiusForTesting: CGFloat {
    layer?.shadowRadius ?? 0
  }

  var shadowOffsetForTesting: CGSize {
    layer?.shadowOffset ?? .zero
  }

  var isVerticalOverlayBelowContentForTesting: Bool {
    guard
      let overlayIndex = subviews.firstIndex(of: verticalOverlayView),
      let contentIndex = subviews.firstIndex(of: hostedContentView)
    else { return false }
    return overlayIndex < contentIndex
  }

  var isVerticalOverlayInFrontOfGlassForTesting: Bool {
    guard let effectView,
          let glassIndex = subviews.firstIndex(of: effectView),
          let overlayIndex = subviews.firstIndex(of: verticalOverlayView)
    else { return false }
    return overlayIndex > glassIndex
  }

  var effectCornerRadiusForTesting: CGFloat {
    if let glass = effectView as? NSGlassEffectView {
      return glass.cornerRadius
    }
    return effectView?.layer?.cornerRadius ?? 0
  }

  private(set) var shadowCornerRadiusForTesting: CGFloat = 0

  private var style: PaletteSurfaceStyle
  private var drawsOuterShadow: Bool
  private var glassStyle: PaletteGlassMaterialStyle
  private var verticalOverlay: PaletteGlassVerticalOverlay?
  /// The wash that is fading out — still drawn, no longer the style's.
  private var fadingOutOverlay: PaletteGlassVerticalOverlay?
  private var washFadeGeneration = 0
  private var effectView: NSView?
  private let colorLayerView = NSView(frame: .zero)
  private let verticalOverlayView = PaletteGlassOverlayView(frame: .zero)
  private let verticalOverlayGradientLayer = CAGradientLayer()
  private let bottomHighlightGradientLayer = CAGradientLayer()
  private let innerTopShadowLayer = CAGradientLayer()
  private var showsGlass = true

  init(
    content: NSView,
    cornerRadius: CGFloat,
    style: PaletteSurfaceStyle = .plain,
    hostsContentInGlass: Bool = false
  ) {
    self.cornerRadius = cornerRadius
    self.hostsContentInGlass = hostsContentInGlass
    self.effectIsInteractive = false
    self.style = style
    self.drawsOuterShadow = style.drawsOuterShadow
    self.glassStyle = style.material
    self.verticalOverlay = hostsContentInGlass ? nil : style.wash
    super.init(frame: .zero)

    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.masksToBounds = false
    setupEffect(with: content)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    applyCornerRadius()
    ensureStackingOrder()
    layoutVerticalOverlayGradient()
    applyOuterShadow()
    applyEdge()
  }

  private func layoutVerticalOverlayGradient() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let bounds = verticalOverlayView.bounds
    for layer in [verticalOverlayGradientLayer, bottomHighlightGradientLayer] {
      layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      layer.frame = bounds
      layer.contentsScale = scale
      applyContinuousCorner(to: layer, radius: effectiveCornerRadius, masksToBounds: true)
    }
    layoutInnerTopShadow(in: bounds, scale: scale)
    applyCornerRadius()
    applyVerticalOverlayColors()
    CATransaction.commit()
  }

  private func layoutInnerTopShadow(in bounds: CGRect, scale: CGFloat) {
    let height = min(Self.innerTopShadowHeight, bounds.height)
    innerTopShadowLayer.frame = CGRect(
      x: 0,
      y: bounds.maxY - height,
      width: bounds.width,
      height: height
    )
    innerTopShadowLayer.contentsScale = scale
  }


  static let innerTopShadowHeight: CGFloat = 14

  private func applyContinuousCorner(
    to layer: CALayer?,
    radius: CGFloat,
    masksToBounds: Bool = false
  ) {
    guard let layer else { return }
    layer.cornerRadius = radius
    layer.cornerCurve = effectiveCornerCurve
    layer.masksToBounds = masksToBounds
  }

  private func ensureStackingOrder() {
    if let effectView, effectView.superview === self {
      addSubview(effectView, positioned: .below, relativeTo: verticalOverlayView)
    }
    if verticalOverlayView.superview === self {
      addSubview(verticalOverlayView, positioned: .above, relativeTo: effectView)
    }
    if !hostsContentInGlass, hostedContentView.superview === self {
      addSubview(hostedContentView, positioned: .above, relativeTo: verticalOverlayView)
    }
    colorLayerView.layer?.zPosition = 0
    effectView?.layer?.zPosition = 1
    verticalOverlayView.layer?.zPosition = 2
    hostedContentView.layer?.zPosition = 10
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyAppearance()
    needsLayout = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
    needsLayout = true
  }

  static let reducedTransparencyFill = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

  func apply(showsGlass: Bool) {
    self.showsGlass = showsGlass
    renderBackgroundStyle()
  }

  private func setupEffect(with content: NSView) {
    hostedContentView.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    hostedContentView.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: hostedContentView.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: hostedContentView.trailingAnchor),
      content.topAnchor.constraint(equalTo: hostedContentView.topAnchor),
      content.bottomAnchor.constraint(equalTo: hostedContentView.bottomAnchor)
    ])

    let glass = NSGlassEffectView()
    glass.style = glassStyle == .clear ? .clear : .regular
    glass.cornerRadius = cornerRadius
    glass.translatesAutoresizingMaskIntoConstraints = false
    if hostsContentInGlass {
      glass.contentView = hostedContentView
    } else {
      let glassSpacer = NSView(frame: .zero)
      glassSpacer.translatesAutoresizingMaskIntoConstraints = false
      glass.contentView = glassSpacer
    }
    effectView = glass

    colorLayerView.wantsLayer = true
    colorLayerView.translatesAutoresizingMaskIntoConstraints = false
    colorLayerView.isHidden = true
    addSubview(colorLayerView)
    pinEdges(of: colorLayerView, to: self)

    if let effectView {
      addSubview(effectView)
      pinEdges(of: effectView, to: self)
    }

    verticalOverlayView.wantsLayer = true
    verticalOverlayView.translatesAutoresizingMaskIntoConstraints = false
    applyContinuousCorner(to: verticalOverlayView.layer, radius: cornerRadius, masksToBounds: true)
    verticalOverlayView.layer?.backgroundColor = NSColor.clear.cgColor

    configureGradientAxis(verticalOverlayGradientLayer)
    configureGradientAxis(bottomHighlightGradientLayer)
    bottomHighlightGradientLayer.isHidden = true

    configureGradientAxis(innerTopShadowLayer)
    applyInnerTopShadowColors()

    applyVerticalOverlayColors()
    verticalOverlayView.layer?.addSublayer(verticalOverlayGradientLayer)
    verticalOverlayView.layer?.addSublayer(bottomHighlightGradientLayer)
    verticalOverlayView.layer?.addSublayer(innerTopShadowLayer)
    addSubview(verticalOverlayView)
    pinEdges(of: verticalOverlayView, to: self)

    hostedContentView.wantsLayer = true
    hostedContentView.layer?.backgroundColor = NSColor.clear.cgColor
    if hostedContentView.superview == nil {
      addSubview(hostedContentView)
      pinEdges(of: hostedContentView, to: self)
    }

    ensureStackingOrder()

    applyCornerRadius()
    applyAppearance()
    applyInteractionState()
    renderBackgroundStyle()
  }

  private func configureGradientAxis(_ layer: CAGradientLayer) {
    layer.isGeometryFlipped = false
    layer.startPoint = CGPoint(x: 0.5, y: 1)
    layer.endPoint = CGPoint(x: 0.5, y: 0)
  }

  private func pinEdges(of child: NSView, to parent: NSView) {
    NSLayoutConstraint.activate([
      child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
      child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
      child.topAnchor.constraint(equalTo: parent.topAnchor),
      child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
    ])
  }

  private func renderBackgroundStyle() {
    let showGlass = showsGlass
    let solidColor = Self.reducedTransparencyFill

    effectView?.isHidden = !showGlass
    verticalOverlayView.isHidden = !showGlass || (verticalOverlay ?? fadingOutOverlay) == nil

    if showGlass {
      colorLayerView.isHidden = true
      colorLayerView.layer?.backgroundColor = .clear
    } else {
      colorLayerView.isHidden = false
      colorLayerView.layer?.backgroundColor = solidColor.cgColor
      colorLayerView.alphaValue = 1
    }

    applyEdge()
    applyInnerTopShadowColors()
    applyVerticalOverlayColors()
  }

  private var effectiveCornerRadius: CGFloat {
    guard !bounds.isEmpty else { return cornerRadius }
    return min(cornerRadius, min(bounds.width, bounds.height) / 2)
  }

  private func applyCornerRadius() {
    let radius = effectiveCornerRadius

    (effectView as? NSGlassEffectView)?.cornerRadius = radius
    if let effectView {
      effectView.wantsLayer = true
      applyContinuousCorner(to: effectView.layer, radius: radius, masksToBounds: false)
    }
    applyContinuousCorner(to: colorLayerView.layer, radius: radius, masksToBounds: true)
    applyContinuousCorner(to: verticalOverlayView.layer, radius: radius, masksToBounds: true)
    applyContinuousCorner(to: verticalOverlayGradientLayer, radius: radius, masksToBounds: true)
    applyContinuousCorner(to: bottomHighlightGradientLayer, radius: radius, masksToBounds: true)
    applyContinuousCorner(to: layer, radius: radius, masksToBounds: false)
  }

  static let defaultGlassTintAlpha: CGFloat = 0.52

  var effectiveGlassTintAlpha: CGFloat {
    verticalOverlay?.glassTintAlpha ?? style.glassTintAlpha ?? Self.defaultGlassTintAlpha
  }

  static var prefersReducedTransparency: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
  }

  func apply(surfaceStyle: PaletteSurfaceStyle) {
    guard surfaceStyle != style else { return }
    let previousWash = verticalOverlay
    style = surfaceStyle
    drawsOuterShadow = surfaceStyle.drawsOuterShadow
    glassStyle = surfaceStyle.material
    verticalOverlay = surfaceStyle.wash
    prepareWashFade(from: previousWash, to: surfaceStyle.wash)
    renderBackgroundStyle()
    applyAppearance()
    applyCornerRadius()
    needsLayout = true
    runWashFade(to: surfaceStyle.wash)
  }

  /// How long a wash takes to come or go: a little longer than
  /// the shell's own spring, so the ramp is still thinning as the glass lands.
  static let washFadeDuration: TimeInterval = 0.32

  /// A wash that is going away stays drawn until its fade has run — the
  /// first screen's black ramp used to vanish in one frame while the shell
  /// was still growing into the list, and the two read as separate cuts.
  private func prepareWashFade(
    from old: PaletteGlassVerticalOverlay?, to new: PaletteGlassVerticalOverlay?
  ) {
    washFadeGeneration += 1
    guard window != nil, !MotionPreferences.reduceMotion, old != new else {
      fadingOutOverlay = nil
      verticalOverlayView.layer?.removeAnimation(forKey: "washFade")
      verticalOverlayView.layer?.opacity = 1
      return
    }
    fadingOutOverlay = (new == nil) ? old : nil
  }

  private func runWashFade(to new: PaletteGlassVerticalOverlay?) {
    guard let layer = verticalOverlayView.layer, window != nil, !MotionPreferences.reduceMotion else {
      return
    }
    let start = layer.presentation()?.opacity ?? layer.opacity
    let target: Float = new == nil ? 0 : 1
    guard fadingOutOverlay != nil || new != nil, start != target else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = target
    CATransaction.commit()

    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = new == nil ? max(start, 0.001) : (start >= 1 ? 0 : start)
    fade.toValue = target
    fade.duration = Self.washFadeDuration
    fade.timingFunction = Motion.standardCurve
    layer.add(fade, forKey: "washFade")

    guard new == nil else { return }
    let generation = washFadeGeneration
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Motion.scaled(Self.washFadeDuration) + 0.05
    ) { [weak self] in
      guard let self, self.washFadeGeneration == generation, self.verticalOverlay == nil
      else { return }
      self.fadingOutOverlay = nil
      self.verticalOverlayView.layer?.opacity = 1
      self.renderBackgroundStyle()
      self.applyVerticalOverlayColors()
    }
  }

  private func applyAppearance() {
    applyVerticalOverlayColors()
    if let glass = effectView as? NSGlassEffectView {
      let tint = effectiveGlassTintAlpha
      glass.tintColor = tint > 0 ? NSColor.black.withAlphaComponent(tint) : nil
    }
  }

  private func applyVerticalOverlayColors() {
    guard let verticalOverlay = verticalOverlay ?? fadingOutOverlay else {
      verticalOverlayGradientLayer.colors = nil
      verticalOverlayGradientLayer.compositingFilter = nil
      verticalOverlayGradientLayer.locations = [0, 1]
      bottomHighlightGradientLayer.isHidden = true
      bottomHighlightGradientLayer.colors = nil
      verticalOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
      return
    }

    if let base = verticalOverlay.baseFillColor {
      verticalOverlayView.layer?.backgroundColor =
        base.usingColorSpace(.sRGB)?.cgColor ?? base.cgColor
    } else {
      verticalOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    let washStops = verticalOverlay.stops(reduceTransparency: Self.prefersReducedTransparency)
    if !washStops.isEmpty {
      verticalOverlayGradientLayer.compositingFilter = nil
      applyStops(washStops, to: verticalOverlayGradientLayer)
    } else {
      verticalOverlayGradientLayer.compositingFilter =
        verticalOverlay.usesSoftLightBlend ? "softLightBlendMode" : nil
      verticalOverlayGradientLayer.locations = [0, 1]
      if let top = verticalOverlay.topColor, let bottom = verticalOverlay.bottomColor {
        verticalOverlayGradientLayer.colors = [
          top.usingColorSpace(.sRGB)?.cgColor ?? top.cgColor,
          bottom.usingColorSpace(.sRGB)?.cgColor ?? bottom.cgColor,
        ]
      } else {
        verticalOverlayGradientLayer.colors = [
          NSColor.black.withAlphaComponent(0).cgColor,
          NSColor.black.withAlphaComponent(verticalOverlay.bottomOpacity).cgColor,
        ]
      }
    }

    if let highlight = verticalOverlay.bottomHighlight, !highlight.stops.isEmpty {
      bottomHighlightGradientLayer.isHidden = false
      bottomHighlightGradientLayer.compositingFilter = highlight.compositingFilter
      applyStops(highlight.stops, to: bottomHighlightGradientLayer)
    } else {
      bottomHighlightGradientLayer.isHidden = true
      bottomHighlightGradientLayer.colors = nil
      bottomHighlightGradientLayer.compositingFilter = nil
    }
  }

  private func applyStops(_ stops: [PaletteGlassGradientStop], to layer: CAGradientLayer) {
    layer.colors = stops.map { stop in
      stop.color.usingColorSpace(.sRGB)?.cgColor ?? stop.color.cgColor
    }
    layer.locations = stops.map { NSNumber(value: Double($0.location)) }
  }

  private func applyInnerTopShadowColors() {
    let visible = showsGlass
    innerTopShadowLayer.isHidden = !visible
    guard visible else {
      innerTopShadowLayer.colors = nil
      return
    }
    applyStops(
      PaletteGlassRamp.resample([
        .srgb(0, 0, 0, alpha: 0.16, at: 0),
        .srgb(0, 0, 0, alpha: 0, at: 1),
      ]),
      to: innerTopShadowLayer
    )
  }

  private func applyInteractionState() {
    if #available(macOS 27.0, *), let glass = effectView as? NSGlassEffectView {
      glass.effectIsInteractive = effectIsInteractive
    }
  }

  private func applyOuterShadow() {
    guard let layer else { return }

    guard drawsOuterShadow, !bounds.isEmpty else {
      layer.shadowOpacity = 0
      layer.shadowPath = nil
      shadowCornerRadiusForTesting = 0
      return
    }

    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOpacity = Self.floatingShadowOpacity
    layer.shadowRadius = Self.floatingShadowRadius
    layer.shadowOffset = Self.floatingShadowOffset
    layer.shadowPath = CGPath(
      roundedRect: bounds,
      cornerWidth: effectiveCornerRadius,
      cornerHeight: effectiveCornerRadius,
      transform: nil
    )
    shadowCornerRadiusForTesting = effectiveCornerRadius
  }

  static let floatingShadowOpacity: Float = 0.40
  static let floatingShadowRadius: CGFloat = 13.4
  static let floatingShadowOffset = CGSize(width: 0, height: -1.3)

  static let ambientShadowOpacity: Float = 0.35
  static let ambientShadowRadius: CGFloat = 30
  static let ambientShadowOffset = CGSize(width: 0, height: -14)

  nonisolated static let edgeHighlightAlpha: CGFloat = 0.20

  private func applyEdge() {
    guard let layer else { return }

    applyContinuousCorner(to: layer, radius: effectiveCornerRadius, masksToBounds: false)
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    layer.borderWidth = style.edgeAlpha > 0 ? 1 / max(scale, 1) : 0
    layer.borderColor = NSColor.white.withAlphaComponent(style.edgeAlpha).cgColor
  }
}
