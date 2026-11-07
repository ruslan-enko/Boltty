import AppKit
import ImageIO
import UniformTypeIdentifiers

extension PromptAttachment {
  var tooltip: String {
    switch payload {
    case let .file(url):
      url.path
    case let .imageData(data, type):
      "Pasted \(type.localizedDescription ?? "image") · \(Self.byteLabel(data.count))"
    case let .text(text):
      "Pasted text · \(Self.byteLabel(text.utf8.count))"
    case let .screen(selection):
      selection.context.map { "Selected on screen in \($0)" } ?? "Selected on screen"
    }
  }

  private static func byteLabel(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
  }
}

@MainActor
final class PromptAttachmentCard: NSView {
  struct Look: Equatable {
    enum Words: Equatable {
      case path(String)
      case excerpt(String)
    }

    var picture: PictureSource?
    var words: Words
    var tag: String
    var isMissing = false

    var showsWordsAtRest: Bool { picture == nil }
  }

  enum PictureSource: Equatable {
    case file(URL)
    case data(Data)
  }

  // MARK: Looks

  static func look(for attachment: PromptAttachment) -> Look {
    switch attachment.payload {
    case let .imageData(data, _):
      Look(picture: .data(data), words: .path(attachment.label), tag: "Image")
    case let .screen(selection):
      Look(picture: .data(selection.region), words: .path(attachment.label), tag: "Image")
    case let .text(text):
      Look(picture: nil, words: .excerpt(excerpt(of: text)), tag: "Text")
    case let .file(url):
      Look(
        picture: attachment.kind == .image ? .file(url) : nil,
        words: .path(shownPath(of: url, named: restoredName(of: url))),
        tag: tag(forPath: url.path))
    }
  }

  static func look(forSentPath path: String, name: String?) -> Look {
    let url = URL(fileURLWithPath: path)
    let named = name ?? restoredName(of: url)
    guard FileManager.default.fileExists(atPath: path) else {
      return Look(picture: nil, words: .path(shownPath(of: url, named: named)), tag: "Missing", isMissing: true)
    }
    if isBolttysOwn(path), url.pathExtension == "txt", let text = beginning(of: url) {
      return Look(picture: nil, words: .excerpt(excerpt(of: text)), tag: "Text")
    }
    let isPicture = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    return Look(
      picture: isPicture ? .file(url) : nil,
      words: .path(shownPath(of: url, named: named)),
      tag: tag(forPath: path))
  }

  static func tag(forPath path: String) -> String {
    PaletteFileRowView.kindWord(ofPath: path) ?? "File"
  }

  static func shownPath(of url: URL, named name: String) -> String {
    guard !isBolttysOwn(url.path) else { return name }
    return (url.path as NSString).abbreviatingWithTildeInPath
  }

  private static func isBolttysOwn(_ path: String) -> Bool {
    path.contains("/Application Support/Boltty/")
  }

  private static func restoredName(of url: URL) -> String {
    let chat = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    return UUID(uuidString: chat).map { ConversationStore.attachedName(of: url, in: $0) }
      ?? url.lastPathComponent
  }

