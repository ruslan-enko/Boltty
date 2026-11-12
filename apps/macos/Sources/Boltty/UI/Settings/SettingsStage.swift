import AppKit
import SwiftUI

/// What a setting changes, shown as the thing itself over the person's own
/// desktop, the way the system shows Liquid Glass.
struct SettingsStage<Content: View>: View {
  /// `nil` takes the row's whole width.
  var width: CGFloat? = SettingsStageMetrics.size.width
  var height: CGFloat = SettingsStageMetrics.size.height
  var corner: CGFloat = 16
  @ViewBuilder let content: () -> Content
  @State private var wallpaper = DesktopPicture.cached

  var body: some View {
    ZStack {
      Color.black.opacity(0.4)
      if let wallpaper {
        Image(decorative: wallpaper.image, scale: 1)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fill)
          .frame(width: width, height: height)
          .frame(maxWidth: width == nil ? .infinity : nil)
          .clipped()
          .transition(.opacity)
      }
      content()
    }
    .frame(width: width, height: height)
    .frame(maxWidth: width == nil ? .infinity : nil)
    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    .accessibilityHidden(true)
    .task {
      // The desktop as it is now: a wallpaper changed since is read again.
      let sources = DesktopPicture.sources()
      if let cached = DesktopPicture.cached, cached.source == sources.first {
        wallpaper = cached
        return
      }
      let found = await Task.detached(priority: .utility) {
        DesktopPicture.load(from: sources, maxPixels: 960)
      }.value
      DesktopPicture.cached = found
      withAnimation(SettingsMotion.quick) { wallpaper = found }
    }
  }
}

enum SettingsStageMetrics {
  static let size = CGSize(width: 320, height: 150)
  /// A grouped section's corner and its rows' inset, read off macOS 26.
  static let sectionCorner: CGFloat = 11
  static let rowInset: CGFloat = 10
  /// A stage that fills its section stands this far from every edge, its
  /// corner concentric with the section's.
  static let sectionGap: CGFloat = 6
  static var fillingCorner: CGFloat { sectionCorner - sectionGap }
}

// MARK: - The first screen

struct PromptSample: NSViewRepresentable {
  let clearGlass: Bool
  let look: MascotLook

  func makeNSView(context: Context) -> PromptSampleView {
    PromptSampleView(look: look)
  }

  func updateNSView(_ view: PromptSampleView, context: Context) {
    view.show(clearGlass: clearGlass, look: look)
  }
}

final class PromptSampleView: NSView {
  static let size = CGSize(width: 264, height: 48)

  private let row = PromptSampleRow()
  private let host: PaletteGlassHost

  init(look: MascotLook) {
    host = PaletteGlassHost(content: NSView(), cornerRadius: Self.size.height / 2, style: .bolttyAIPrompt)
    super.init(frame: CGRect(origin: .zero, size: Self.size))
    appearance = NSAppearance(named: .darkAqua)
    for view in [host, row] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = true
      view.frame = bounds
      view.autoresizingMask = [.width, .height]
      addSubview(view)
    }
    row.apply(look: look)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func show(clearGlass: Bool, look: MascotLook) {
    host.apply(surfaceStyle: .bolttyAIPrompt(clearGlass: clearGlass))
    row.apply(look: look)
  }
}

/// The first screen's line: the face, the placeholder, the folder and the microphone.
final class PromptSampleRow: NSView {
  private static let face: CGFloat = 26
  private static let inset: CGFloat = 14

  private let face: MascotNSView

  init() {
    face = MascotNSView(conversationID: UUID(), look: .face(for: nil))
    face.reduceMotion = MotionPreferences.reduceMotion
    super.init(frame: .zero)
    let hint = NSTextField(labelWithString: SampleText.placeholder)
    hint.font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
    hint.textColor = PaletteInk.secondary
    hint.lineBreakMode = .byTruncatingTail
    let glyphs = [BolttyIcon.folder, .mic].map { icon -> NSImageView in
      let view = NSImageView(image: icon.image(size: AgentPaletteMetrics.iconSide(15)) ?? NSImage())
      view.contentTintColor = PaletteInk.secondary
      return view
    }
    for view in [face, hint] + glyphs {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      face.widthAnchor.constraint(equalToConstant: Self.face),
      face.heightAnchor.constraint(equalToConstant: Self.face),
      face.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset - 2),
      face.centerYAnchor.constraint(equalTo: centerYAnchor),
      hint.leadingAnchor.constraint(equalTo: face.trailingAnchor, constant: 8),
      hint.centerYAnchor.constraint(equalTo: centerYAnchor),
      hint.trailingAnchor.constraint(lessThanOrEqualTo: glyphs[0].leadingAnchor, constant: -8),
      glyphs[0].trailingAnchor.constraint(equalTo: glyphs[1].leadingAnchor, constant: -10),
      glyphs[0].centerYAnchor.constraint(equalTo: centerYAnchor),
      glyphs[1].trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset - 2),
      glyphs[1].centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(look: MascotLook) { face.apply(look: look) }
}

