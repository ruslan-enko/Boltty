import AppKit
import Combine

@MainActor
final class LimitsMenu: NSObject {
  var rows: () -> [UsageGlanceRow] = { [] }
  var refresh: () async -> Void = {}
  var changes: AnyPublisher<Void, Never>? {
    didSet { if menu != nil { watchChanges() } }
  }
  var onOpenUsage: (() -> Void)?

  private weak var menu: NSMenu?
  private var shownItems: [NSMenuItem] = []
  private var shownRows: [UsageGlanceRow]?
  private var subscription: AnyCancellable?
  private var ticker: Timer?
  private var reading: Task<Void, Never>?

  static let width: CGFloat = 320
  static let sideInset: CGFloat = 14
  static let iconSize: CGFloat = 16
  static let iconGap: CGFloat = 6
  static let lineGap: CGFloat = 4
  static let columnGap: CGFloat = 8
  static let nameWidth: CGFloat = 76
  static let percentWidth: CGFloat = 24
  static let percentSize: CGFloat = 9.5
  static let meterHeight: CGFloat = 4
  static let nameSize: CGFloat = 13
  static let detailSize: CGFloat = 11

  private var meterLeading: CGFloat { Self.sideInset + Self.iconSize + Self.iconGap + Self.nameWidth + Self.columnGap }

