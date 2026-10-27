import AppKit
import CoreText

extension PromptAttachmentKind {
  var chipColor: NSColor {
    switch self {
    case .image: HexColor.nsColor("#5FE3BD")
    case .file: HexColor.nsColor("#3D94FF")
    case .text: HexColor.nsColor("#FFAA3D")
    case .link: HexColor.nsColor("#C7C7CC")
    }
  }

  var chipFillColor: NSColor {
    chipColor.withAlphaComponent(AgentPaletteMetrics.chipFillAlpha)
  }

  var chipSymbolName: String {
    switch self {
    case .image: "photo"
    case .file: "doc"
    case .text: "text.viewfinder"
    case .link: "link"
    }
  }
}

/// How a link standing in the draft is drawn: the
/// sentence's own type in a cyan-blue, underlined — a link is words, never a
/// chip. `key` marks the characters `PromptTextView.styleLinks` has styled.
enum PromptLinkStyle {
  static let color = HexColor.nsColor("#5AC8FA")
  static let key = NSAttributedString.Key("boltty.promptLink")
}

final class PromptChipAttachment: NSTextAttachment {
  let promptAttachment: PromptAttachment

  init(_ promptAttachment: PromptAttachment) {
    self.promptAttachment = promptAttachment
    super.init(data: nil, ofType: nil)
    attachmentCell = MainActor.assumeIsolated { PromptChipCell(promptAttachment) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func attributedString() -> NSAttributedString {
    NSAttributedString(attachment: self)
  }
}

extension PromptAttachment {
  var tooltip: String {
    switch payload {
    case let .file(url):
      url.path
    case let .imageData(data, type):
      "Pasted \(type.localizedDescription ?? "image") · \(Self.byteLabel(data.count))"
    case let .text(text):
      "Pasted text · \(Self.byteLabel(text.utf8.count))"
    case let .screen(selection):
      selection.context.map { "Selected on screen in \($0)" } ?? "Selected on screen"
    }
  }

  private static func byteLabel(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
  }
}

final class PromptChipCell: NSTextAttachmentCell {
  let promptAttachment: PromptAttachment

  var appearProgress: CGFloat = 1

  private var cachedLabel: NSAttributedString?
  private var cachedSymbol: NSImage?
  var displayFont: NSFont = PromptChipCell.font {
    didSet {
      guard displayFont != oldValue else { return }
      cachedLabel = nil
      cachedSymbol = nil
    }
  }

  private var label: NSAttributedString {
    if let cachedLabel { return cachedLabel }
    let label = NSAttributedString(
      string: Self.title(for: promptAttachment),
      attributes: [
        .font: displayFont,
        .foregroundColor: promptAttachment.kind.chipColor,
      ]
    )
    cachedLabel = label
    return label
  }

  private var symbol: NSImage? {
    if let cachedSymbol { return cachedSymbol }
    let configuration = NSImage.SymbolConfiguration(
      pointSize: displayFont.pointSize * AgentPaletteMetrics.chipSymbolPerPoint,
      weight: .regular
    ).applying(.init(paletteColors: [promptAttachment.kind.chipColor]))
    let symbol = NSImage(
      systemSymbolName: promptAttachment.kind.chipSymbolName,
      accessibilityDescription: nil
    )?.withSymbolConfiguration(configuration)
    cachedSymbol = symbol
    return symbol
  }

  static var font: NSFont { PromptTextView.promptFont }

  static func title(for attachment: PromptAttachment) -> String {
    let label = attachment.displayLabel()
    let kind = attachment.kind.rawValue
    guard label.hasPrefix(kind) else { return label }
    let number = label.dropFirst(kind.count)
    guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return label }
    return "\(kind) \(number)"
  }

  init(_ promptAttachment: PromptAttachment) {
    self.promptAttachment = promptAttachment
    super.init(imageCell: nil)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  static func height(for font: NSFont) -> CGFloat {
    (font.pointSize * AgentPaletteMetrics.chipHeightPerPoint * 2).rounded() / 2
  }

  static func descent(for font: NSFont) -> CGFloat {
    height(for: font) / 2 - font.capHeight / 2
  }

  static func lineHeight(for font: NSFont) -> CGFloat {
    let height = height(for: font)
    let descent = descent(for: font)
    return ceil(max(font.ascender, height - descent) + max(-font.descender, descent))
  }

  /// The kind's glass picture, drawn in Figma with its word in it: the chip
  /// itself, edge to edge. A kind with no picture falls back to the capsule.
  @MainActor static func picture(for kind: PromptAttachmentKind) -> NSImage? {
    if let cached = pictures[kind] { return cached }
    let picture = Bundle.main
      .url(forResource: kind.rawValue, withExtension: "png", subdirectory: "ChipGlass")
      .flatMap(NSImage.init(contentsOf:))
    pictures[kind] = .some(picture)
    return picture
  }

  @MainActor private static var pictures: [PromptAttachmentKind: NSImage?] = [:]

  private static func pictureSize(_ picture: NSImage, for font: NSFont) -> NSSize {
    let height = Self.height(for: font)
    let aspect = picture.size.width / max(picture.size.height, 1)
    return NSSize(width: ceil(height * aspect * 2) / 2, height: height)
  }

  override func cellSize() -> NSSize {
    MainActor.assumeIsolated {
      if let picture = Self.picture(for: promptAttachment.kind) {
        return Self.pictureSize(picture, for: displayFont)
      }
      let size = displayFont.pointSize
      let glyph = symbol?.size.width ?? 0
      return NSSize(
        width: ceil(
          size * AgentPaletteMetrics.chipPaddingPerPoint * 2
            + glyph + size * AgentPaletteMetrics.chipSymbolGapPerPoint
            + label.size().width
        ),
        height: Self.height(for: displayFont)
      )
    }
  }

  override func cellBaselineOffset() -> NSPoint {
    MainActor.assumeIsolated {
      NSPoint(x: 0, y: -Self.descent(for: displayFont))
    }
  }

  override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
    draw(withFrame: cellFrame, in: controlView, characterIndex: 0)
  }

  override func draw(
    withFrame cellFrame: NSRect,
    in controlView: NSView?,
    characterIndex charIndex: Int
  ) {
    guard appearProgress > 0 else { return }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    if appearProgress < 1 {
      let transform = NSAffineTransform()
      let center = NSPoint(x: cellFrame.midX, y: cellFrame.midY)
      transform.translateX(by: center.x, yBy: center.y)
      transform.scale(by: PromptChipCell.entranceScale(for: appearProgress))
      transform.translateX(by: -center.x, yBy: -center.y)
      transform.concat()
      NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    let alpha = appearProgress
    if let picture = MainActor.assumeIsolated({ Self.picture(for: promptAttachment.kind) }) {
      picture.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: alpha,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
      return
    }
    let radius = PromptChipCell.cornerRadius(forHeight: cellFrame.height)
    let capsule = NSBezierPath(roundedRect: cellFrame, xRadius: radius, yRadius: radius)
    let fill = promptAttachment.kind.chipFillColor
    fill.withAlphaComponent(fill.alphaComponent * alpha).setFill()
    capsule.fill()

    let size = displayFont.pointSize
    let flipped = controlView?.isFlipped ?? true
    let capMidY = cellFrame.midY
    var x = cellFrame.minX + size * AgentPaletteMetrics.chipPaddingPerPoint

    if let symbol {
      let rect = NSRect(
        x: x,
        y: capMidY - symbol.size.height / 2,
        width: symbol.size.width,
        height: symbol.size.height
      )
      symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
      x = rect.maxX + size * AgentPaletteMetrics.chipSymbolGapPerPoint
    }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let line = CTLineCreateWithAttributedString(label)
    let baselineY = flipped
      ? capMidY + displayFont.capHeight / 2
      : capMidY - displayFont.capHeight / 2
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: x, y: baselineY)
    if flipped { ctx.scaleBy(x: 1, y: -1) }
    ctx.textMatrix = .identity
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }

  static func cornerRadius(forHeight height: CGFloat) -> CGFloat {
    min(AgentPaletteMetrics.chipCornerRadius, height / 2)
  }

  static func entranceScale(for progress: CGFloat) -> CGFloat {
    let clamped = min(max(progress, 0), 1)
    return AgentPaletteMetrics.chipAppearStartScale
      + (1 - AgentPaletteMetrics.chipAppearStartScale) * clamped
  }
}
