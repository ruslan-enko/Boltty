import AppKit

struct ComposerSuggestion: Equatable {
  let icon: BolttyIcon
  let title: String
  let detail: String
  var detailLeads = false
}

@MainActor
final class ComposerSuggestionPicker<Item> {
  typealias Search = (_ query: String, _ deliver: @escaping @MainActor ([Item]) -> Void) -> Void

  var onPick: ((Item, NSRange) -> Void)?
  var onOpenChange: (() -> Void)?
  var shellFrame: (() -> NSRect)?

  private let findToken: (String, Int) -> ComposerToken?
  private let suggestion: (Item) -> ComposerSuggestion
  private let accessibilityLabel: String
  private weak var host: NSView?
  private weak var field: PromptTextView?
  private var list: ComposerSuggestionList? {
    didSet { if (oldValue == nil) != (list == nil) { onOpenChange?() } }
  }
  private var items: [Item] = []
  private var token: ComposerToken?
  private var context: String?
  private var search: Search?
  private var dismissedAt: Int?
  private var debounce: Timer?
  private var generation = 0

  init(
    host: NSView, field: PromptTextView, label: String,
    token: @escaping (String, Int) -> ComposerToken?,
    suggestion: @escaping (Item) -> ComposerSuggestion
  ) {
    self.host = host
    self.field = field
    self.accessibilityLabel = label
    self.findToken = token
    self.suggestion = suggestion
  }

  var isOpen: Bool { list != nil }

  func update(allowed: Bool, context: String, search: @escaping Search) {
    guard allowed, let field, field.selectedRange().length == 0,
          let found = findToken(field.string, field.selectedRange().location)
    else {
      if allowed { dismissedAt = nil }
      close()
      return
    }
    if let dismissedAt {
      if dismissedAt == found.range.location { return }
      self.dismissedAt = nil
    }
    let changed = found != token || context != self.context
    token = found
    self.context = context
    self.search = search
    guard changed else { return }
    debounce?.invalidate()
    let delay = list == nil ? 0 : 0.08
    debounce = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.runSearch() }
    }
  }

  private func runSearch() {
    guard let token, let search else { return }
    generation += 1
    let current = generation
    search(token.query) { [weak self] found in
      guard let self, self.generation == current, self.token != nil else { return }
      self.show(found)
    }
  }

  func handle(_ selector: Selector) -> Bool {
    guard let list else { return false }
    switch selector {
    case #selector(NSResponder.moveDown(_:)):
      list.move(by: 1)
    case #selector(NSResponder.moveUp(_:)):
      list.move(by: -1)
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
      pick(list.chosenIndex)
    case #selector(NSResponder.cancelOperation(_:)):
      dismissedAt = token?.range.location
      close()
    default:
      return false
    }
    return true
  }

  func close() {
    debounce?.invalidate()
    debounce = nil
    generation += 1
    token = nil
    context = nil
    list?.removeFromSuperview()
    list = nil
    items = []
  }

  func reset() {
    dismissedAt = nil
    close()
  }

  private func pick(_ index: Int) {
    guard let token, items.indices.contains(index) else { return }
    let item = items[index]
    close()
    onPick?(item, token.range)
  }

  private func show(_ found: [Item]) {
    guard let host, let field, let token else { return }
    if found.isEmpty {
      list?.removeFromSuperview()
      list = nil
      items = []
      return
    }
    let view = list ?? ComposerSuggestionList(label: accessibilityLabel)
    view.onPick = { [weak self] in self?.pick($0) }
    let keep = list.map { _ in view.chosenTitle } ?? nil
    items = found
    view.show(found.map(suggestion), keeping: token.query.isEmpty ? nil : keep)
    if view.superview !== host {
      host.addSubview(view, positioned: .above, relativeTo: nil)
    }
    list = view
    view.frame = frame(for: view.fittingSize, in: host, field: field, at: token.range.location)
  }

  private func frame(for size: NSSize, in host: NSView, field: PromptTextView, at location: Int) -> NSRect {
    let room = PaletteHelpPresenter.room(in: host)
    var anchor = field.caretBarRect ?? field.bounds
    if let layout = field.layoutManager, let container = field.textContainer,
       location < (field.string as NSString).length {
      let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 1),
                                     actualCharacterRange: nil)
      anchor.origin.x = layout.boundingRect(forGlyphRange: glyphs, in: container).minX
        + field.textContainerOrigin.x
    }
    let line = host.convert(anchor, from: field)
    let shell = shellFrame?() ?? line
    let gap = AgentPaletteMetrics.mentionGap
    let flipped = host.isFlipped
    let roomAbove = flipped ? line.minY - room.minY : room.maxY - line.maxY
    let staysInShell = flipped
      ? line.minY - gap - size.height >= shell.minY
      : line.maxY + gap + size.height <= shell.maxY
    let y: CGFloat
    if roomAbove >= size.height + gap * 2, staysInShell {
      y = flipped ? line.minY - gap - size.height : line.maxY + gap
    } else {
      y = flipped ? shell.maxY + gap : shell.minY - gap - size.height
    }
    let x = min(max(line.minX - AgentPaletteMetrics.mentionInset - AgentPaletteMetrics.mentionRowPadding,
                    room.minX + gap),
                max(room.minX + gap, room.maxX - size.width - gap))
    return NSRect(x: x, y: y, width: size.width, height: size.height).integral
  }
}

