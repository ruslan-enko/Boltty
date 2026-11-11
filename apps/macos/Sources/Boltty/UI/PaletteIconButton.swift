import AppKit
import CoreImage

// MARK: - Icon button

class PaletteIconButton: NSButton {
  var helpShortcut: String?
  private var helpText: String?
  override var toolTip: String? {
    get { helpText }
    set {
      helpText = newValue
      super.toolTip = nil
      setAccessibilityHelp(newValue)
    }
  }
  var restingTint: NSColor = .secondaryLabelColor {
    didSet { applyTint() }
  }

  var restingBackground: NSColor = .clear {
    didSet { applyRestingBackground() }
  }

  var hoverBackground: NSColor = PaletteInk.fill {
    didSet { if isHovered { layer?.backgroundColor = hoverBackground.cgColor } }
  }

  var hoverBackdropBlurRadius: CGFloat = 0 {
    didSet {
      guard hoverBackdropBlurRadius != oldValue else { return }
      layerUsesCoreImageFilters = hoverBackdropBlurRadius > 0
      applyHoverBackdropBlur()
    }
  }

  var hoverTint: NSColor = .labelColor {
    didSet { applyTint() }
  }

  var disabledTint: NSColor? {
    didSet { applyTint() }
  }

  override var isEnabled: Bool {
    didSet { if isEnabled != oldValue { applyTint() } }
  }

  var pressScale: CGFloat = AgentPaletteMetrics.controlPressedScale

  private(set) var isHovered = false {
    didSet {
      guard isHovered != oldValue else { return }
      applyTint()
      animateHoverBackground()
      applyHoverBackdropBlur()
    }
  }

  var isKeyboardTarget = false {
    didSet {
      guard isKeyboardTarget != oldValue else { return }
      applyTint()
    }
  }
  private var isPressed = false
  private var trackingArea: NSTrackingArea?

