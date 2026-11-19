import AppKit
import QuartzCore

final class VoiceRecordingControls: NSView {
  var onCancel: (() -> Void)?
  var onConfirm: (() -> Void)?

  private let cancelButton = PaletteIconButton()
  private let confirmButton = PaletteIconButton()
  private let timerLabel = NSTextField(labelWithString: "0:00")
  private let meter = VoiceLevelMeter(frame: .zero)
  private let row = NSStackView()
  private let pillGlass = PaletteGlassHost(
    content: NSView(),
    cornerRadius: AgentPaletteMetrics.voiceControlsCornerRadius,
    style: .bolttyAIControl
  )
  private var startedAt: Date?
  private var tick: Timer?

  var confirmButtonForTesting: PaletteIconButton { confirmButton }
  var cancelButtonForTesting: PaletteIconButton { cancelButton }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true

    addSubview(pillGlass)

    configure(
      cancelButton,
      icon: .xmark,
      tint: AgentPaletteMetrics.voiceControlsCancelGlyphColor,
      fill: .clear,
      hoverFill: AgentPaletteMetrics.voiceControlsCancelHoverFillColor,
      action: #selector(cancelPressed)
    )
    cancelButton.hoverBackdropBlurRadius = AgentPaletteMetrics.voiceControlsCancelHoverBlurRadius
    configure(
      confirmButton,
      icon: .check,
      tint: AgentPaletteMetrics.voiceControlsConfirmGlyphColor,
      fill: AgentPaletteMetrics.voiceControlsConfirmFillColor,
      hoverFill: AgentPaletteMetrics.voiceControlsConfirmHoverFillColor,
      action: #selector(confirmPressed)
    )

    timerLabel.font = NSFont.monospacedDigitSystemFont(
      ofSize: AgentPaletteMetrics.voiceControlsTimerFontSize,
      weight: .medium
    )
    timerLabel.textColor = PaletteInk.primary
    timerLabel.alignment = .center

    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = AgentPaletteMetrics.voiceControlsSpacing
    row.translatesAutoresizingMaskIntoConstraints = false
    row.setViews(
      [Self.sized(cancelButton), timerLabel, meter, Self.sized(confirmButton)],
      in: .leading
    )
    addSubview(row)

    let padding = AgentPaletteMetrics.voiceControlsPadding
    NSLayoutConstraint.activate([
      pillGlass.leadingAnchor.constraint(equalTo: leadingAnchor),
      pillGlass.trailingAnchor.constraint(equalTo: trailingAnchor),
      pillGlass.topAnchor.constraint(equalTo: topAnchor),
      pillGlass.bottomAnchor.constraint(equalTo: bottomAnchor),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
      row.topAnchor.constraint(equalTo: topAnchor, constant: padding),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
      widthAnchor.constraint(equalTo: row.widthAnchor, constant: padding * 2),
      heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceControlsHeight),
      meter.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceMeterSize.width),
      meter.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceMeterSize.height),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Recording")
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Session

  func startRecording() {
    startedAt = Date()
    updateElapsed()
    tick?.invalidate()
    tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateElapsed() }
    }
  }

  func stopRecording() {
    tick?.invalidate()
    tick = nil
    startedAt = nil
    meter.setLevel(0)
  }

  func setAudioLevel(_ level: CGFloat) {
    meter.setLevel(level)
  }

  private func updateElapsed() {
    guard let startedAt else { return }
    let seconds = Int(Date().timeIntervalSince(startedAt))
    timerLabel.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  private func configure(
    _ button: PaletteIconButton,
    icon: BolttyIcon,
    tint: NSColor,
    fill: NSColor,
    hoverFill: NSColor,
    action: Selector
  ) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.imagePosition = .imageOnly
    button.focusRingType = .none
    button.title = ""
    button.setButtonType(.momentaryChange)
    button.image = icon.image(
      size: AgentPaletteMetrics.iconSide(AgentPaletteMetrics.voiceControlsIconSize),
      description: icon == .xmark ? "Cancel dictation" : "Send dictation"
    )
    button.toolTip = icon == .xmark ? "Cancel dictation — restore the draft" : "Confirm and send recording"
    button.helpShortcut = icon == .check ? "↵" : nil
    button.contentTintColor = tint
    button.restingTint = tint
    button.hoverTint = tint
    button.restingBackground = fill
    button.hoverBackground = hoverFill
    button.target = self
    button.action = action
    button.setAccessibilityIdentifier(
      icon == .xmark ? "boltty.ask.voice.cancel" : "boltty.ask.voice.confirm"
    )
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceOrbDiameter),
      button.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceOrbDiameter),
    ])
  }

  private static func sized(_ button: PaletteIconButton) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(button)
    NSLayoutConstraint.activate([
      container.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceOrbDiameter),
      container.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.voiceOrbDiameter),
      button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      button.topAnchor.constraint(equalTo: container.topAnchor),
      button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
  }

  @objc private func cancelPressed() { onCancel?() }
  @objc private func confirmPressed() { onConfirm?() }
}

