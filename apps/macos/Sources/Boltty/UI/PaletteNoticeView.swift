import AppKit

final class PaletteNoticeView: NSView {
  let label = NSTextField(wrappingLabelWithString: "")
  private let glyph = NSImageView()
  private let row = NSView()
  private lazy var host = PaletteGlassHost(
    content: row,
    cornerRadius: AgentPaletteMetrics.noticeCornerRadius,
    style: .bolttyAIControl
  )
  private lazy var widthLimit = widthAnchor.constraint(lessThanOrEqualToConstant: 520)

  var maximumWidth: CGFloat = 520 {
    didSet {
      guard maximumWidth != oldValue else { return }
      widthLimit.constant = maximumWidth
      applyWrapWidth()
    }
  }

  var message: String {
    get { label.stringValue }
    set {
      label.stringValue = newValue
      setAccessibilityLabel(newValue)
      invalidateIntrinsicContentSize()
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.masksToBounds = false

    glyph.image = NSImage(
      systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(
      pointSize: AgentPaletteMetrics.promptNoteFontSize, weight: .semibold))
    glyph.contentTintColor = AgentPaletteMetrics.failureCardAccent
    glyph.setContentHuggingPriority(.required, for: .horizontal)
    glyph.setContentCompressionResistancePriority(.required, for: .horizontal)

    label.font = roundedAppFont(size: AgentPaletteMetrics.promptNoteFontSize)
    label.textColor = PaletteInk.primary
    label.isSelectable = false
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.setContentHuggingPriority(.required, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)

    row.translatesAutoresizingMaskIntoConstraints = false
    glyph.translatesAutoresizingMaskIntoConstraints = false
    label.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(glyph)
    row.addSubview(label)
    let horizontal = AgentPaletteMetrics.noticeHorizontalPadding
    let vertical = AgentPaletteMetrics.noticeVerticalPadding
    NSLayoutConstraint.activate([
      glyph.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: horizontal),
      glyph.centerYAnchor.constraint(
        equalTo: label.firstBaselineAnchor,
        constant: -(label.font?.capHeight ?? 0) / 2),
      label.leadingAnchor.constraint(
        equalTo: glyph.trailingAnchor, constant: AgentPaletteMetrics.noticeGlyphSpacing),
      label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -horizontal),
      label.topAnchor.constraint(equalTo: row.topAnchor, constant: vertical),
      label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -vertical),
    ])

    addSubview(host)
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: leadingAnchor),
      host.trailingAnchor.constraint(equalTo: trailingAnchor),
      host.topAnchor.constraint(equalTo: topAnchor),
      host.bottomAnchor.constraint(equalTo: bottomAnchor),
      widthLimit,
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    applyWrapWidth()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func applyWrapWidth() {
    let glyphWidth = glyph.image?.size.width ?? 0
    label.preferredMaxLayoutWidth = max(
      0,
      maximumWidth - AgentPaletteMetrics.noticeHorizontalPadding * 2
        - glyphWidth - AgentPaletteMetrics.noticeGlyphSpacing)
    invalidateIntrinsicContentSize()
  }

  override func layout() {
    super.layout()
    host.cornerRadius = min(AgentPaletteMetrics.noticeCornerRadius, bounds.height / 2)
  }
}
