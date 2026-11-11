import Combine
import Foundation
import os

@MainActor
final class ConversationEngine: ObservableObject {
  let store: ConversationStore
  let registry: AgentRegistry
  private let log = Logger(subsystem: "com.boltty", category: "conversation-engine")

  @Published private(set) var notices: [UUID: EngineNotice] = [:]
  @Published private(set) var modelsByProvider: [String: [AgentModelOption]] = [:]
  @Published private(set) var usageByProvider: [String: AgentUsage] = [:]
  @Published private(set) var historyByProvider: [String: AgentActivityHistory] = [:]
  @Published private(set) var contextByConversation: [UUID: AgentContextUsage] = [:]
  private var usageReadAt: Date?
  static let usageRefreshInterval: TimeInterval = 60
  @Published private(set) var hasProbed = false

  private var eventTasks: [Task<Void, Never>] = []
  private var listening: Set<String> = []
  private var hasStarted = false
  private var conversationLookupSubscription: AnyCancellable?
  private var attached: Set<String> = []
  private var creatingSessions: [UUID: Task<String, Error>] = [:]
  private var sending: Set<UUID> = []
  private var namingChats: Set<UUID> = []
  private var processesToRestart: Set<UUID> = []
  private var modelsReadAt: Date?
  private var modelRefresh: Task<Void, Never>?
  private var modelsReadAtByProvider: [String: Date] = [:]
  private var modelReads: [String: Task<Void, Never>] = [:]
  private var settingsInForce: [String: AgentSessionOptions] = [:]
  private var seenVersions: [String: String] = [:]
  nonisolated static let modelListLifetime: TimeInterval = 60 * 60
  private static let modelReadDelay: UInt64 = 1_000_000_000

  static let defaultModelListDeadline: TimeInterval = 30
  private let modelListDeadline: TimeInterval

  init(
    store: ConversationStore,
    registry: AgentRegistry,
    modelListDeadline: TimeInterval = ConversationEngine.defaultModelListDeadline
  ) {
    self.store = store
    self.registry = registry
    self.modelListDeadline = modelListDeadline
    // Called off the main actor: never read the store here.
    let lookup = ConversationSessionLookup()
    conversationLookupSubscription = store.$conversations.sink { conversations in
      lookup.replace(with: conversations)
    }
    for client in registry.clients {
      let providerID = client.providerID
      client.setConversationResolver { remoteID in
        lookup.conversationID(remoteID: remoteID, providerID: providerID)
      }
    }
  }

  convenience init(store: ConversationStore, client: AgentClient) {
    self.init(store: store, registry: AgentRegistry(clients: [client]))
  }

  // MARK: - Routing

  func client(for conversationID: UUID) -> AgentClient? {
    guard let providerID = store.conversation(id: conversationID)?.providerID else { return nil }
    return registry.client(forProviderID: providerID)
  }

  func provider(for conversationID: UUID) -> AgentId? {
    AgentId(rawValue: store.conversation(id: conversationID)?.providerID ?? "")
  }

  func capabilities(for conversationID: UUID) -> AgentCapabilities {
    guard let providerID = store.conversation(id: conversationID)?.providerID else { return [] }
    return registry.capabilities(forProviderID: providerID)
  }

  func models(for conversationID: UUID) -> [AgentModelOption] {
    guard let providerID = store.conversation(id: conversationID)?.providerID else { return [] }
    return modelsByProvider[providerID] ?? []
  }

  func setAutoApprove(_ enabled: Bool, for conversationID: UUID) async {
    store.setAutoApprove(enabled, for: conversationID)
    guard let remote = store.conversation(id: conversationID)?.remoteSessionID,
          let client = client(for: conversationID)
    else { return }
    do {
      try await client.setAutoApproval(enabled, sessionID: remote)
      settingsInForce[remote]?.autoApprove = enabled
    } catch {
      notices[conversationID] = EngineNotice(
        text: "\(agentName(for: conversationID)) did not take that change. It will apply to the "
          + "next conversation.",
        isBlocking: false
      )
    }
  }

  func effortOptions(for conversationID: UUID) -> [AgentEffortOption] {
    guard let conversation = store.conversation(id: conversationID),
          registry.capabilities(forProviderID: conversation.providerID)
            .contains(.reasoningEffort)
    else { return [] }
    let options = models(for: conversationID)
    return (options.option(for: conversation.model) ?? options.agentDefault)?.effortOptions ?? []
  }