  var isHoveredForTesting: Bool { isHovered }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  func applyRestingBackground() {
    guard !isHovered else { return }
    layer?.backgroundColor = restingBackground.cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

  override func layout() {
    super.layout()
    layer?.applyPaletteCorner(radius: bounds.height / 2)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { beginHover() }

  private func beginHover() {
    guard !isOutOfSight else { return }
    isHovered = true
    if let helpText {
      PaletteHelpPresenter.shared.schedule(
        for: self, text: helpText, shortcut: helpShortcut)
    }
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    PaletteHelpPresenter.shared.dismiss(for: self)
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    guard let window, window.isKeyWindow else { return }
    let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    guard bounds.contains(location), !isHovered else { return }
    beginHover()
  }

  override func viewDidHide() {
    super.viewDidHide()
    guard isHovered else { return }
    isHovered = false
    PaletteHelpPresenter.shared.dismiss(for: self)
  }

  override func mouseDown(with event: NSEvent) {
    PaletteHelpPresenter.shared.dismissBeforePressing(self)
    isPressed = true
    applyTint()
    setScale(pressScale)

    super.mouseDown(with: event)

    isPressed = false
    if let location = window?.mouseLocationOutsideOfEventStream {
      isHovered = bounds.contains(convert(location, from: nil))
    }
    applyTint()
    setScale(1)
  }

  private var currentScale: CGFloat = 1

  var pressTarget: CALayer? { layer }

  func setPressedForTesting(_ pressed: Bool) { setScale(pressed ? pressScale : 1) }

  private func setScale(_ scale: CGFloat) {
    guard let target = pressTarget, scale != currentScale else { return }
    currentScale = scale
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    MotionPreferences.springScale(target, to: scale)
    CATransaction.commit()
  }

  func applyTint() {
    if !isEnabled {
      contentTintColor = disabledTint ?? restingTint
    } else if isPressed {
      contentTintColor = restingTint.withAlphaComponent(1)
    } else if isHovered || isKeyboardTarget {
      contentTintColor = hoverTint
    } else {
      contentTintColor = restingTint
    }
  }

  private func applyHoverBackdropBlur() {
    guard
      isHovered,
      hoverBackdropBlurRadius > 0,
      let blur = CIFilter(name: "CIGaussianBlur")
    else {
      layer?.backgroundFilters = nil
      return
    }
    blur.setValue(hoverBackdropBlurRadius, forKey: kCIInputRadiusKey)
    layer?.backgroundFilters = [blur]
  }

  private func animateHoverBackground() {
    guard let layer else { return }
    let target = isHovered ? hoverBackground.cgColor : restingBackground.cgColor
    let previous = layer.backgroundColor
    layer.backgroundColor = target
    guard !MotionPreferences.reduceMotion else { return }
    let fade = CABasicAnimation(keyPath: "backgroundColor")
    fade.fromValue = previous
    fade.toValue = target
    fade.duration = AgentPaletteMetrics.hoverFadeDuration
    fade.timingFunction = Motion.standardCurve
    layer.add(fade, forKey: "hoverBackground")
  }
}

final class PaletteDisclosureButton: NSButton {
  var onHover: ((Bool) -> Void)?
  private(set) var isHovered = false {
    didSet { if isHovered != oldValue { onHover?(isHovered) } }
  }
  private var hoverArea: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isBordered = false
    title = ""
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isEnabled: Bool {
    didSet { if !isEnabled { isHovered = false } }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseEntered(with event: NSEvent) { isHovered = isEnabled }
  override func mouseExited(with event: NSEvent) { isHovered = false }
}

extension NSView {
  var isOutOfSight: Bool {
    var view: NSView? = self
    while let current = view {
      if current.isHidden || current.alphaValue == 0 { return true }
      view = current.superview
    }
    return false
  }
}

@MainActor
protocol PaletteHelpRoomProviding: AnyObject {
  var helpRoom: NSRect? { get }
}

@MainActor
final class PaletteHelpPresenter {
  static let shared = PaletteHelpPresenter()
  private weak var owner: NSView?
  private var bubble: NSView?
  private var delay: Timer?
  private var eventMonitor: Any?
  private var closeObserver: NSObjectProtocol?
  private(set) var isPinned = false
  private var warmUntil: CFTimeInterval = 0
  var isVisibleForTesting: Bool { bubble?.superview != nil }
  var bubbleForTesting: NSView? { bubble }
  var isWarmForTesting: Bool { CACurrentMediaTime() < warmUntil }

  func schedule(for view: NSView, text: String, shortcut: String? = nil) {
    guard !isPinned else { return }
    let warm = bubble != nil || CACurrentMediaTime() < warmUntil
    tearDown()
    owner = view
    if warm, view.window != nil, !view.isOutOfSight {
      show(for: view, text: text, shortcut: shortcut)
      return
    }
    delay = Timer.scheduledTimer(
      withTimeInterval: AgentPaletteMetrics.helpTagDelay, repeats: false
    ) { [weak self, weak view] _ in
      Task { @MainActor in
        guard let self, let view, self.owner === view, view.window != nil,
              !view.isOutOfSight else { return }
        self.show(for: view, text: text, shortcut: shortcut)
      }
    }
  }

  func show(
    for view: NSView, text: String, shortcut: String? = nil,
    pinned: Bool = false, actionTitle: String? = nil, action: (() -> Void)? = nil
  ) {
    guard let host = view.window?.contentView else { return }
    dismiss()
    owner = view
    isPinned = pinned
    let tag = PaletteHelpTag(text: text, shortcut: shortcut,
                             actionTitle: actionTitle, action: action)
    tag.frame = Self.frame(
      of: tag.fittingSize,
      for: host.convert(view.bounds, from: view),
      in: Self.room(in: host, for: view),
      flipped: host.isFlipped)
    tag.isInteractive = pinned
    host.addSubview(tag, positioned: .above, relativeTo: nil)
    tag.layoutSubtreeIfNeeded()
    bubble = tag
    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
    ) { [weak self] event in
      guard let self else { return event }
      if event.type == .keyDown, event.keyCode == 53, self.isPinned {
        self.dismiss()
        return nil
      }
      if let bubble = self.bubble, event.window === bubble.window,
         event.type == .leftMouseDown,
         bubble.bounds.contains(bubble.convert(event.locationInWindow, from: nil)) {
        return event
      }
      self.dismiss()
      return event
    }
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: view.window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss() }
    }
  }

  static func keys(of shortcut: String) -> [String] {
    var keys: [String] = []
    var rest = ""
    for character in shortcut {
      if rest.isEmpty, "⌘⌥⌃⇧".contains(character) {
        keys.append(String(character))
      } else {
        rest.append(character)
      }
    }
    if !rest.isEmpty { keys.append(rest) }
    return keys
  }

  static let tagGap: CGFloat = 6

  static func frame(of size: NSSize, for anchor: NSRect, in room: NSRect,
                    flipped: Bool) -> NSRect {
    let gap = tagGap
    let aboveY = flipped ? anchor.minY - gap - size.height : anchor.maxY + gap
    let belowY = flipped ? anchor.maxY + gap : anchor.minY - gap - size.height
    let roomAbove = flipped ? anchor.minY - room.minY : room.maxY - anchor.maxY
    let roomBelow = flipped ? room.maxY - anchor.maxY : anchor.minY - room.minY
    let needed = size.height + gap * 2
    let proposedY = roomAbove >= needed || roomAbove >= roomBelow ? aboveY : belowY
    let y = min(max(proposedY, room.minY + gap), max(room.minY + gap, room.maxY - size.height - gap))
    let x = min(max(anchor.midX - size.width / 2, room.minX + gap),
                max(room.minX + gap, room.maxX - size.width - gap))
    return NSRect(x: x, y: y, width: size.width, height: size.height)
  }

