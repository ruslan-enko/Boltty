import AppKit

// MARK: - Notification lifetime

final class NotificationTokenBag {
  private var tokens: [NSObjectProtocol] = []

  func keep(_ token: NSObjectProtocol) {
    tokens.append(token)
  }

  func releaseAll() {
    tokens.forEach(NotificationCenter.default.removeObserver)
    tokens.removeAll()
  }

  deinit { releaseAll() }
}

// MARK: - Results scrolling

final class FlippedStackView: NSStackView {
  override var isFlipped: Bool { true }
}

@MainActor
/// A view the list stands alone in that takes at least the visible height,
/// so what it holds can stand in the middle of the card rather than at its top.
protocol FillsResultsViewport: NSView {}

final class ResultsListView: NSView {
  override var isFlipped: Bool { true }

  struct Line: Equatable {
    let id: AnyHashable
    let height: CGFloat
  }

  var edgeInsets = NSEdgeInsets() {
    didSet {
      measureLines()
      invalidateArrangement()
      placeLines()
    }
  }

  private(set) var lines: [Line] = []
  private var lineTops: [CGFloat] = []
  private var viewForLine: ((Int) -> NSView)?
  private var shownLines: [NSView] = []
  private var measuredViews: [NSView] = []

  var arrangedSubviews: [NSView] { lines.isEmpty ? measuredViews : shownLines }

  private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)
  private var pinned: [NSLayoutConstraint] = []
  private let scrollObservers = NotificationTokenBag()

  static let minimumReach: CGFloat = 480

  func addArrangedSubview(_ view: NSView) {
    clearLines()
    measuredViews.append(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    addSubview(view)
    invalidateArrangement()
  }

  func setLines(_ newLines: [Line], view: @escaping (Int) -> NSView) {
    releasePins()
    isRearranging = true
    measuredViews.forEach { $0.removeFromSuperview() }
    isRearranging = false
    measuredViews = []
    lines = newLines
    viewForLine = view
    measureLines()
    invalidateArrangement()
    placeLines()
  }

  func removeAllArrangedSubviews() {
    releasePins()
    isRearranging = true
    subviews.forEach { $0.removeFromSuperview() }
    isRearranging = false
    measuredViews = []
    shownLines = []
    clearLines()
    invalidateArrangement()
  }

  func frameOfLine(at index: Int) -> NSRect {
    guard lines.indices.contains(index) else { return .zero }
    return NSRect(
      x: edgeInsets.left, y: lineTops[index],
      width: max(0, bounds.width - edgeInsets.left - edgeInsets.right),
      height: lines[index].height
    )
  }

  private func clearLines() {
    for view in shownLines where view.superview === self { view.isHidden = true }
    shownLines = []
    lines = []
    lineTops = []
    viewForLine = nil
  }

  private var isRearranging = false

  override func willRemoveSubview(_ subview: NSView) {
    super.willRemoveSubview(subview)
    guard !isRearranging, superview != nil else { return }
    shownLines.removeAll { $0 === subview }
    guard let index = measuredViews.firstIndex(where: { $0 === subview }) else { return }
    measuredViews.remove(at: index)
    invalidateArrangement()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    scrollObservers.releaseAll()
    invalidateArrangement()
    guard let clip = superview as? NSClipView else { return }
    clip.postsBoundsChangedNotifications = true
    scrollObservers.keep(NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.placeLines() }
    })
  }

  private func measureLines() {
    var y = edgeInsets.top
    lineTops = lines.map { line in
      defer { y += line.height }
      return y
    }
  }

  private var columnHeight: CGFloat {
    edgeInsets.top + edgeInsets.bottom + lines.reduce(0) { $0 + $1.height }
  }

  private func releasePins() {
    NSLayoutConstraint.deactivate(pinned)
    pinned = []
  }

  private func invalidateArrangement() {
    releasePins()
    if !measuredViews.isEmpty {
      heightConstraint.isActive = false
      var above = topAnchor
      var aboveInset = edgeInsets.top
      for view in measuredViews {
        pinned += [
          view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: edgeInsets.left),
          view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgeInsets.right),
          view.topAnchor.constraint(equalTo: above, constant: aboveInset),
        ]
        above = view.bottomAnchor
        aboveInset = 0
      }
      pinned.append(bottomAnchor.constraint(equalTo: above, constant: edgeInsets.bottom))
      if measuredViews.count == 1, measuredViews[0] is FillsResultsViewport,
        let clip = superview as? NSClipView
      {
        pinned.append(heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor))
      }
      NSLayoutConstraint.activate(pinned)
    } else {
      heightConstraint.constant = columnHeight
      heightConstraint.isActive = true
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    placeLines()
  }

  private func placeLines() {
    guard let viewForLine, !lines.isEmpty else { return }
    let reach = linesInReach()
    var placed: [NSView] = []
    placed.reserveCapacity(reach.count)
    for index in reach {
      let view = viewForLine(index)
      let frame = frameOfLine(at: index)
      if view.superview !== self {
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = frame
        addSubview(view)
      } else if view.frame != frame {
        view.frame = frame
      }
      if view.isHidden { view.isHidden = false }
      placed.append(view)
    }
    let kept = Set(placed.map(ObjectIdentifier.init))
    for view in shownLines where view.superview === self && !kept.contains(ObjectIdentifier(view)) {
      view.isHidden = true
    }
    shownLines = placed
  }

  private func linesInReach() -> Range<Int> {
    let viewport = (superview as? NSClipView).map { convert($0.bounds, from: $0) } ?? bounds
    let reach = max(viewport.height, Self.minimumReach)
    let top = viewport.minY - reach
    let bottom = viewport.maxY + reach
    let first = partition { lineTops[$0] + lines[$0].height > top }
    let end = partition { lineTops[$0] >= bottom }
    return first..<max(first, end)
  }

  private func partition(_ isPast: (Int) -> Bool) -> Int {
    var low = 0
    var high = lines.count
    while low < high {
      let mid = (low + high) / 2
      if isPast(mid) { high = mid } else { low = mid + 1 }
    }
    return low
  }
}

