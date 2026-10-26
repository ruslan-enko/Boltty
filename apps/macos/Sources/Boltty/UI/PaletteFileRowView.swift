import AppKit
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

final class PaletteFileRowView: NSView {
  var onPreview: ((URL) -> Void)?
  var onReveal: ((URL) -> Void)?
  var onUse: ((URL) -> Void)? {
    didSet { useButton.isHidden = onUse == nil || isMissing }
  }

  private let url: URL
  private var isMissing: Bool = false

  private let icon = NSImageView()
  private let tile = NSView()
  private let thumbnail = NSView()
  private let nameLabel = NSTextField(labelWithString: "")
  private let sizeLabel = NSTextField(labelWithString: "")
  private let previewButton = PaletteIconButton()
  private let revealButton = PaletteIconButton()
  private let useButton = PaletteIconButton()

  var isDimmedForTesting: Bool { alphaValue < 1 }
  var showsThumbnailForTesting: Bool { thumbnail.layer?.contents != nil }
  var thumbnailOpacityForTesting: Float { thumbnail.layer?.opacity ?? 0 }
  var displayedNameForTesting: String { nameLabel.stringValue }
  var displayedSizeForTesting: String { sizeLabel.stringValue }
  var previewButtonForTesting: NSButton { previewButton }
  var revealButtonForTesting: NSButton { revealButton }
  var useButtonForTesting: NSButton { useButton }

  init(path: String, name: String? = nil) {
    self.url = URL(fileURLWithPath: path)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    let exists = FileManager.default.fileExists(atPath: path)
    isMissing = !exists

    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.image = NSWorkspace.shared.icon(forFile: path)
    icon.imageScaling = .scaleProportionallyDown

    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.font = roundedAppFont(size: AgentPaletteMetrics.previewFileNameFontSize)
    nameLabel.textColor = PaletteInk.primary
    nameLabel.stringValue = name ?? url.lastPathComponent
    nameLabel.lineBreakMode = .byTruncatingMiddle
    nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    nameLabel.toolTip = path

    sizeLabel.translatesAutoresizingMaskIntoConstraints = false
    sizeLabel.font = roundedAppFont(size: AgentPaletteMetrics.previewFileSizeFontSize)
    sizeLabel.textColor = PaletteInk.secondary
    sizeLabel.stringValue = exists ? Self.formattedSize(ofPath: path) : "No longer on disk"
    sizeLabel.setContentHuggingPriority(.required, for: .horizontal)

    makeButton(
      previewButton,
      symbol: "eye",
      description: "Preview file",
      identifier: "boltty.ask.chat.file.preview",
      tooltip: "Quick Look",
      action: #selector(didPressPreview)
    )
    makeButton(
      revealButton,
      symbol: "folder",
      description: "Reveal file in Finder",
      identifier: "boltty.ask.chat.file.reveal",
      tooltip: "Reveal in Finder",
      action: #selector(didPressReveal)
    )
    makeButton(
      useButton,
      symbol: "plus",
      description: "Use file in a follow-up",
      identifier: "boltty.ask.chat.file.use",
      tooltip: "Use in follow-up",
      action: #selector(didPressUse)
    )

    wantsLayer = true
    layer?.borderWidth = 1
    layer?.borderColor = AgentPaletteMetrics.previewFileCardBorder.cgColor
    tile.translatesAutoresizingMaskIntoConstraints = false
    tile.wantsLayer = true
    tile.layer?.backgroundColor = AgentPaletteMetrics.previewFileIconTileFill.cgColor
    tile.addSubview(icon)
    thumbnail.translatesAutoresizingMaskIntoConstraints = false
    thumbnail.wantsLayer = true
    thumbnail.layer?.contentsGravity = .resizeAspectFill
    thumbnail.layer?.masksToBounds = true
    tile.addSubview(thumbnail)
    let words = NSStackView(views: [nameLabel, sizeLabel])
    words.orientation = .vertical
    words.alignment = .leading
    words.spacing = 1
    words.setClippingResistancePriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [tile, words, previewButton, revealButton, useButton])
    row.translatesAutoresizingMaskIntoConstraints = false
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 2
    row.setCustomSpacing(10, after: tile)
    row.setCustomSpacing(6, after: words)
    row.distribution = .fill
    words.setHuggingPriority(.init(1), for: .horizontal)
    words.setContentHuggingPriority(.init(1), for: .horizontal)
    row.setClippingResistancePriority(.defaultLow, for: .horizontal)
    addSubview(row)

