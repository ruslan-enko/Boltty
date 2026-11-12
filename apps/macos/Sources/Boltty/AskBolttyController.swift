import AppKit
import Carbon
import Combine

@MainActor
final class AskBolttyController {
  let session: AskBolttySession
  private let overlay = AskBolttyOverlayController()
  var overlayForTesting: AskBolttyOverlayController { overlay }
  private let coordinator: ChatWorkspaceCoordinator
  private let settings: () -> AppSettings
  private var cancellables = Set<AnyCancellable>()
  private lazy var escapeKey = GlobalHotkeyService(number: 2) { [weak self] in
    MainActor.assumeIsolated { self?.escapePressed() }
  }
  private var holdsEscape = false
  private var lastRegion: CGRect?
  private var panelIsUp = false

  var onNeedsYou: ((UUID) -> Void)?
  var launchKeyName: (() -> String?)?
  var finderSelection = FinderSelectionService()

  init(
    coordinator: ChatWorkspaceCoordinator,
    speech: SpeechOutput,
    settings: @escaping () -> AppSettings
  ) {
    self.coordinator = coordinator
    self.settings = settings
    session = AskBolttySession(coordinator: coordinator, speech: speech)

    overlay.onVisibleChange = { [weak self] in self?.syncEscapeKey() }
    overlay.restHint = { [weak self] in Self.restHint(launchKey: self?.launchKeyName?()) }
    session.onSpent = { [weak self] providerID, resetsAt in
      self?.coordinator.markSpent(providerID, until: resetsAt)
    }
    session.findPlace = { [weak self] spot in
      guard let self, settings().attachesFinderSelection else { return nil }
      return await self.finderSelection.place(of: spot)
    }

    Publishers.CombineLatest3(session.$phase, session.$caption, session.$step)
      .receive(on: RunLoop.main)
      .sink { [weak self] phase, caption, step in
        guard let self else { return }
        if phase == .thinking || phase == .speaking, let id = self.session.conversationID,
           self.coordinator.store.selectedConversationID == id {
          self.overlay.hide()
          return
        }
        self.overlay.isSaidAloud = self.session.readsAloud
        self.overlay.show(
          phase, caption: caption,
          agent: self.session.providerID.flatMap(AgentId.init(rawValue:)),
          step: step)
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
    coordinator.forgetAskBolttyChats()
    // On the next turn of the run loop: `$speakingID` tells before the value
    // changes, and asked then the voice is still saying what it has finished.
    speech.$speakingID
      .removeDuplicates()
      .filter { $0 == nil }
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.session.speechFinished() }
      .store(in: &cancellables)
  }

  // MARK: - A question about a region

  static func restHint(launchKey: String?) -> String {
    guard let launchKey else { return "Esc to close" }
    return "\(launchKey) to ask more · Esc to close"
  }

  var answeringAgent: AgentId? {
    target(for: nil).flatMap { AgentId(rawValue: $0.providerID) }
  }

  func warmUp(agent: AgentId?) {
    guard let target = target(for: agent) else { return }
    overlay.hide()
    session.warmUp(target)
  }

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

  func ask(
    _ words: String, about selection: ScreenSelection, on displayFrame: CGRect, agent: AgentId?
  ) -> Bool {
    let targets = targets(for: agent)
    guard !targets.isEmpty else { return false }
    lastRegion = selection.frame
    overlay.holdForArrival()
    session.ask(
      words, about: selection, on: displayFrame, targets: targets,
      note: skipNote(wanted: agent, answering: targets.first?.providerID),
      speaksAloud: settings().askBolttySpeaksAloud)
    return true
  }

  func faceArrives(from point: CGPoint?) {
    overlay.arrive(from: point)
  }

  func cancelQuestion() {
    session.cancel()
  }

  private func target(for agent: AgentId?) -> AskBolttyTarget? {
    targets(for: agent).first
  }

  /// Every agent that could answer, in the order they are tried; one whose plan
  /// is used up goes last, so a question is never refused while another could
  /// take it.
  private func targets(for agent: AgentId?) -> [AskBolttyTarget] {
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
    let asked = agent?.rawValue ?? current.askBolttyProviderID
    let byPlan = asked == nil && current.routesAutomatically
    let ranked = byPlan
      ? coordinator.routingOrder(among: candidates)
      : AskBolttyConfiguration.ranked(settings: current, candidates: candidates, chosen: agent?.rawValue)
    let spent = ranked.filter(isSpent)
    return (ranked.filter { !spent.contains($0) } + spent).map {
      AskBolttyConfiguration.target(for: $0, settings: current, models: engine.modelsByProvider)
    }
  }

  private func isSpent(_ providerID: String) -> Bool { coordinator.isSpent(providerID) }

  /// Said beside the face when the agent that would have answered is skipped.
  private func skipNote(wanted: AgentId?, answering: String?) -> String? {
    let current = settings()
    let first = wanted?.rawValue ?? current.askBolttyProviderID
      ?? (current.routesAutomatically ? nil : current.agentPreset?.rawValue)
    guard let first, let answering, first != answering, isSpent(first),
          let skipped = AgentId(rawValue: first), let next = AgentId(rawValue: answering)
    else { return nil }
    return AskBolttySession.handOverNote(skipped: skipped.displayName, why: .spent, next: next.displayName)
  }

  func apply(_ settings: AppSettings) {
    overlay.makesSounds = settings.playsSounds
  }

  func setPanelVisible(_ visible: Bool) {
    panelIsUp = visible
    if visible, session.phase == .idle { overlay.giveWay() }
    syncEscapeKey()
  }

  private func syncEscapeKey() {
    let wanted = overlay.isVisible && !panelIsUp
    guard wanted != holdsEscape else { return }
    if wanted {
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
