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
      symbol: "xmark",
      tint: AgentPaletteMetrics.voiceControlsCancelGlyphColor,
      fill: .clear,
      hoverFill: AgentPaletteMetrics.voiceControlsCancelHoverFillColor,
      action: #selector(cancelPressed)
    )
    cancelButton.hoverBackdropBlurRadius = AgentPaletteMetrics.voiceControlsCancelHoverBlurRadius
    configure(
      confirmButton,
      symbol: "checkmark",
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
    symbol: String,
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
    button.image = NSImage(
      systemSymbolName: symbol,
      accessibilityDescription: symbol == "xmark" ? "Cancel dictation" : "Send dictation"
    )?.withSymbolConfiguration(
      .init(pointSize: AgentPaletteMetrics.voiceControlsGlyphPointSize, weight: .semibold)
    )
    button.toolTip = symbol == "xmark" ? "Cancel dictation — restore the draft" : "Confirm and send recording"
    button.helpShortcut = symbol == "checkmark" ? "↵" : nil
    button.contentTintColor = tint
    button.restingTint = tint
    button.hoverTint = tint
    button.restingBackground = fill
    button.hoverBackground = hoverFill
    button.target = self
    button.action = action
    button.setAccessibilityIdentifier(
      symbol == "xmark" ? "boltty.ask.voice.cancel" : "boltty.ask.voice.confirm"
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