// MARK: - A chat's backdrop

struct ChatBackdropSample: NSViewRepresentable {
  let backdrop: ChatBackdrop
  let look: MascotLook
  let clearGlass: Bool

  func makeNSView(context: Context) -> ChatBackdropSampleView { ChatBackdropSampleView(look: look) }

  func updateNSView(_ view: ChatBackdropSampleView, context: Context) {
    view.show(backdrop, look: look, clearGlass: clearGlass)
  }
}

/// An open chat at half its size: the panel's shell, the backdrop drawn by the
/// chat's own renderer, a question and the start of an answer.
final class ChatBackdropSampleView: NSView {
  static let size = CGSize(width: 440, height: 220)
  /// Even on every side of the stage.
  static let margin: CGFloat = 28
  private static let inset: CGFloat = 18
  private static let corner: CGFloat = 26
  private static let bubbleCorner: CGFloat = 13

  private let host: PaletteGlassHost
  private let backdrop = AgentBackdropView(frame: .zero)
  private let face: MascotNSView
  private let question = NSView()

  init(look: MascotLook) {
    face = MascotNSView(conversationID: UUID(), look: look)
    face.reduceMotion = MotionPreferences.reduceMotion
    host = PaletteGlassHost(content: NSView(), cornerRadius: Self.corner, style: .bolttyAIPrompt)
    super.init(frame: CGRect(origin: .zero, size: Self.size))
    appearance = NSAppearance(named: .darkAqua)
    backdrop.sceneScale = 0.75

    let asked = NSTextField(labelWithString: SampleText.request)
    asked.font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
    asked.textColor = .black
    asked.isSelectable = false
    question.wantsLayer = true
    question.layer?.backgroundColor = NSColor.white.cgColor
    question.layer?.cornerRadius = Self.bubbleCorner
    question.layer?.cornerCurve = .continuous
    question.layer?.maskedCorners = MessageTailView.roundedCorners
    let tail = MessageTailView()

    let answer = NSTextField(wrappingLabelWithString: SampleText.chatAnswer)
    answer.font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
    answer.textColor = PaletteInk.primary
    answer.isSelectable = false
    answer.maximumNumberOfLines = 3

    for view in [host, backdrop] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = true
      view.frame = bounds
      addSubview(view)
    }
    for view in [question, asked, answer, face] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    question.addSubview(asked)
    addSubview(question)
    addSubview(tail)
    addSubview(answer)
    addSubview(face)
    NSLayoutConstraint.activate([
      question.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
      question.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -Self.inset - MessageTailView.size.width),
      tail.leadingAnchor.constraint(equalTo: question.trailingAnchor),
      tail.bottomAnchor.constraint(equalTo: question.bottomAnchor),
      asked.leadingAnchor.constraint(equalTo: question.leadingAnchor, constant: 11),
      asked.trailingAnchor.constraint(equalTo: question.trailingAnchor, constant: -11),
      asked.topAnchor.constraint(equalTo: question.topAnchor, constant: 6),
      asked.bottomAnchor.constraint(equalTo: question.bottomAnchor, constant: -6),
      answer.topAnchor.constraint(equalTo: question.bottomAnchor, constant: 12),
      answer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset + 2),
      answer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset - 16),
      face.widthAnchor.constraint(equalToConstant: 26),
      face.heightAnchor.constraint(equalToConstant: 26),
      face.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
      face.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset + 2),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    host.frame = bounds
    host.layoutSubtreeIfNeeded()
    backdrop.layOut(in: bounds, corner: host.renderedCornerRadius, curve: host.renderedCornerCurve)
  }

  func show(_ chosen: ChatBackdrop, look: MascotLook, clearGlass: Bool) {
    host.apply(surfaceStyle: .bolttyAIPrompt(clearGlass: clearGlass))
    face.apply(look: look)
    backdrop.show(chosen, palette: chosen == .standard ? .standard : look.palette)
    needsLayout = true
  }
}

