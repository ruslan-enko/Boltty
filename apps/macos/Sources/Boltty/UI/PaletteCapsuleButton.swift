import AppKit

final class GlassPillLabelButton: PaletteIconButton {
  static let horizontalInset: CGFloat = 12

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configure()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configure() {
    isBordered = true
    bezelStyle = .glass
    borderShape = .capsule
    controlSize = .large
    imagePosition = .noImage
    wantsLayer = true
    restingTint = AgentPaletteMetrics.directoryChipTextColor
    hoverTint = .white
    restingBackground = .clear
    hoverBackground = .clear
    pressScale = 1
    applyRestingBackground()
    applyTitle()
  }

  override var title: String {
    get { word }
    set { word = newValue; applyTitle() }
  }
  private var word = ""

  override func applyTint() {
    super.applyTint()
    applyTitle()
  }

  override var isEnabled: Bool {
    didSet { applyTint() }
  }

  var titleFontSize: CGFloat = AgentPaletteMetrics.glassButtonFontSize {
    didSet { applyTitle(); invalidateIntrinsicContentSize() }
  }
  var height: CGFloat = AgentPaletteMetrics.glassButtonHeight {
    didSet { invalidateIntrinsicContentSize() }
  }

  private func applyTitle() {
    let colour = !isEnabled ? PaletteInk.tertiary : isHovered ? hoverTint : restingTint
    let words = NSMutableAttributedString()
    words.append(NSAttributedString(
      string: word,
      attributes: [.font: roundedAppFont(size: titleFontSize), .foregroundColor: colour]
    ))
    attributedTitle = words
  }

  override var intrinsicContentSize: NSSize {
    NSSize(
      width: super.intrinsicContentSize.width + Self.horizontalInset * 2,
      height: height
    )
  }

}


@MainActor
final class GlassPillButton: NSView {
  let button = GlassPillLabelButton(frame: .zero)
  var usesSystemGlassForTesting: Bool { button.isBordered && button.bezelStyle == .glass }
  var isCapsuleForTesting: Bool { button.borderShape == .capsule }

  static func titled(_ title: String) -> GlassPillButton {
    let wrapper = GlassPillButton(frame: .zero)
    wrapper.title = title
    return wrapper
  }

  var title: String {
    get { button.title }
    set { button.title = newValue }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize { button.intrinsicContentSize }
}