    let inset = AgentPaletteMetrics.previewFileCardInset
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewFileRowHeight),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
      tile.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewFileIconTileSize),
      tile.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewFileIconTileSize),
      icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewFileIconSize),
      icon.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewFileIconSize),
      thumbnail.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
      thumbnail.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
      thumbnail.topAnchor.constraint(equalTo: tile.topAnchor),
      thumbnail.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
      previewButton.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewFileButtonSize),
      previewButton.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewFileButtonSize),
      revealButton.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewFileButtonSize),
      revealButton.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewFileButtonSize),
      useButton.widthAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewFileButtonSize),
      useButton.heightAnchor.constraint(equalToConstant: AgentPaletteMetrics.previewFileButtonSize),
    ])

    onPreview = { FileQuickLookStore.shared.show(url: $0) }
    onReveal = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    if isMissing {
      alphaValue = 0.5
      previewButton.isEnabled = false
      revealButton.isEnabled = false
      useButton.isHidden = true
    }

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("\(nameLabel.stringValue), \(sizeLabel.stringValue)")

    if exists {
      FileThumbnails.shared.thumbnail(of: url) { [weak self] image in
        self?.showThumbnail(image)
      }
    }
  }

  private func showThumbnail(_ image: CGImage) {
    guard let layer = thumbnail.layer, layer.contents == nil else { return }
    layer.contents = image
    icon.isHidden = true
    guard window?.isVisible == true else { return }
    if !MotionPreferences.reduceMotion, tile.bounds.width > 1,
       let reveal = PaletteRevealView.make(
         image: image, cornerRadius: AgentPaletteMetrics.previewFileIconTileCornerRadius) {
      reveal.frame = tile.bounds
      reveal.autoresizingMask = [.width, .height]
      tile.addSubview(reveal)
      layer.opacity = 0
      reveal.finished = { [weak self, weak reveal] in
        self?.thumbnail.layer?.opacity = 1
        reveal?.removeFromSuperview()
      }
      reveal.start()
      revealForTesting = reveal
      return
    }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = Motion.standard
    fade.timingFunction = Motion.emphasizedCurve
    layer.add(fade, forKey: "thumbnail")
  }

  private(set) weak var revealForTesting: PaletteRevealView?

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    layer?.applyPaletteCorner(radius: AgentPaletteMetrics.previewFileCardCornerRadius)
    tile.layer?.applyPaletteCorner(radius: AgentPaletteMetrics.previewFileIconTileCornerRadius)
    thumbnail.layer?.applyPaletteCorner(radius: AgentPaletteMetrics.previewFileIconTileCornerRadius)
  }

  private func makeButton(
    _ button: PaletteIconButton,
    symbol: String,
    description: String,
    identifier: String,
    tooltip: String,
    action: Selector
  ) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.title = ""
    button.imagePosition = .imageOnly
    button.image = NSImage(
      systemSymbolName: symbol,
      accessibilityDescription: description
    )?.withSymbolConfiguration(.init(
      pointSize: AgentPaletteMetrics.previewFileGlyphPointSize,
      weight: .medium
    ))
    button.contentTintColor = .white
    button.restingTint = PaletteInk.secondary
    button.hoverTint = .white
    button.target = self
    button.action = action
    button.toolTip = tooltip
    button.setAccessibilityIdentifier(identifier)
    button.setAccessibilityLabel(description)
  }

  private static func formattedSize(ofPath path: String) -> String {
    guard
      let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]),
      let bytes = values.fileSize
    else { return "" }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  @objc private func didPressPreview() { onPreview?(url) }
  @objc private func didPressReveal() { onReveal?(url) }
  @objc private func didPressUse() { onUse?(url) }
}

final class FileQuickLookStore: NSObject, QLPreviewPanelDataSource {
  nonisolated(unsafe) static let shared = FileQuickLookStore()
  nonisolated(unsafe) private var url: URL?

  @MainActor
  func show(url: URL) {
    self.url = url
    guard let panel = QLPreviewPanel.shared() else { return }
    panel.dataSource = self
    panel.makeKeyAndOrderFront(nil)
  }

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    url as NSURL?
  }
}

@MainActor
final class FileThumbnails {
  static let shared = FileThumbnails()

  private let cache = NSCache<NSString, CGImage>()
  private var waiting: [String: [(CGImage) -> Void]] = [:]
  var generate: (URL, CGSize, CGFloat, @escaping @Sendable (CGImage?) -> Void) -> Void = { url, size, scale, done in
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
      done(representation?.cgImage)
    }
  }

  static func wantsThumbnail(_ url: URL) -> Bool {
    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie)
  }

  func thumbnail(of url: URL, done: @escaping (CGImage) -> Void) {
    guard Self.wantsThumbnail(url) else { return }
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate?.timeIntervalSince1970 ?? 0
    let key = "\(url.path)#\(modified)"
    if let image = cache.object(forKey: key as NSString) { return done(image) }
    if waiting[key] != nil {
      waiting[key]?.append(done)
      return
    }
    waiting[key] = [done]
    let side = AgentPaletteMetrics.previewFileIconTileSize
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    generate(url, CGSize(width: side, height: side), scale) { image in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          let callbacks = FileThumbnails.shared.waiting.removeValue(forKey: key) ?? []
          guard let image else { return }
          FileThumbnails.shared.cache.setObject(image, forKey: key as NSString)
          callbacks.forEach { $0(image) }
        }
      }
    }
  }
}