  func open(in menu: NSMenu) {
    self.menu = menu
    shownItems = []
    rebuild(force: true)
    watchChanges()
    let ticker = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.rebuild(force: true) }
    }
    RunLoop.main.add(ticker, forMode: .common)
    self.ticker = ticker
    read()
  }

  func close() {
    subscription = nil
    ticker?.invalidate()
    ticker = nil
    if let menu {
      for item in shownItems where item.menu === menu { menu.removeItem(item) }
    }
    menu = nil
    shownItems = []
    shownRows = nil
  }

  private func read() {
    guard reading == nil else { return }
    reading = Task { [weak self] in
      await self?.refresh()
      guard let self else { return }
      reading = nil
      rebuild(force: true)
    }
  }


  private func watchChanges() {
    subscription = changes?.sink { [weak self] in self?.rebuild(force: false) }
  }

  private func rebuild(force: Bool) {
    guard let menu else { return }
    let rows = rows()
    guard force || rows != shownRows else { return }
    shownRows = rows
    for item in shownItems where item.menu === menu { menu.removeItem(item) }
    shownItems = items(for: rows)
    for (index, item) in shownItems.enumerated() { menu.insertItem(item, at: index) }
  }

  private func items(for rows: [UsageGlanceRow]) -> [NSMenuItem] {
    let shown = rows.filter {
      if case let .limits(usage) = $0.content { !usage.windows.isEmpty } else { false }
    }
    var items: [NSMenuItem] = []
    if !shown.isEmpty { items.append(.sectionHeader(title: String(localized: "Limits"))) }
    for row in shown {
      let item = viewItem(agentView(for: row))
      item.view?.setAccessibilityElement(true)
      item.view?.setAccessibilityRole(.group)
      item.view?.setAccessibilityLabel(row.agent.displayName)
      item.view?.setAccessibilityIdentifier("boltty.limits.\(row.agent.rawValue)")
      items.append(item)
    }
    let usage = NSMenuItem(
      title: String(localized: "Usage in Settings"), action: #selector(openUsage), keyEquivalent: "")
    usage.target = self
    usage.image = BolttyIcon.chart.image(size: 16)
    items.append(usage)
    items.append(.separator())
    return items
  }

  @objc private func openUsage() { onOpenUsage?() }

  private func viewItem(_ content: NSView) -> NSMenuItem {
    let container = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      content.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
      content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
      container.widthAnchor.constraint(equalToConstant: Self.width),
    ])
    container.layoutSubtreeIfNeeded()
    container.frame = NSRect(x: 0, y: 0, width: Self.width, height: container.fittingSize.height.rounded(.up))
    let item = NSMenuItem()
    item.view = container
    item.isEnabled = false
    return item
  }

  private func agentView(for row: UsageGlanceRow) -> NSView {
    let line = NSStackView(views: [icon(of: row.agent), name(of: row)])
    line.orientation = .horizontal
    line.alignment = .centerY
    line.spacing = Self.iconGap
    line.edgeInsets = NSEdgeInsets(top: 0, left: Self.sideInset, bottom: 0, right: Self.sideInset)
    line.toolTip = row.takesNextChat ? UsageGlanceText.takesNextChat : nil

    line.setCustomSpacing(Self.columnGap, after: line.arrangedSubviews[1])
    guard case let .limits(usage) = row.content else { return line }
    let meters = usage.windows.sorted { $0.kind.order < $1.kind.order }.map(meter(for:))
    for meter in meters { line.addArrangedSubview(meter) }
    for meter in meters.dropFirst() {
      meter.widthAnchor.constraint(equalTo: meters[0].widthAnchor).isActive = true
    }
    let below = usage.notes.map { note($0, leading: meterLeading) }

    let stack = NSStackView(views: [line] + below)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Self.lineGap
    for view in stack.arrangedSubviews {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    return stack
  }

  private func icon(of agent: AgentId) -> NSView {
    let icon = NSImageView()
    if let face = MascotSnapshotCache.image(MascotLook.face(for: agent), size: Self.iconSize, scale: 2) {
      icon.image = NSImage(cgImage: face, size: NSSize(width: Self.iconSize, height: Self.iconSize))
    }
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
      icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
    ])
    return icon
  }

  private func name(of row: UsageGlanceRow) -> NSView {
    let name = Self.label(
      row.agent.shortDisplayName, size: Self.nameSize, ink: .labelColor,
      weight: row.takesNextChat ? .semibold : .regular)
    name.widthAnchor.constraint(equalToConstant: Self.nameWidth).isActive = true
    return name
  }

  private func meter(for window: AgentUsageWindow) -> NSView {
    let used = min(100, max(0, window.usedPercent))
    let meter = SegmentedUsageMeter()
    meter.segments = UsageSegments.count(for: window.kind)
    meter.used = Double(used) / 100
    meter.translatesAutoresizingMaskIntoConstraints = false
    meter.heightAnchor.constraint(equalToConstant: Self.meterHeight).isActive = true
    let percent = Self.label("\(used)%", size: Self.percentSize, ink: .secondaryLabelColor, digits: true)
    percent.alignment = .right
    percent.widthAnchor.constraint(equalToConstant: Self.percentWidth).isActive = true
    let pair = NSStackView(views: [meter, percent])
    pair.orientation = .horizontal
    pair.alignment = .centerY
    pair.spacing = 3
    meter.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let phrase = [UsageGlanceText.used(window), UsageGlanceText.reset(window)].compactMap { $0 }.joined(separator: ", ")
    pair.toolTip = "\(window.title): \(phrase)"
    pair.setAccessibilityElement(true)
    pair.setAccessibilityLabel(window.title)
    pair.setAccessibilityValue(phrase)
    return pair
  }

  private func note(_ text: String, leading: CGFloat) -> NSView {
    let trailing = Self.sideInset
    let words = NSAttributedString(
      string: text,
      attributes: [.font: NSFont.menuFont(ofSize: Self.detailSize), .foregroundColor: NSColor.secondaryLabelColor]
    )
    let label = NSTextField(labelWithAttributedString: words)
    label.isSelectable = false
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.preferredMaxLayoutWidth = Self.width - leading - trailing
    let holder = NSView()
    label.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: leading),
      label.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -trailing),
      label.topAnchor.constraint(equalTo: holder.topAnchor),
      label.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
    ])
    return holder
  }

  private static func label(
    _ text: String, size: CGFloat, ink: NSColor, weight: NSFont.Weight = .regular, digits: Bool = false
  ) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    let base = NSFont.menuFont(ofSize: size)
    let font = weight == .regular ? base : NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    label.font = digits ? font.withMonospacedDigits : font
    label.textColor = ink
    label.lineBreakMode = .byTruncatingTail
    label.isSelectable = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }
}

private extension NSFont {
  var withMonospacedDigits: NSFont {
    let descriptor = fontDescriptor.addingAttributes([
      .featureSettings: [[
        NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
        NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
      ]],
    ])
    return NSFont(descriptor: descriptor, size: pointSize) ?? self
  }
}
