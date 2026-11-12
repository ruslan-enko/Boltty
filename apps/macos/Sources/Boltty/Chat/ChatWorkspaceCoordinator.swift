import AppKit
import Combine
import Foundation

@MainActor
final class ChatWorkspaceCoordinator {
  let store: ConversationStore
  let engine: ConversationEngine
  var pendingPanelPrompts: [UUID: (text: String, messageCount: Int, sentAt: Date)] = [:]
  private var panelSendTasks: [UUID: Task<Void, Never>] = [:]
  var failedPanelPrompts: [UUID: String] = [:]
  var queuedPanelPrompts: [UUID: String] = [:]
  var questionAnswers: [UUID: [String: [[String]]]] = [:]

  private var cancellables: Set<AnyCancellable> = []
  private var previousStates: [UUID: ConversationExecutionState] = [:]

  var onStatusSnapshotChange: ((StatusBarSnapshot) -> Void)?
  var notificationDelivery: ((SystemAttentionNotification) -> Void)?
  var onTurnFinished: ((Conversation) -> Void)?

  var isProviderEnabled: (String) -> Bool = { _ in true }
  var preferredProviderID: () -> String? = { nil }
  var routesAutomatically: () -> Bool = { false }
  var defaultModelID: (String) -> String? = { _ in nil }
  var defaultEffortID: (String) -> String? = { _ in nil }
  var defaultAutoApprove: (String) -> Bool = { _ in false }

  init(
    store: ConversationStore,
    engine: ConversationEngine
  ) {
    self.store = store
    self.engine = engine
    observe()
  }

  var statusSnapshot: StatusBarSnapshot {
    let conversations = store.orderedConversations.filter { !$0.isAskBoltty }
    let unread = conversations.first { $0.hasUnread }
    let active = conversations.filter { $0.lastKnownState.blocksSending }
    return StatusBarSnapshot(
      iconState: unread == nil ? .idle : .attention,
      agentRows: active.map {
        AgentStatusRow(
          id: $0.id,
          agent: AgentId(rawValue: $0.providerID) ?? .opencode,
          prompt: $0.title)
      },
      latestUnreadSessionID: unread?.id,
      latestUnreadTitle: unread?.title,
      accessibilityLabel: unread == nil ? "Boltty" : "Boltty — unread conversations"
    )
  }

  // MARK: - Limits under the menu-bar mark

  func usageGlanceRows() -> [UsageGlanceRow] {
    let listed = listedProviderIDs().compactMap(AgentId.init(rawValue:))
    let next = routesAutomatically() && listed.count > 1 ? routingOrder().first : nil
    return listed.map { agent in
      var row = usageGlanceRow(for: agent)
      row.takesNextChat = agent.rawValue == next
      return row
    }
  }

  private func usageGlanceRow(for agent: AgentId) -> UsageGlanceRow {
    if engine.registry.installation(for: agent)?.availability.isSignedOut == true {
      return UsageGlanceRow(agent: agent, content: .signedOut(command: agent.signInCommand ?? agent.program))
    }
    if let usage = engine.usageByProvider[agent.rawValue], !usage.windows.isEmpty || !usage.notes.isEmpty {
      return UsageGlanceRow(agent: agent, content: .limits(usage))
    }
    let reports = engine.registry.capabilities(forProviderID: agent.rawValue).contains(.usageLimits)
    return UsageGlanceRow(agent: agent, content: reports ? .waiting : .noPlanLimit)
  }

  func refreshUsageForGlance() async {
    await engine.refreshUsage()
  }

  // MARK: - Conversations

  func resolvedDefaultModel(for providerID: String) -> ModelSelection? {
    guard let stored = defaultModelID(providerID), !stored.isEmpty else { return nil }
    let listed = engine.modelsByProvider[providerID] ?? []
    if let option = listed.option(stored: stored) { return option.selection }
    return listed.isEmpty ? Self.unlistedSelection(stored: stored, agent: providerID) : nil
  }

  private static func unlistedSelection(stored: String, agent: String) -> ModelSelection? {
    if let slash = stored.firstIndex(of: "/") {
      return ModelSelection(
        providerID: String(stored[..<slash]), modelID: String(stored[stored.index(after: slash)...]))
    }
    return agent == AgentId.opencode.rawValue ? nil : ModelSelection(providerID: agent, modelID: stored)
  }

  func resolvedDefaultEffort(for providerID: String, model: ModelSelection?) -> String? {
    guard let effort = defaultEffortID(providerID), !effort.isEmpty,
          let match = modelOption(for: providerID, model: model),
          match.effortOptions.contains(where: { $0.value == effort })
    else { return nil }
    return effort
  }