// MARK: - Finder's selection in the prompt

struct FinderSelectionSample: NSViewRepresentable {
  let attaches: Bool
  let look: MascotLook
  let clearGlass: Bool

  func makeNSView(context: Context) -> FinderSelectionSampleView { FinderSelectionSampleView(look: look) }

  func updateNSView(_ view: FinderSelectionSampleView, context: Context) {
    view.show(attaches: attaches, look: look, clearGlass: clearGlass)
  }
}

/// The first screen opened over Finder with two files selected there: one
/// shell keeping its corner as it grows, the panel's own file cards in the band
/// over the line, concentric with the shell.
final class FinderSelectionSampleView: NSView {
  private static let lineHeight: CGFloat = 56
  private static let corner = lineHeight / 2
  private static let inset: CGFloat = 12
  private static let side = AgentPaletteMetrics.attachmentCardSide
  private static let band = inset + side
  static let size = CGSize(width: 280, height: band + lineHeight)

  private let host: PaletteGlassHost
  private let row = PromptSampleRow()
  private let cardsHost = NSView()
  private var attaches: Bool?

  init(look: MascotLook) {
    host = PaletteGlassHost(content: NSView(), cornerRadius: Self.corner, style: .bolttyAIPrompt)
    super.init(frame: CGRect(origin: .zero, size: Self.size))
    appearance = NSAppearance(named: .darkAqua)
    for view in [host, cardsHost, row] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(view)
    }
    row.apply(look: look)
    let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    for (index, name) in SampleText.selectedFiles.enumerated() {
      let card = PromptAttachmentCard(
        attachment: .file(home.appendingPathComponent(name), label: name),
        corner: Self.corner - Self.inset)
      card.frame = CGRect(
        x: Self.inset + CGFloat(index) * (Self.side + AgentPaletteMetrics.attachmentCardGap),
        y: 0, width: Self.side, height: Self.side)
      cardsHost.addSubview(card)
    }
    lay(attaches: true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private func frames(attaches: Bool) -> (host: CGRect, row: CGRect, cards: CGRect) {
    let height = attaches ? Self.size.height : Self.lineHeight
    let bottom = ((Self.size.height - height) / 2).rounded()
    return (
      CGRect(x: 0, y: bottom, width: Self.size.width, height: height),
      CGRect(x: 0, y: bottom, width: Self.size.width, height: Self.lineHeight),
      CGRect(x: 0, y: bottom + Self.lineHeight, width: Self.size.width, height: Self.side)
    )
  }

  private func lay(attaches: Bool) {
    let frames = frames(attaches: attaches)
    host.frame = frames.host
    row.frame = frames.row
    cardsHost.frame = frames.cards
    cardsHost.alphaValue = attaches ? 1 : 0
    host.cornerRadius = Self.corner
  }

  func show(attaches: Bool, look: MascotLook, clearGlass: Bool) {
    host.apply(surfaceStyle: .bolttyAIPrompt(clearGlass: clearGlass))
    row.apply(look: look)
    guard attaches != self.attaches else { return }
    let first = self.attaches == nil
    self.attaches = attaches
    guard !first, !MotionPreferences.reduceMotion else { return lay(attaches: attaches) }
    let frames = frames(attaches: attaches)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Motion.standard
      context.timingFunction = Motion.emphasizedCurve
      host.animator().frame = frames.host
      row.animator().frame = frames.row
      cardsHost.animator().frame = frames.cards
      cardsHost.animator().alphaValue = attaches ? 1 : 0
    }
    // The glass's corner is set again for each new size, so it stays the line's.
    host.cornerRadius = Self.corner
  }
}

// MARK: - Words arriving as they are heard

/// The listening orb's words, arriving out of the face's colours, over and over.
final class ArrivingWordsSampleView: NSView {
  private let words = ListeningWordsView()
  private var phrase: [String] = []
  private var shown = 0
  private var timer: Timer?
  var pause: TimeInterval = 2.2
  var step: TimeInterval = 0.32