final class ComposerSuggestionList: NSView {
  var onPick: ((Int) -> Void)?
  private var rows: [ComposerSuggestionRowView] = []
  private var titles: [String] = []
  private let content = FlippedRowsView()
  private(set) var chosenIndex = 0

  var chosenTitle: String? { titles.indices.contains(chosenIndex) ? titles[chosenIndex] : nil }

  init(label: String) {
    super.init(frame: .zero)
    let glass = PaletteGlassHost(
      content: content, cornerRadius: AgentPaletteMetrics.mentionCornerRadius,
      style: .bolttyAIPrompt(clearGlass: false))
    addSubview(glass)
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    content.onLayout = { [weak self] in self?.placeRows() }
    setAccessibilityRole(.list)
    setAccessibilityLabel(label)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isFlipped: Bool { true }

  override var fittingSize: NSSize {
    let inset = AgentPaletteMetrics.mentionInset
    return NSSize(
      width: AgentPaletteMetrics.mentionWidth,
      height: CGFloat(rows.count) * AgentPaletteMetrics.mentionRowHeight + inset * 2)
  }

  func show(_ suggestions: [ComposerSuggestion], keeping title: String?) {
    titles = suggestions.map(\.title)
    rows.forEach { $0.removeFromSuperview() }
    rows = suggestions.enumerated().map { index, suggestion in
      let row = ComposerSuggestionRowView(suggestion)
      row.onHover = { [weak self] in self?.choose(index) }
      row.onClick = { [weak self] in self?.onPick?(index) }
      content.addSubview(row)
      return row
    }
    choose(title.flatMap(titles.firstIndex(of:)) ?? 0)
    content.needsLayout = true
  }

  func move(by step: Int) {
    guard !rows.isEmpty else { return }
    choose((chosenIndex + step + rows.count) % rows.count)
  }

  private func choose(_ index: Int) {
    chosenIndex = index
    for (offset, row) in rows.enumerated() { row.isChosen = offset == index }
  }

  private func placeRows() {
    let inset = AgentPaletteMetrics.mentionInset
    let height = AgentPaletteMetrics.mentionRowHeight
    for (index, row) in rows.enumerated() {
      row.frame = NSRect(x: inset, y: inset + CGFloat(index) * height,
                         width: content.bounds.width - inset * 2, height: height)
    }
  }
}

private final class FlippedRowsView: NSView {
  var onLayout: (() -> Void)?
  override var isFlipped: Bool { true }
  override func layout() {
    super.layout()
    onLayout?()
  }
}

private final class ComposerSuggestionRowView: NSView {
  var onHover: (() -> Void)?
  var onClick: (() -> Void)?
  var isChosen = false {
    didSet {
      guard isChosen != oldValue else { return }
      layer?.backgroundColor = isChosen ? PaletteInk.selectedFill.cgColor : nil
      setAccessibilitySelected(isChosen)
    }
  }