  private func modelOption(for providerID: String, model: ModelSelection?) -> AgentModelOption? {
    let options = engine.modelsByProvider[providerID] ?? []
    return options.option(for: model) ?? options.agentDefault
  }

  func defaultProviderID() -> String {
    if let automatic = automaticProviderID() { return automatic }
    let previous = store.selectedConversation?.providerID
      ?? store.orderedConversations.first { !$0.isAskBoltty }?.providerID
    if let previous, engine.registry.installation(forProviderID: previous)?.isReady == true {
      return previous
    }
    return engine.registry.defaultProvider?.rawValue ?? AgentId.opencode.rawValue
  }

  func automaticProviderID() -> String? {
    if routesAutomatically() { return routingOrder().first }
    let readyEnabled = engine.registry.ready.filter {
      isProviderEnabled($0.provider.rawValue)
    }
    guard !readyEnabled.isEmpty else { return nil }
    if let preferred = preferredProviderID(),
       readyEnabled.contains(where: { $0.provider.rawValue == preferred })
    {
      return preferred
    }
    return readyEnabled.first?.provider.rawValue
  }

  // MARK: - Routing by what is left of each plan

  private var spentUntil: [String: Date] = [:]
  static let spentWithoutReset: TimeInterval = 15 * 60

  /// An agent that hit its limit here counts as spent until it comes back,
  /// whatever the last usage read said.
  func markSpent(_ providerID: String, until reset: Date?, now: Date = Date()) {
    spentUntil[providerID] = reset.flatMap { $0 > now ? $0 : nil }
      ?? now.addingTimeInterval(Self.spentWithoutReset)
  }

  func isSpent(_ providerID: String, now: Date = Date()) -> Bool {
    AgentRouting.standing(
      of: providerID, usage: engine.usageByProvider[providerID],
      spentUntil: spentUntil[providerID], now: now
    ).isSpent
  }

  func routingOrder(forPictures: Bool = false, among agents: [String]? = nil) -> [String] {
    var candidates = agents ?? launchableProviderIDs()
    if forPictures {
      let seeing = candidates.filter {
        AskBolttyConfiguration.canAnswer(engine.registry.capabilities(forProviderID: $0))
      }
      if !seeing.isEmpty { candidates = seeing }
    }
    return AgentRouting.ranked(
      candidates: candidates,
      usage: engine.usageByProvider,
      spentUntil: spentUntil,
      sticky: store.orderedConversations.first { !$0.isAskBoltty }?.providerID,
      preferred: preferredProviderID())
  }

  // MARK: - Handing a failed first turn over

  private struct AutomaticSend {
    var prompt: String
    var pictures: [ConversationAttachment]
    var tried: [String]
  }

  private var automaticSends: [UUID: AutomaticSend] = [:]
  private(set) var handOvers: [UUID: AgentHandOver] = [:]

  /// A chat nobody chose the agent for, whose first turn failed before the agent
  /// said or did anything, goes to the next agent, each tried once.
  @discardableResult
  private func handOverIfDue(_ id: UUID) -> Bool {
    guard let send = automaticSends[id], let conversation = store.conversation(id: id) else { return false }
    guard pendingPanelPrompts[id] == nil, !store.isReadOnly else { return false }
    let state = conversation.lastKnownState
    let neverSent = failedPanelPrompts[id] != nil && !state.blocksSending
    guard state == .failed || state == .rateLimited || neverSent else { return false }
    let messages = store.transcript(id: id).messages
    let answered = messages.contains { message in
      message.role == .agent && message.parts.contains { part in
        if case .reasoning = part { false } else { true }
      }
    }
    let failure = messages.last { $0.failure != nil }?.failure
    guard !answered, failure?.isAbort != true else {
      automaticSends[id] = nil
      return false
    }
    let reason: AgentHandOver.Reason
    if let hit = failure?.rateLimit {
      reason = .spent
      markSpent(conversation.providerID, until: hit.resetsAt)
    } else if state == .rateLimited {
      reason = .spent
      markSpent(conversation.providerID, until: nil)
    } else if failure.map(AgentFailureReport.saysModelIsGone) == true {
      reason = .modelGone
    } else {
      reason = .failed
    }
    let next = routingOrder(forPictures: !send.pictures.isEmpty)
      .first { !send.tried.contains($0) && !isSpent($0) }
    guard let next, let from = AgentId(rawValue: conversation.providerID),
          let to = AgentId(rawValue: next)
    else {
      automaticSends[id] = nil
      return false
    }
    automaticSends[id]?.tried.append(next)
    handOvers[id] = AgentHandOver(from: from, to: to, reason: reason)
    let start = newChatSettings(for: next)
    engine.handOver(
      conversationID: id, to: next, model: start.model, effort: start.effort,
      autoApprove: start.autoApprove)
    previousStates[id] = .idle
    sendPanelPrompt(send.prompt, pictures: send.pictures, to: id)
    return true
  }

