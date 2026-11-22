import AppKit

extension ConversationMessage {
  /// The region an Ask Boltty question was about, when this question is one.
  var askedRegion: (path: String, region: AskedRegion)? {
    for part in parts {
      if case let .attachment(attachment) = part, let region = attachment.asked,
         let url = attachment.url {
        return (url.path, region)
      }
    }
    return nil
  }
}

/// What an Ask Boltty question was about, over its words: where it was asked,
/// the region at the chat's width, and what the answer drew on it.
final class PaletteAskedRegionView: NSView {
  static let placeHeight: CGFloat = 18
  static let placeGap: CGFloat = 6
  static let maxPictureHeight: CGFloat = 240
  static let minPictureHeight: CGFloat = 48
  static let pointRadius: CGFloat = 14
  static let wholeScreenInset: CGFloat = 8
  static let wholeScreenDiameter: CGFloat = 28
  static let drawingScale: CGFloat = 0.7

  let regionPath: String
  private(set) var region: AskedRegion
  private let place = NSTextField(labelWithString: "")
  private let picture = NSView()
  private let drawing = AskBolttyDrawingLayer()
  private let wholeScreen = GlassCircleButton(
    icon: .expand, accessibilityDescription: String(localized: "Whole Screen"),
    diameter: PaletteAskedRegionView.wholeScreenDiameter, size: AgentPaletteMetrics.typeMeta)
  private var drawnShapes: [AskBolttyShape] = []
  private var hasLoaded = false
  var colours: [NSColor] = [] {
    didSet {
      drawing.colours = colours
      redraw()
    }
  }

  private func redraw() {
    guard !drawnShapes.isEmpty else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    drawing.clear()
    drawing.animates = false
    for shape in drawnShapes { drawing.draw(shape, in: drawingSpace) }
    CATransaction.commit()
  }
  var onUse: ((URL) -> Void)?
  var drawnShapesForTesting: [AskBolttyShape] { drawnShapes }

  init(path: String, region: AskedRegion) {
    regionPath = path
    self.region = region
    super.init(frame: .zero)
    wantsLayer = true
    place.font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
    place.textColor = PaletteInk.secondary
    place.lineBreakMode = .byTruncatingMiddle
    place.alignment = .right
    place.isSelectable = false
    addSubview(place)

    picture.wantsLayer = true
    picture.layer?.backgroundColor = PaletteInk.fill.cgColor
    picture.layer?.masksToBounds = true
    picture.layer?.contentsGravity = .resizeAspect
    drawing.scale = Self.drawingScale
    drawing.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    picture.layer?.addSublayer(drawing)
    addSubview(picture)

    wholeScreen.translatesAutoresizingMaskIntoConstraints = true
    wholeScreen.button.target = self
    wholeScreen.button.action = #selector(showWholeScreen)
    wholeScreen.button.toolTip = String(localized: "The whole screen, as the agent saw it")
    wholeScreen.isHidden = region.area == nil
    addSubview(wholeScreen)

    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    apply(region, animates: false)
  }

  required init?(coder: NSCoder) { nil }

  static func height(for region: AskedRegion, width: CGFloat) -> CGFloat {
    (region.place == nil ? 0 : placeHeight + placeGap) + pictureSize(for: region, width: width).height
  }

  static func pictureSize(for region: AskedRegion, width: CGFloat) -> CGSize {
    guard width > 0 else { return .zero }
    guard region.width > 0, region.height > 0 else { return CGSize(width: width, height: maxPictureHeight) }
    let aspect = region.height / region.width
    var size = CGSize(width: width, height: (width * aspect).rounded())
    if size.height > maxPictureHeight {
      size = CGSize(width: (maxPictureHeight / aspect).rounded(), height: maxPictureHeight)
    }
    size.height = max(size.height, minPictureHeight)
    return size
  }

  /// The shapes an answer drew, with each place it pointed at as a ring.
  static func shapes(in answer: String?) -> [AskBolttyShape] {
    guard let answer else { return [] }
    return AskBolttyMark.all(in: answer).compactMap { mark in
      switch mark {
      case let .shape(shape): return shape
      case let .point(point), let .step(point):
        guard point.hasPosition else { return nil }
        return AskBolttyShape(
          kind: .circle(center: CGPoint(x: point.x, y: point.y), radius: pointRadius), label: point.label)
      case .board: return nil
      }
    }
  }

