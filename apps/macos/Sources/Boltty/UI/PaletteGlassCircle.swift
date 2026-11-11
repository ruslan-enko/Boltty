import AppKit

@MainActor
enum PaletteGlassCircle {
  static func makeCapsule(height: CGFloat, interactive: Bool) -> NSView {
    let glass = NSGlassEffectView()
    glass.cornerRadius = height / 2
    if #available(macOS 27.0, *) { glass.effectIsInteractive = interactive }
    return glass
  }
}

@MainActor
final class GlassCircleButton: NSView {
  let button = PaletteIconButton()
  private let showsGlass: Bool
  var usesSystemGlass: Bool { button.isBordered && button.bezelStyle == .glass }
  private var sizeConstraints: [NSLayoutConstraint] = []
  var diameter: CGFloat {
    get { sizeConstraints.first?.constant ?? 0 }
    set {
      guard !showsGlass else { return }
      for constraint in sizeConstraints where constraint.constant != newValue {
        constraint.constant = newValue
      }
    }
  }
  private let icon: BolttyIcon
  private let symbolDescription: String
  private(set) var pointSize: CGFloat

  func setPointSize(_ pointSize: CGFloat) {
    guard pointSize != self.pointSize else { return }
    self.pointSize = pointSize
    button.image = icon.image(size: AgentPaletteMetrics.iconSide(pointSize), description: symbolDescription)
  }

  init(
    icon: BolttyIcon,
    accessibilityDescription: String,
    diameter: CGFloat,
    size pointSize: CGFloat,
    showsGlass: Bool = true
  ) {
    self.showsGlass = showsGlass
    self.icon = icon
    self.symbolDescription = accessibilityDescription
    self.pointSize = pointSize
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.masksToBounds = false

    button.translatesAutoresizingMaskIntoConstraints = false
    button.title = ""
    button.imagePosition = .imageOnly
    button.image = icon.image(size: AgentPaletteMetrics.iconSide(pointSize), description: accessibilityDescription)
    button.restingBackground = .clear
    button.hoverBackdropBlurRadius = 0
    if showsGlass {
      button.isBordered = true
      button.bezelStyle = .glass
      button.borderShape = .circle
      button.controlSize = .extraLarge
      button.restingTint = PaletteInk.primary
      button.hoverTint = PaletteInk.primary
      button.hoverBackground = .clear
      button.pressScale = 1
    } else {
      button.isBordered = false
      button.bezelStyle = .regularSquare
      button.restingTint = PaletteInk.secondary
      button.hoverTint = PaletteInk.primary
      button.hoverBackground = PaletteInk.fill
    }
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    sizeConstraints = [
      widthAnchor.constraint(equalToConstant: diameter),
      heightAnchor.constraint(equalToConstant: diameter),
    ]
    NSLayoutConstraint.activate(sizeConstraints)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