  private func newChatSettings(
    for provider: String
  ) -> (model: ModelSelection?, effort: String?, autoApprove: Bool) {
    var model = resolvedDefaultModel(for: provider)
    let effort = resolvedDefaultEffort(for: provider, model: model)
    if model == nil, effort != nil { model = modelOption(for: provider, model: nil)?.selection }
    let autoApprove = engine.registry.capabilities(forProviderID: provider).contains(.autoApproval)
      && defaultAutoApprove(provider)
    return (model, effort, autoApprove)
  }

  // MARK: - Ask Boltty

  func prepareAskBolttyConversation(
    providerID: String, model: ModelSelection?, effort: String?, readOnly: Bool,
    workingDirectory: String? = nil
  ) -> Conversation {
    let model = model ?? resolvedDefaultModel(for: providerID)
    let conversation = store.createConversation(
      title: ConversationEngine.untitled,
      workingDirectory: workingDirectory ?? store.defaultWorkingDirectory(),
      providerID: providerID,
      model: model,
      reasoningEffort: effort ?? AskBolttyConfiguration.fastestEffort(
        modelOption(for: providerID, model: model)?.effortOptions ?? []),
      readOnly: readOnly,
      isAskBoltty: true
    )
    Task { [engine] in _ = try? await engine.ensureRemoteSession(for: conversation.id) }
    return conversation
  }

  func discardAskBolttyConversation(_ id: UUID) {
    guard store.transcript(id: id).messages.isEmpty, pendingPanelPrompts[id] == nil else { return }
    forgetAskBolttyChat(id)
  }

  func forgetAskBolttyChats(except kept: UUID? = nil) {
    for conversation in store.conversations
    where conversation.id != kept && Self.isAskBoltty(conversation)
      && !conversation.lastKnownState.blocksSending {
      forgetAskBolttyChat(conversation.id)
    }
  }

  static func isAskBoltty(_ conversation: Conversation) -> Bool {
    conversation.isAskBoltty || conversation.title.hasPrefix("[Talk: the person asked")
  }

  private func forgetAskBolttyChat(_ id: UUID) {
    let pictures = (store.conversation(id: id)?.sentFiles ?? [])
      .map { URL(fileURLWithPath: $0.path) }
      .filter { $0.lastPathComponent.hasPrefix("talk-") }
    pendingPanelPrompts[id] = nil
    failedPanelPrompts[id] = nil
    engine.forgetConversation(id: id)
    Task.detached(priority: .utility) {
      for picture in pictures { try? FileManager.default.removeItem(at: picture) }
    }
  }

  // MARK: - Boltty AI

  @discardableResult
  func startConversationInBackground(
    prompt: String,
    id: UUID = UUID(),
    providerID: String? = nil,
    workingDirectory: String? = nil,
    pictures: [ConversationAttachment] = [],
    handsOver: Bool = false
  ) -> Conversation {
    let provider = providerID ?? defaultProviderID()
    let start = newChatSettings(for: provider)
    let conversation = store.createConversation(
      id: id,
      title: ConversationEngine.title(from: prompt),
      workingDirectory: workingDirectory ?? store.defaultWorkingDirectory(),
      providerID: provider,
      model: start.model,
      reasoningEffort: start.effort,
      autoApprove: start.autoApprove
    )
    if handsOver {
      automaticSends[conversation.id] = AutomaticSend(prompt: prompt, pictures: pictures, tried: [provider])
    }
    sendPanelPrompt(prompt, pictures: pictures, to: conversation.id)
    return conversation
  }

  func sendFollowUp(
    _ prompt: String, pictures: [ConversationAttachment] = [], to conversationID: UUID
  ) -> Bool {
    guard let conversation = store.conversation(id: conversationID),
          !conversation.lastKnownState.blocksSending,
          pendingPanelPrompts[conversationID] == nil
    else { return false }
    automaticSends[conversationID] = nil
    handOvers[conversationID] = nil
    sendPanelPrompt(prompt, pictures: pictures, to: conversationID)
    return true
  }

