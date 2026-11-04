import AppKit
import Carbon
import Combine

/// Ask Boltty, put together: the session that answers about a region beside
/// the face, and the settings that choose its agent. The region and the words
/// are the panel's.
@MainActor
final class AskBolttyController {
  let session: AskBolttySession
  private let overlay = AskBolttyOverlayController()
  private let coordinator: ChatWorkspaceCoordinator
  private let settings: () -> AppSettings
  private var cancellables = Set<AnyCancellable>()
  /// Escape, from whichever app is in front, needing no permission: held only
  /// while the face is on the screen and the panel, which has its own Escape,
  /// is not.
  private lazy var escapeKey = GlobalHotkeyService(number: 2) { [weak self] in
    MainActor.assumeIsolated { self?.escapePressed() }
  }
  private var holdsEscape = false
  /// What the last question was about, in global coordinates.
  private var lastRegion: CGRect?
  private var panelIsUp = false

  /// The answer waits on the person — a permission, a question: the panel
  /// opens on its chat.
  var onNeedsYou: ((UUID) -> Void)?

  init(
    coordinator: ChatWorkspaceCoordinator,
    speech: SpeechOutput,
    settings: @escaping () -> AppSettings
  ) {
    self.coordinator = coordinator
    self.settings = settings
    session = AskBolttySession(coordinator: coordinator, speech: speech)

    overlay.onVisibleChange = { [weak self] in self?.syncEscapeKey() }

    Publishers.CombineLatest(session.$phase, session.$caption)
      .receive(on: RunLoop.main)
      .sink { [weak self] phase, caption in
        guard let self else { return }
        self.overlay.isSaidAloud = self.session.readsAloud
        self.overlay.show(
          phase, caption: caption,
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

  // MARK: - A question about a region

  /// The agent a region is asked of, before ⇧Tab moves it: Settings › Ask
  /// Boltty's choice where it is ready, else the fastest that sees.
  var answeringAgent: AgentId? {
    target(for: nil).flatMap { AgentId(rawValue: $0.providerID) }
  }

  /// A region was drawn: the agent's session starts while the person speaks.
  func warmUp(agent: AgentId?) {
    guard let target = target(for: agent) else { return }
    overlay.hide()
    session.warmUp(target)
  }

  /// The question the launch key goes on with, while the face that answered it
  /// is still beside the pointer and the pointer is on that screen.
  var questionToContinue: (region: CGRect, agent: AgentId?)? {
    guard overlay.isFaceUp, let lastRegion else { return nil }
    switch session.phase {
    case .idle, .thinking, .speaking: break
    case .needsYou, .failed: return nil
    }
    let middle = CGPoint(x: lastRegion.midX, y: lastRegion.midY)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
          screen.frame.contains(middle)
    else { return nil }
    return (lastRegion, session.providerID.flatMap(AgentId.init(rawValue:)))
  }

  /// Sends the question; `false` when no agent could take it. The turn starts
  /// now; the face beside the pointer waits for `faceArrives`.
  func ask(
    _ words: String, about selection: ScreenSelection, on displayFrame: CGRect, agent: AgentId?
  ) -> Bool {
    guard let target = target(for: agent) else { return false }
    lastRegion = selection.frame
    overlay.holdForArrival()
    session.ask(
      words, about: selection, on: displayFrame, target: target,
      speaksAloud: settings().askBolttySpeaksAloud)
    return true
  }

  /// The panel has gone from under its face, which stood at `point`: this one
  /// takes up from there and flies to the pointer.
  func faceArrives(from point: CGPoint?) {
    overlay.arrive(from: point)
  }

  /// The region was let go of without a question.
  func cancelQuestion() {
    session.cancel()
  }

  /// Ask Boltty's agent and model, or — when ⇧Tab chose another agent — that
  /// one at its default model; always at the model's lowest effort.
  private func target(for agent: AgentId?) -> AskBolttyTarget? {
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
    let resolved = AskBolttyConfiguration.resolve(
      settings: current, candidates: candidates, models: engine.modelsByProvider)
    guard let agent, agent.rawValue != resolved?.providerID else { return resolved }
    guard candidates.contains(agent.rawValue) else { return nil }
    return AskBolttyTarget(
      providerID: agent.rawValue, model: nil, effort: nil, readOnly: current.askBolttyReadOnly)
  }

  func apply(_ settings: AppSettings) {
    overlay.makesSounds = settings.playsSounds
  }

  /// The panel came up or went. A face resting from its last answer gives way
  /// to it; one still answering stays, without Escape.
  func setPanelVisible(_ visible: Bool) {
    panelIsUp = visible
    if visible, session.phase == .idle { overlay.hide() }
    syncEscapeKey()
  }

  private func syncEscapeKey() {
    let wanted = overlay.isVisible && !panelIsUp
    guard wanted != holdsEscape else { return }
    if wanted {
      // Another app holding it costs only the key: a click still works.
      holdsEscape = escapeKey.register(
        HotkeyBinding(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)
      ).isFree
    } else {
      escapeKey.stop()
      holdsEscape = false
    }
  }

  private func escapePressed() {
    session.stop()
    overlay.hide()
  }

  func shutDown() {
    escapeKey.stop()
    holdsEscape = false
    session.cancel()
    overlay.hide()
  }
}