  static func room(in host: NSView, for view: NSView) -> NSRect {
    var room = room(in: host)
    var ancestor = view.superview
    while let current = ancestor {
      if let provider = current as? PaletteHelpRoomProviding, let glass = provider.helpRoom {
        let cut = room.intersection(host.convert(glass, from: current))
        if !cut.isEmpty { room = cut }
        break
      }
      ancestor = current.superview
    }
    return room
  }

  static func room(in host: NSView) -> NSRect {
    guard let window = host.window, let screen = window.screen else { return host.bounds }
    let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
    let topInHost = host.convert(window.convertPoint(fromScreen: NSPoint(x: 0, y: top)), from: nil).y
    var room = host.bounds
    if host.isFlipped {
      let cut = min(max(topInHost - room.minY, 0), room.height)
      room.origin.y += cut
      room.size.height -= cut
    } else {
      room.size.height = min(max(topInHost - room.minY, 0), room.height)
    }
    return room
  }

  func dismissBeforePressing(_ view: NSView) {
    if let bubble, view.isDescendant(of: bubble) { return }
    dismiss()
  }

  func isPinned(for view: NSView) -> Bool { isPinned && owner === view }

  func dismiss(for view: NSView) {
    guard owner === view, !isPinned else { return }
    let wasShowing = bubble != nil
    tearDown()
    if wasShowing {
      warmUntil = CACurrentMediaTime() + AgentPaletteMetrics.helpTagWarmWindow
    }
  }

  func dismiss() {
    warmUntil = 0
    tearDown()
  }

  private func tearDown() {
    delay?.invalidate()
    delay = nil
    bubble?.removeFromSuperview()
    bubble = nil
    owner = nil
    isPinned = false
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    closeObserver = nil
  }
}

final class PaletteHelpBackdrop: NSView {
  private let glass = NSGlassEffectView()
  private let density = NSView()

  static func install(in tag: NSView) {
    let backdrop = PaletteHelpBackdrop()
    backdrop.translatesAutoresizingMaskIntoConstraints = false
    tag.addSubview(backdrop, positioned: .below, relativeTo: nil)
    NSLayoutConstraint.activate([
      backdrop.leadingAnchor.constraint(equalTo: tag.leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: tag.trailingAnchor),
      backdrop.topAnchor.constraint(equalTo: tag.topAnchor),
      backdrop.bottomAnchor.constraint(equalTo: tag.bottomAnchor),
    ])
  }

  private init() {
    super.init(frame: .zero)
    glass.style = .regular
    glass.contentView = NSView()
    density.wantsLayer = true
    density.layer?.backgroundColor = AgentPaletteMetrics.helpDensity.cgColor
    addSubview(glass)
    addSubview(density)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    glass.frame = bounds
    density.frame = bounds
    glass.cornerRadius = AgentPaletteMetrics.helpCornerRadius
    density.layer?.applyPaletteCorner(radius: AgentPaletteMetrics.helpCornerRadius)
  }
}

private final class PaletteHelpTag: NSView {
  var isInteractive = false
  private var action: (() -> Void)?