  func chooseModel(_ option: AgentModelOption, for conversationID: UUID) {
    guard let conversation = store.conversation(id: conversationID) else { return }
    let effort = conversation.reasoningEffort.flatMap { level in
      option.effortOptions.contains { $0.value == level } ? level : nil
    }
    store.setModel(option.selection, effort: effort, for: conversationID)
  }

  func chooseEffort(_ effort: String?, for conversationID: UUID) {
    guard let conversation = store.conversation(id: conversationID) else { return }
    if conversation.model == nil, let current = models(for: conversationID).agentDefault {
      store.setModel(current.selection, effort: effort, for: conversationID)
    } else {
      store.setReasoningEffort(effort, for: conversationID)
    }
  }

  func modelIsGone(for conversationID: UUID) -> Bool {
    guard let model = store.conversation(id: conversationID)?.model else { return false }
    let options = models(for: conversationID)
    return !options.isEmpty && options.option(for: model) == nil
  }

  func availability(for conversationID: UUID) -> AgentAvailability? {
    guard hasProbed, let providerID = store.conversation(id: conversationID)?.providerID else {
      return nil
    }
    return registry.installation(forProviderID: providerID)?.availability
  }

  private func requireClient(for conversationID: UUID) throws -> AgentClient {
    guard let client = client(for: conversationID) else { throw AgentClientError.notInstalled }
    return client
  }

