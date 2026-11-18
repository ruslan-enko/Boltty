import AppKit

/// What `@` opens in the composer: files to bring with the words. It reads the
/// token at the caret, keeps the keys the composer would give a list, and hands
/// the chosen file back to become a card; the `@word` goes with it.
@MainActor
final class FileMentionPicker {
  var onPick: ((URL, NSRange) -> Void)?
  /// The shell in the host's coordinates, for the list to stand clear of it.
  var shellFrame: (() -> NSRect)?

  private weak var host: NSView?
  private weak var field: PromptTextView?
  private let search = FileMentionSearch()
  private var list: FileMentionListView?
  private var token: FileMention.Token?
  private var folder: String?
  /// The `@` Escape let go of: it stays shut until another `@` is typed.
  private var dismissedAt: Int?
  private var debounce: Timer?

  init(host: NSView, field: PromptTextView) {
    self.host = host
    self.field = field
  }

  var isOpen: Bool { list != nil }

  /// Read the field again: called on every change of its words or caret.
  func update(folder: String?, allowed: Bool) {
    guard allowed, let field,
          let found = FileMention.token(in: field.string, caret: field.selectedRange().location),
          field.selectedRange().length == 0
    else {
      if allowed { dismissedAt = nil }
      close()
      return
    }
    if let dismissedAt {
      if dismissedAt == found.range.location { return }
      self.dismissedAt = nil
    }
    let changed = found != token || folder != self.folder
    token = found
    self.folder = folder
    guard changed else { return }
    debounce?.invalidate()
    let delay = list == nil ? 0 : 0.08
    debounce = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.runSearch() }
    }
  }

  private func runSearch() {
    guard let token else { return }
    search.search(token.query, in: folder) { [weak self] found in
      self?.show(found)
    }
  }

  /// The composer's keys while the list is up; true when the list took it.
  func handle(_ selector: Selector) -> Bool {
    guard let list else { return false }
    switch selector {
    case #selector(NSResponder.moveDown(_:)):
      list.move(by: 1)
    case #selector(NSResponder.moveUp(_:)):
      list.move(by: -1)
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
      guard let chosen = list.chosen else { return false }
      pick(chosen)
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
    search.cancel()
    token = nil
    list?.removeFromSuperview()
    list = nil
  }

  /// Escape's mark goes with the words it was on.
  func reset() {
    dismissedAt = nil
    close()
  }

  private func pick(_ candidate: FileMention.Candidate) {
    guard let token else { return }
    let range = token.range
    close()
    onPick?(candidate.url, range)
  }

  private func show(_ found: [FileMention.Candidate]) {
    guard let host, let field, let token else { return }
    if found.isEmpty {
      list?.removeFromSuperview()
      list = nil
      return
    }
    let view = list ?? FileMentionListView()
    view.onPick = { [weak self] in self?.pick($0) }
    view.show(found, query: token.query)
    if view.superview !== host {
      host.addSubview(view, positioned: .above, relativeTo: nil)
    }
    list = view
    view.frame = frame(for: view.fittingSize, in: host, field: field, at: token.range.location)
  }

  /// Left-aligned at the `@`: above the line when the room is there (a chat's
  /// composer at the foot), else under the shell (the first screen under the notch).
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
    let y: CGFloat
    if roomAbove >= size.height + gap * 2 {
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

final class FileMentionListView: NSView {
  var onPick: ((FileMention.Candidate) -> Void)?
  private var rows: [FileMentionRowView] = []
  private let content = FlippedRowsView()
  private var candidates: [FileMention.Candidate] = []
  private var chosenIndex = 0

  var chosen: FileMention.Candidate? {
    candidates.indices.contains(chosenIndex) ? candidates[chosenIndex] : nil
  }

  init() {
    super.init(frame: .zero)
    // Frosted, as Limits is: it opens over any window, and clear glass let that
    // window's words read through.
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
    setAccessibilityLabel("Files")
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

  func show(_ found: [FileMention.Candidate], query: String) {
    let keep = chosen.flatMap { old in found.firstIndex { $0.url == old.url } }
    candidates = found
    rows.forEach { $0.removeFromSuperview() }
    rows = found.enumerated().map { index, candidate in
      let row = FileMentionRowView(candidate)
      row.onHover = { [weak self] in self?.choose(index) }
      row.onClick = { [weak self] in self?.onPick?(candidate) }
      content.addSubview(row)
      return row
    }
    chosenIndex = query.isEmpty ? 0 : (keep ?? 0)
    choose(chosenIndex)
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

private final class FileMentionRowView: NSView {
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

  init(_ candidate: FileMention.Candidate) {
    super.init(frame: .zero)
    wantsLayer = true
    let font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
    icon.image = (candidate.isDirectory ? BolttyIcon.folder : BolttyIcon.doc)
      .image(size: AgentPaletteMetrics.mentionIconSide)
    icon.contentTintColor = PaletteInk.secondary
    name.stringValue = candidate.url.lastPathComponent
    name.font = font
    name.textColor = PaletteInk.primary
    name.lineBreakMode = .byTruncatingMiddle
    name.isSelectable = false
    let parent = (candidate.relativePath as NSString).deletingLastPathComponent
    place.stringValue = parent.hasPrefix("/") ? (parent as NSString).abbreviatingWithTildeInPath : parent
    place.font = font
    place.textColor = PaletteInk.secondary
    place.lineBreakMode = .byTruncatingHead
    place.isSelectable = false
    place.alignment = .right
    for view in [icon, name, place] as [NSView] { addSubview(view) }
    setAccessibilityElement(true)
    setAccessibilityRole(.row)
    setAccessibilityLabel(candidate.relativePath)
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
    // The name has the row; the folder only what is left, giving way first.
    let gap = AgentPaletteMetrics.mentionPlaceGap
    let placeWidth = place.stringValue.isEmpty ? 0
      : min(Self.width(of: place), max(0, available - Self.width(of: name) - gap))
    let nameWidth = placeWidth > 0 ? available - placeWidth - gap : available
    name.frame = NSRect(x: nameX, y: textY, width: nameWidth, height: textHeight)
    place.frame = NSRect(x: bounds.width - padding - placeWidth, y: textY, width: placeWidth,
                         height: textHeight)
  }

  /// The words at their font, and the cell's own padding either side:
  /// `intrinsicContentSize` came short and cut every name in its middle.
  private static func width(of label: NSTextField) -> CGFloat {
    let words = (label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width
    return ceil(words) + 6
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
