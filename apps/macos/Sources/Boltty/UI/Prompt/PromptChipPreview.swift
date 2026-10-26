import AppKit

@MainActor
final class PromptChipPreview {
  private weak var host: NSView?
  private var popover: NSPopover?
  private var shownID: UUID?
  private var pendingID: UUID?
  private var timer: Timer?
  private var lastClosedAt: TimeInterval = -.infinity

  var isShownForTesting: Bool { popover?.isShown == true }

  init(host: NSView) {
    self.host = host
  }

  func hover(_ attachment: PromptAttachment?, at rect: NSRect) {
    guard let attachment else {
      dismiss()
      return
    }
    if shownID == attachment.id {
      popover?.positioningRect = rect
      return
    }
    if pendingID == attachment.id { return }
    let warm = popover?.isShown == true
      || Motion.now - lastClosedAt < AgentPaletteMetrics.helpTagWarmWindow
    close()
    pendingID = attachment.id
    timer?.invalidate()
    let delay = warm ? 0 : Motion.scaled(AgentPaletteMetrics.helpTagDelay)
    timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.show(attachment, at: rect) }
    }
  }

  func dismiss() {
    timer?.invalidate()
    timer = nil
    pendingID = nil
    close()
  }

  private func close() {
    guard let popover else { return }
    if popover.isShown {
      popover.close()
      lastClosedAt = Motion.now
    }
    self.popover = nil
    shownID = nil
  }

  private func show(_ attachment: PromptAttachment, at rect: NSRect) {
    pendingID = nil
    guard let host, host.window?.isVisible == true else { return }
    let content = Self.content(for: attachment)
    let controller = NSViewController()
    controller.view = content
    let popover = NSPopover()
    popover.behavior = .applicationDefined
    popover.animates = true
    popover.appearance = NSAppearance(named: .darkAqua)
    popover.contentViewController = controller
    popover.contentSize = content.fittingSize
    popover.show(relativeTo: rect, of: host, preferredEdge: host.isFlipped ? .minY : .maxY)
    self.popover = popover
    shownID = attachment.id
  }

  // MARK: - Content

  static func content(for attachment: PromptAttachment) -> NSView {
    switch attachment.payload {
    case let .imageData(data, _):
      if let image = NSImage(data: data) { return imageContent(image) }
      return textContent(attachment.tooltip)
    case let .screen(selection):
      if let image = NSImage(data: selection.region) { return imageContent(image) }
      return textContent(attachment.tooltip)
    case let .file(url):
      if attachment.kind == .image, let image = NSImage(contentsOf: url) {
        return imageContent(image)
      }
      return fileContent(url)
    case let .text(text):
      return textContent(text)
    }
  }

  private static func imageContent(_ image: NSImage) -> NSView {
    let side = AgentPaletteMetrics.chipPreviewImageMaxSide
    let scale = min(1, side / max(image.size.width, image.size.height, 1))
    let size = NSSize(
      width: max(1, (image.size.width * scale).rounded()),
      height: max(1, (image.size.height * scale).rounded())
    )
    let picture = NSImageView(image: image)
    picture.imageScaling = .scaleProportionallyUpOrDown
    picture.wantsLayer = true
    picture.layer?.cornerRadius = AgentPaletteMetrics.chipPreviewImageCornerRadius
    picture.layer?.cornerCurve = .continuous
    picture.layer?.masksToBounds = true
    picture.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      picture.widthAnchor.constraint(equalToConstant: size.width),
      picture.heightAnchor.constraint(equalToConstant: size.height),
    ])
    return padded(picture, by: AgentPaletteMetrics.chipPreviewImageInset)
  }

  private static func fileContent(_ url: URL) -> NSView {
    let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
    icon.translatesAutoresizingMaskIntoConstraints = false
    let side = AgentPaletteMetrics.chipPreviewFileIconSize
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: side),
      icon.heightAnchor.constraint(equalToConstant: side),
    ])
    let name = label(url.lastPathComponent, font: roundedAppFont(size: AgentPaletteMetrics.typeMeta, weight: .medium))
    name.textColor = PaletteInk.primary
    name.lineBreakMode = .byTruncatingMiddle
    let folder = label(
      (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
      font: roundedAppFont(size: AgentPaletteMetrics.typeFootnote)
    )
    folder.textColor = PaletteInk.secondary
    folder.lineBreakMode = .byTruncatingMiddle
    let words = NSStackView(views: [name, folder])
    words.orientation = .vertical
    words.alignment = .leading
    words.spacing = 2
    let row = NSStackView(views: [icon, words])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.widthAnchor.constraint(lessThanOrEqualToConstant: AgentPaletteMetrics.chipPreviewTextMaxWidth)
      .isActive = true
    return padded(row, by: AgentPaletteMetrics.chipPreviewTextInset)
  }

  private static func textContent(_ text: String) -> NSView {
    let field = label(excerpt(of: text), font: roundedAppFont(size: AgentPaletteMetrics.typeMeta))
    field.textColor = PaletteInk.primary
    field.maximumNumberOfLines = AgentPaletteMetrics.chipPreviewTextMaxLines
    field.lineBreakMode = .byTruncatingTail
    field.cell?.wraps = true
    field.cell?.truncatesLastVisibleLine = true
    field.preferredMaxLayoutWidth = AgentPaletteMetrics.chipPreviewTextMaxWidth
    return padded(field, by: AgentPaletteMetrics.chipPreviewTextInset)
  }

  static func excerpt(of text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
    let limit = AgentPaletteMetrics.chipPreviewTextMaxLines
    guard lines.count > limit else { return trimmed }
    return lines.prefix(limit).joined(separator: "\n") + "\n…"
  }

  private static func label(_ string: String, font: NSFont) -> NSTextField {
    let field = NSTextField(labelWithString: string)
    field.font = font
    field.isSelectable = false
    return field
  }

  private static func padded(_ view: NSView, by inset: CGFloat) -> NSView {
    let container = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
      view.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
      view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
    ])
    return container
  }
}
