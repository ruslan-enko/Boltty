import AppKit

final class DesignInspector: NSView, NSSearchFieldDelegate {
  var onChange: (() -> Void)?
  var onParent: (() -> Void)?
  var onLetGo: (() -> Void)?
  var page = ""
  private let elementBox = NSStackView()
  private let elementName = NSTextField(wrappingLabelWithString: "")
  private let elementDetails = NSTextField(wrappingLabelWithString: "")
  private let comment = NSTextField(string: "")
  private var element: (name: String, details: [String], place: DesignElementSource.Place?, keys: Set<String>)?
  private let store: DesignKnobStore
  private let search = NSSearchField()
  private let everything = NSButton(checkboxWithTitle: "Only what this page uses", target: nil, action: nil)
  private let list = NSStackView()
  private let scroll = NSScrollView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let save = NSButton(title: "Save", target: nil, action: nil)
  private let revert = NSButton(title: "Revert All", target: nil, action: nil)
  private var rows: [DesignKnobRow] = []
  private var used: Set<String> = []
  private let history = UndoManager()

  override var undoManager: UndoManager? { history }

  init(store: DesignKnobStore) {
    self.store = store
    super.init(frame: .zero)
    search.placeholderString = "Filter values"
    search.delegate = self
    everything.state = .on
    everything.target = self
    everything.action = #selector(rebuild)
    status.font = roundedAppFont(size: AgentPaletteMetrics.typeFootnote)
    status.textColor = .secondaryLabelColor
    save.target = self
    save.action = #selector(savePressed)
    save.keyEquivalent = "s"
    save.keyEquivalentModifierMask = .command
    save.bezelColor = BolttyBrand.accent
    revert.target = self
    revert.action = #selector(revertPressed)
    list.orientation = .vertical
    list.alignment = .leading
    list.spacing = 14
    list.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 24, right: 16)
    list.translatesAutoresizingMaskIntoConstraints = false
    let document = DesignFlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(list)
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let buttons = NSStackView(views: [revert, save])
    buildElementBox()
    for view in [elementBox, search, everything, scroll, status, buttons] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      elementBox.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      elementBox.leadingAnchor.constraint(equalTo: search.leadingAnchor),
      elementBox.trailingAnchor.constraint(equalTo: search.trailingAnchor),
      search.topAnchor.constraint(equalTo: elementBox.bottomAnchor, constant: 12),
      search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      everything.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
      everything.leadingAnchor.constraint(equalTo: search.leadingAnchor),
      scroll.topAnchor.constraint(equalTo: everything.bottomAnchor, constant: 8),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      list.topAnchor.constraint(equalTo: document.topAnchor),
      list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      status.leadingAnchor.constraint(equalTo: search.leadingAnchor),
      status.trailingAnchor.constraint(equalTo: search.trailingAnchor),
      status.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
      buttons.trailingAnchor.constraint(equalTo: search.trailingAnchor),
      buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
    ])
    showChanges()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func buildElementBox() {
    elementName.font = roundedAppFont(size: 13, weight: .semibold)
    elementName.isSelectable = true
    elementDetails.font = roundedAppFont(size: 11)
    elementDetails.textColor = .secondaryLabelColor
    elementDetails.isSelectable = true
    comment.placeholderString = "What to change here"
    comment.usesSingleLineMode = false
    comment.cell?.wraps = true
    comment.cell?.isScrollable = false
    comment.maximumNumberOfLines = 4
    comment.lineBreakMode = .byWordWrapping
    let copy = NSButton(title: "Copy for Claude", target: self, action: #selector(copyPressed))
    let parent = NSButton(title: "Around It", target: self, action: #selector(parentPressed))
    let letGo = NSButton(title: "Let Go", target: self, action: #selector(letGoPressed))
    let buttons = NSStackView(views: [copy, parent, letGo])
    buttons.spacing = 6
    for button in [copy, parent, letGo] { button.controlSize = .small }
    elementBox.orientation = .vertical
    elementBox.alignment = .leading
    elementBox.spacing = 6
    elementBox.setViews([elementName, elementDetails, comment, buttons], in: .top)
    for view in [elementName, elementDetails, comment] as [NSView] {
      view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      view.widthAnchor.constraint(equalTo: elementBox.widthAnchor).isActive = true
    }
    comment.heightAnchor.constraint(equalToConstant: 48).isActive = true
    show(element: nil, source: nil)
  }

  func show(element shown: DesignElement?, source: DesignElementSource?, around: [DesignElement] = []) {
    defer {
      elementBox.arrangedSubviews.forEach { $0.isHidden = shown == nil }
      rebuild()
    }
    guard let shown else {
      element = nil
      return
    }
    var keys = shown.plainProperty.map { source?.values(of: shown.owner, property: $0) ?? [] } ?? []
    if shown.isBoltty { keys.formUnion(source?.values(of: shown.type) ?? []) }
    if shown.view is NSTextView || shown.plainProperty == "answerViews" || shown.plainProperty == "textViews" {
      keys.formUnion(source?.values(of: "PaletteAnswerText") ?? [])
    }
    for outer in around where keys.isEmpty {
      keys = source?.values(of: outer.owner, property: outer.plainProperty) ?? []
      if keys.isEmpty, outer.isBoltty { keys = source?.values(of: outer.type) ?? [] }
    }
    if keys.count > 30 { keys.formIntersection(used) }
    let place = source?.place(of: shown.property == nil ? shown.type : shown.owner, property: shown.plainProperty)
    element = (shown.name, (shown.isBoltty && shown.property != nil ? [shown.type] : []) + shown.details, place, keys)
    elementName.stringValue = shown.name
    var lines = [element!.details.joined(separator: ", ")]
    if let place { lines.append("\(place.file.lastPathComponent):\(place.line)") }
    if keys.isEmpty { lines.append("No value of its own here: say what to change and copy it for Claude.") }
    elementDetails.stringValue = lines.joined(separator: "\n")
  }

  var note: String? {
    guard let element else { return nil }
    var lines = ["Boltty Design, page “\(page)”", "Element: \(element.name)"]
    if let place = element.place {
      let path = place.file.path
      let root = DesignSources.root.path
      lines.append("Source: Sources/Boltty\(path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path):\(place.line)")
    }
    lines.append("Now: \(element.details.joined(separator: ", "))")
    let values = store.knobs.filter { element.keys.contains($0.key) }.map { knob in
      let now = DesignKnob.source(of: store.current(knob))
      return "- \(knob.owner).\(knob.name) = \(knob.expression)" + (store.changes[knob.key] == nil ? "" : " → \(now) (not saved)")
    }
    if !values.isEmpty { lines += ["Values:"] + values }
    let wish = comment.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !wish.isEmpty { lines += ["", "Change: \(wish)"] }
    return lines.joined(separator: "\n")
  }

  @objc private func copyPressed() {
    guard let note else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(note, forType: .string)
    status.stringValue = "Copied. Paste it to Claude."
  }

  @objc private func parentPressed() { onParent?() }

  @objc private func letGoPressed() {
    comment.stringValue = ""
    onLetGo?()
  }

  func pageUses(_ keys: Set<String>, isNewPage: Bool) {
    used = isNewPage ? keys : used.union(keys)
    if isNewPage { rebuild() }
  }

  func sourceChanged() {
    history.removeAllActions()
    status.stringValue = ""
    rebuild()
    showChanges()
  }

  func controlTextDidChange(_ notification: Notification) { rebuild() }

  @objc private func rebuild() {
    let words = search.stringValue.lowercased().split(separator: " ")
    everything.isEnabled = element == nil
    rows.forEach { $0.removeFromSuperview() }
    rows = store.knobs.filter { knob in
      let text = "\(knob.owner).\(knob.name)".lowercased()
      return (element.map { $0.keys.contains(knob.key) } ?? (everything.state == .off || used.contains(knob.key))) && words.allSatisfy { text.contains($0) }
    }.map { knob in
      let row = DesignKnobRow(knob: knob, setting: store.current(knob))
      row.onSet = { [weak self] setting in self?.set(setting, knob) }
      return row
    }
    list.setViews(rows, in: .top)
    for row in rows {
      row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -32).isActive = true
    }
  }

  private func set(_ setting: LiveSetting, _ knob: DesignKnob) {
    let before = store.current(knob)
    guard before != setting else { return }
    history.registerUndo(withTarget: self) { target in
      MainActor.assumeIsolated { target.set(before, knob) }
    }
    store.set(setting, for: knob)
    rows.first { $0.knob.key == knob.key }?.show(setting)
    status.stringValue = ""
    showChanges()
    onChange?()
  }

  private func showChanges() {
    let count = store.changes.count
    save.isEnabled = count > 0
    revert.isEnabled = count > 0
    save.title = count > 0 ? "Save \(count)" : "Save"
    if status.stringValue.isEmpty {
      status.stringValue = count > 0 ? "Not saved yet. Save writes the Swift source." : "As the source has it."
    }
  }

  @objc private func savePressed() {
    let names = store.knobs.filter { store.changes[$0.key] != nil }.map(\.name)
    do {
      try store.save()
      sourceChanged()
      status.stringValue = "Saved: \(names.joined(separator: ", "))."
    } catch let error as DesignKnobStore.SaveError {
      status.stringValue = error.message
    } catch {
      status.stringValue = error.localizedDescription
    }
    showChanges()
  }

  @objc private func revertPressed() {
    store.revertAll()
    sourceChanged()
    onChange?()
  }
}

final class DesignKnobRow: NSView {
  let knob: DesignKnob
  var onSet: ((LiveSetting) -> Void)?
  private var setting: LiveSetting
  private var parts: [Part] = []
  private let title = NSTextField(labelWithString: "")
  private let swatch = DesignSwatch()
  private let reset = NSButton(title: "Reset", target: nil, action: nil)

  private struct Part {
    let slider: NSSlider
    let field: NSTextField
    let step: Double
  }

  init(knob: DesignKnob, setting: LiveSetting) {
    self.knob = knob
    self.setting = setting
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    title.stringValue = knob.name
    title.toolTip = "\(knob.owner).\(knob.name) — \(knob.file.lastPathComponent)"
    title.font = roundedAppFont(size: 13)
    title.lineBreakMode = .byTruncatingMiddle
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    reset.controlSize = .small
    reset.bezelStyle = .inline
    reset.target = self
    reset.action = #selector(resetPressed)
    let head = NSStackView(views: [title, swatch, reset])
    head.spacing = 8
    let column = NSStackView(views: [head])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 4
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    var constraints = [
      column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
      column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
      swatch.widthAnchor.constraint(equalToConstant: 28), swatch.heightAnchor.constraint(equalToConstant: 16),
    ]
    switch knob.setting {
    case .number(let value):
      swatch.isHidden = true
      let fine = knob.isTime || value != value.rounded() && value < 2 || value == 0
      let top = fine ? max(1, value * 3) : max(value * 2, value + 16)
      add(to: column, label: nil, top: top, step: fine ? 0.01 : 0.5)
    case .colour:
      add(to: column, label: "L", top: 1, step: 0.005)
      add(to: column, label: "C", top: 0.35, step: 0.005)
      add(to: column, label: "H", top: 360, step: 1)
      add(to: column, label: "A", top: 1, step: 0.01)
    }
    for view in column.arrangedSubviews {
      constraints.append(view.widthAnchor.constraint(equalTo: column.widthAnchor))
    }
    NSLayoutConstraint.activate(constraints)
    show(setting)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func add(to column: NSStackView, label: String?, top: Double, step: Double) {
    let slider = NSSlider(value: 0, minValue: 0, maxValue: top, target: self, action: #selector(slid(_:)))
    slider.controlSize = .small
    slider.isContinuous = true
    let field = NSTextField(string: "")
    field.controlSize = .small
    field.alignment = .right
    field.target = self
    field.action = #selector(typed(_:))
    field.widthAnchor.constraint(equalToConstant: 60).isActive = true
    var views: [NSView] = [slider, field]
    if let label {
      let name = NSTextField(labelWithString: label)
      name.textColor = .secondaryLabelColor
      name.widthAnchor.constraint(equalToConstant: 14).isActive = true
      views.insert(name, at: 0)
    }
    let row = NSStackView(views: views)
    row.spacing = 8
    column.addArrangedSubview(row)
    parts.append(Part(slider: slider, field: field, step: step))
  }

  func show(_ next: LiveSetting) {
    setting = next
    let values: [Double]
    switch next {
    case .number(let value): values = [value]
    case .colour(let value, let alpha):
      values = [value.l, value.c, value.h, alpha]
      swatch.colour = value.color(alpha: alpha)
    }
    for (part, value) in zip(parts, values) {
      if part.slider.maxValue < value { part.slider.maxValue = value }
      part.slider.doubleValue = value
      part.field.stringValue = DesignKnob.number(value)
    }
    reset.isHidden = next == knob.setting
    title.font = roundedAppFont(size: 13, weight: next == knob.setting ? .regular : .semibold)
  }

  private func value(at index: Int, is value: Double) -> LiveSetting {
    switch setting {
    case .number: return .number(value)
    case .colour(var colour, var alpha):
      switch index {
      case 0: colour.l = min(1, max(0, value))
      case 1: colour.c = max(0, value)
      case 2: colour.h = value
      default: alpha = min(1, max(0, value))
      }
      return .colour(colour, alpha: alpha)
    }
  }

  @objc private func slid(_ slider: NSSlider) {
    guard let index = parts.firstIndex(where: { $0.slider === slider }) else { return }
    let step = parts[index].step
    onSet?(value(at: index, is: ((slider.doubleValue / step).rounded() * step * 10_000).rounded() / 10_000))
  }

  @objc private func typed(_ field: NSTextField) {
    guard let index = parts.firstIndex(where: { $0.field === field }) else { return }
    guard let value = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")), value.isFinite, value >= 0
    else { return show(setting) }
    onSet?(self.value(at: index, is: value))
  }

  @objc private func resetPressed() { onSet?(knob.setting) }
}

final class DesignSwatch: NSView {
  var colour = NSColor.clear {
    didSet { needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
    shape.addClip()
    NSColor.white.setFill()
    bounds.fill()
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height).fill()
    colour.setFill()
    bounds.fill(using: .sourceOver)
  }
}
