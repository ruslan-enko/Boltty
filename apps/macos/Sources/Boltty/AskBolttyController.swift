import AppKit
import Combine

/// Ask Boltty, put together: the held chord, the session it drives, the line on
/// screen, and the settings that turn it on and choose its agent.
@MainActor
final class AskBolttyController {
  static let chord: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
  static let chordName = "⌃⌥⌘"
  /// How often a chord waiting for Input Monitoring tries again.
  static let accessRetryInterval: TimeInterval = 2

  let session: AskBolttySession
  private let overlay = AskBolttyOverlayController()
  private let monitor = ModifierHoldMonitor(chord: AskBolttyController.chord)
  private let listener: DictationListener
  private var retry: Timer?
  private var cancellables = Set<AnyCancellable>()
  private var enabled = false

  /// The chord began: whatever Boltty was showing steps aside.
  var onBegin: (() -> Void)?
  var onSent: (() -> Void)?
  /// The answer waits on the person — a permission, a question. Ask Boltty chats
  /// are in no history, so the panel opens on it.
  var onNeedsYou: ((UUID) -> Void)?

  init(
    coordinator: ChatWorkspaceCoordinator,
    speech: SpeechOutput,
    settings: @escaping () -> AppSettings
  ) {
    let listener = DictationListener()
    self.listener = listener
    session = AskBolttySession(coordinator: coordinator, listener: listener, speech: speech) {
      let current = settings()
      let engine = coordinator.engine
      let candidates = AgentHistory.tabOrder
        .filter { current.isProviderEnabled($0.rawValue) }
        .compactMap { agent -> String? in
          guard let installation = engine.registry.installation(for: agent), installation.isReady,
                AskBolttyConfiguration.canAnswer(installation.capabilities)
          else { return nil }
          return agent.rawValue
        }
      return AskBolttyConfiguration.resolve(
        settings: current, candidates: candidates, models: engine.modelsByProvider)
    }

    monitor.onBegin = { [weak self] in
      guard let self else { return }
      self.onBegin?()
      self.session.begin()
    }
    monitor.onEnd = { [weak self] in
      guard let self, self.session.phase == .listening else { return }
      self.session.end()
      self.onSent?()
    }
    monitor.onCancel = { [weak self] in self?.session.cancel() }
    monitor.onEscape = { [weak self] in
      self?.session.stop()
      self?.overlay.hide()
    }
    overlay.onTrace = { [weak self] point in self?.session.trace(point) }

    Publishers.CombineLatest3(session.$phase, session.$heard, session.$caption)
      .receive(on: RunLoop.main)
      .sink { [weak self] phase, heard, caption in
        guard let self else { return }
        self.overlay.show(
          phase, heard: heard, caption: caption,
          agent: self.session.providerID.flatMap(AgentId.init(rawValue:)))
      }
      .store(in: &cancellables)
    session.$pointing
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] pointing in
        guard let self else { return }
        if let pointing { self.overlay.point(at: pointing.location) } else { self.overlay.release() }
      }
      .store(in: &cancellables)
    session.$drawn
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] strokes in self?.overlay.draw(strokes) }
      .store(in: &cancellables)
    session.$phase
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] phase in
        guard let self, case .needsYou = phase, let id = self.session.conversationID else { return }
        self.onNeedsYou?(id)
      }
      .store(in: &cancellables)
    // What an Ask Boltty left behind when Boltty last quit is done with.
    coordinator.forgetAskBolttyChats()
    speech.$speakingID
      .removeDuplicates()
      .filter { $0 == nil }
      .sink { [weak self] _ in self?.session.speechFinished() }
      .store(in: &cancellables)
  }

  var isListeningForTheChord: Bool { monitor.isRunning }

  func apply(_ settings: AppSettings) {
    overlay.makesSounds = settings.playsSounds
    listener.dictation.localeIdentifier = settings.dictationLocaleIdentifier
    listener.dictation.secondLocaleIdentifier = settings.dictationSecondLocaleIdentifier
    guard settings.askBolttyEnabled != enabled else { return }
    enabled = settings.askBolttyEnabled
    if enabled {
      listenForTheChord(asking: true)
    } else {
      retry?.invalidate()
      retry = nil
      monitor.stop()
      session.cancel()
      overlay.hide()
    }
  }

  /// Input Monitoring is asked once; a grant given in System Settings is
  /// taken up on the next try, without a relaunch.
  private func listenForTheChord(asking: Bool) {
    guard enabled, !monitor.isRunning else { return }
    if monitor.start() == .free {
      retry?.invalidate()
      retry = nil
      return
    }
    if asking { ModifierHotkeyMonitor.requestAccess() }
    guard retry == nil else { return }
    retry = Timer.scheduledTimer(withTimeInterval: Self.accessRetryInterval, repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.listenForTheChord(asking: false) }
    }
  }

  func shutDown() {
    retry?.invalidate()
    retry = nil
    monitor.stop()
    session.cancel()
    overlay.hide()
  }
}
