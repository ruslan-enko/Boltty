import AVFoundation
import AppKit

@MainActor
final class FirstRunShowController {
  private static let sceneHeight: CGFloat = 680

  private let screen: NSScreen
  private let playsSound: Bool
  private var panel: PassivePanel?
  private var film: FirstRunFilmView?
  private var keyMonitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var status: NSKeyValueObservation?
  private var completion: (@MainActor () -> Void)?

  var isPlaying: Bool { completion != nil }

  init(on screen: NSScreen, playsSound: Bool) {
    self.screen = screen
    self.playsSound = playsSound
  }

  func play(completion: @escaping @MainActor () -> Void) {
    guard !MotionPreferences.reduceMotion,
          let url = Bundle.main.url(forResource: "first-run", withExtension: "mp4")
    else { return completion() }
    self.completion = completion
    let frame = CGRect(origin: .zero, size: screen.frame.size)

    let root = NSView(frame: frame)
    let sky = AgentBackdropView(frame: frame)
    sky.sceneScale = max(1, frame.height / Self.sceneHeight)
    root.addSubview(sky)
    sky.layOut(in: frame, corner: 0, curve: .continuous)
    sky.show(.sky, palette: .standard)
    let film = FirstRunFilmView(frame: frame, url: url)
    film.onSkip = { [weak self] in self?.finish() }
    film.player.isMuted = !playsSound
    root.addSubview(film)
    self.film = film

    let panel = PassivePanel(
      contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.contentView = root
    panel.orderFrontRegardless()
    self.panel = panel

    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.completion != nil, event.keyCode == 53 else { return event }
      self.finish()
      return nil
    }
    let item = film.player.currentItem
    observers = [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification].map {
      NotificationCenter.default.addObserver(forName: $0, object: item, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.finish() }
      }
    }
    status = item?.observe(\.status) { [weak self] item, _ in
      guard item.status == .failed else { return }
      Task { @MainActor in self?.finish() }
    }
    film.player.play()
  }

  func settle(under window: NSWindow) {
    guard let panel else { return }
    panel.level = .normal
    panel.order(.below, relativeTo: window.windowNumber)
  }

  func dismissBackdrop() {
    guard let panel else { return }
    self.panel = nil
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Motion.standard
      panel.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated { panel.orderOut(nil) }
    }
  }

  private func finish() {
    guard let completion else { return }
    self.completion = nil
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    status = nil
    panel?.ignoresMouseEvents = true
    guard let film else { return completion() }
    self.film = nil
    film.player.isMuted = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Motion.standard
      film.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated {
        film.player.pause()
        film.removeFromSuperview()
        completion()
      }
    }
  }
}

private final class FirstRunFilmView: NSView {
  let player: AVPlayer
  var onSkip: (() -> Void)?
  private let skip = NSTextField(labelWithString: String(localized: "Skip Intro"))

  init(frame: CGRect, url: URL) {
    player = AVPlayer(url: url)
    super.init(frame: frame)
    player.actionAtItemEnd = .pause
    player.preventsDisplaySleepDuringVideoPlayback = true
    wantsLayer = true
    layer?.backgroundColor = OKLCH(0.9943, 0, 0).color.cgColor
    let picture = AVPlayerLayer(player: player)
    picture.frame = bounds
    picture.videoGravity = .resizeAspectFill
    layer?.masksToBounds = true
    layer?.addSublayer(picture)

    skip.font = roundedAppFont(size: AgentPaletteMetrics.typeMeta)
    skip.textColor = NSColor.black.withAlphaComponent(0.45)
    skip.sizeToFit()
    skip.frame.origin = CGPoint(x: bounds.maxX - skip.frame.width - 28, y: 24)
    addSubview(skip)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if skip.frame.insetBy(dx: -14, dy: -10).contains(point) { onSkip?() }
  }
}