  // MARK: - Lifecycle

  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    Task { [weak self] in
      guard let self else { return }
      await registry.probeAll()
      hasProbed = true
      await restartOutdatedProcesses()
      await loadModels()
      listenToInstalledAgents()
    }
  }

  private func listenToInstalledAgents() {
    for installation in registry.installations where installation.availability.isInstalled {
      guard let client = registry.client(for: installation.provider) else { continue }
      let providerID = client.providerID
      guard listening.insert(providerID).inserted else { continue }
      eventTasks.append(Task { [weak self] in
        for await envelope in client.events() {
          guard let self else { return }
          await handle(envelope.stamped(with: providerID))
        }
      })
    }
  }

  private func loadModels(only providers: Set<String>? = nil) async {
    let deadline = modelListDeadline
    await withTaskGroup(of: (String, [AgentModelOption]?).self) { group in
      for installation in registry.ready {
        guard let client = registry.client(for: installation.provider),
              installation.capabilities.contains(.modelSelection),
              providers?.contains(client.providerID) != false
        else { continue }
        group.addTask {
          (client.providerID, await ConversationEngine.modelList(from: client, within: deadline))
        }
      }
      for await (providerID, options) in group {
        if options == nil {
          log.notice("\(providerID, privacy: .public) did not list its models within \(deadline, privacy: .public) s")
        }
        if let options, !options.isEmpty {
          modelsByProvider[providerID] = options
        } else if modelsByProvider[providerID] == nil {
          modelsByProvider[providerID] = []
        }
        modelsReadAtByProvider[providerID] = Date()
      }
    }
    if providers == nil { modelsReadAt = Date() }
  }

  func refreshModelsIfStale(now: Date = Date()) {
    guard modelRefresh == nil, let modelsReadAt else { return }
    if now.timeIntervalSince(modelsReadAt) >= Self.modelListLifetime {
      modelRefresh = Task { [weak self] in
        await self?.refreshAvailability()
        self?.modelRefresh = nil
      }
      return
    }
    for client in registry.clients where client.modelListLifetime < Self.modelListLifetime {
      let readAt = modelsReadAtByProvider[client.providerID] ?? modelsReadAt
      if now.timeIntervalSince(readAt) >= client.modelListLifetime {
        readModels(of: client.providerID)
      }
    }
  }

  private func readModels(of providerID: String) {
    guard modelReads[providerID] == nil else { return }
    modelReads[providerID] = Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.modelReadDelay)
      await self?.loadModels(only: [providerID])
      self?.modelReads[providerID] = nil
    }
  }

  private func readModelsAfterFailure(of providerID: String?) {
    guard let providerID else { return }
    if let readAt = modelsReadAtByProvider[providerID], Date().timeIntervalSince(readAt) < 60 { return }
    readModels(of: providerID)
  }

  private func restartOutdatedProcesses() async {
    for installation in registry.installations {
      guard case let .available(version?) = installation.availability,
            let client = registry.client(for: installation.provider)
      else { continue }
      let providerID = client.providerID
      guard let seen = seenVersions[providerID], seen != version else {
        seenVersions[providerID] = version
        continue
      }
      let isBusy = store.conversations.contains {
        $0.providerID == providerID
          && ($0.lastKnownState.blocksSending || sending.contains($0.id) || creatingSessions[$0.id] != nil)
      }
      guard !isBusy else { continue }
      log.notice("\(providerID, privacy: .public) changed to \(version, privacy: .public): restarting its process")
      await client.restartIdleProcess()
      seenVersions[providerID] = version
    }
  }

  nonisolated static func modelList(
    from client: AgentClient,
    within deadline: TimeInterval
  ) async -> [AgentModelOption]? {
    let (answers, answer) = AsyncStream.makeStream(of: [AgentModelOption]?.self)
    let read = Task {
      let options = (try? await client.availableModels()) ?? []
      answer.yield(options)
    }
    let timer = Task {
      try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
      answer.yield(nil)
    }
    var first = answers.makeAsyncIterator()
    let options = await first.next() ?? nil
    answer.finish()
    read.cancel()
    timer.cancel()
    return options
  }

  func refreshUsage(force: Bool = false) async {
    if !force, let usageReadAt, Date().timeIntervalSince(usageReadAt) < Self.usageRefreshInterval {
      return
    }
    usageReadAt = Date()
    for installation in registry.installations
    where !installation.isReady && usageByProvider[installation.provider.rawValue] != nil {
      usageByProvider.removeValue(forKey: installation.provider.rawValue)
    }
    await withTaskGroup(of: (String, AgentUsage?).self) { group in
      for installation in registry.ready where installation.capabilities.contains(.usageLimits) {
        guard let client = registry.client(for: installation.provider) else { continue }
        group.addTask { (client.providerID, await client.usageLimits()) }
      }
      for await (providerID, usage) in group {
        if let usage { usageByProvider[providerID] = usage }
      }
    }
  }

  func refreshAvailability() async {
    await registry.probeAll()
    hasProbed = true
    await restartOutdatedProcesses()
    await loadModels()
    listenToInstalledAgents()
  }

  func shutdown() async {
    for task in eventTasks { task.cancel() }
    eventTasks.removeAll()
    listening.removeAll()
    hasStarted = false
    store.flush()
    for client in registry.clients {
      await client.shutdown()
    }
  }

  func requestStopForAll(timeout: TimeInterval = 3) async {
    let running = store.conversations.filter {
      $0.lastKnownState.blocksSending && $0.remoteSessionID != nil
    }
    guard !running.isEmpty else { return }
    // Before the stops: their cancellations would read as the person refusing,
    // and a question left waiting at a quit is still theirs to answer next time.
    for conversation in running { store.markQuestionsGone(in: conversation.id) }
    let stops = running.compactMap { conversation -> (AgentClient, String)? in
      guard let remote = conversation.remoteSessionID,
            let client = registry.client(forProviderID: conversation.providerID)
      else { return nil }
      return (client, remote)
    }
    // Every stop, not the first to answer: a turn on the person's own OpenCode
    // service outlives Boltty if its stop is cut short. The deadline is a timer
    // racing the stops, so a stop that never answers cannot hold the quit.
    let (finished, finish) = AsyncStream.makeStream(of: Void.self)
    let all = Task {
      await withTaskGroup(of: Void.self) { group in
        for (client, remote) in stops {
          group.addTask { try? await client.stop(sessionID: remote) }
        }
      }
      finish.yield()
    }
    let timer = Task {
      try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      finish.yield()
    }
    var first = finished.makeAsyncIterator()
    _ = await first.next()
    finish.finish()
    all.cancel()
    timer.cancel()
  }

  // MARK: - Events

  private func handle(_ envelope: AgentEventEnvelope) async {
    if case .modelsChanged = envelope.event {
      if let providerID = envelope.providerID { readModels(of: providerID) }
      return
    }
    if case let .connection(state) = envelope.event {
      store.apply(envelope)
      if case .connected = state {
        if let providerID = envelope.providerID,
           let client = registry.client(forProviderID: providerID),
           client.modelListLifetime < Self.modelListLifetime {
          readModels(of: providerID)
        }
        // Off the event loop: a re-read per chat held every event behind it.
        Task { [weak self] in await self?.resyncAll() }
      }
      return
    }
    var envelope = envelope
    if case let .sessionFailed(_, failure) = envelope.event, failure.rateLimit == nil, !failure.isAbort {
      readModelsAfterFailure(of: envelope.providerID)
    }
    if case let .sessionFailed(sessionID, failure) = envelope.event, var hit = failure.rateLimit {
      if hit.resetsAt == nil, let providerID = envelope.providerID {
        hit.resetsAt = usageByProvider[providerID]?.windows
          .filter { $0.severity == .exhausted }.compactMap(\.resetsAt).max()
        var filled = failure
        filled.rateLimit = hit
        envelope = AgentEventEnvelope(
          providerID: providerID, id: envelope.id, sequence: envelope.sequence,
          event: .sessionFailed(sessionID: sessionID, failure: filled))
      }
      Task { await refreshUsage(force: true) }
    }
    store.apply(envelope)
    if case let .interactionAsked(interaction) = envelope.event,
       case .permission = interaction.kind,
       let conversation = store.conversation(
         remoteSessionID: interaction.remoteSessionID, providerID: envelope.providerID),
       conversation.readOnly {
      Task {
        await reply(
          permissionID: interaction.id, in: conversation.id, decision: .reject,
          message: Self.readOnlyRefusal)
      }
    }
    if case let .executionStateChanged(sessionID, state) = envelope.event,
       !state.blocksSending,
       let conversation = store.conversation(
         remoteSessionID: sessionID, providerID: envelope.providerID) {
      if state == .idle { nameIfDue(conversation.id) }
      let id = conversation.id
      Task { [weak self] in await self?.refreshContext(conversationID: id) }
    }
  }

  // MARK: - Naming

  private func nameIfDue(_ id: UUID) {
    guard !store.isReadOnly, !namingChats.contains(id),
          let conversation = store.conversation(id: id),
          !conversation.hasOwnName, !conversation.isAskBoltty,
          let session = conversation.remoteSessionID,
          let client = registry.client(forProviderID: conversation.providerID),
          let material = ChatTitle.namingMaterial(conversation, transcript: store.transcript(id: id))
    else { return }
    namingChats.insert(id)
    Task { [weak self] in
      let answer = await client.chatTitle(sessionID: session, material: material)
      guard let self else { return }
      self.namingChats.remove(id)
      guard let name = ChatNaming.name(from: answer) else { return }
      self.store.giveName(name, to: id)
    }
  }

  func refreshActivityHistory() async {
    await withTaskGroup(of: (String, AgentActivityHistory?).self) { group in
      for installation in registry.ready where installation.capabilities.contains(.activityHistory) {
        guard let client = registry.client(for: installation.provider) else { continue }
        group.addTask { (client.providerID, await client.activityHistory()) }
      }
      for await (providerID, history) in group {
        if let history { historyByProvider[providerID] = history }
      }
    }
    await refreshUsage(force: true)
  }

  // MARK: - Context

  func refreshContext(conversationID: UUID) async {
    guard let conversation = store.conversation(id: conversationID),
          let remote = conversation.remoteSessionID,
          registry.capabilities(forProviderID: conversation.providerID).contains(.contextUsage),
          let client = registry.client(forProviderID: conversation.providerID),
          let usage = await client.contextUsage(sessionID: remote)
    else { return }
    contextByConversation[conversationID] = usage
  }

  // MARK: - Steering

  func steer(text: String, in conversationID: UUID) async -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !store.isReadOnly,
          canSteer(conversationID),
          let conversation = store.conversation(id: conversationID),
          let remote = conversation.remoteSessionID,
          let client = registry.client(forProviderID: conversation.providerID)
    else { return false }
    let messageID = Self.makeMessageID()
    store.appendUserMessage(id: messageID, text: trimmed, attachments: [], to: conversationID)
    do {
      try await client.steer(messageID: messageID, text: trimmed, to: remote)
      return true
    } catch {
      store.apply(AgentEventEnvelope(
        providerID: conversation.providerID,
        event: .messageRemoved(sessionID: remote, messageID: messageID)))
      return false
    }
  }

  func canSteer(_ conversationID: UUID) -> Bool {
    guard let conversation = store.conversation(id: conversationID),
          conversation.lastKnownState == .working,
          conversation.remoteSessionID != nil
    else { return false }
    return registry.capabilities(forProviderID: conversation.providerID).contains(.steering)
  }

  func compact(conversationID: UUID) async {
    guard let conversation = store.conversation(id: conversationID),
          !conversation.lastKnownState.blocksSending,
          let remote = conversation.remoteSessionID,
          registry.capabilities(forProviderID: conversation.providerID).contains(.compaction),
          let client = registry.client(forProviderID: conversation.providerID)
    else { return }
    do {
      try await client.compact(sessionID: remote)
    } catch {
      notices[conversationID] = EngineNotice(
        text: "\(agentName(for: conversationID)) could not compact this conversation: \(error.localizedDescription)",
        isBlocking: false
      )
    }
  }

  private func resyncAll() async {
    for conversation in store.conversations {
      guard let remote = conversation.remoteSessionID, attached.contains(remote),
            let client = registry.client(forProviderID: conversation.providerID)
      else { continue }
      if await client.missedAnything(sessionID: remote) == false { continue }
      await refresh(conversationID: conversation.id)
    }
  }

  @discardableResult
  func refresh(conversationID: UUID) async -> Bool {
    guard let conversation = store.conversation(id: conversationID),
          let remote = conversation.remoteSessionID,
          let client = registry.client(forProviderID: conversation.providerID)
    else { return false }
    do {
      let snapshot = try await client.loadSession(id: remote)
      attached.insert(remote)
      var interactions = snapshot.openInteractions
      for index in interactions.indices {
        interactions[index] = PendingInteraction(
          id: interactions[index].id,
          conversationID: conversationID,
          remoteSessionID: remote,
          kind: interactions[index].kind,
          askedAt: interactions[index].askedAt
        )
      }
      // Not asked any more and no turn going on past it: its server went, since
      // an answer from elsewhere would have the turn working.
      if snapshot.state != .working {
        store.markQuestionsGone(in: conversationID, except: Set(interactions.map(\.id)))
      }
      // An adapter answering from what is live, before the CLI has written its
      // record, has no messages: that is not a chat emptied.
      let known = store.transcript(id: conversationID).messages
      store.replaceMessages(
        snapshot.messages.isEmpty ? known : snapshot.messages,
        in: conversationID,
        openInteractions: interactions
      )
      store.setExecutionState(snapshot.state, for: conversationID)
      if let model = snapshot.info.model, conversation.model == nil {
        store.setModel(model, effort: conversation.reasoningEffort, for: conversationID)
      }
      notices[conversationID] = nil
      return true
    } catch AgentClientError.sessionNotFound where !attached.contains(remote) {
      log.debug("session \(remote, privacy: .public) is not one this adapter can re-read")
      return false
    } catch AgentClientError.sessionNotFound {
      attached.remove(remote)
      store.apply(
        AgentEventEnvelope(
          providerID: conversation.providerID,
          event: .sessionDeleted(sessionID: remote)
        )
      )
      notices[conversationID] = EngineNotice(
        text: "This conversation is no longer on \(agentName(for: conversationID)). Its history "
          + "is kept, but sending will start a new session.",
        isBlocking: false
      )
      return true
    } catch {
      log.debug("refresh failed: \(String(describing: error), privacy: .public)")
      return false
    }
  }

  // MARK: - Sending

  @discardableResult
  func send(
    text: String,
    attachments: [ConversationAttachment] = [],
    in conversationID: UUID
  ) async -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
    guard let conversation = store.conversation(id: conversationID) else { return false }
    guard !store.isReadOnly else {
      notices[conversationID] = EngineNotice(text: Self.secondCopyRefusal, isBlocking: true)
      return false
    }
    guard !conversation.lastKnownState.blocksSending else { return false }
    guard !sending.contains(conversationID) else { return false }
    sending.insert(conversationID)
    defer { sending.remove(conversationID) }

    if processesToRestart.remove(conversationID) != nil, let remote = conversation.remoteSessionID {
      settingsInForce[remote] = nil
      await registry.client(forProviderID: conversation.providerID)?.release(sessionID: remote)
    }
    notices[conversationID] = nil
    let delivered = await deliver(
      text: trimmed,
      attachments: attachments,
      in: conversationID,
      mayStartNewSession: true
    )
    if delivered { store.letGoOfQuestions(in: conversationID) }
    return delivered
  }

  func keepAskBolttyChat(id: UUID) {
    guard let conversation = store.conversation(id: id), conversation.isAskBoltty else { return }
    store.keepAskBolttyChat(id: id)
    if conversation.readOnly { processesToRestart.insert(id) }
  }

  private func deliver(
    text trimmed: String,
    attachments: [ConversationAttachment],
    in conversationID: UUID,
    mayStartNewSession: Bool
  ) async -> Bool {
    guard let conversation = store.conversation(id: conversationID) else { return false }
    let messageID = Self.makeMessageID()

    let client: AgentClient
    let remote: String
    do {
      client = try requireClient(for: conversationID)
      remote = try await ensureRemoteSession(for: conversationID)
    } catch {
      notices[conversationID] = EngineNotice(
        text: reason(error, for: conversationID, fallback: "could not be started"),
        isBlocking: true
      )
      return false
    }

    store.appendUserMessage(
      id: messageID,
      text: trimmed,
      attachments: attachments,
      to: conversationID
    )
    store.setExecutionState(.working, for: conversationID)

    let outgoing = attachments.compactMap { attachment -> OutgoingAttachment? in
      guard let url = attachment.url else { return nil }
      return OutgoingAttachment(
        url: url,
        displayName: attachment.displayName,
        mimeType: attachment.mimeType
      )
    }

    do {
      if let wanted = store.conversation(id: conversationID).map(Self.sessionOptions(for:)),
         settingsInForce[remote] != wanted {
        try await client.prepareSession(remote, options: wanted)
        settingsInForce[remote] = wanted
      }
      try await client.send(
        messageID: messageID,
        text: trimmed,
        attachments: outgoing,
        to: remote
      )
      if conversation.title == Self.untitled || conversation.title.isEmpty {
        store.rename(id: conversationID, to: Self.title(from: trimmed))
      }
      return true
    } catch AgentClientError.indeterminate {
      return await resolveIndeterminateSend(
        messageID: messageID,
        text: trimmed,
        attachments: attachments,
        remote: remote,
        client: client,
        conversationID: conversationID
      )
    } catch AgentClientError.sessionNotFound where mayStartNewSession {
      store.revertUserMessage(
        id: messageID,
        restoringDraft: trimmed,
        attachments: attachments,
        in: conversationID
      )
      store.apply(
        AgentEventEnvelope(
          providerID: conversation.providerID,
          event: .sessionDeleted(sessionID: remote)
        )
      )
      attached.remove(remote)
      settingsInForce[remote] = nil
      let sent = await deliver(
        text: trimmed,
        attachments: attachments,
        in: conversationID,
        mayStartNewSession: false
      )
      if sent {
        notices[conversationID] = EngineNotice(
          text: "\(agentName(for: conversationID)) had no record of this conversation, so Boltty "
            + "started a new session. The history above is kept, but the agent has not seen it.",
          isBlocking: false
        )
      }
      return sent
    } catch {
      store.revertUserMessage(
        id: messageID,
        restoringDraft: trimmed,
        attachments: attachments,
        in: conversationID
      )
      store.setExecutionState(.idle, for: conversationID)
      notices[conversationID] = EngineNotice(
        text: (error as? LocalizedError)?.errorDescription ?? "That message was not sent.",
        isBlocking: false
      )
      return false
    }
  }

  private func agentName(for conversationID: UUID) -> String {
    provider(for: conversationID)?.displayName ?? "that agent"
  }

  private func reason(_ error: Error, for conversationID: UUID, fallback: String) -> String {
    let name = agentName(for: conversationID)
    if case AgentClientError.notInstalled = error {
      return "\(name) is not installed."
    }
    guard let described = (error as? LocalizedError)?.errorDescription else {
      return "\(name) \(fallback)."
    }
    return "\(name): \(described)"
  }

  private func resolveIndeterminateSend(
    messageID: String,
    text: String,
    attachments: [ConversationAttachment],
    remote: String,
    client: AgentClient,
    conversationID: UUID
  ) async -> Bool {
    do {
      if try await client.messageExists(id: messageID, in: remote) {
        return true
      }
      store.revertUserMessage(
        id: messageID,
        restoringDraft: text,
        attachments: attachments,
        in: conversationID
      )
      store.setExecutionState(.idle, for: conversationID)
      notices[conversationID] = EngineNotice(
        text: "That message did not reach \(agentName(for: conversationID)). It is back in the "
          + "composer — send it again when you are ready.",
        isBlocking: false
      )
      return false
    } catch {
      // It may have landed and be running: idle would invite a second send
      // into a live turn. Ask the agent's record; only with no answer at all
      // is the chat let go.
      if await !refresh(conversationID: conversationID) {
        store.setExecutionState(.idle, for: conversationID)
      }
      notices[conversationID] = EngineNotice(
        text: "Boltty could not confirm whether that message was sent. Check the conversation "
          + "before sending it again.",
        isBlocking: false
      )
      return true
    }
  }

  /// One session per chat, however many callers ask at once: Ask Boltty warms a
  /// chat's session while the person speaks, and the send that follows must
  /// wait for that one rather than start a second.
  func ensureRemoteSession(for conversationID: UUID) async throws -> String {
    guard let conversation = store.conversation(id: conversationID) else {
      throw AgentClientError.sessionNotFound
    }
    if let remote = conversation.remoteSessionID { return remote }
    guard !store.isReadOnly else { throw AgentClientError.serverStartFailed(Self.secondCopyRefusal) }
    if let pending = creatingSessions[conversationID] { return try await pending.value }
    let task = Task { try await self.createRemoteSession(for: conversationID) }
    creatingSessions[conversationID] = task
    defer { creatingSessions[conversationID] = nil }
    return try await task.value
  }

  private func createRemoteSession(for conversationID: UUID) async throws -> String {
    guard let conversation = store.conversation(id: conversationID) else {
      throw AgentClientError.sessionNotFound
    }
    if let remote = conversation.remoteSessionID { return remote }
    let client = try requireClient(for: conversationID)

    let sessionID = client.makeSessionID()
    let options = Self.sessionOptions(for: conversation)
    let info = try await client.createSession(id: sessionID, options: options)
    // A chat forgotten while its session started (Ask Boltty let go before the
    // warm-up finished) must not keep the process it just got.
    guard store.conversation(id: conversationID) != nil else {
      await client.release(sessionID: info.id)
      throw AgentClientError.sessionNotFound
    }
    store.attachRemoteSession(info.id, to: conversationID, model: info.model)
    attached.insert(info.id)
    settingsInForce[info.id] = options
    return info.id
  }

  private static func sessionOptions(for conversation: Conversation) -> AgentSessionOptions {
    AgentSessionOptions(
      directory: conversation.workingDirectory,
      model: conversation.model,
      effort: conversation.reasoningEffort,
      autoApprove: conversation.autoApprove,
      readOnly: conversation.readOnly
    )
  }

  // MARK: - Stopping

  func stop(conversationID: UUID) async {
    guard let remote = store.conversation(id: conversationID)?.remoteSessionID,
          let client = client(for: conversationID)
    else { return }
    do {
      try await client.stop(sessionID: remote)
      store.letGoOfQuestions(in: conversationID, includingOpen: true)
      await refresh(conversationID: conversationID)
    } catch {
      notices[conversationID] = EngineNotice(
        text: "Boltty could not reach \(agentName(for: conversationID)) to stop that.",
        isBlocking: false
      )
    }
  }

  func forgetConversation(id: UUID) {
    guard let conversation = store.conversation(id: id) else { return }
    notices[id] = nil
    store.deleteConversation(id: id)
    guard let remote = conversation.remoteSessionID,
          let client = registry.client(forProviderID: conversation.providerID)
    else { return }
    attached.remove(remote)
    settingsInForce[remote] = nil
    let running = conversation.lastKnownState.blocksSending
    Task {
      if running { try? await client.stop(sessionID: remote) }
      await client.release(sessionID: remote)
    }
  }

  func deleteConversation(id: UUID) async {
    if let conversation = store.conversation(id: id),
       let remote = conversation.remoteSessionID,
       let client = registry.client(forProviderID: conversation.providerID) {
      if conversation.lastKnownState.blocksSending { try? await client.stop(sessionID: remote) }
      attached.remove(remote)
      settingsInForce[remote] = nil
      await client.release(sessionID: remote)
    }
    notices[id] = nil
    store.trashConversation(id: id)
  }

  // MARK: - Interactions

  @discardableResult
  func answer(
    interactionID: String,
    in conversationID: UUID,
    answers: [[String]]
  ) async -> Bool {
    guard let remote = store.conversation(id: conversationID)?.remoteSessionID,
          let client = client(for: conversationID),
          store.beginSubmitting(interactionID: interactionID, in: conversationID)
    else { return false }
    do {
      try await client.answerQuestion(
        requestID: interactionID,
        sessionID: remote,
        answers: answers
      )
      store.resolveInteraction(id: interactionID, in: conversationID, with: .answered(answers))
      notices[conversationID] = nil
      return true
    } catch AgentClientError.requestGone {
      await putAway(interactionID: interactionID, in: conversationID)
      return false
    } catch {
      store.cancelSubmitting(interactionID: interactionID, in: conversationID)
      notices[conversationID] = EngineNotice(
        text: "That answer was not delivered. Try again.",
        isBlocking: false
      )
      return false
    }
  }

  func rejectQuestion(interactionID: String, in conversationID: UUID) async {
    guard let remote = store.conversation(id: conversationID)?.remoteSessionID,
          let client = client(for: conversationID),
          store.beginSubmitting(interactionID: interactionID, in: conversationID)
    else { return }
    do {
      try await client.rejectQuestion(requestID: interactionID, sessionID: remote)
      store.resolveInteraction(id: interactionID, in: conversationID, with: .rejected)
    } catch AgentClientError.requestGone {
      // Refused, so it does not stay to be answered late.
      store.resolveInteraction(id: interactionID, in: conversationID, with: .rejected)
      await putAway(interactionID: interactionID, in: conversationID)
    } catch {
      store.cancelSubmitting(interactionID: interactionID, in: conversationID)
    }
  }

  @discardableResult
  func reply(
    permissionID: String,
    in conversationID: UUID,
    decision: PermissionDecision,
    message: String? = nil
  ) async -> Bool {
    guard let remote = store.conversation(id: conversationID)?.remoteSessionID,
          let client = client(for: conversationID),
          store.beginSubmitting(interactionID: permissionID, in: conversationID)
    else { return false }
    do {
      try await client.answerPermission(
        requestID: permissionID,
        sessionID: remote,
        decision: decision,
        message: registry.capabilities(forProviderID: client.provider.rawValue)
          .contains(.permissionMessage) ? message : nil
      )
      store.resolveInteraction(
        id: permissionID,
        in: conversationID,
        with: .permission(decision)
      )
      notices[conversationID] = nil
      return true
    } catch AgentClientError.requestGone {
      await putAway(interactionID: permissionID, in: conversationID)
      return false
    } catch {
      store.cancelSubmitting(interactionID: permissionID, in: conversationID)
      notices[conversationID] = EngineNotice(
        text: "That reply was not delivered. Try again.",
        isBlocking: false
      )
      return false
    }
  }

  @discardableResult
  func reply(
    planID: String,
    in conversationID: UUID,
    decision: PlanDecision,
    feedback: String? = nil
  ) async -> Bool {
    guard let remote = store.conversation(id: conversationID)?.remoteSessionID,
          let client = client(for: conversationID),
          store.beginSubmitting(interactionID: planID, in: conversationID)
    else { return false }
    let words = feedback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    do {
      try await client.answerPlan(
        requestID: planID,
        sessionID: remote,
        decision: decision,
        feedback: decision == .cancelled && !words.isEmpty ? words : nil
      )
      store.resolveInteraction(id: planID, in: conversationID, with: .plan(decision))
      notices[conversationID] = nil
      return true
    } catch AgentClientError.requestGone {
      await putAway(interactionID: planID, in: conversationID)
      return false
    } catch {
      store.cancelSubmitting(interactionID: planID, in: conversationID)
      notices[conversationID] = EngineNotice(
        text: "That reply was not delivered. Try again.",
        isBlocking: false
      )
      return false
    }
  }

  private func putAway(interactionID: String, in conversationID: UUID) async {
    store.expireInteraction(id: interactionID, in: conversationID)
    notices[conversationID] = nil
    await refresh(conversationID: conversationID)
    if store.transcript(id: conversationID).openInteraction == nil,
       store.conversation(id: conversationID)?.lastKnownState == .waiting {
      store.setExecutionState(.idle, for: conversationID)
    }
  }

  // MARK: - Helpers

  nonisolated static let untitled = "New conversation"
  static let secondCopyRefusal =
    "Another Boltty is already running and owns your conversations. Use that one to send."

  static let readOnlyRefusal =
    "This chat is read-only: answer from what you can see, without changing files or running commands."

  static func makeMessageID() -> String { "msg_" + randomSuffix() }

  private static func randomSuffix() -> String {
    let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    return String((0..<24).map { _ in alphabet.randomElement()! })
  }

  static func title(from prompt: String) -> String {
    let cleaned = ChatTitle.clean(prompt)
    guard !cleaned.isEmpty else { return untitled }
    let words = cleaned.split(separator: " ")
    var title = ""
    for word in words {
      if title.count + word.count + 1 > 40 { break }
      title += title.isEmpty ? String(word) : " " + word
    }
    if title.isEmpty { title = String(cleaned.prefix(40)) }
    return title.count < cleaned.count ? title + "…" : title
  }
}

struct EngineNotice: Equatable, Sendable {
  var text: String
  var isBlocking: Bool
}

private final class ConversationSessionLookup: @unchecked Sendable {
  private struct Key: Hashable {
    let providerID: String
    let remoteID: String
  }
  private let lock = NSLock()
  private var conversations: [Key: UUID] = [:]

  func replace(with rows: [Conversation]) {
    var snapshot: [Key: UUID] = [:]
    for row in rows {
      guard let remoteID = row.remoteSessionID else { continue }
      let key = Key(providerID: row.providerID, remoteID: remoteID)
      if snapshot[key] == nil { snapshot[key] = row.id }
    }
    lock.withLock { conversations = snapshot }
  }

  func conversationID(remoteID: String, providerID: String) -> UUID? {
    lock.withLock { conversations[Key(providerID: providerID, remoteID: remoteID)] }
  }
}
