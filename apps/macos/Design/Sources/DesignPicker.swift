import AppKit

@MainActor
struct DesignElement {
  let view: NSView
  let owner: String
  let property: String?
  let type: String
  let isBoltty: Bool

  var name: String { property.map { "\(owner).\($0)" } ?? type }

  var plainProperty: String? { property.map { String($0.prefix { $0 != "[" }) } }

  static func all(in root: NSView) -> [DesignElement] {
    var names: [ObjectIdentifier: (owner: String, property: String)] = [:]
    var found: [DesignElement] = []
    func visit(_ view: NSView) {
      let reflected = String(reflecting: Swift.type(of: view))
      let type = plain(reflected)
      let isBoltty = reflected.hasPrefix("Boltty.") && !type.hasPrefix("Design")
      if isBoltty { hold(Mirror(reflecting: view), owner: type) }
      let name = names[ObjectIdentifier(view)]
      if isBoltty || name != nil {
        found.append(DesignElement(
          view: view, owner: name?.owner ?? type, property: name?.property, type: type, isBoltty: isBoltty))
      }
      view.subviews.forEach(visit)
    }
    func hold(_ mirror: Mirror, owner: String) {
      for child in mirror.children {
        guard var label = child.label else { continue }
        if label.hasPrefix("$__lazy_storage_$_") { label = String(label.dropFirst("$__lazy_storage_$_".count)) }
        if let view = unwrapped(child.value) as? NSView {
          keep(view, owner, label)
        } else if let views = child.value as? [NSView] {
          for (index, view) in views.enumerated() { keep(view, owner, "\(label)[\(index)]") }
        }
      }
      if let parent = mirror.superclassMirror, String(reflecting: parent.subjectType).hasPrefix("Boltty.") {
        hold(parent, owner: plain(String(reflecting: parent.subjectType)))
      }
    }
    func keep(_ view: NSView, _ owner: String, _ label: String) {
      if names[ObjectIdentifier(view)] == nil { names[ObjectIdentifier(view)] = (owner, label) }
    }
    visit(root)
    return found
  }

  private static func unwrapped(_ value: Any) -> Any {
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional, let inner = mirror.children.first?.value else { return value }
    return inner
  }

  private static func plain(_ reflected: String) -> String {
    String(reflected.split(separator: ".").last ?? "")
  }

  private static let unseen: Set<String> = ["PaletteInvisibleScroller"]

  static func under(_ point: NSPoint, among elements: [DesignElement]) -> DesignElement? {
    let hits = elements.filter { element in
      guard !unseen.contains(element.type), element.name != "MascotNSView.canvas" else { return false }
      let view = element.view
      guard !view.isOutOfSight, view.bounds.width >= 1, view.bounds.height >= 1 else { return false }
      return element.shown.contains(view.convert(point, from: nil)) && element.isSeen
    }
    return hits.min { $0.area < $1.area }
  }

  /// A view that does not clip has a visible rect past its own bounds.
  var shown: NSRect { view.visibleRect.intersection(view.bounds) }

  private var area: CGFloat { view.bounds.width * view.bounds.height }

  private var isSeen: Bool {
    if property?.hasSuffix("Sensor") == true { return false }
    if let field = view as? NSTextField { return !field.stringValue.isEmpty }
    if let image = view as? NSImageView { return image.image != nil }
    if view is NSControl || isBoltty { return true }
    guard let layer = view.layer else { return false }
    return layer.contents != nil || (layer.backgroundColor?.alpha ?? 0) > 0
  }

  func parent(among elements: [DesignElement]) -> DesignElement? {
    var view = view.superview
    while let current = view {
      if let element = elements.first(where: { $0.view === current }) { return element }
      view = current.superview
    }
    return nil
  }