  @discardableResult
  func queueFollowUp(_ prompt: String, to id: UUID) -> BolttyAIFollowUp.QueuedSend {
    let outcome: BolttyAIFollowUp.QueuedSend =
      queuedPanelPrompts[id] == nil ? .queued : .replaced
    queuedPanelPrompts[id] = prompt
    store.objectWillChange.send()
    flushQueuedPrompts(store.conversations)
    return outcome
  }

  @discardableResult
  func steerFollowUp(_ prompt: String, to id: UUID) -> BolttyAIFollowUp.QueuedSend {
    guard engine.canSteer(id) else { return queueFollowUp(prompt, to: id) }
    Task { @MainActor [weak self] in
      guard let self, await !self.engine.steer(text: prompt, in: id) else { return }
      self.queueFollowUp(prompt, to: id)
    }
    return .steered
  }

  func canSteer(_ id: UUID) -> Bool { engine.canSteer(id) }

  @discardableResult
  func cancelQueuedFollowUp(for id: UUID) -> String? {
    guard let prompt = queuedPanelPrompts.removeValue(forKey: id) else { return nil }
    store.objectWillChange.send()
    return prompt
  }

  @discardableResult
  func refuse(permissionID: String, in id: UUID, saying words: String) async -> Bool {
    guard let conversation = store.conversation(id: id) else { return false }
    let carried = engine.registry.capabilities(forProviderID: conversation.providerID)
      .contains(.permissionMessage)
    let delivered = await engine.reply(
      permissionID: permissionID, in: id, decision: .reject, message: words
    )
    let gone = !delivered && store.transcript(id: id).interactions
      .first(where: { $0.id == permissionID })?.resolution == .expired
    guard delivered || gone else { return false }
    guard gone || !carried else { return true }
    queuedPanelPrompts[id] = [queuedPanelPrompts[id], words]
      .compactMap { $0 }.joined(separator: "\n\n")
    store.objectWillChange.send()
    if !gone, store.conversation(id: id)?.lastKnownState.blocksSending == true {
      await engine.stop(conversationID: id)
    }
    flushQueuedPrompts(store.conversations)
    return true
  }

  /// An answer whose ask is gone goes as the chat's next message, by the path any
  /// message takes: refused or failed, its words come back to the composer.
  func deliverLateAnswer(
    _ answers: [[String]],
    to prompt: QuestionPrompt,
    interactionID: String,
    in id: UUID
  ) -> Bool {
    guard store.answerLateQuestion(id: interactionID, in: id, answers: answers) else { return false }
    questionAnswers[id]?[interactionID] = nil
    let words = prompt.lateAnswer(answers)
    if !sendFollowUp(words, to: id) {
      queuedPanelPrompts[id] = [queuedPanelPrompts[id], words]
        .compactMap { $0 }.joined(separator: "\n\n")
      store.objectWillChange.send()
      flushQueuedPrompts(store.conversations)
    }
    return true
  }

  private func flushQueuedPrompts(_ conversations: [Conversation]) {
    guard !queuedPanelPrompts.isEmpty else { return }
    let live = Set(conversations.map(\.id))
    queuedPanelPrompts = queuedPanelPrompts.filter { live.contains($0.key) }
    for conversation in conversations {
      guard let prompt = queuedPanelPrompts[conversation.id],
            !conversation.lastKnownState.blocksSending,
            pendingPanelPrompts[conversation.id] == nil
      else { continue }
      queuedPanelPrompts[conversation.id] = nil
      _ = sendFollowUp(prompt, to: conversation.id)
    }
  }

  // MARK: - Sending

  private func sendPanelPrompt(
    _ prompt: String, pictures: [ConversationAttachment] = [], to id: UUID
  ) {
    pendingPanelPrompts[id] = (prompt, store.transcript(id: id).messages.count, Date())
    failedPanelPrompts[id] = nil
    store.setDraft(prompt, for: id)
    store.objectWillChange.send()
    panelSendTasks[id]?.cancel()
    panelSendTasks[id] = Task { [weak self] in
      defer {
        if let self {
          self.pendingPanelPrompts[id] = nil
          self.panelSendTasks[id] = nil
          self.store.objectWillChange.send()
          self.flushQueuedPrompts(self.store.conversations)
        }
      }
      guard let engine = self?.engine else { return }
      let sent = await engine.send(text: prompt, attachments: pictures, in: id)
      guard let self, !Task.isCancelled else { return }
      if !sent { self.failedPanelPrompts[id] = prompt }
      if self.automaticSends[id] != nil {
        // After this task has let go of the chat: the hand-over sends again.
        Task { @MainActor [weak self] in self?.handOverIfDue(id) }
      }
    }
  }