final class VoiceLevelMeter: NSView {
  private var bars: [CALayer] = []
  private var level: CGFloat = 0
  private var phase: CGFloat = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    bars = (0..<AgentPaletteMetrics.voiceMeterBarCount).map { _ in
      let bar = CALayer()
      bar.backgroundColor = NSColor.white.cgColor
      bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      layer?.addSublayer(bar)
      return bar
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    layoutBars()
  }

  func setLevel(_ level: CGFloat) {
    self.level = min(1, max(0, level))
    phase += AgentPaletteMetrics.voiceOrbBarPhaseStep
    layoutBars()
  }

  private func layoutBars() {
    guard !bars.isEmpty, bounds.width > 0 else { return }
    let width = AgentPaletteMetrics.voiceMeterBarWidth
    let pitch = bounds.width / CGFloat(bars.count)
    let centreY = bounds.height / 2
    let minimum = bounds.height * AgentPaletteMetrics.voiceMeterMinimumBarFraction

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, bar) in bars.enumerated() {
      let travelling = sin(phase + CGFloat(index) * AgentPaletteMetrics.voiceOrbBarPhaseSpread)
      let taper = sin((CGFloat(index) + 0.5) / CGFloat(bars.count) * .pi)
      let height = minimum
        + (bounds.height - minimum) * level * taper * (0.55 + 0.45 * travelling)
      bar.bounds = CGRect(x: 0, y: 0, width: width, height: max(minimum, height))
      bar.applyPaletteCorner(radius: width / 2)
      bar.position = CGPoint(x: pitch * (CGFloat(index) + 0.5), y: centreY)
    }
    CATransaction.commit()
  }
}

/// An open chat's composer foot while it listens: × lets the take go, the
/// voice runs across as a wave, the time it has run, and the microphone ends
/// the take with its words left to edit.
final class ChatDictationBar: NSView {
  var onCancel: (() -> Void)?
  var onStop: (() -> Void)?

  private let cancelDisc = GlassCircleButton(
    icon: .xmark,
    accessibilityDescription: "Cancel dictation",
    diameter: ComposerControlGroup.target,
    size: ComposerControlGroup.iconSize(chat: true),
    showsGlass: false
  )
  private let stopDisc = GlassCircleButton(
    icon: .mic,
    accessibilityDescription: "Stop dictation",
    diameter: ComposerControlGroup.target,
    size: ComposerControlGroup.iconSize(chat: true),
    showsGlass: false
  )
  private let wave = DictationWaveView(frame: .zero)
  private let timerLabel = NSTextField(labelWithString: "0:00")
  private var startedAt: Date?
  private var tick: Timer?

  var cancelButtonForTesting: PaletteIconButton { cancelDisc.button }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    for view in [cancelDisc, wave, timerLabel, stopDisc] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    ComposerControlGroup.style(cancelDisc.button)
    cancelDisc.button.target = self
    cancelDisc.button.action = #selector(cancelPressed)
    cancelDisc.button.toolTip = "Cancel dictation"
    cancelDisc.button.helpShortcut = "esc"
    cancelDisc.button.setAccessibilityIdentifier("boltty.ask.voice.cancel")
    ComposerControlGroup.style(stopDisc.button)
    stopDisc.button.restingTint = ComposerControlGroup.hoverInk
    stopDisc.button.target = self
    stopDisc.button.action = #selector(stopPressed)
    stopDisc.button.toolTip = "Stop dictation"
    stopDisc.button.helpShortcut = ComposerChord.dictate.display
    stopDisc.button.setAccessibilityIdentifier("boltty.ask.voice.stop")

