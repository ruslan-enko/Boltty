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

  var isProviderEnabled: (String) -> Bool = { _ in true }
  var preferredProviderID: () -> String? = { nil }
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

  // MARK: - Conversations

  func resolvedDefaultModel(for providerID: String) -> ModelSelection? {
    guard let modelID = defaultModelID(providerID), !modelID.isEmpty else { return nil }
    if let option = engine.modelsByProvider[providerID]?.first(where: {
      $0.selection.modelID == modelID
    }) {
      return option.selection
    }
    return ModelSelection(providerID: providerID, modelID: modelID)
  }

  func resolvedDefaultEffort(for providerID: String, model: ModelSelection?) -> String? {
    guard let effort = defaultEffortID(providerID), !effort.isEmpty else { return nil }
    let options = engine.modelsByProvider[providerID] ?? []
    let match = model.flatMap { selection in
      options.first { $0.selection.modelID == selection.modelID }
    } ?? options.first { $0.isDefault } ?? options.first
    guard let match, match.effortOptions.contains(where: { $0.value == effort }) else {
      return nil
    }
    return effort
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

  // MARK: - Ask Boltty

  /// Ask Boltty's chat is made the moment the chord is held, and its session
  /// started then, so the agent is up by the time the person stops speaking.
  func prepareAskBolttyConversation(
    providerID: String, model: ModelSelection?, effort: String?, readOnly: Bool
  ) -> Conversation {
    let model = model ?? resolvedDefaultModel(for: providerID)
    let conversation = store.createConversation(
      title: ConversationEngine.untitled,
      workingDirectory: store.defaultWorkingDirectory(),
      providerID: providerID,
      model: model,
      reasoningEffort: effort ?? resolvedDefaultEffort(for: providerID, model: model),
      readOnly: readOnly,
      isAskBoltty: true
    )
    Task { [engine] in _ = try? await engine.ensureRemoteSession(for: conversation.id) }
    return conversation
  }

  /// An Ask Boltty that was let go without a word leaves no chat behind.
  func discardAskBolttyConversation(_ id: UUID) {
    guard store.transcript(id: id).messages.isEmpty, pendingPanelPrompts[id] == nil else { return }
    forgetAskBolttyChat(id)
  }

  /// Ask Boltty keeps no history: an Ask Boltty chat lasts as
  /// long as a follow-up can reach it. Every other one goes — its session
  /// let go, its record and its screenshots deleted — unless it is still
  /// working or waiting on the person. Also the chats an early Ask Boltty
  /// made without marking them, known by the bracket that titled them.
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
    pictures: [ConversationAttachment] = []
  ) -> Conversation {
    let provider = providerID ?? defaultProviderID()
    let model = resolvedDefaultModel(for: provider)
    let conversation = store.createConversation(
      id: id,
      title: ConversationEngine.title(from: prompt),
      workingDirectory: workingDirectory ?? store.defaultWorkingDirectory(),
      providerID: provider,
      model: model,
      reasoningEffort: resolvedDefaultEffort(for: provider, model: model),
      autoApprove: engine.registry.capabilities(forProviderID: provider).contains(.autoApproval)
        && defaultAutoApprove(provider)
    )
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
    }
  }

  @discardableResult
  func abandonPanelSend(for id: UUID) -> Bool {
    guard let task = panelSendTasks[id] else { return false }
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
      case .waiting:
        let transcript = store.transcript(id: conversation.id)
        status = SystemAttentionNotification.needsWords(
          for: (transcript.openInteraction ?? transcript.interactions.last)?.kind)
      case .failed: status = "Didn't finish"
      case .interrupted: continue
      case .rateLimited: status = "Rate limited"
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
