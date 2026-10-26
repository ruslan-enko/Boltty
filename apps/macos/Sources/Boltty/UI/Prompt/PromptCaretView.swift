import AppKit
import QuartzCore

@MainActor
final class PromptCaretView: NSView {
  struct Look: Equatable {
    var barSize: CGSize
    var glowMargin: CGFloat
    var glowSpread: CGFloat
    var glowBlur: CGFloat
    var glowAlpha: CGFloat
  }

  private let blinkLayer = CALayer()
  private let glowLayer = CALayer()
  private let barLayer = CALayer()
  private var look: Look?
  private var renderedScale: CGFloat = 0

  var color: NSColor = .white {
    didSet { barLayer.backgroundColor = color.cgColor }
  }
  var glowColors: [NSColor] = [] {
    didSet { if glowColors != oldValue { renderedScale = 0; renderGlow() } }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = false
    for sublayer in [blinkLayer, glowLayer, barLayer] {
      sublayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
                          "opacity": NSNull(), "backgroundColor": NSNull()]
    }
    blinkLayer.addSublayer(glowLayer)
    blinkLayer.addSublayer(barLayer)
    layer?.addSublayer(blinkLayer)
    barLayer.backgroundColor = color.cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  nonisolated static func size(for look: Look) -> CGSize {
    CGSize(width: look.barSize.width + look.glowMargin * 2,
           height: look.barSize.height + look.glowMargin * 2)
  }

  func apply(_ look: Look) {
    guard look != self.look else { return }
    self.look = look
    renderedScale = 0
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let look else { return }
    blinkLayer.frame = bounds
    glowLayer.frame = bounds
    barLayer.frame = CGRect(
      x: look.glowMargin, y: look.glowMargin,
      width: look.barSize.width, height: look.barSize.height)
    barLayer.cornerRadius = look.barSize.width / 2
    renderGlow()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    renderedScale = 0
    renderGlow()
  }

  private func renderGlow() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    guard let look, scale != renderedScale, glowColors.count >= 3 else { return }
    renderedScale = scale
    glowLayer.contentsScale = scale
    glowLayer.contents = Self.glowImage(look: look, colors: glowColors, scale: scale)
  }

  // MARK: Blinking

  func restartBlink(delay: TimeInterval, period: TimeInterval) {
    blinkLayer.removeAnimation(forKey: "blink")
    blinkLayer.opacity = 1
    let blink = CAKeyframeAnimation(keyPath: "opacity")
    blink.values = [1, 1, 0, 0, 1]
    blink.keyTimes = [0, 0.5, 0.62, 0.88, 1]
    blink.calculationMode = .linear
    blink.duration = period
    blink.repeatCount = .infinity
    blink.beginTime = blinkLayer.convertTime(CACurrentMediaTime(), from: nil) + delay
    blink.fillMode = .backwards
    blink.isRemovedOnCompletion = false
    blinkLayer.add(blink, forKey: "blink")
  }

  var isBlinkingForTesting: Bool { blinkLayer.animation(forKey: "blink") != nil }
  var barFrameForTesting: CGRect { convert(barLayer.frame, to: superview) }

  // MARK: The light

  nonisolated static let haloBlurRatio: CGFloat = 3
  nonisolated static let haloStrength: CGFloat = 0.6
  nonisolated static let endPaleness: CGFloat = 0.5

  nonisolated static func glowImage(look: Look, colors: [NSColor], scale: CGFloat) -> CGImage? {
    let size = Self.size(for: look)
    let width = Int(ceil(size.width * scale))
    let height = Int(ceil(size.height * scale))
    guard width > 0, height > 0,
          let maskContext = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }

    maskContext.setFillColor(gray: 0, alpha: 1)
    maskContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let bar = CGRect(
      x: look.glowMargin * scale, y: look.glowMargin * scale,
      width: look.barSize.width * scale, height: look.barSize.height * scale)
      .insetBy(dx: -look.glowSpread * scale, dy: -look.glowSpread * scale)
    let away = CGFloat(width) * 4
    for (blur, strength) in [(look.glowBlur * haloBlurRatio, haloStrength), (look.glowBlur, 1)] {
      maskContext.setShadow(
        offset: CGSize(width: away, height: 0), blur: blur * scale,
        color: CGColor(gray: 1, alpha: strength))
      maskContext.addPath(CGPath(
        roundedRect: bar.offsetBy(dx: -away, dy: 0),
        cornerWidth: bar.width / 2, cornerHeight: bar.width / 2, transform: nil))
      maskContext.setFillColor(gray: 1, alpha: 1)
      maskContext.fillPath()
    }
    guard let mask = maskContext.makeImage(),
          let srgb = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: mask)
    let pale = colors[1]
    let ends = [colors[0], colors[2]].map { $0.blended(withFraction: endPaleness, of: pale) ?? $0 }
    let stops = [ends[0], ends[0], pale, ends[1], ends[1]]
      .compactMap { $0.usingColorSpace(.sRGB)?.withAlphaComponent(look.glowAlpha).cgColor }
    let span = look.barSize.height + look.glowMargin * 2
    let top = look.glowMargin / span
    let foot = 1 - top
    guard stops.count == 5,
          let gradient = CGGradient(
            colorsSpace: srgb, colors: stops as CFArray,
            locations: [0, top, 0.5, foot, 1])
    else { return nil }
    context.drawLinearGradient(
      gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
    return context.makeImage()
  }
}