// MARK: - Empty results

final class BolttyAIEmptyResultsView: NSView, FillsResultsViewport {
  private let label = NSTextField(labelWithString: "")
  private let mascotView: MascotNSView
  var title: String { label.stringValue }
  var mascotLookForTesting: MascotLook { mascotView.look }

  convenience init(emptyHistoryFor agent: AgentId) {
    self.init(query: "", message: "No chats with \(agent.shortDisplayName) yet", agent: agent)
  }

  convenience init(query: String, agent: AgentId? = nil) {
    self.init(query: query, message: nil, agent: agent)
  }

  private init(query: String, message: String?, agent: AgentId?) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    mascotView = MascotNSView(
      conversationID: Self.emptyStateIdentity,
      look: MascotLook.face(for: agent)
    )
    super.init(frame: .zero)
    mascotView.emotion = message != nil ? .sleeping : trimmed.isEmpty ? .curious : .concerned
    label.stringValue = message ?? (
      trimmed.isEmpty ? "No chats yet" : "Send as new prompt"
    )
    label.setAccessibilityLabel(label.stringValue)
    if !trimmed.isEmpty {
      label.setAccessibilityHelp("Starts a new chat with \(trimmed)")
    }
    label.lineBreakMode = .byTruncatingTail
    translatesAutoresizingMaskIntoConstraints = false

    label.font = roundedAppFont(size: AgentPaletteMetrics.resultsTitleFontSize)
    label.textColor = NSColor.secondaryLabelColor
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    mascotView.translatesAutoresizingMaskIntoConstraints = false
    mascotView.reduceMotion = MotionPreferences.reduceMotion
    addSubview(mascotView)
    addSubview(label)

    // Face and words stand as one group in the middle of whatever height the
    // list gives (`FillsResultsViewport`); alone, the view hugs them.
    let content = NSLayoutGuide()
    addLayoutGuide(content)
    let hug = heightAnchor.constraint(equalToConstant: 0)
    hug.priority = .defaultLow

    NSLayoutConstraint.activate([
      mascotView.centerXAnchor.constraint(equalTo: centerXAnchor),
      mascotView.topAnchor.constraint(
        greaterThanOrEqualTo: topAnchor,
        constant: AgentPaletteMetrics.resultsEmptyOwnVerticalPadding
      ),
      content.topAnchor.constraint(equalTo: mascotView.topAnchor),
      content.bottomAnchor.constraint(equalTo: label.bottomAnchor),
      content.centerYAnchor.constraint(equalTo: centerYAnchor),
      hug,
      mascotView.widthAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.resultsEmptyMascotSize
      ),
      mascotView.heightAnchor.constraint(
        equalToConstant: AgentPaletteMetrics.resultsEmptyMascotSize
      ),

      label.topAnchor.constraint(
        equalTo: mascotView.bottomAnchor,
        constant: AgentPaletteMetrics.resultsEmptyMascotTextSpacing
      ),
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.leadingAnchor.constraint(
        greaterThanOrEqualTo: leadingAnchor,
        constant: AgentPaletteMetrics.resultsRowHorizontalInset
      ),
      label.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor,
        constant: -AgentPaletteMetrics.resultsRowHorizontalInset
      ),
      bottomAnchor.constraint(
        greaterThanOrEqualTo: label.bottomAnchor,
        constant: AgentPaletteMetrics.resultsEmptyOwnVerticalPadding
      ),
    ])
  }

  private static let emptyStateIdentity = UUID()

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
