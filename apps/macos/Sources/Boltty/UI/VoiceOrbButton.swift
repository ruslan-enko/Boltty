import AppKit
import QuartzCore

final class GlassCircleVoiceButton: PaletteIconButton {
  private(set) var isListening = false

  var isListeningForTesting: Bool { isListening }
  var smoothedLevelForTesting: CGFloat { smoothedLevel }
  var barHeightsForTesting: [CGFloat] { bars.map { $0.bounds.height } }
  var barColorsForTesting: [CGColor] { bars.compactMap(\.backgroundColor) }

  private let chrome = NSView()
  var usesSystemGlass: Bool { isBordered && bezelStyle == .glass }
  var usesSystemGlassForTesting: Bool { usesSystemGlass }
  private var bars: [CALayer] = []

  private var smoothedLevel: CGFloat = 0
  var showsMicrophoneGlyphForTesting: Bool { image != nil }
  var drawsBarsForTesting: Bool { !chrome.isHidden }
  var restingGlyphPointSize: CGFloat = ComposerControlGroup.pointSize(chat: false) {
    didSet { if restingGlyphPointSize != oldValue { syncRestingGlyph() } }
  }
  private func syncRestingGlyph() {
    let mic = !usesSystemGlass
    chrome.isHidden = mic
    image = mic
      ? NSImage(systemSymbolName: "mic", accessibilityDescription: "Dictate prompt")?
          .withSymbolConfiguration(.init(pointSize: restingGlyphPointSize, weight: .medium))
      : nil
  }
  private var phase: CGFloat = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    restingBackground = .clear
    hoverBackground = .clear
    hoverBackdropBlurRadius = 0
    restingTint = AgentPaletteMetrics.voiceOrbGlyphColor
    hoverTint = PaletteInk.primary

    title = ""
    image = nil
    imagePosition = .imageOnly

    chrome.wantsLayer = true
    borderShape = .circle
    controlSize = .extraLarge
    applyBezel(glass: true)
    addSubview(chrome)

    buildBars()
    applyRestingBackground()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func applyBezel(glass: Bool) {
    isBordered = glass
    bezelStyle = glass ? .glass : .regularSquare
    pressScale = glass ? 1 : AgentPaletteMetrics.controlPressedScale
  }

  func setShowsGlass(_ showsGlass: Bool) {
    guard usesSystemGlass != showsGlass else { return }
    applyBezel(glass: showsGlass)
    syncRestingGlyph()
    if showsGlass {
      restingTint = AgentPaletteMetrics.voiceOrbGlyphColor
      hoverTint = PaletteInk.primary
      disabledTint = nil
    } else {
      ComposerControlGroup.style(self)
    }
    needsLayout = true
  }

  override func applyTint() {
    super.applyTint()
    applyBarColors()
  }

  func setListening(_ listening: Bool) {
    guard listening != isListening else { return }
    isListening = listening
    if !listening {
      smoothedLevel = 0
      phase = 0
      layoutBars()
    }
    applyBarColors()
  }

  func setAudioLevel(_ level: CGFloat) {
    let clamped = min(1, max(0, level))
    let rate = clamped > smoothedLevel
      ? AgentPaletteMetrics.voiceOrbLevelAttack
      : AgentPaletteMetrics.voiceOrbLevelRelease
    smoothedLevel += (clamped - smoothedLevel) * rate
    guard isListening else { return }
    phase += AgentPaletteMetrics.voiceOrbBarPhaseStep
    layoutBars()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    chrome.frame = CGRect(origin: .zero, size: bounds.size)
    layoutBars()
    CATransaction.commit()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyBarColors()
  }

  // MARK: - Bars

  private func buildBars() {
    bars = (0..<AgentPaletteMetrics.voiceOrbBarCount).map { _ in
      let bar = CALayer()
      bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      chrome.layer?.addSublayer(bar)
      return bar
    }
    applyBarColors()
  }

  private func layoutBars() {
    guard !bars.isEmpty else { return }
    let width = AgentPaletteMetrics.voiceOrbBarWidth
    let spacing = usesSystemGlass
      ? AgentPaletteMetrics.voiceOrbBarSpacing
      : AgentPaletteMetrics.restingWaveformBarSpacing
    let total = CGFloat(bars.count) * width + CGFloat(bars.count - 1) * spacing
    let originX = (bounds.width - total) / 2
    let centreY = bounds.height / 2
    let level = isListening ? smoothedLevel : 0

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, bar) in bars.enumerated() {
      let resting = AgentPaletteMetrics.voiceOrbBarProfile[
        index % AgentPaletteMetrics.voiceOrbBarProfile.count
      ] * (usesSystemGlass
        ? AgentPaletteMetrics.voiceOrbBarHeight
        : AgentPaletteMetrics.restingWaveformGlyphSize.height)
      let wave = sin(phase + CGFloat(index) * AgentPaletteMetrics.voiceOrbBarPhaseSpread)
      let swing = 1 + AgentPaletteMetrics.voiceOrbBarSwing * level * wave
      let height = max(width, resting * swing)
      bar.bounds = CGRect(x: 0, y: 0, width: width, height: height)
      bar.applyPaletteCorner(radius: width / 2)
      bar.position = CGPoint(x: originX + CGFloat(index) * (width + spacing) + width / 2, y: centreY)
    }
    CATransaction.commit()
  }

  private func applyBarColors() {
    let tint = contentTintColor ?? restingTint
    var resolved = tint
    effectiveAppearance.performAsCurrentDrawingAppearance {
      resolved = tint.usingColorSpace(.sRGB) ?? tint
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bars.forEach { $0.backgroundColor = resolved.cgColor }
    CATransaction.commit()
  }

  // MARK: - Colour wheel
}