  var details: [String] {
    var said = ["\(Self.number(view.bounds.width)) × \(Self.number(view.bounds.height))"]
    if let field = view as? NSTextField {
      if let font = field.font { said.append("font \(Self.number(font.pointSize))") }
      let words = field.stringValue.replacingOccurrences(of: "\n", with: " ")
      said.append("“\(words.count > 40 ? words.prefix(40) + "…" : words)”")
    }
    if let layer = view.layer {
      if layer.cornerRadius > 0 { said.append("corner \(Self.number(layer.cornerRadius))") }
      if let colour = layer.backgroundColor, colour.alpha > 0, let made = NSColor(cgColor: colour) {
        said.append("fill \(DesignFoundations.oklch(made))")
      }
    }
    if let host = view as? PaletteGlassHost { said.append("corner \(Self.number(host.renderedCornerRadius))") }
    return said
  }

  private static func number(_ value: CGFloat) -> String { DesignFoundations.number(value) }
}

final class DesignPickerOverlay: NSView {
  var onPick: ((DesignElement) -> Void)?
  var onCancel: (() -> Void)?
  var elements: () -> [DesignElement] = { [] }
  private weak var scroll: NSScrollView?
  private var known: [DesignElement] = []
  private var hovered: DesignElement? {
    didSet { needsDisplay = true }
  }
  var chosen: DesignElement? {
    didSet { needsDisplay = true }
  }
  var isPicking = false {
    didSet {
      guard isPicking != oldValue else { return }
      known = isPicking ? elements() : []
      hovered = nil
      window?.invalidateCursorRects(for: self)
      if isPicking { window?.makeFirstResponder(self) }
    }
  }

  init(over scroll: NSScrollView) {
    self.scroll = scroll
    super.init(frame: .zero)
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(moved), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var acceptsFirstResponder: Bool { isPicking }

  override func hitTest(_ point: NSPoint) -> NSView? { isPicking ? super.hitTest(point) : nil }

  override func resetCursorRects() {
    if isPicking { addCursorRect(bounds, cursor: .crosshair) }
  }

  @objc private func moved() { needsDisplay = true }

  override func scrollWheel(with event: NSEvent) {
    hovered = nil
    scroll?.scrollWheel(with: event)
  }

  override func mouseMoved(with event: NSEvent) {
    guard isPicking else { return }
    hovered = DesignElement.under(event.locationInWindow, among: known)
  }

  override func mouseExited(with event: NSEvent) { hovered = nil }

  override func mouseDown(with event: NSEvent) {
    guard let element = DesignElement.under(event.locationInWindow, among: known) else { return }
    onPick?(element)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
  }

  override func draw(_ dirtyRect: NSRect) {
    if let chosen, chosen.view.window === window { outline(chosen, labelled: !isPicking) }
    if let hovered { outline(hovered, labelled: true) }
  }

  private func outline(_ element: DesignElement, labelled: Bool) {
    let rect = convert(element.shown, from: element.view)
    guard rect.width > 0, rect.height > 0 else { return }
    BolttyBrand.accentOnGlass.withAlphaComponent(0.18).setFill()
    rect.fill(using: .sourceOver)
    BolttyBrand.accentOnGlass.setFill()
    rect.frame(withWidth: 1.5)
    guard labelled else { return }
    let words = NSAttributedString(string: "\(element.name)  \(element.details[0])", attributes: [
      .font: roundedAppFont(size: 11, weight: .medium), .foregroundColor: NSColor.black,
    ])
    let size = words.size()
    var tag = NSRect(x: rect.minX, y: rect.maxY + 3, width: ceil(size.width) + 10, height: ceil(size.height) + 4)
    if tag.maxY > bounds.maxY { tag.origin.y = max(0, rect.minY - tag.height - 3) }
    tag.origin.x = max(0, min(tag.minX, bounds.maxX - tag.width))
    NSBezierPath(roundedRect: tag, xRadius: 4, yRadius: 4).fill()
    words.draw(at: NSPoint(x: tag.minX + 5, y: tag.minY + 2))
  }
}