  private static func beginning(of url: URL) -> String? {
    guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? file.close() }
    let bytes = (try? file.read(upToCount: 600)) ?? Data()
    return String(decoding: bytes, as: UTF8.self)
  }

  static func excerpt(of text: String) -> String {
    String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
  }

  static func fitted(path: String, font: NSFont, width: CGFloat, lines: Int) -> String {
    let room = CGFloat(lines) * AgentPaletteMetrics.attachmentCardLineHeight + 0.5
    func fits(_ candidate: String) -> Bool {
      wordsText(candidate, font: font, ink: .white).boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
      ).height <= room
    }
    guard !fits(path) else { return path }
    var parts = path.split(separator: "/", omittingEmptySubsequences: true)
    while parts.count > 1 {
      parts.removeFirst()
      let shorter = "…/" + parts.joined(separator: "/")
      if fits(shorter) { return shorter }
    }
    let name = String(parts.last ?? "")
    var budget = name.count
    while budget > 8 {
      budget -= 4
      let cut = name.middleTruncated(to: budget)
      if fits(cut) { return cut }
    }
    return name.middleTruncated(to: 8)
  }

  private static func wordsText(
    _ words: String, font: NSFont, ink: NSColor, breaks: NSLineBreakMode = .byCharWrapping
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = breaks
    paragraph.minimumLineHeight = AgentPaletteMetrics.attachmentCardLineHeight
    paragraph.maximumLineHeight = AgentPaletteMetrics.attachmentCardLineHeight
    return NSAttributedString(string: words, attributes: [
      .font: font, .foregroundColor: ink, .paragraphStyle: paragraph,
    ])
  }

  // MARK: The view

  let look: Look
  private(set) var attachmentID: UUID?
  private let sentURL: URL?

  var onOpen: (() -> Void)?
  var onRemove: (() -> Void)? {
    didSet { syncClose() }
  }
  var onUse: ((URL) -> Void)?

  var corner: CGFloat {
    didSet { if corner != oldValue { needsLayout = true } }
  }

  private let surface = CardSurface()
  private let thumbnail = NSView()
  private let wordsLabel = NSTextField(wrappingLabelWithString: "")
  private let tagBackground = NSView()
  private let tagLabel = NSTextField(labelWithString: "")
  private let closeButton: GlassCircleButton
  private var trackingArea: NSTrackingArea?
  private var isHovered = false
  private var isPressed = false
  private var pictureFailed = false
  private(set) weak var revealForTesting: PaletteRevealView?

  var showsPictureForTesting: Bool { thumbnail.layer?.contents != nil }
  var isCloseShownForTesting: Bool { !closeButton.isHidden }
  func setHoveredForTesting(_ hovered: Bool) { setHovered(hovered) }
  func pressCloseForTesting() { didPressClose() }

  convenience init(attachment: PromptAttachment, corner: CGFloat) {
    self.init(look: Self.look(for: attachment), url: nil, corner: corner)
    attachmentID = attachment.id
    toolTip = attachment.tooltip
    setAccessibilityLabel(attachment.tooltip)
  }

  convenience init(sentPath path: String, name: String?, corner: CGFloat) {
    self.init(look: Self.look(forSentPath: path, name: name), url: URL(fileURLWithPath: path), corner: corner)
    toolTip = path
    setAccessibilityLabel(name ?? URL(fileURLWithPath: path).lastPathComponent)
  }

  private init(look: Look, url: URL?, corner: CGFloat) {
    self.look = look
    self.sentURL = url
    self.corner = corner
    closeButton = GlassCircleButton(
      icon: .xmark, accessibilityDescription: "Remove",
      diameter: AgentPaletteMetrics.attachmentCloseDiameter,
      size: AgentPaletteMetrics.attachmentCloseGlyph)
    super.init(frame: NSRect(
      x: 0, y: 0,
      width: AgentPaletteMetrics.attachmentCardSide, height: AgentPaletteMetrics.attachmentCardSide))
    wantsLayer = true
    layer?.masksToBounds = false

    surface.wantsLayer = true
    surface.layer?.masksToBounds = true
    surface.layer?.backgroundColor = AgentPaletteMetrics.previewFileCardFill.cgColor
    surface.autoresizingMask = [.width, .height]
    surface.frame = bounds
    addSubview(surface)

    thumbnail.wantsLayer = true
    thumbnail.layer?.contentsGravity = .resizeAspectFill
    thumbnail.layer?.masksToBounds = true
    thumbnail.autoresizingMask = [.width, .height]
    thumbnail.frame = surface.bounds
    surface.addSubview(thumbnail)

    wordsLabel.isSelectable = false
    wordsLabel.isEditable = false
    wordsLabel.drawsBackground = false
    wordsLabel.isBordered = false
    wordsLabel.cell?.wraps = true
    wordsLabel.cell?.truncatesLastVisibleLine = true
    wordsLabel.maximumNumberOfLines = AgentPaletteMetrics.attachmentCardLines
    surface.addSubview(wordsLabel)

    tagBackground.wantsLayer = true
    tagBackground.layer?.backgroundColor = AgentPaletteMetrics.attachmentTagFill.cgColor
    surface.addSubview(tagBackground)
    tagLabel.font = roundedAppFont(size: AgentPaletteMetrics.typeFootnote)
    tagLabel.textColor = PaletteInk.secondary
    tagLabel.isSelectable = false
    tagLabel.alignment = .center
    tagLabel.lineBreakMode = .byClipping
    tagLabel.stringValue = look.tag
    surface.addSubview(tagLabel)
    applyWords()
    showRestingContent(look.showsWordsAtRest)

    closeButton.button.controlSize = .small
    closeButton.button.refusesFirstResponder = true
    closeButton.button.target = self
    closeButton.button.action = #selector(didPressClose)
    closeButton.button.setAccessibilityLabel("Remove")
    closeButton.isHidden = true
    addSubview(closeButton)
    let overhang = AgentPaletteMetrics.attachmentCloseOverhang
    NSLayoutConstraint.activate([
      closeButton.topAnchor.constraint(equalTo: topAnchor, constant: -overhang),
      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: overhang),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    if look.isMissing { alphaValue = 0.5 }
    needsLayout = true
    loadPicture()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool { true }
  override var allowsVibrancy: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func layout() {
    super.layout()
    surface.layer?.applyPaletteCorner(radius: corner)
    let inset = AgentPaletteMetrics.attachmentCardInset
    let width = bounds.width - inset * 2
    let tagHeight = AgentPaletteMetrics.attachmentTagHeight
    let padding = AgentPaletteMetrics.attachmentTagPadding
    let word = ceil(tagLabel.attributedStringValue.size().width)
    let tagTop = bounds.height - inset - tagHeight
    let tag = NSRect(x: inset, y: tagTop, width: min(width, word + padding * 2), height: tagHeight)
    tagBackground.frame = tag
    tagBackground.layer?.applyPaletteCorner(radius: tagHeight / 2)
    let labelHeight = ceil(tagLabel.intrinsicContentSize.height)
    tagLabel.frame = NSRect(
      x: tag.minX, y: tag.midY - labelHeight / 2, width: tag.width, height: labelHeight)
    let cellPadding = Self.labelCellPadding
    wordsLabel.preferredMaxLayoutWidth = width + cellPadding * 2
    wordsLabel.frame = NSRect(
      x: inset - cellPadding, y: inset - 1,
      width: width + cellPadding * 2, height: tagTop - inset)
  }

  private static let labelCellPadding: CGFloat = 2

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let overhang = onRemove == nil ? 0 : AgentPaletteMetrics.attachmentCloseOverhang
    let area = NSTrackingArea(
      rect: NSRect(
        x: 0, y: -overhang, width: bounds.width + overhang, height: bounds.height + overhang),
      options: [.activeAlways, .mouseEnteredAndExited],
      owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  /// The × stands past the card's own frame, where the hit test would never look.
  override func hitTest(_ point: NSPoint) -> NSView? {
    if !closeButton.isHidden {
      let local = convert(point, from: superview)
      if closeButton.frame.contains(local) {
        return closeButton.hitTest(convert(local, to: closeButton.superview)) ?? closeButton.button
      }
    }
    return super.hitTest(point)
  }

  // MARK: Pointer

  override func mouseEntered(with event: NSEvent) { setHovered(true) }
  override func mouseExited(with event: NSEvent) {
    setHovered(false)
    setPressed(false)
  }

  /// A card taken out from under the pointer never hears `mouseExited`.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window == nil else { return }
    setHovered(false)
    setPressed(false)
  }

  override func mouseDown(with event: NSEvent) {
    guard !look.isMissing else { return }
    setPressed(true)
  }

  override func mouseUp(with event: NSEvent) {
    guard isPressed else { return }
    setPressed(false)
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    open()
  }

  override func accessibilityPerformPress() -> Bool {
    guard !look.isMissing else { return false }
    open()
    return true
  }

  private func open() {
    if let onOpen { return onOpen() }
    if let sentURL { FileQuickLookStore.shared.show(url: sentURL) }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard sentURL != nil, !look.isMissing else { return super.menu(for: event) }
    let menu = NSMenu()
    menu.addItem(withTitle: "Quick Look", action: #selector(lookAtCard), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder), keyEquivalent: "").target = self
    if onUse != nil {
      menu.addItem(withTitle: "Use in Follow-up", action: #selector(useInFollowUp), keyEquivalent: "").target = self
    }
    return menu
  }

  @objc private func lookAtCard() { open() }
  @objc private func showInFinder() {
    if let sentURL { NSWorkspace.shared.activateFileViewerSelecting([sentURL]) }
  }
  @objc private func useInFollowUp() {
    if let sentURL { onUse?(sentURL) }
  }
  @objc private func didPressClose() { onRemove?() }

  private func setHovered(_ hovered: Bool) {
    let shown = hovered && !look.isMissing
    guard shown != isHovered else { return }
    isHovered = shown
    syncClose()
    MotionPreferences.animate(duration: Motion.quick) {
      surface.layer?.backgroundColor = (shown
        ? AgentPaletteMetrics.previewFileCardHoverFill
        : AgentPaletteMetrics.previewFileCardFill).cgColor
    }
  }

  private func syncClose() {
    closeButton.isHidden = !isHovered || onRemove == nil
  }

  private func setPressed(_ pressed: Bool) {
    guard pressed != isPressed, let layer = surface.layer else { return }
    isPressed = pressed
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    MotionPreferences.springScale(layer, to: pressed ? AgentPaletteMetrics.attachmentCardPressedScale : 1)
    CATransaction.commit()
  }

  // MARK: Content

  private func applyWords() {
    let inset = AgentPaletteMetrics.attachmentCardInset
    let width = bounds.width - inset * 2
    let font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
    switch look.words {
    case let .path(path):
      wordsLabel.attributedStringValue = Self.wordsText(
        Self.fitted(path: path, font: font, width: width, lines: AgentPaletteMetrics.attachmentCardLines),
        font: font, ink: PaletteInk.primary)
    case let .excerpt(text):
      wordsLabel.attributedStringValue = Self.wordsText(
        text, font: font, ink: PaletteInk.secondary, breaks: .byWordWrapping)
    }
  }

  private func showRestingContent(_ shown: Bool) {
    wordsLabel.isHidden = !shown
    tagBackground.isHidden = !shown
    tagLabel.isHidden = !shown
  }

  private func loadPicture() {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    switch look.picture {
    case nil:
      break
    case let .file(url):
      var answeredAtOnce = true
      FileThumbnails.shared.thumbnail(
        of: url, side: AgentPaletteMetrics.attachmentThumbnailSide,
        done: { [weak self] image in self?.show(picture: image, reveals: !answeredAtOnce) },
        failed: { [weak self] in self?.showRestingContent(true) })
      answeredAtOnce = false
    case let .data(data):
      let pixels = Int(AgentPaletteMetrics.attachmentThumbnailSide * scale)
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let image = Self.downsampled(data, maxPixels: pixels)
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let self else { return }
            if let image { self.show(picture: image, reveals: true) } else { self.showRestingContent(true) }
          }
        }
      }
    }
  }

  nonisolated private static func downsampled(_ data: Data, maxPixels: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ] as CFDictionary)
  }

  private func show(picture image: CGImage, reveals: Bool) {
    guard let layer = thumbnail.layer else { return }
    layer.contents = image
    showRestingContent(false)
    guard reveals, window?.isVisible == true, !MotionPreferences.reduceMotion,
          let reveal = PaletteRevealView.make(image: image, cornerRadius: corner) else { return }
    reveal.frame = surface.bounds
    reveal.autoresizingMask = [.width, .height]
    surface.addSubview(reveal)
    layer.opacity = 0
    reveal.finished = { [weak self, weak reveal] in
      self?.thumbnail.layer?.opacity = 1
      reveal?.removeFromSuperview()
    }
    reveal.start()
    revealForTesting = reveal
  }

  // MARK: Coming and going

  func playEntrance() {
    guard !MotionPreferences.reduceMotion, let layer = surface.layer else { return }
    let scale = CABasicAnimation(keyPath: "transform")
    scale.fromValue = NSValue(caTransform3D: Motion.centredScale(
      AgentPaletteMetrics.attachmentCardAppearScale, size: layer.bounds.size))
    scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    let group = CAAnimationGroup()
    group.animations = [scale, fade]
    group.duration = AgentPaletteMetrics.attachmentCardAppearDuration
    group.timingFunction = Motion.emphasizedCurve
    layer.add(group, forKey: "entrance")
  }

  func playExit(completion: @escaping @MainActor () -> Void) {
    guard !MotionPreferences.reduceMotion, let layer = surface.layer else { return completion() }
    closeButton.isHidden = true
    CATransaction.begin()
    CATransaction.setCompletionBlock {
      MainActor.assumeIsolated(completion)
    }
    let scale = CABasicAnimation(keyPath: "transform")
    scale.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
    scale.toValue = NSValue(caTransform3D: Motion.centredScale(
      AgentPaletteMetrics.attachmentCardAppearScale, size: layer.bounds.size))
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    let group = CAAnimationGroup()
    group.animations = [scale, fade]
    group.duration = Motion.quick
    group.timingFunction = Motion.standardCurve
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false
    layer.add(group, forKey: "exit")
    CATransaction.commit()
  }

  func snapshot() -> NSImage? {
    guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { return nil }
    surface.cacheDisplay(in: surface.bounds, to: bitmap)
    let image = NSImage(size: surface.bounds.size)
    image.addRepresentation(bitmap)
    return image
  }
}

private final class CardSurface: NSView {
  override var isFlipped: Bool { true }
  override var allowsVibrancy: Bool { false }
}