  init(text: String, shortcut: String?, actionTitle: String?, action: (() -> Void)?) {
    self.action = action
    super.init(frame: .zero)
    wantsLayer = true
    PaletteHelpBackdrop.install(in: self)

    let lines = text.components(separatedBy: "\n")
    let maxWidth = AgentPaletteMetrics.helpTextMaxWidth
    let title = Self.label(lines.first ?? "", ink: PaletteInk.primary, maxWidth: maxWidth)
    let titleRow = NSStackView()
    titleRow.orientation = .horizontal
    titleRow.alignment = .centerY
    titleRow.spacing = AgentPaletteMetrics.helpKeysGap
    titleRow.setViews([title], in: .leading)
    if let shortcut, !shortcut.isEmpty {
      let caps = PaletteHelpPresenter.keys(of: shortcut).map(PaletteKeycapView.init(key:))
      let keys = NSStackView(views: caps)
      keys.orientation = .horizontal
      keys.spacing = AgentPaletteMetrics.helpKeycapSpacing
      keys.setHuggingPriority(.required, for: .horizontal)
      title.setContentHuggingPriority(.defaultLow, for: .horizontal)
      titleRow.setViews([keys], in: .trailing)
    }
    let column = NSStackView(views: [titleRow])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = AgentPaletteMetrics.helpLineSpacing
    column.translatesAutoresizingMaskIntoConstraints = false
    let rest = lines.dropFirst().joined(separator: "\n")
    if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      column.addArrangedSubview(Self.label(rest, ink: PaletteInk.secondary, maxWidth: maxWidth))
    }
    if let actionTitle, action != nil {
      let button = GlassPillButton.titled(actionTitle)
      button.button.controlSize = .regular
      button.button.titleFontSize = AgentPaletteMetrics.typeMeta
      button.button.height = AgentPaletteMetrics.helpActionHeight
      button.invalidateIntrinsicContentSize()
      button.button.target = self
      button.button.action = #selector(performAction)
      button.button.setAccessibilityIdentifier("boltty.ask.context.compact")
      if let last = column.arrangedSubviews.last {
        column.setCustomSpacing(AgentPaletteMetrics.helpActionSpacing, after: last)
      }
      column.addArrangedSubview(button)
    }
    addSubview(column)
    let horizontal = AgentPaletteMetrics.helpHorizontalPadding
    let vertical = AgentPaletteMetrics.helpVerticalPadding
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontal),
      column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontal),
      column.topAnchor.constraint(equalTo: topAnchor, constant: vertical),
      column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vertical),
      titleRow.widthAnchor.constraint(equalTo: column.widthAnchor),
    ])
    setAccessibilityRole(.group)
    setAccessibilityLabel(text)
  }

  private static func label(_ text: String, ink: NSColor, maxWidth: CGFloat) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
    label.textColor = ink
    label.preferredMaxLayoutWidth = maxWidth
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    return label
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func hitTest(_ point: NSPoint) -> NSView? {
    isInteractive ? super.hitTest(point) : nil
  }
  override func mouseDown(with event: NSEvent) {}

  @objc private func performAction() {
    PaletteHelpPresenter.shared.dismiss()
    action?()
  }
}

private final class PaletteKeycapView: NSView {
  private let glass = NSGlassEffectView()

  init(key: String) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    glass.style = .regular
    glass.contentView = NSView()
    addSubview(glass)
    let font = roundedAppFont(size: AgentPaletteMetrics.typeFootnote)
    let size = AgentPaletteMetrics.helpKeycapSize
    var constraints = [
      heightAnchor.constraint(equalToConstant: size),
      widthAnchor.constraint(greaterThanOrEqualToConstant: size),
      {
        let snug = widthAnchor.constraint(equalToConstant: size)
        snug.priority = .defaultHigh
        return snug
      }(),
    ]
    if let image = Self.icons[key]?.image(size: font.pointSize + 2, description: key) {
      let mark = NSImageView(image: image)
      mark.contentTintColor = PaletteInk.secondary
      mark.translatesAutoresizingMaskIntoConstraints = false
      addSubview(mark)
      constraints += [
        mark.centerXAnchor.constraint(equalTo: centerXAnchor),
        mark.centerYAnchor.constraint(equalTo: centerYAnchor),
      ]
    } else {
      let mark = PaletteKeyLettersView(key: key, font: font)
      mark.translatesAutoresizingMaskIntoConstraints = false
      addSubview(mark)
      constraints += [
        mark.leadingAnchor.constraint(equalTo: leadingAnchor),
        mark.trailingAnchor.constraint(equalTo: trailingAnchor),
        mark.topAnchor.constraint(equalTo: topAnchor),
        mark.bottomAnchor.constraint(equalTo: bottomAnchor),
        widthAnchor.constraint(
          greaterThanOrEqualToConstant: ceil(mark.inkWidth) + AgentPaletteMetrics.helpKeycapInset * 2),
      ]
    }
    NSLayoutConstraint.activate(constraints)
    setAccessibilityElement(false)
  }

  override func layout() {
    super.layout()
    glass.frame = bounds
    glass.cornerRadius = AgentPaletteMetrics.helpKeycapCornerRadius
  }

  private static let icons: [String: BolttyIcon] = [
    "↵": .keyReturn, "⏎": .keyReturn, "⌘": .keyCommand, "⇧": .keyShift,
    "⌥": .keyOption, "⌃": .keyControl, "⌫": .keyDelete, "⇥": .keyTab,
  ]

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class PaletteKeyLettersView: NSView {
  private let line: CTLine
  private let ink: CGRect
  var inkWidth: CGFloat { ink.width }

  init(key: String, font: NSFont) {
    line = CTLineCreateWithAttributedString(NSAttributedString(string: key, attributes: [
      .font: font,
      NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]))
    ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    super.init(frame: .zero)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let scale = window?.backingScaleFactor ?? 2
    PaletteInk.secondary.setFill()
    context.textMatrix = .identity
    context.textPosition = CGPoint(
      x: ((bounds.midX - ink.midX) * scale).rounded() / scale,
      y: ((bounds.midY - ink.midY) * scale).rounded() / scale)
    CTLineDraw(line, context)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