  override init(frame: NSRect) {
    super.init(frame: frame)
    words.translatesAutoresizingMaskIntoConstraints = true
    words.autoresizingMask = [.width, .height]
    words.frame = bounds
    addSubview(words)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func configure(phrase: String, colors: [NSColor], centred: Bool, width: CGFloat) {
    words.colors = colors
    words.isCentred = centred
    words.wrapWidth = width
    let incoming = phrase.split(separator: " ").map(String.init)
    guard incoming != self.phrase else { return }
    self.phrase = incoming
    restart()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window == nil ? stop() : restart()
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func restart() {
    stop()
    shown = 0
    words.setText("", animated: false)
    guard window != nil else { return }
    if MotionPreferences.reduceMotion {
      words.setText(phrase.joined(separator: " "), animated: false)
      return
    }
    schedule(after: 0.3)
  }

  private func schedule(after delay: TimeInterval) {
    timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.advance() }
    }
  }

  private func advance() {
    if shown >= phrase.count {
      shown = 0
      words.setText("", animated: false)
      schedule(after: 0.5)
      return
    }
    shown += 1
    words.setText(phrase.prefix(shown).joined(separator: " "), animated: true)
    schedule(after: shown == phrase.count ? pause : step)
  }
}

// MARK: - Dictation

struct DictationSample: NSViewRepresentable {
  let phrase: String
  let look: MascotLook
  let clearGlass: Bool

  func makeNSView(context: Context) -> DictationSampleView { DictationSampleView(look: look) }

  func updateNSView(_ view: DictationSampleView, context: Context) {
    view.show(phrase: phrase, look: look, clearGlass: clearGlass)
  }
}

/// The listening capsule: the face over the words, which arrive as they are heard.
final class DictationSampleView: NSView {
  static let size = CGSize(width: 268, height: 116)
  private static let faceSide: CGFloat = 30

  private let host: PaletteGlassHost
  private let face: MascotNSView
  private let words = ArrivingWordsSampleView()

  init(look: MascotLook) {
    face = MascotNSView(conversationID: UUID(), look: look)
    face.reduceMotion = MotionPreferences.reduceMotion
    face.emotion = .listening
    host = PaletteGlassHost(content: NSView(), cornerRadius: 34, style: .bolttyAIPrompt)
    super.init(frame: CGRect(origin: .zero, size: Self.size))
    appearance = NSAppearance(named: .darkAqua)
    host.translatesAutoresizingMaskIntoConstraints = true
    host.frame = bounds
    host.autoresizingMask = [.width, .height]
    addSubview(host)
    face.translatesAutoresizingMaskIntoConstraints = true
    face.frame = CGRect(
      x: ((Self.size.width - Self.faceSide) / 2).rounded(), y: Self.size.height - Self.faceSide - 10,
      width: Self.faceSide, height: Self.faceSide)
    addSubview(face)
    words.translatesAutoresizingMaskIntoConstraints = true
    words.frame = CGRect(x: 14, y: 12, width: Self.size.width - 28, height: Self.size.height - Self.faceSide - 26)
    addSubview(words)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func show(phrase: String, look: MascotLook, clearGlass: Bool) {
    host.apply(surfaceStyle: .bolttyAIPrompt(clearGlass: clearGlass))
    face.apply(look: look)
    words.configure(
      phrase: phrase, colors: VoiceEdgeGlowLayout.rayColors(from: look.palette),
      centred: true, width: words.frame.width)
  }
}

/// What the samples say. One language for now, in the catalogue so the
/// samples follow Boltty's own language once it can be chosen.
enum SampleText {
  static let placeholder = String(localized: "Describe a task or ask", comment: "The first screen's placeholder, in a Settings sample")
  static let request = String(localized: "Rename these photos by date", comment: "A request in a Settings sample chat")
  static let chatAnswer = String(localized: "Done: 24 photos now start with the day they were taken, oldest first.", comment: "An answer in a Settings sample chat")
  static let spoken = String(localized: "Rename the photos on my desktop by date", comment: "Words being dictated, in a Settings sample")
  static let lookedAndAnswered = String(localized: "Export is in the File menu, third from the bottom.", comment: "Ask Boltty's answer when it only looks, in a Settings sample")
  static let didIt = String(localized: "Renamed 24 photos by the day they were taken.", comment: "Ask Boltty's answer when it can make changes, in a Settings sample")

