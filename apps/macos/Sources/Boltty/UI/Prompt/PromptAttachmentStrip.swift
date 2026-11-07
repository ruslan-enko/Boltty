import AppKit

@MainActor
final class PromptAttachmentStrip: NSView {
  struct Placement: Equatable {
    var inset: CGFloat
    var corner: CGFloat
    var band: CGFloat { inset + AgentPaletteMetrics.attachmentCardSide }
  }

  var placement = AgentPaletteMetrics.attachmentStripOnFirstScreen {
    didSet {
      guard placement != oldValue else { return }
      cards.forEach { $0.corner = placement.corner }
      needsLayout = true
    }
  }

  var onRemove: ((UUID) -> Void)?
  var onOpen: ((PromptAttachment) -> Void)?

  private let scroll = AttachmentStripScrollView()
  private let document = StripDocumentView()
  private let edgeFade = CAGradientLayer()
  private var attachments: [PromptAttachment] = []
  private var cards: [PromptAttachmentCard] = []
  private var scrollObserver: NSObjectProtocol?

  var cardsForTesting: [PromptAttachmentCard] { cards }
  var scrollForTesting: NSScrollView { scroll }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    scroll.translatesAutoresizingMaskIntoConstraints = true
    scroll.autoresizingMask = [.width, .height]
    scroll.frame = bounds
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasHorizontalScroller = false
    scroll.hasVerticalScroller = false
    scroll.verticalScrollElasticity = .none
    scroll.horizontalScrollElasticity = .allowed
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentView.drawsBackground = false
    scroll.contentView.postsBoundsChangedNotifications = true
    scroll.wantsLayer = true
    scroll.documentView = document
    addSubview(scroll)

    edgeFade.startPoint = CGPoint(x: 0, y: 0.5)
    edgeFade.endPoint = CGPoint(x: 1, y: 0.5)
    let opaque = NSColor.black.cgColor
    let clear = NSColor.black.withAlphaComponent(0).cgColor
    edgeFade.colors = [clear, opaque, opaque, clear]

    scrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.syncEdgeFade() }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var allowsVibrancy: Bool { false }

  func show(_ next: [PromptAttachment], animated: Bool) {
    let moves = animated && window?.isVisible == true && !MotionPreferences.reduceMotion
    let stays = Set(next.map(\.id))
    let knew = Set(attachments.map(\.id))
    attachments = next

    var arriving: [PromptAttachmentCard] = []
    var kept = cards.filter { card in
      guard let id = card.attachmentID, !stays.contains(id) else { return true }
      if moves {
        card.playExit { [weak card] in card?.removeFromSuperview() }
      } else {
        card.removeFromSuperview()
      }
      return false
    }
    for attachment in next where !knew.contains(attachment.id) {
      let card = PromptAttachmentCard(attachment: attachment, corner: placement.corner)
      card.onRemove = { [weak self] in self?.onRemove?(attachment.id) }
      card.onOpen = { [weak self] in self?.onOpen?(attachment) }
      kept.append(card)
      arriving.append(card)
      document.addSubview(card)
    }
    cards = next.compactMap { attachment in kept.first { $0.attachmentID == attachment.id } }

    placeCards(animated: moves, arriving: arriving)
    guard !arriving.isEmpty else { return }
    arriving.forEach { $0.layoutSubtreeIfNeeded() }
    if moves { arriving.forEach { $0.playEntrance() } }
    scrollToEnd(animated: moves)
  }

  func cardSnapshots() -> [UUID: (frame: NSRect, image: NSImage?)] {
    var snapshots: [UUID: (frame: NSRect, image: NSImage?)] = [:]
    let visible = scroll.contentView.bounds
    for card in cards {
      guard let id = card.attachmentID, visible.intersects(card.frame) else { continue }
      snapshots[id] = (card.convert(card.bounds, to: nil), card.snapshot())
    }
    return snapshots
  }

  override func layout() {
    super.layout()
    placeCards(animated: false, arriving: [])
  }

  private static func width(of count: Int, inset: CGFloat) -> CGFloat {
    let side = AgentPaletteMetrics.attachmentCardSide
    let gap = AgentPaletteMetrics.attachmentCardGap
    return inset * 2 + CGFloat(count) * side + CGFloat(max(0, count - 1)) * gap
  }

  private func placeCards(animated: Bool, arriving: [PromptAttachmentCard]) {
    let side = AgentPaletteMetrics.attachmentCardSide
    let gap = AgentPaletteMetrics.attachmentCardGap
    let inset = placement.inset
    let width = max(bounds.width, Self.width(of: cards.count, inset: inset))
    document.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
    let glides = cards.filter { !arriving.contains($0) }
    func place(_ card: PromptAttachmentCard, animator: Bool) {
      let index = CGFloat(cards.firstIndex { $0 === card } ?? 0)
      let origin = NSPoint(x: inset + index * (side + gap), y: inset)
      if animator {
        card.animator().setFrameOrigin(origin)
      } else {
        card.frame = NSRect(origin: origin, size: NSSize(width: side, height: side))
      }
    }
    arriving.forEach { place($0, animator: false) }
    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Motion.standard
        context.timingFunction = Motion.emphasizedCurve
        context.allowsImplicitAnimation = true
        glides.forEach { place($0, animator: true) }
      }
    } else {
      glides.forEach { place($0, animator: false) }
    }
    let overflow = max(0, width - scroll.contentView.bounds.width)
    if scroll.contentView.bounds.minX > overflow {
      scroll.contentView.setBoundsOrigin(NSPoint(x: overflow, y: 0))
    }
    scroll.reflectScrolledClipView(scroll.contentView)
    syncEdgeFade()
  }

  private func scrollToEnd(animated: Bool) {
    let end = NSPoint(x: max(0, document.frame.width - scroll.contentView.bounds.width), y: 0)
    guard animated else {
      scroll.contentView.setBoundsOrigin(end)
      scroll.reflectScrolledClipView(scroll.contentView)
      syncEdgeFade()
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Motion.standard
      context.timingFunction = Motion.emphasizedCurve
      context.allowsImplicitAnimation = true
      scroll.contentView.animator().setBoundsOrigin(end)
    }
  }

  private func syncEdgeFade() {
    guard let layer = scroll.layer else { return }
    let visible = scroll.contentView.bounds
    let width = visible.width
    guard width > 0 else { return }
    let depth = AgentPaletteMetrics.attachmentStripFadeWidth
    let before = max(0, visible.minX)
    let after = max(0, document.frame.width - visible.maxX)
    guard before > 0.5 || after > 0.5 else {
      layer.mask = nil
      return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    edgeFade.frame = scroll.bounds
    edgeFade.locations = [
      0,
      NSNumber(value: Double(min(depth, before) / width)),
      NSNumber(value: Double(1 - min(depth, after) / width)),
      1,
    ]
    layer.mask = edgeFade
    CATransaction.commit()
  }
}

private final class StripDocumentView: NSView {
  override var isFlipped: Bool { true }
  override var allowsVibrancy: Bool { false }
}

private final class AttachmentStripScrollView: NSScrollView {
  override func scrollWheel(with event: NSEvent) {
    let vertical = event.scrollingDeltaY
    let overflow = (documentView?.frame.width ?? 0) - contentView.bounds.width
    guard abs(vertical) > abs(event.scrollingDeltaX), overflow > 0 else {
      return super.scrollWheel(with: event)
    }
    let step = event.hasPreciseScrollingDeltas
      ? vertical : vertical * AgentPaletteMetrics.attachmentStripWheelStep
    let x = min(max(0, contentView.bounds.minX - step), overflow)
    contentView.setBoundsOrigin(NSPoint(x: x, y: 0))
    reflectScrolledClipView(contentView)
  }
}
