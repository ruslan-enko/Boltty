import AppKit

enum PaletteAnswerText {
  static func attributed(_ message: ConversationMessage, color: NSColor) -> NSAttributedString {
    attributed(blocks: message.paletteBlocks, color: color)
  }

  static func attributed(
    blocks: [PaletteMessageBlock], color: NSColor
  ) -> NSAttributedString {
    let key = SetKey(blocks: blocks, color: color)
    if let cached = setCache[key] { return cached }
    let set = setUncached(blocks: blocks, color: color)
    if setCache.count >= setCacheLimit { setCache.removeAll(keepingCapacity: true) }
    setCache[key] = set
    return set
  }

  private struct SetKey: Hashable {
    let text: [String]
    let color: NSColor
    init(blocks: [PaletteMessageBlock], color: NSColor) {
      text = blocks.compactMap { block in
        switch block {
        case let .prose(markdown): "p" + markdown
        case let .attachment(attachment): "a" + attachment.displayName
        case let .failure(message): "f" + message
        case .reasoning, .activity: nil
        }
      }
      self.color = color
    }
  }

  private static let setCacheLimit = 512
  nonisolated(unsafe) private static var setCache: [SetKey: NSAttributedString] = [:]

  private static func setUncached(
    blocks: [PaletteMessageBlock], color: NSColor
  ) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for block in blocks {
      switch block {
      case let .prose(markdown):
        append(markdown: markdown, color: color, to: out)
      case let .attachment(attachment):
        append(plain: attachment.displayName, color: color, to: out)
      case let .failure(message):
        append(plain: message, color: color, to: out)
      case .reasoning, .activity:
        continue
      }
    }
    while out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
    return NSAttributedString(attributedString: out)
  }

  static func attributed(markdown: String, color: NSColor) -> NSAttributedString {
    let out = NSMutableAttributedString()
    append(markdown: markdown, color: color, to: out)
    return out
  }

  // MARK: - Blocks

  private static func append(plain text: String, color: NSColor, to out: NSMutableAttributedString) {
    separate(out)
    out.append(NSAttributedString(
      string: text,
      attributes: bodyAttributes(color: color, style: paragraphStyle())
    ))
  }

  static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
    guard !(text is NSMutableAttributedString) else { return measure(text, width: width) }
    let id = ObjectIdentifier(text)
    if let hit = heightCache[id], hit.text === text, hit.width == width { return hit.height }
    let height = measure(text, width: width)
    if heightCache.count >= setCacheLimit * 2 { heightCache.removeAll(keepingCapacity: true) }
    heightCache[id] = (text, width, height)
    return height
  }

  nonisolated(unsafe) private static var heightCache:
    [ObjectIdentifier: (text: NSAttributedString, width: CGFloat, height: CGFloat)] = [:]

  private static func measure(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
    ceil(text.boundingRect(
      with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height)
  }

  static func streaming(_ text: String, color: NSColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: bodyAttributes(color: color, style: paragraphStyle()))
  }

  private static func append(markdown: String, color: NSColor, to out: NSMutableAttributedString) {
    guard let parsed = parse(markdown) else {
      append(plain: markdown, color: color, to: out)
      return
    }
    let all = blocks(of: parsed)
    var index = 0
    while index < all.count {
      guard case let .tableCell(identity, _, _, columns, _) = kind(of: all[index]) else {
        separate(out)
        let next = index + 1 < all.count ? kind(of: all[index + 1]) : nil
        out.append(set(all[index], color: color, before: next))
        index += 1
        continue
      }
      var cells: [AttributedSubstring] = []
      while index < all.count,
            case let .tableCell(next, _, _, _, _) = kind(of: all[index]), next == identity {
        cells.append(all[index])
        index += 1
      }
      separate(out)
      out.append(table(cells, columns: columns, color: color))
    }
  }

  private static func kind(of block: AttributedSubstring) -> Kind {
    Kind(components: block.runs.first?.presentationIntent?.components ?? [])
  }

  private static func separate(_ out: NSMutableAttributedString) {
    guard out.length > 0 else { return }
    guard !out.string.hasSuffix("\n") else { return }
    let style = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil)
    out.append(NSAttributedString(string: "\n", attributes: style.map { [.paragraphStyle: $0] } ?? [:]))
  }

  private static func parse(_ markdown: String) -> AttributedString? {
    try? AttributedString(
      markdown: markdown,
      options: .init(
        allowsExtendedAttributes: true,
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
      )
    )
  }

  private static func blocks(of parsed: AttributedString) -> [AttributedSubstring] {
    var result: [AttributedSubstring] = []
    var currentIdentity: Int?
    var start: AttributedString.Index?
    var end: AttributedString.Index?

    for run in parsed.runs {
      let identity = run.presentationIntent?.components.first?.identity
      if identity != currentIdentity || start == nil {
        if let start, let end { result.append(parsed[start..<end]) }
        start = run.range.lowerBound
        currentIdentity = identity
      }
      end = run.range.upperBound
    }
    if let start, let end { result.append(parsed[start..<end]) }
    return result
  }

  // MARK: - A table

  private static func table(
    _ cells: [AttributedSubstring],
    columns: Int,
    color: NSColor
  ) -> NSAttributedString {
    let table = NSTextTable()
    table.numberOfColumns = max(1, columns)
    table.layoutAlgorithm = .automaticLayoutAlgorithm
    table.collapsesBorders = true
    table.hidesEmptyCells = false

    let rows = cells.compactMap { cell -> Int? in
      guard case let .tableCell(_, row, _, _, _) = kind(of: cell) else { return nil }
      return row
    }
    let lastRow = rows.max() ?? 0
    let out = NSMutableAttributedString()
    for cell in cells {
      guard case let .tableCell(_, row, column, _, isHeader) = kind(of: cell) else { continue }
      let style = cellStyle(
        table, row: row, column: column, isLastRow: row == lastRow,
        isLastColumn: column == table.numberOfColumns - 1)
      let text = String(cell.characters).trimmingCharacters(in: .whitespacesAndNewlines)
      var attributes = bodyAttributes(color: color, style: style)
      attributes[.font] = font(
        size: AgentPaletteMetrics.answerTableFontSize,
        weight: isHeader ? .semibold : .regular,
        italic: false,
        mono: false
      )
      out.append(NSAttributedString(string: text + "\n", attributes: attributes))
    }
    return out
  }

  private static func cellStyle(
    _ table: NSTextTable,
    row: Int,
    column: Int,
    isLastRow: Bool,
    isLastColumn: Bool
  ) -> NSParagraphStyle {
    let block = PaletteEdgeTableBlock(
      table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1
    )
    let vertical = AgentPaletteMetrics.answerTableCellVerticalPadding
    block.setWidth(vertical, type: .absoluteValueType, for: .padding, edge: .minY)
    block.setWidth(vertical, type: .absoluteValueType, for: .padding, edge: .maxY)
    block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .minX)
    block.setWidth(
      isLastColumn ? 0 : AgentPaletteMetrics.answerTableCellTrailingPadding,
      type: .absoluteValueType, for: .padding, edge: .maxX)
    if !isLastRow {
      block.setWidth(
        AgentPaletteMetrics.answerTableRuleWidth, type: .absoluteValueType, for: .border, edge: .maxY)
      block.setBorderColor(AgentPaletteMetrics.answerTableRule, for: .maxY)
    }
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    style.minimumLineHeight = AgentPaletteMetrics.previewBodyLineHeight
    style.maximumLineHeight = AgentPaletteMetrics.previewBodyLineHeight
    style.textBlocks = [block]
    return style
  }

  // MARK: - One block

  private static func set(
    _ block: AttributedSubstring, color: NSColor, before next: Kind?
  ) -> NSAttributedString {
    let components = block.runs.first?.presentationIntent?.components ?? []
    let kind = Kind(components: components)
    let out = NSMutableAttributedString()
    let style = kind.paragraphStyle(before: next)

    if let marker = kind.marker {
      var attributes = bodyAttributes(color: color, style: style)
      if case .listItem(.some, _) = kind {
        attributes[.font] = roundedAppFont(size: AgentPaletteMetrics.previewBodyFontSize, weight: .semibold)
      }
      out.append(NSAttributedString(string: marker, attributes: attributes))
    }

    if kind == .rule {
      return NSAttributedString(string: "\u{200B}", attributes: bodyAttributes(color: color, style: style))
    }

    for run in block.runs {
      var text = String(block[run.range].characters)
      guard !text.isEmpty else { continue }
      let isInlineCode = kind != .code && (run.inlinePresentationIntent ?? []).contains(.code)
      if kind == .code {
        text = text.replacingOccurrences(of: "\n", with: "\u{2028}")
      }
      let room = AgentPaletteMetrics.answerInlineCodeInset * 2
      if isInlineCode, out.length > 0, !out.string.hasSuffix("\n") {
        out.addAttribute(.kern, value: room, range: NSRange(location: out.length - 1, length: 1))
      }
      let start = out.length
      out.append(NSAttributedString(
        string: text,
        attributes: attributes(for: run, kind: kind, color: color, style: style)
      ))
      if isInlineCode {
        out.addAttribute(.kern, value: room, range: NSRange(location: out.length - 1, length: 1))
        out.addAttribute(.paletteInlineCode, value: true, range: NSRange(location: start, length: out.length - start))
      }
    }

    while kind == .code, out.string.hasSuffix("\u{2028}") {
      out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
    }

    let trimmed = out.string.trimmingCharacters(in: .newlines)
    if trimmed.isEmpty && kind.marker == nil { return NSAttributedString() }
    return out
  }

  private static func attributes(
    for run: AttributedString.Runs.Run,
    kind: Kind,
    color: NSColor,
    style: NSParagraphStyle
  ) -> [NSAttributedString.Key: Any] {
    let inline = run.inlinePresentationIntent ?? []
    let isCode = inline.contains(.code) || kind == .code
    let bold = inline.contains(.stronglyEmphasized) || kind.isHeading
    let italic = inline.contains(.emphasized)
    let struck = inline.contains(.strikethrough)

    var attributes: [NSAttributedString.Key: Any] = [
      .font: font(size: isCode ? AgentPaletteMetrics.answerCodeFontSize : kind.fontSize,
                  weight: bold ? .semibold : .regular,
                  italic: italic,
                  mono: isCode),
      .foregroundColor: kind.ink(color),
      .paragraphStyle: style,
    ]
    if struck {
      attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    if let link = run.link {
      attributes[.link] = link
      attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
      attributes[.underlineColor] = PaletteInk.tertiary
    }
    return attributes
  }

  // MARK: - Fonts

  private static func font(
    size: CGFloat,
    weight: NSFont.Weight,
    italic: Bool,
    mono: Bool
  ) -> NSFont {
    let base = mono
      ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
      : roundedAppFont(size: size, weight: weight)
    guard italic else { return base }
    let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
    return NSFont(descriptor: descriptor, size: size) ?? base
  }

  private static func bodyAttributes(
    color: NSColor,
    style: NSParagraphStyle
  ) -> [NSAttributedString.Key: Any] {
    [
      .font: roundedAppFont(size: AgentPaletteMetrics.previewBodyFontSize),
      .foregroundColor: color,
      .paragraphStyle: style,
    ]
  }

  private static func paragraphStyle() -> NSParagraphStyle {
    Kind.paragraph.paragraphStyle
  }

  // MARK: - What a block is

  enum Kind: Equatable {
    case paragraph
    case heading(level: Int)
    case listItem(ordinal: Int?, depth: Int)
    case code
    case quote
    case tableCell(table: Int, row: Int, column: Int, columns: Int, isHeader: Bool)
    case rule

    init(components: [PresentationIntent.IntentType]) {
      var ordinal: Int?
      var listDepth = 0
      var isList = false
      var isOrdered = false
      var kind: Kind = .paragraph

      var tableIdentity: Int?
      var tableColumns = 0
      var cellColumn: Int?
      var cellRow = 0
      var isHeaderRow = false

      for component in components {
        switch component.kind {
        case let .header(level):
          kind = .heading(level: level)
        case .codeBlock:
          kind = .code
        case .blockQuote:
          kind = .quote
        case .thematicBreak:
          kind = .rule
        case let .listItem(ordinal: value):
          if !isList { ordinal = value }
          isList = true
        case .unorderedList:
          if listDepth == 0 { isOrdered = false }
          listDepth += 1
        case .orderedList:
          if listDepth == 0 { isOrdered = true }
          listDepth += 1
        case let .table(columns):
          tableIdentity = component.identity
          tableColumns = columns.count
        case let .tableCell(columnIndex):
          cellColumn = columnIndex
        case let .tableRow(rowIndex):
          cellRow = rowIndex
        case .tableHeaderRow:
          isHeaderRow = true
          cellRow = 0
        default:
          continue
        }
      }

      if let tableIdentity, let cellColumn {
        self = .tableCell(
          table: tableIdentity,
          row: cellRow,
          column: cellColumn,
          columns: tableColumns,
          isHeader: isHeaderRow
        )
        return
      }
      if !isOrdered { ordinal = nil }
      if isList {
        self = .listItem(ordinal: ordinal, depth: max(0, listDepth - 1))
      } else {
        self = kind
      }
    }

    var isHeading: Bool {
      if case .heading = self { return true }
      return false
    }

    var fontSize: CGFloat {
      switch self {
      case .heading(1): AgentPaletteMetrics.answerHeading1FontSize
      case .heading(2): AgentPaletteMetrics.answerHeading2FontSize
      case .heading(3): AgentPaletteMetrics.answerHeading3FontSize
      case .code: AgentPaletteMetrics.answerCodeFontSize
      case .heading, .paragraph, .listItem, .quote, .tableCell, .rule:
        AgentPaletteMetrics.previewBodyFontSize
      }
    }

    var lineHeight: CGFloat {
      switch self {
      case .heading(1): AgentPaletteMetrics.answerHeading1LineHeight
      case .heading(2), .heading(3): AgentPaletteMetrics.answerHeading2LineHeight
      case .rule: 1
      default: AgentPaletteMetrics.previewAnswerLineHeight
      }
    }

    func ink(_ color: NSColor) -> NSColor {
      switch self {
      case .rule: PaletteInk.secondary
      case .paragraph, .heading, .listItem, .code, .tableCell, .quote: color
      }
    }

    var marker: String? {
      guard case let .listItem(ordinal, depth) = self else { return nil }
      guard let ordinal else { return ["•", "◦", "▪"][min(depth, 2)] + "\t" }
      return "\t\(ordinal).\t"
    }

    var isListItem: Bool {
      if case .listItem = self { return true }
      return false
    }

    func paragraphStyle(before next: Kind?) -> NSParagraphStyle {
      let style = paragraphStyle
      guard let next else { return style }
      let spacing: CGFloat
      switch (self, next.isListItem) {
      case (.paragraph, true), (.listItem, true): spacing = AgentPaletteMetrics.answerListItemSpacing
      case (.listItem, false): spacing = AgentPaletteMetrics.answerParagraphSpacing
      default: return style
      }
      guard let mutable = style.mutableCopy() as? NSMutableParagraphStyle else { return style }
      mutable.paragraphSpacing = spacing
      return mutable
    }

    var paragraphStyle: NSParagraphStyle {
      let style = NSMutableParagraphStyle()
      style.lineBreakMode = .byWordWrapping
      style.minimumLineHeight = lineHeight
      style.maximumLineHeight = lineHeight

      switch self {
      case let .heading(level):
        style.paragraphSpacing = switch level {
        case 1: AgentPaletteMetrics.answerHeading1SpacingAfter
        case 2, 3: AgentPaletteMetrics.answerHeading2SpacingAfter
        default: 0
        }
      case .rule:
        let block = PaletteEdgeTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        block.setBorderColor(AgentPaletteMetrics.answerQuoteBar, for: .minY)
        block.setWidth(
          AgentPaletteMetrics.answerRuleSpacing - AgentPaletteMetrics.answerParagraphSpacing,
          type: .absoluteValueType, for: .margin, edge: .minY)
        style.textBlocks = [block]
        style.paragraphSpacing = AgentPaletteMetrics.answerRuleSpacingAfter
      case .tableCell:
        style.paragraphSpacing = 0
      case let .listItem(ordinal, depth):
        let step = CGFloat(depth) * AgentPaletteMetrics.answerListNestIndent
        let marker = AgentPaletteMetrics.answerListMarkerIndent + step
        let head = AgentPaletteMetrics.answerListHeadIndent + step
        style.headIndent = head
        if ordinal == nil {
          style.firstLineHeadIndent = marker
          style.tabStops = [NSTextTab(textAlignment: .left, location: head)]
        } else {
          style.firstLineHeadIndent = step
          style.tabStops = [
            NSTextTab(textAlignment: .right, location: head - AgentPaletteMetrics.answerListNumberGap),
            NSTextTab(textAlignment: .left, location: head),
          ]
        }
        style.defaultTabInterval = head
        style.paragraphSpacing = AgentPaletteMetrics.answerListItemSpacing
      case .quote:
        let block = PaletteEdgeTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        let bar = AgentPaletteMetrics.answerQuoteBarWidth
        block.setWidth(bar, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(AgentPaletteMetrics.answerQuoteBar, for: .minX)
        block.setWidth(
          AgentPaletteMetrics.answerQuoteIndent - bar, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(
          AgentPaletteMetrics.answerQuoteVerticalPadding, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(
          AgentPaletteMetrics.answerQuoteVerticalPadding, type: .absoluteValueType, for: .padding, edge: .maxY)
        style.textBlocks = [block]
        style.paragraphSpacing = AgentPaletteMetrics.answerParagraphSpacing
      case .code:
        style.lineBreakMode = .byCharWrapping
        style.paragraphSpacing = AgentPaletteMetrics.answerParagraphSpacing
      case .paragraph:
        style.paragraphSpacing = AgentPaletteMetrics.answerParagraphSpacing
      }
      return style
    }
  }
}

extension NSAttributedString.Key {
  static let paletteInlineCode = NSAttributedString.Key("boltty.answer.inlineCode")
}

final class PaletteAnswerTextView: NSTextView {
  private var heightConstraint: NSLayoutConstraint!

  init() {
    let storage = NSTextStorage()
    let layout = PaletteAnswerLayoutManager()
    storage.addLayoutManager(layout)
    // **Contiguous, on purpose.** Non-contiguous layout lays out only what it
    // is asked to draw and *estimates* where the rest stands. This view's
    // height is not the layout manager's: it is measured (`fit`) and forced,
    // so a long answer first shown at its foot — which is where a chat opens,
    // on its latest — asks for a rect past anything the estimate knows, finds
    // no glyph there and draws nothing, and never asks again. A chat with a
    // long answer opens blank until it is left and opened a second time.
    // Only laying the whole text out cures it; measured, that
    // costs no more per resize step than the estimate did.
    layout.allowsNonContiguousLayout = false
    let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.widthTracksTextView = true
    layout.addTextContainer(container)
    super.init(frame: .zero, textContainer: container)
    translatesAutoresizingMaskIntoConstraints = false
    isEditable = false
    isSelectable = true
    isRichText = true
    drawsBackground = false
    textContainerInset = .zero
    isVerticallyResizable = false
    isHorizontallyResizable = false
    linkTextAttributes = [.cursor: NSCursor.pointingHand]
    heightConstraint = heightAnchor.constraint(equalToConstant: 0)
    heightConstraint.isActive = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
  }

  var attributedStringValue: NSAttributedString {
    get { textStorage.map { NSAttributedString(attributedString: $0) } ?? NSAttributedString() }
    set {
      shown = newValue is NSMutableAttributedString
        ? NSAttributedString(attributedString: newValue) : newValue
      guard let textStorage, !textStorage.isEqual(to: newValue) else { return }
      textStorage.setAttributedString(newValue)
      needsDisplay = true
    }
  }
  private var shown: NSAttributedString?

  private var isResizing = false

  override func setFrameSize(_ newSize: NSSize) {
    isResizing = true
    defer { isResizing = false }
    super.setFrameSize(newSize)
  }

  override func scrollToVisible(_ rect: NSRect) -> Bool {
    isResizing ? false : super.scrollToVisible(rect)
  }

  var stringValue: String { string }

  func fit(width: CGFloat) {
    let height = PaletteAnswerText.height(of: shown ?? attributedStringValue, width: width)
    if abs(heightConstraint.constant - height) > 0.5 { heightConstraint.constant = height }
  }
}

/// Filled, never stroked: wide strokes go to CA's wide-line renderer, which can issue a zero-instance Metal draw.
final class PaletteEdgeTextBlock: NSTextBlock {
  override func drawBackground(
    withFrame frameRect: NSRect, in controlView: NSView?,
    characterRange charRange: NSRange, layoutManager: NSLayoutManager
  ) {
    PaletteEdgeTextBlock.fillBorders(of: self, in: frameRect)
  }

  static func fillBorders(of block: NSTextBlock, in frame: NSRect) {
    if let ground = block.backgroundColor {
      ground.setFill()
      frame.fill()
    }
    let box = NSRect(
      x: frame.minX + block.width(for: .margin, edge: .minX),
      y: frame.minY + block.width(for: .margin, edge: .minY),
      width: frame.width - block.width(for: .margin, edge: .minX) - block.width(for: .margin, edge: .maxX),
      height: frame.height - block.width(for: .margin, edge: .minY) - block.width(for: .margin, edge: .maxY))
    for edge in [NSRectEdge.minX, .minY, .maxX, .maxY] {
      let width = block.width(for: .border, edge: edge)
      guard width > 0, let color = block.borderColor(for: edge) else { continue }
      let strip: NSRect = switch edge {
      case .minX: NSRect(x: box.minX, y: box.minY, width: width, height: box.height)
      case .maxX: NSRect(x: box.maxX - width, y: box.minY, width: width, height: box.height)
      case .minY: NSRect(x: box.minX, y: box.minY, width: box.width, height: width)
      default: NSRect(x: box.minX, y: box.maxY - width, width: box.width, height: width)
      }
      color.setFill()
      strip.fill(using: .sourceOver)
    }
  }
}

final class PaletteEdgeTableBlock: NSTextTableBlock {
  override func drawBackground(
    withFrame frameRect: NSRect, in controlView: NSView?,
    characterRange charRange: NSRange, layoutManager: NSLayoutManager
  ) {
    PaletteEdgeTextBlock.fillBorders(of: self, in: frameRect)
  }
}

final class PaletteAnswerLayoutManager: NSLayoutManager {
  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    guard let storage = textStorage, let container = textContainers.first else { return }
    let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    let inset = AgentPaletteMetrics.answerInlineCodeInset
    storage.enumerateAttribute(.paletteInlineCode, in: characters) { value, range, _ in
      guard value != nil, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
      else { return }
      let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
        let piece = NSIntersectionRange(lineGlyphs, glyphs)
        guard piece.length > 0 else { return }
        let box = self.boundingRect(forGlyphRange: piece, in: container)
        let baseline = fragment.minY + self.location(forGlyphAt: piece.location).y
        let trailing = NSMaxRange(piece) == NSMaxRange(glyphs) ? inset * 2 : 0
        let well = NSRect(
          x: box.minX - inset + origin.x,
          y: baseline - font.ascender - 1 + origin.y,
          width: box.width - trailing + inset * 2,
          height: font.ascender - font.descender + 2)
        AgentPaletteMetrics.answerInlineCodeFill.setFill()
        let radius = AgentPaletteMetrics.answerInlineCodeCornerRadius
        NSBezierPath(roundedRect: well, xRadius: radius, yRadius: radius).fill()
      }
    }
  }
}

final class PaletteCodeBlockView: NSView {
  let text = PaletteAnswerTextView()
  private let copyButton = PaletteIconButton()
  private(set) var code = ""
  private var heightConstraint: NSLayoutConstraint!
  private var copyResetWork: DispatchWorkItem?
  var isCopyVisibleForTesting: Bool { !copyButton.isHidden }

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = AgentPaletteMetrics.answerCodeBlockFill.cgColor
    layer?.borderColor = AgentPaletteMetrics.answerCodeBlockBorder.cgColor
    layer?.borderWidth = 1
    addSubview(text)
    copyButton.translatesAutoresizingMaskIntoConstraints = false
    copyButton.isBordered = false
    copyButton.title = ""
    copyButton.imagePosition = .imageOnly
    copyButton.restingTint = ComposerControlGroup.restingInk
    copyButton.hoverTint = .white
    copyButton.hoverBackground = .clear
    copyButton.target = self
    copyButton.action = #selector(copyCode)
    copyButton.toolTip = "Copy code"
    copyButton.setAccessibilityLabel("Copy code")
    copyButton.isHidden = true
    applyCopyGlyph("doc.on.doc")
    addSubview(copyButton)
    heightConstraint = heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      heightConstraint,
      text.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: AgentPaletteMetrics.answerCodeBlockLeadingPadding),
      text.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -AgentPaletteMetrics.answerCodeBlockTrailingPadding),
      text.topAnchor.constraint(equalTo: topAnchor, constant: AgentPaletteMetrics.answerCodeBlockVerticalPadding),
      copyButton.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewCopyButtonSize),
      copyButton.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewCopyButtonSize),
      copyButton.topAnchor.constraint(equalTo: topAnchor, constant: AgentPaletteMetrics.answerCodeBlockCopyInset),
      copyButton.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -AgentPaletteMetrics.answerCodeBlockCopyInset),
    ])
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(_ value: String) {
    guard value != code || text.string.isEmpty else { return }
    code = value
    text.attributedStringValue = Self.attributed(value)
  }

  func fit(width: CGFloat) {
    text.fit(width: Self.textWidth(in: width))
    let height = Self.height(for: code, width: width)
    if abs(heightConstraint.constant - height) > 0.5 { heightConstraint.constant = height }
  }

  override func layout() {
    super.layout()
    layer?.applyPaletteCorner(radius: AgentPaletteMetrics.answerCodeBlockCornerRadius)
  }

  override func mouseEntered(with event: NSEvent) { copyButton.isHidden = code.isEmpty }
  override func mouseExited(with event: NSEvent) { copyButton.isHidden = true }

  @objc private func copyCode() {
    guard !code.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
    applyCopyGlyph("checkmark")
    copyResetWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.applyCopyGlyph("doc.on.doc") }
    copyResetWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
  }

  private func applyCopyGlyph(_ name: String) {
    copyButton.image = NSImage(systemSymbolName: name, accessibilityDescription: "Copy code")?
      .withSymbolConfiguration(.init(pointSize: AgentPaletteMetrics.previewFileGlyphPointSize, weight: .medium))
  }

  static func attributed(_ code: String) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byCharWrapping
    style.minimumLineHeight = AgentPaletteMetrics.answerCodeBlockLineHeight
    style.maximumLineHeight = AgentPaletteMetrics.answerCodeBlockLineHeight
    return NSAttributedString(string: code, attributes: [
      .font: NSFont.monospacedSystemFont(ofSize: AgentPaletteMetrics.answerCodeFontSize, weight: .regular),
      .foregroundColor: PaletteInk.primary,
      .paragraphStyle: style,
    ])
  }

  private static func textWidth(in width: CGFloat) -> CGFloat {
    max(1, width - AgentPaletteMetrics.answerCodeBlockLeadingPadding
      - AgentPaletteMetrics.answerCodeBlockTrailingPadding)
  }

  static func height(for code: String, width: CGFloat) -> CGFloat {
    let text = max(
      AgentPaletteMetrics.answerCodeBlockLineHeight,
      PaletteAnswerText.height(of: attributed(code), width: textWidth(in: width)))
    return text + AgentPaletteMetrics.answerCodeBlockVerticalPadding * 2
  }
}