  static let selectedFiles = [
    String(localized: "Report.pdf", comment: "A file selected in Finder, on a Settings sample card"),
    String(localized: "Trip.mp4", comment: "A file selected in Finder, on a Settings sample card"),
  ]
}

// MARK: - Ask Boltty's answer beside the pointer

struct AskAnswerSample: NSViewRepresentable {
  let canMakeChanges: Bool
  let look: MascotLook

  func makeNSView(context: Context) -> AskAnswerSampleView { AskAnswerSampleView(look: look) }

  func updateNSView(_ view: AskAnswerSampleView, context: Context) {
    view.show(canMakeChanges: canMakeChanges, look: look)
  }
}

/// The face beside the pointer with its answer in the overlay's bubble.
final class AskAnswerSampleView: NSView {
  static let size = CGSize(width: 292, height: 96)
  private static let faceSide: CGFloat = 40

  private let bubble: PaletteGlassHost
  private let face: MascotNSView
  private let words = ArrivingWordsSampleView()

  init(look: MascotLook) {
    face = MascotNSView(conversationID: UUID(), look: look)
    face.reduceMotion = MotionPreferences.reduceMotion
    let content = NSView()
    content.wantsLayer = true
    content.layer?.backgroundColor = AskBolttyOverlayController.bubbleShade.cgColor
    content.layer?.cornerRadius = AskBolttyOverlayController.bubbleCornerRadius
    content.layer?.cornerCurve = .continuous
    content.layer?.masksToBounds = true
    bubble = PaletteGlassHost(
      content: content, cornerRadius: AskBolttyOverlayController.bubbleCornerRadius, style: .bolttyAI)
    super.init(frame: CGRect(origin: .zero, size: Self.size))
    appearance = NSAppearance(named: .darkAqua)
    face.translatesAutoresizingMaskIntoConstraints = true
    face.frame = CGRect(x: 4, y: ((Self.size.height - Self.faceSide) / 2).rounded(), width: Self.faceSide, height: Self.faceSide)
    addSubview(face)
    let bubbleX = face.frame.maxX + AskBolttyOverlayController.bubbleGap
    bubble.translatesAutoresizingMaskIntoConstraints = true
    bubble.frame = CGRect(x: bubbleX, y: 6, width: Self.size.width - bubbleX - 4, height: Self.size.height - 12)
    addSubview(bubble)
    let padding = AskBolttyOverlayController.bubblePadding
    words.translatesAutoresizingMaskIntoConstraints = true
    words.frame = bubble.frame.insetBy(dx: padding.width, dy: padding.height)
    addSubview(words)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func show(canMakeChanges: Bool, look: MascotLook) {
    face.apply(look: look)
    let answer = canMakeChanges ? SampleText.didIt : SampleText.lookedAndAnswered
    words.configure(
      phrase: answer, colors: VoiceEdgeGlowLayout.rayColors(from: look.palette),
      centred: false, width: words.frame.width)
  }
}

// MARK: - The desktop behind it

struct DesktopPicture: @unchecked Sendable {
  let image: CGImage
  /// The first place looked, the wallpaper as the system names it.
  var source: URL?

  @MainActor static var cached: DesktopPicture?

  private static let fallback = URL(
    fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails/Sonoma.heic")

  @MainActor
  static func sources() -> [URL] {
    var urls: [URL] = []
    if let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) {
      if url.pathExtension == "madesktop" {
        urls += madesktopSources(url)
      } else {
        urls.append(url)
      }
    }
    urls.append(fallback)
    return urls
  }

  // A system wallpaper is a .madesktop stub: the picture is a mobile asset,
  // downloaded only once chosen, beside a small thumbnail that always ships.
  private static func madesktopSources(_ url: URL) -> [URL] {
    guard
      let data = try? Data(contentsOf: url),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return [] }
    var urls: [URL] = []
    if let id = plist["mobileAssetID"] as? String,
       let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    {
      urls.append(support.appendingPathComponent("com.apple.mobileAssetDesktop/\(id).heic"))
    }
    if let thumbnail = plist["thumbnailPath"] as? String {
      urls.append(URL(fileURLWithPath: thumbnail))
    }
    return urls
  }

  static func load(from urls: [URL], maxPixels: CGFloat) -> DesktopPicture? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    for url in urls {
      guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
      else { continue }
      return DesktopPicture(image: image, source: urls.first)
    }
    return nil
  }
}