  private let icon = NSImageView()
  private let name = NSTextField(labelWithString: "")
  private let place = NSTextField(labelWithString: "")
  private var hoverArea: NSTrackingArea?

  private let detailLeads: Bool
  private let detail: String

  init(_ suggestion: ComposerSuggestion) {
    detailLeads = suggestion.detailLeads
    detail = suggestion.detail
    super.init(frame: .zero)
    wantsLayer = true
    let font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
    icon.image = suggestion.icon.image(size: AgentPaletteMetrics.mentionIconSide)
    icon.contentTintColor = PaletteInk.secondary
    name.stringValue = suggestion.title
    name.font = font
    name.textColor = PaletteInk.primary
    name.lineBreakMode = .byTruncatingMiddle
    name.isSelectable = false
    place.stringValue = suggestion.detail
    place.font = font
    place.textColor = PaletteInk.secondary
    place.lineBreakMode = suggestion.detailLeads ? .byTruncatingTail : .byTruncatingHead
    place.isSelectable = false
    place.alignment = suggestion.detailLeads ? .left : .right
    for view in [icon, name, place] as [NSView] { addSubview(view) }
    setAccessibilityElement(true)
    setAccessibilityRole(.row)
    setAccessibilityLabel([suggestion.title, suggestion.detail].filter { !$0.isEmpty }.joined(separator: ", "))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isFlipped: Bool { true }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
  }

  override func layout() {
    super.layout()
    layer?.applyPaletteCorner(radius: AgentPaletteMetrics.mentionRowCornerRadius)
    let padding = AgentPaletteMetrics.mentionRowPadding
    let side = AgentPaletteMetrics.mentionIconSide
    icon.frame = NSRect(x: padding, y: (bounds.height - side) / 2, width: side, height: side)
    let textHeight = ceil(name.intrinsicContentSize.height)
    let textY = ((bounds.height - textHeight) / 2).rounded()
    let nameX = icon.frame.maxX + AgentPaletteMetrics.mentionIconGap
    let available = bounds.width - nameX - padding
    let gap = AgentPaletteMetrics.mentionPlaceGap
    let room = max(0, available - Self.width(of: name) - gap)
    if detailLeads {
      let nameWidth = min(Self.width(of: name), available)
      name.frame = NSRect(x: nameX, y: textY, width: nameWidth, height: textHeight)
      place.frame = NSRect(x: name.frame.maxX + gap, y: textY, width: room, height: textHeight)
      return
    }
    place.stringValue = SuggestionPlace.folders(of: detail, fitting: room) { [place] words in
      Self.width(of: words, font: place.font)
    }
    let placeWidth = place.stringValue.isEmpty ? 0 : min(Self.width(of: place), room)
    let nameWidth = placeWidth > 0 ? available - placeWidth - gap : available
    name.frame = NSRect(x: nameX, y: textY, width: nameWidth, height: textHeight)
    place.frame = NSRect(x: bounds.width - padding - placeWidth, y: textY, width: placeWidth,
                         height: textHeight)
  }

  /// The words at their font, and the cell's own padding either side:
  /// `intrinsicContentSize` came short and cut every name in its middle.
  private static func width(of label: NSTextField) -> CGFloat {
    width(of: label.stringValue, font: label.font)
  }

  private static func width(of words: String, font: NSFont?) -> CGFloat {
    ceil((words as NSString).size(withAttributes: [.font: font as Any]).width) + 6
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                              owner: self)
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseMoved(with event: NSEvent) { onHover?() }
  override func mouseEntered(with event: NSEvent) { onHover?() }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick?()
  }
}

enum SuggestionPlace {
  static func folders(of path: String, fitting room: CGFloat, width: (String) -> CGFloat) -> String {
    guard !path.isEmpty, width(path) > room else { return path }
    var parts = path.split(separator: "/").map(String.init)
    while parts.count > 1 {
      parts.removeFirst()
      let shorter = "…/" + parts.joined(separator: "/")
      if width(shorter) <= room { return shorter }
    }
    if let last = parts.last, width(last) <= room { return last }
    return ""
  }
}