  func apply(_ region: AskedRegion, animates: Bool) {
    self.region = region
    place.stringValue = region.place ?? ""
    place.isHidden = region.place == nil
    setAccessibilityLabel(region.place ?? String(localized: "Area of the screen"))
    let shapes = Self.shapes(in: region.answer)
    guard shapes != drawnShapes else { return }
    if !shapes.starts(with: drawnShapes) {
      drawing.clear()
      drawnShapes = []
    }
    drawing.animates = animates
    let space = drawingSpace
    for shape in shapes.dropFirst(drawnShapes.count) { drawing.draw(shape, in: space) }
    drawnShapes = shapes
  }

  override func layout() {
    super.layout()
    let size = Self.pictureSize(for: region, width: bounds.width)
    picture.frame = CGRect(x: bounds.width - size.width, y: 0, width: size.width, height: size.height)
    picture.layer?.applyPaletteCorner(radius: AgentPaletteMetrics.attachmentCardCornerInChat)
    place.frame = CGRect(
      x: 0, y: size.height + Self.placeGap, width: bounds.width, height: Self.placeHeight)
    let side = Self.wholeScreenDiameter
    wholeScreen.frame = CGRect(
      x: picture.frame.maxX - Self.wholeScreenInset - side, y: Self.wholeScreenInset,
      width: side, height: side)
    let before = drawing.frame
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    drawing.frame = picture.bounds
    CATransaction.commit()
    if before.size != picture.bounds.size { redraw() }
    if !hasLoaded, size.width > 0 { loadPicture(side: max(size.width, size.height)) }
  }

  /// The whole screen in the picture's points, so the answer's thousandths land
  /// where it meant them on the region.
  private var drawingSpace: CGRect {
    let frame = shownImageRect
    let area = region.areaRect
    guard area.width > 0, area.height > 0 else { return frame }
    let x = frame.width / area.width
    let y = frame.height / area.height
    let height = 1000 * y
    let maxY = frame.maxY + area.minY * y
    return CGRect(x: frame.minX - area.minX * x, y: maxY - height, width: 1000 * x, height: height)
  }

  /// Where the picture stands in its box: a region too thin for the box's least
  /// height stands in its middle.
  private var shownImageRect: CGRect {
    let box = picture.bounds
    guard region.width > 0, region.height > 0, box.width > 0 else { return box }
    let scale = min(box.width / region.width, box.height / region.height)
    let size = CGSize(width: region.width * scale, height: region.height * scale)
    return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                  width: size.width, height: size.height)
  }

  private func loadPicture(side: CGFloat) {
    hasLoaded = true
    FileThumbnails.shared.thumbnail(
      of: URL(fileURLWithPath: regionPath), side: side,
      done: { [weak self] image in
        guard let layer = self?.picture.layer else { return }
        if !MotionPreferences.reduceMotion {
          let fade = CATransition()
          fade.type = .fade
          fade.duration = Motion.quick
          layer.add(fade, forKey: "arrive")
        }
        layer.contents = image
      })
  }

  // MARK: - Acting on it

  override func mouseUp(with event: NSEvent) {
    guard event.clickCount == 1,
          picture.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
    FileQuickLookStore.shared.show(url: URL(fileURLWithPath: regionPath), from: picture)
  }

  @objc private func showWholeScreen() {
    PaletteHelpPresenter.shared.dismiss()
    let area = region.areaRect
    FileQuickLookStore.shared.show(
      url: URL(fileURLWithPath: region.screenPath), from: picture,
      crop: CGRect(x: area.minX / 1000, y: area.minY / 1000, width: area.width / 1000, height: area.height / 1000))
  }

  @objc private func lookAtRegion() {
    FileQuickLookStore.shared.show(url: URL(fileURLWithPath: regionPath), from: picture)
  }

  @objc private func showInFinder() {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: regionPath)])
  }

  @objc private func useInFollowUp() {
    onUse?(URL(fileURLWithPath: regionPath))
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    menu.addItem(withTitle: String(localized: "Quick Look"), action: #selector(lookAtRegion), keyEquivalent: "")
      .target = self
    if region.area != nil {
      menu.addItem(withTitle: String(localized: "Whole Screen"), action: #selector(showWholeScreen), keyEquivalent: "")
        .target = self
    }
    menu.addItem(withTitle: String(localized: "Show in Finder"), action: #selector(showInFinder), keyEquivalent: "")
      .target = self
    if onUse != nil {
      menu.addItem(withTitle: String(localized: "Use in Follow-up"), action: #selector(useInFollowUp), keyEquivalent: "")
        .target = self
    }
    return menu
  }
}
