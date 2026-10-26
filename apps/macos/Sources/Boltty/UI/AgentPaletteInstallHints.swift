import AppKit

final class BolttyAINoAgentsView: NSView {
  var onOpenSettings: (() -> Void)?

  private let mascotView = NSView()
  private let faces = AgentHistory.tabOrder.map {
    MascotNSView(conversationID: BolttyAINoAgentsView.identity, look: MascotLook.face(for: $0))
  }
  private let settingsButtonPill = GlassPillButton.titled("Open Settings")
  private var settingsButton: NSButton { settingsButtonPill.button }

  var faceLooksForTesting: [MascotLook] { faces.map(\.look) }

  private static let identity = UUID()

  var buttonTitleForTesting: String { settingsButton.title }
  func pressOpenSettingsForTesting() { openSettings(settingsButton) }

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    mascotView.translatesAutoresizingMaskIntoConstraints = false
    let side = AgentPaletteMetrics.resultsEmptyMascotSize / 2
    for (index, face) in faces.enumerated() {
      face.emotion = .concerned
      face.reduceMotion = MotionPreferences.reduceMotion
      face.translatesAutoresizingMaskIntoConstraints = false
      mascotView.addSubview(face)
      NSLayoutConstraint.activate([
        face.widthAnchor.constraint(equalToConstant: side),
        face.heightAnchor.constraint(equalToConstant: side),
        face.leadingAnchor.constraint(equalTo: mascotView.leadingAnchor, constant: CGFloat(index % 2) * side),
        face.topAnchor.constraint(equalTo: mascotView.topAnchor, constant: CGFloat(index / 2) * side),
      ])
    }

    let title = NSTextField(labelWithString: "No agents found")
    title.font = roundedAppFont(size: AgentPaletteMetrics.resultsTitleFontSize)
    title.textColor = .labelColor

    let subtitle = NSTextField(
      wrappingLabelWithString:
        "Boltty works with the CLI agents already installed on this Mac."
    )
    subtitle.font = roundedAppFont(size: AgentPaletteMetrics.resultsSubtitleFontSize)
    subtitle.textColor = .secondaryLabelColor
    subtitle.alignment = .center
    subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    title.alignment = .center

    settingsButton.target = self
    settingsButton.action = #selector(openSettings(_:))
    settingsButton.setAccessibilityIdentifier("boltty.ask.noAgents.openSettings")

    let stack = NSStackView(views: [title, subtitle, settingsButtonPill])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 6
    stack.setCustomSpacing(2, after: title)
    stack.setCustomSpacing(12, after: subtitle)
    stack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(mascotView)
    addSubview(stack)
    NSLayoutConstraint.activate([
      mascotView.centerXAnchor.constraint(equalTo: centerXAnchor),
      mascotView.topAnchor.constraint(
        equalTo: topAnchor, constant: AgentPaletteMetrics.resultsEmptyOwnVerticalPadding),
      mascotView.widthAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.resultsEmptyMascotSize),
      mascotView.heightAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.resultsEmptyMascotSize),

      stack.topAnchor.constraint(
        equalTo: mascotView.bottomAnchor, constant: AgentPaletteMetrics.resultsEmptyMascotTextSpacing),
      stack.bottomAnchor.constraint(
        equalTo: bottomAnchor, constant: -AgentPaletteMetrics.resultsEmptyOwnVerticalPadding),
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.leadingAnchor.constraint(
        greaterThanOrEqualTo: leadingAnchor, constant: AgentPaletteMetrics.resultsRowHorizontalInset),
      stack.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor, constant: -AgentPaletteMetrics.resultsRowHorizontalInset),
      subtitle.widthAnchor.constraint(
        lessThanOrEqualTo: widthAnchor, constant: -AgentPaletteMetrics.resultsRowHorizontalInset * 2),
    ])
  }

  @objc private func openSettings(_ sender: NSButton) {
    onOpenSettings?()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
