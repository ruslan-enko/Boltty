import AppKit

/// Every design value the source writes, with a filter. A double click opens its file.
final class DesignValuesView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  private static let columns: [(id: String, title: String, width: CGFloat)] = [
    ("name", "Name", 260), ("value", "Value", 300), ("owner", "Owner", 190), ("uses", "Mentions", 70),
    ("file", "File", 260),
  ]
  private static var loaded: [DesignValue]?

  private let search = NSSearchField()
  private let count = NSTextField(labelWithString: "")
  private let table = NSTableView()
  private let written = NSButton(checkboxWithTitle: "Only written numbers and colours", target: nil, action: nil)
  private var all: [DesignValue] = []
  private var shown: [DesignValue] = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    search.placeholderString = "Filter values"
    search.delegate = self
    count.textColor = .secondaryLabelColor
    written.target = self
    written.action = #selector(filterChanged)
    for column in Self.columns {
      let made = NSTableColumn(identifier: .init(column.id))
      made.title = column.title
      made.width = column.width
      made.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: column.id != "uses")
      table.addTableColumn(made)
    }
    table.usesAlternatingRowBackgroundColors = true
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(openFile)
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    let bar = NSStackView(views: [search, written, count])
    bar.spacing = 12
    for view in [bar, scroll] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      search.widthAnchor.constraint(equalToConstant: 260),
      bar.topAnchor.constraint(equalTo: topAnchor, constant: 16),
      bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
      bar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
      scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    if let loaded = Self.loaded {
      show(loaded)
    } else if DesignSources.areHere {
      count.stringValue = "Reading the source…"
      Task { [weak self] in
        let values = await Task.detached { DesignSources.load() }.value
        Self.loaded = values
        self?.show(values)
      }
    } else {
      count.stringValue = "The source this build came from is not on this Mac."
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func show(_ values: [DesignValue]) {
    all = values
    filterChanged()
  }

  func controlTextDidChange(_ notification: Notification) { filterChanged() }

  @objc private func filterChanged() {
    let words = search.stringValue.lowercased().split(separator: " ")
    shown = all.filter { value in
      let text = "\(value.owner).\(value.name) \(value.expression) \(value.file.lastPathComponent)".lowercased()
      return (written.state == .off || value.isWritten) && words.allSatisfy { text.contains($0) }
    }
    sort()
    count.stringValue = "\(shown.count) of \(all.count)"
    table.reloadData()
  }

  private func sort() {
    guard let order = table.sortDescriptors.first, let key = order.key else { return }
    shown.sort { a, b in
      let before = key == "uses" ? a.mentions < b.mentions
        : text(a, key).localizedStandardCompare(text(b, key)) == .orderedAscending
      let after = key == "uses" ? b.mentions < a.mentions
        : text(b, key).localizedStandardCompare(text(a, key)) == .orderedAscending
      return order.ascending ? before : after
    }
  }

  private func text(_ value: DesignValue, _ column: String) -> String {
    switch column {
    case "name": value.name
    case "value": value.expression
    case "owner": value.owner
    case "uses": "\(value.mentions)"
    default: "\(value.file.lastPathComponent):\(value.line)"
    }
  }

  @objc private func openFile() {
    guard shown.indices.contains(table.clickedRow) else { return }
    NSWorkspace.shared.open(shown[table.clickedRow].file)
  }

  func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

  func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
    sort()
    tableView.reloadData()
  }

  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    guard let column, shown.indices.contains(row) else { return nil }
    let field = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTextField
      ?? {
        let made = NSTextField(labelWithString: "")
        made.identifier = column.identifier
        made.lineBreakMode = .byTruncatingTail
        return made
      }()
    field.stringValue = text(shown[row], column.identifier.rawValue)
    field.toolTip = field.stringValue
    return field
  }
}