    timerLabel.font = roundedAppFont(size: AgentPaletteMetrics.typeMeta, weight: .medium).withMonospacedDigits
    timerLabel.textColor = ComposerControlGroup.restingInk
    timerLabel.alignment = .right
    timerLabel.setContentHuggingPriority(.required, for: .horizontal)
    timerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    let gap = ComposerControlGroup.gap
    NSLayoutConstraint.activate([
      cancelDisc.leadingAnchor.constraint(equalTo: leadingAnchor),
      cancelDisc.centerYAnchor.constraint(equalTo: centerYAnchor),
      wave.leadingAnchor.constraint(equalTo: cancelDisc.trailingAnchor, constant: gap),
      wave.centerYAnchor.constraint(equalTo: centerYAnchor),
      wave.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.chatDictationWaveHeight),
      timerLabel.leadingAnchor.constraint(equalTo: wave.trailingAnchor, constant: gap),
      stopDisc.leadingAnchor.constraint(equalTo: timerLabel.trailingAnchor, constant: gap / 2),
      stopDisc.trailingAnchor.constraint(equalTo: trailingAnchor),
      stopDisc.centerYAnchor.constraint(equalTo: centerYAnchor),
      timerLabel.firstBaselineAnchor.constraint(
        equalTo: centerYAnchor, constant: AgentPaletteMetrics.typeMeta * 0.35),
      heightAnchor.constraint(equalToConstant: ComposerControlGroup.sendDisc),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Dictating")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func start() {
    startedAt = Date()
    updateElapsed()
    wave.start()
    tick?.invalidate()
    tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateElapsed() }
    }
  }

  /// Holds the wave where it stood while the last words are worked out.
  func freeze() {
    tick?.invalidate()
    tick = nil
    wave.freeze()
  }

  func stop() {
    freeze()
    startedAt = nil
    wave.reset()
  }

  func setAudioLevel(_ level: CGFloat) { wave.setLevel(level) }

  private func updateElapsed() {
    guard let startedAt else { return }
    let seconds = Int(Date().timeIntervalSince(startedAt))
    timerLabel.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  @objc private func cancelPressed() { onCancel?() }
  @objc private func stopPressed() { onStop?() }
}

/// Bars that run leftward, one a frame of the voice's loudness; the newest
/// stands at the trailing edge.
final class DictationWaveView: NSView {
  private var bars: [CALayer] = []
  private var levels: [CGFloat] = []
  private var level: CGFloat = 0
  private var envelope = VoiceLevelEnvelope(
    attack: AgentPaletteMetrics.chatDictationWaveAttack,
    release: AgentPaletteMetrics.chatDictationWaveRelease)
  private var clock: Timer?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setLevel(_ level: CGFloat) { self.level = min(1, max(0, level)) }

  func start() {
    clock?.invalidate()
    clock = Timer.scheduledTimer(
      withTimeInterval: AgentPaletteMetrics.chatDictationWaveStep, repeats: true
    ) { [weak self] _ in
      Task { @MainActor in self?.advance() }
    }
  }

  func freeze() {
    clock?.invalidate()
    clock = nil
  }

  func reset() {
    freeze()
    level = 0
    envelope.reset()
    levels.removeAll()
    layoutBars()
  }

  override func layout() {
    super.layout()
    rebuildBars()
  }

  private var pitch: CGFloat {
    AgentPaletteMetrics.chatDictationBarWidth + AgentPaletteMetrics.chatDictationBarGap
  }

  private func rebuildBars() {
    let count = max(0, Int((bounds.width + AgentPaletteMetrics.chatDictationBarGap) / pitch))
    if count != bars.count {
      bars.forEach { $0.removeFromSuperlayer() }
      bars = (0..<count).map { _ in
        let bar = CALayer()
        bar.backgroundColor = ComposerControlGroup.hoverInk.cgColor
        layer?.addSublayer(bar)
        return bar
      }
    }
    layoutBars()
  }

  private func advance() {
    levels.append(envelope.accept(level, dt: AgentPaletteMetrics.chatDictationWaveStep))
    if levels.count > bars.count { levels.removeFirst(levels.count - bars.count) }
    layoutBars()
  }

  private func layoutBars() {
    guard !bars.isEmpty else { return }
    let width = AgentPaletteMetrics.chatDictationBarWidth
    let minimum = AgentPaletteMetrics.chatDictationBarMinimum
    let room = bounds.height - minimum
    let missing = bars.count - levels.count
    let scale = window?.backingScaleFactor ?? 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, bar) in bars.enumerated() {
      let heard = index >= missing ? levels[index - missing] : 0
      let loud = min(1, heard * AgentPaletteMetrics.chatDictationWaveGain)
      let height = ((minimum + room * loud) * scale).rounded() / scale
      bar.frame = CGRect(
        x: CGFloat(index) * pitch, y: ((bounds.height - height) / 2 * scale).rounded() / scale,
        width: width, height: height)
      bar.applyPaletteCorner(radius: width / 2)
      bar.opacity = index >= missing ? 1 : 0.35
    }
    CATransaction.commit()
  }
}

private extension NSFont {
  var withMonospacedDigits: NSFont {
    let descriptor = fontDescriptor.addingAttributes([
      .featureSettings: [[
        NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
        NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
      ]],
    ])
    return NSFont(descriptor: descriptor, size: pointSize) ?? self
  }
}