  @discardableResult
  func abandonPanelSend(for id: UUID) -> Bool {
    guard let task = panelSendTasks[id] else { return false }
    automaticSends[id] = nil
    failedPanelPrompts[id] = pendingPanelPrompts[id]?.text
    task.cancel()
    panelSendTasks[id] = nil
    pendingPanelPrompts[id] = nil
    if store.conversation(id: id)?.lastKnownState.blocksSending == true {
      store.setExecutionState(.failed, for: id)
    }
    store.objectWillChange.send()
    return true
  }

  func observePreview(
    of conversationID: UUID,
    _ handler: (@Sendable () -> Void)?
  ) {
    previewObservers[conversationID]?.cancel()
    guard let handler else {
      previewObservers[conversationID] = nil
      return
    }
    previewObservers[conversationID] = store.objectWillChange.merge(with: engine.objectWillChange)
      .sink { [weak self] _ in self?.schedulePreviewRefresh(of: conversationID, handler) }
  }

  private var previewObservers: [UUID: AnyCancellable] = [:]
  private var previewRefreshesScheduled: Set<UUID> = []

  private func schedulePreviewRefresh(
    of conversationID: UUID,
    _ handler: @escaping @Sendable () -> Void
  ) {
    guard previewRefreshesScheduled.insert(conversationID).inserted else { return }
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated { _ = self?.previewRefreshesScheduled.remove(conversationID) }
      handler()
    }
  }

  // MARK: - Notifications

  private func observe() {
    previousStates = Dictionary(
      store.conversations.map { ($0.id, $0.lastKnownState) },
      uniquingKeysWith: { first, _ in first }
    )
    store.$conversations
      .receive(on: RunLoop.main)
      .sink { [weak self] conversations in
        guard let self else { return }
        flushQueuedPrompts(conversations)
        announceIfNeeded(conversations)
        onStatusSnapshotChange?(statusSnapshot)
      }
      .store(in: &cancellables)
  }

  private func announceIfNeeded(_ conversations: [Conversation]) {
    for conversation in conversations {
      let old = previousStates[conversation.id]
      let state = conversation.lastKnownState
      previousStates[conversation.id] = state
      guard let old, old != state else { continue }
      let status: String
      var kind = SystemAttentionNotification.Kind.needsYou
      switch state {
      case .working: continue
      case .idle:
        guard old.blocksSending else { continue }
        status = "Done"
        kind = .finished
        automaticSends[conversation.id] = nil
        if !conversation.isAskBoltty { onTurnFinished?(conversation) }
      case .waiting:
        automaticSends[conversation.id] = nil
        let transcript = store.transcript(id: conversation.id)
        status = SystemAttentionNotification.needsWords(
          for: (transcript.openInteraction ?? transcript.interactions.last)?.kind)
      case .failed:
        if handOverIfDue(conversation.id) { continue }
        status = "Didn't finish"
      case .interrupted:
        automaticSends[conversation.id] = nil
        continue
      case .rateLimited:
        if handOverIfDue(conversation.id) { continue }
        status = "Rate limited"
      }
      guard store.selectedConversationID != conversation.id, !conversation.isAskBoltty else { continue }
      let agent = AgentId(rawValue: conversation.providerID)?.shortDisplayName
      notificationDelivery?(SystemAttentionNotification(
        sessionID: conversation.id,
        title: conversation.title,
        body: SystemAttentionNotification.statusLine(status, agent: agent),
        kind: kind
      ))
    }
    let ids = Set(conversations.map(\.id))
    previousStates = previousStates.filter { ids.contains($0.key) }
    automaticSends = automaticSends.filter { ids.contains($0.key) }
    handOvers = handOvers.filter { ids.contains($0.key) }
  }

  func spokenReply(of id: UUID) -> (messageID: String, text: String)? {
    guard let reply = AnswerReading.reply(in: store.transcript(id: id).messages),
          let text = AnswerReading.excerpt(of: reply.copyableText)
    else { return nil }
    return (reply.id, text)
  }

  @discardableResult
  func replyFromNotification(_ text: String, to id: UUID) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, store.conversation(id: id) != nil else { return false }
    guard store.transcript(id: id).openInteraction == nil else { return false }
    if !sendFollowUp(trimmed, to: id) { queueFollowUp(trimmed, to: id) }
    return true
  }

  // MARK: - Lifecycle

  func prepareForTermination() async {
    await engine.requestStopForAll()
    await engine.shutdown()
    store.close()
  }
}
