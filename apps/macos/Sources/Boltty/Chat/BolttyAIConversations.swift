import Combine
import Foundation

@MainActor
protocol BolttyAIConversations: AnyObject {
  func switcherItems() -> [BolttyAISessionItem]

  func sessionTranscripts() -> [UUID: ConversationTranscript]

  var conversationsChanged: AnyPublisher<Void, Never> { get }

  func conversation(id: UUID) -> Conversation?

  func startConversation(
    prompt: String, id: UUID, workingDirectory: String, providerID: String?,
    pictures: [ConversationAttachment]
  ) -> UUID?

  func launchableProviderIDs() -> [String]

  func listedProviderIDs() -> [String]

  func defaultWorkingDirectory() -> String

  func setWorkingDirectory(_ path: String, for id: UUID)

  func recentWorkingDirectories() -> [String]

  func honoursWorkingDirectory(providerID: String) -> Bool

  func acceptsAttachments(providerID: String) -> Bool

  func routingFallback() -> AgentRoutingFallback?

  func plannedProviderID() -> String?

  func recordSentFiles(_ files: [SentFile], in id: UUID)

  func sendFollowUp(_ prompt: String, pictures: [ConversationAttachment], to id: UUID) -> Bool

  @discardableResult
  func queueFollowUp(_ prompt: String, to id: UUID) -> BolttyAIFollowUp.QueuedSend

  @discardableResult
  func steerFollowUp(_ prompt: String, to id: UUID) -> BolttyAIFollowUp.QueuedSend

  func canSteer(_ id: UUID) -> Bool

  func setAutoApprove(_ enabled: Bool, for id: UUID)

  func modelMenu(for id: UUID) -> BolttyAIModelMenu?

  func chooseModel(_ option: AgentModelOption, for id: UUID)

  func chooseEffort(_ effort: String?, for id: UUID)

  @discardableResult
  func cancelQueuedFollowUp(for id: UUID) -> String?

  func finderLocation(forRow id: UUID) -> URL?

  func canDeleteChat(_ id: UUID) -> Bool

  func deleteChat(id: UUID) async

  func setAddressedConversation(_ id: UUID?)

  func keepChat(_ id: UUID)

  func preview(for id: UUID) -> BolttyAISessionPreview?

  func observePreview(of id: UUID, _ handler: (@Sendable () -> Void)?)

  @discardableResult
  func answer(_ question: AgentQuestion, with values: [String]) async throws -> Bool

  var providerAvailability: AgentAvailability? { get }

  func saveDraft(_ draft: PromptDraft, for id: UUID)
  func stopConversation(id: UUID) async

  func usage(providerID: String) -> AgentUsage?
  func refreshUsage()
  func refreshModelsIfStale()
  func contextUsage(for id: UUID) -> AgentContextUsage?
  func canCompact(_ id: UUID) -> Bool
  func refreshContext(for id: UUID)
  func compact(_ id: UUID)
  var usageChanged: AnyPublisher<Void, Never> { get }
}

extension BolttyAIConversations {
  func finderLocation(forRow id: UUID) -> URL? { nil }
  func canDeleteChat(_ id: UUID) -> Bool { false }
  func deleteChat(id: UUID) async {}
  func usage(providerID: String) -> AgentUsage? { nil }
  func contextUsage(for id: UUID) -> AgentContextUsage? { nil }
  func canCompact(_ id: UUID) -> Bool { false }
  func refreshContext(for id: UUID) {}
  func compact(_ id: UUID) {}
  func refreshUsage() {}
  func refreshModelsIfStale() {}
  var usageChanged: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }

  func sessionTranscripts() -> [UUID: ConversationTranscript] { [:] }

  func listedProviderIDs() -> [String] { [] }

  func keepChat(_ id: UUID) {}

  func recentWorkingDirectories() -> [String] { [] }

  @discardableResult
  func steerFollowUp(_ prompt: String, to id: UUID) -> BolttyAIFollowUp.QueuedSend {
    queueFollowUp(prompt, to: id)
  }
  func canSteer(_ id: UUID) -> Bool { false }
  func setAutoApprove(_ enabled: Bool, for id: UUID) {}
  func modelMenu(for id: UUID) -> BolttyAIModelMenu? { nil }
  func chooseModel(_ option: AgentModelOption, for id: UUID) {}
  func chooseEffort(_ effort: String?, for id: UUID) {}

  func startConversation(prompt: String, id: UUID, workingDirectory: String) -> UUID? {
    startConversation(
      prompt: prompt, id: id, workingDirectory: workingDirectory, providerID: nil, pictures: [])
  }
}

extension ChatWorkspaceCoordinator: BolttyAIConversations {
  var conversationsChanged: AnyPublisher<Void, Never> {
    store.objectWillChange
      .map { _ in () }
      .eraseToAnyPublisher()
  }

  var providerAvailability: AgentAvailability? {
    guard engine.hasProbed else { return nil }
    return automaticProviderID() == nil ? .notInstalled : .available(version: nil)
  }

  func switcherItems() -> [BolttyAISessionItem] {
    BolttyAISessionList.items(
      conversations: store.orderedConversations,
      transcripts: store.transcripts,
      damagedIDs: store.damagedConversationIDs,
      selectedID: store.selectedConversationID
    )
  }

  func finderLocation(forRow id: UUID) -> URL? {
    store.conversation(id: id) == nil ? nil : store.folder(of: id)
  }

  func canDeleteChat(_ id: UUID) -> Bool { store.conversation(id: id) != nil }

  func deleteChat(id: UUID) async {
    await engine.deleteConversation(id: id)
  }

  func sessionTranscripts() -> [UUID: ConversationTranscript] {
    store.transcripts
  }

  func conversation(id: UUID) -> Conversation? {
    store.conversation(id: id)
  }

  func saveDraft(_ draft: PromptDraft, for id: UUID) { store.setPanelDraft(draft, for: id) }

  func stopConversation(id: UUID) async {
    if let queued = cancelQueuedFollowUp(for: id) {
      failedPanelPrompts[id] = queued
    }
    abandonPanelSend(for: id)
    await engine.stop(conversationID: id)
  }

  func setAddressedConversation(_ id: UUID?) {
    store.select(id)
  }

  func keepChat(_ id: UUID) {
    engine.keepAskBolttyChat(id: id)
  }

  func startConversation(
    prompt: String, id: UUID, workingDirectory: String, providerID requested: String?,
    pictures: [ConversationAttachment]
  ) -> UUID? {
    let automatic = requested == nil && routesAutomatically()
    let providerID = requested.map { launchableProviderIDs().contains($0) ? $0 : nil }
      ?? (automatic ? routingOrder(forPictures: !pictures.isEmpty).first : automaticProviderID())
    guard let providerID else { return nil }
    return startConversationInBackground(
      prompt: prompt,
      id: id,
      providerID: providerID,
      workingDirectory: workingDirectory,
      pictures: pictures,
      handsOver: automatic
    ).id
  }

  func defaultWorkingDirectory() -> String { store.defaultWorkingDirectory() }

  func setWorkingDirectory(_ path: String, for id: UUID) {
    store.setWorkingDirectory(path, for: id)
  }

  func recentWorkingDirectories() -> [String] {
    let places = store.conversations.map { (path: $0.workingDirectory, touched: $0.updatedAt) }
    return RecentFolders.list(places, home: WorkingDirectoryResolver.homeDirectoryPath) { path in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }
  }

  func honoursWorkingDirectory(providerID: String) -> Bool {
    let capabilities = engine.registry.capabilities(forProviderID: providerID)
    guard !capabilities.isEmpty else { return true }
    return capabilities.contains(.workingDirectory)
  }

  func acceptsAttachments(providerID: String) -> Bool {
    engine.registry.capabilities(forProviderID: providerID).contains(.attachments)
  }

  func recordSentFiles(_ files: [SentFile], in id: UUID) {
    store.recordSentFiles(files, for: id)
  }

  func plannedProviderID() -> String? { automaticProviderID() }

  func usage(providerID: String) -> AgentUsage? { engine.usageByProvider[providerID] }

  func refreshModelsIfStale() {
    engine.refreshModelsIfStale()
  }

  func refreshUsage() {
    Task { @MainActor [engine] in await engine.refreshUsage() }
  }

  func contextUsage(for id: UUID) -> AgentContextUsage? { engine.contextByConversation[id] }

  func canCompact(_ id: UUID) -> Bool {
    guard let conversation = store.conversation(id: id),
          conversation.remoteSessionID != nil,
          !conversation.lastKnownState.blocksSending
    else { return false }
    return engine.registry.capabilities(forProviderID: conversation.providerID)
      .contains(.compaction)
  }

  func refreshContext(for id: UUID) {
    Task { @MainActor [engine] in await engine.refreshContext(conversationID: id) }
  }

  func compact(_ id: UUID) {
    Task { @MainActor [engine] in await engine.compact(conversationID: id) }
  }

  func setAutoApprove(_ enabled: Bool, for id: UUID) {
    Task { @MainActor [engine] in await engine.setAutoApprove(enabled, for: id) }
  }

  func modelMenu(for id: UUID) -> BolttyAIModelMenu? {
    guard let conversation = store.conversation(id: id),
          let agent = AgentId(rawValue: conversation.providerID)
    else { return nil }
    let capabilities = engine.capabilities(for: id)
    let models = capabilities.contains(.modelSwitching) ? engine.models(for: id) : []
    let isGone = engine.modelIsGone(for: id)
    return BolttyAIModelMenu(
      agent: agent,
      models: models,
      current: isGone ? nil : models.option(for: conversation.model) ?? models.agentDefault,
      goneName: isGone ? conversation.model?.displayName : nil,
      efforts: capabilities.contains(.modelSwitching) ? engine.effortOptions(for: id) : [],
      effort: conversation.reasoningEffort,
      canResetEffort: capabilities.contains(.effortReset),
      autoMode: capabilities.contains(.autoApproval) ? conversation.autoApprove : nil
    )
  }

  func chooseModel(_ option: AgentModelOption, for id: UUID) {
    engine.chooseModel(option, for: id)
  }

  func chooseEffort(_ effort: String?, for id: UUID) {
    engine.chooseEffort(effort, for: id)
  }

  private func requestToRetryOnAnotherModel(in id: UUID) -> String? {
    let messages = store.transcript(id: id).messages
    guard store.conversation(id: id)?.lastKnownState == .failed,
          messages.last?.failure.map(AgentFailureReport.saysModelIsGone) == true
    else { return nil }
    return messages.last { $0.role == .user }?.plainText
  }

  private func modelChip(for conversation: Conversation) -> BolttyAIModelChip? {
    guard let menu = modelMenu(for: conversation.id),
          !menu.models.isEmpty || conversation.model != nil || menu.autoMode != nil
    else { return nil }
    let name = menu.goneName ?? menu.current?.selection.displayName
      ?? conversation.model?.displayName ?? "Default"
    let effort = conversation.reasoningEffort.map { level in
      menu.efforts.first { $0.value == level }?.label ?? AgentEffortOption.title(for: level)
    }
    var help = menu.goneName == nil
      ? "Model and permissions for this chat"
      : "\(menu.agent.shortDisplayName) no longer offers this model. Choose another."
    if menu.autoMode == true { help += "\nAuto Mode is on" }
    return BolttyAIModelChip(
      title: [name, effort].compactMap { $0 }.joined(separator: " · "),
      isGone: menu.goneName != nil,
      help: help
    )
  }

  var usageChanged: AnyPublisher<Void, Never> {
    engine.$usageByProvider.map { _ in () }
      .merge(with: engine.$contextByConversation.map { _ in () })
      .receive(on: RunLoop.main)
      .eraseToAnyPublisher()
  }

  func listedProviderIDs() -> [String] {
    let enabled = Set(AgentHistory.tabOrder.map(\.rawValue).filter(isProviderEnabled))
    let installed = engine.hasProbed
      ? Set(engine.registry.installations.filter(\.availability.isInstalled).map(\.provider.rawValue))
      : nil
    return AgentHistory.listed(enabled: enabled, installed: installed).map(\.rawValue)
  }

  func launchableProviderIDs() -> [String] {
    let ready = Set(engine.registry.ready.map(\.provider.rawValue)).filter(isProviderEnabled)
    return AgentHistory.tabOrder.map(\.rawValue).filter(ready.contains)
  }

  func routingFallback() -> AgentRoutingFallback? {
    guard !routesAutomatically(), let preferredID = preferredProviderID(),
          let preferred = AgentId(rawValue: preferredID),
          isProviderEnabled(preferredID),
          let usedID = automaticProviderID(),
          usedID != preferredID,
          let used = AgentId(rawValue: usedID),
          let installation = engine.registry.installation(for: preferred)
    else { return nil }
    return AgentRoutingFallback(
      preferred: preferred,
      used: used,
      reason: installation.statusText
    )
  }

  func preview(for id: UUID) -> BolttyAISessionPreview? {
    guard let conversation = store.conversation(id: id) else { return nil }
    let transcript = store.transcript(id: id)
    let lastAgentText = transcript.messages
      .last { $0.role == .agent && !$0.plainText.isEmpty }?
      .plainText
    let pending = pendingPanelPrompts[id]
    let capabilities = engine.registry.capabilities(forProviderID: conversation.providerID)
    var messages = transcript.messages
    if let pending, messages.count == pending.messageCount {
      messages.append(ConversationMessage(id: "pending-\(id)", role: .user, createdAt: pending.sentAt, parts: [.text(TextPart(id: "prompt", kind: .text, text: pending.text))]))
    }
    messages = LiftedRequests.lift(messages, files: conversation.sentFiles, in: id)
    if let open = transcript.openInteraction, case let .plan(plan) = open.kind,
       let bubble = Self.planBubble(plan, id: open.id, unless: messages) {
      messages.append(bubble)
    }
    return BolttyAISessionPreview(
      id: conversation.id,
      title: conversation.title,
      agent: AgentId(rawValue: conversation.providerID) ?? .custom,
      state: pending != nil && conversation.lastKnownState != .waiting ? .running : conversation.lastKnownState.reportedState,
      body: lastAgentText ?? store.subtitle(for: id),
      question: (transcript.openInteraction
        ?? (pending != nil || conversation.lastKnownState.blocksSending ? nil : transcript.lateQuestion))
        .flatMap { question(from: $0, in: id) },
      messages: messages,
      canStop: pending != nil
        || (conversation.remoteSessionID != nil && capabilities.canEndTurn),
      stopIsAbrupt: capabilities.endingTurnIsAbrupt,
      canSteer: pending == nil && engine.canSteer(id),
      autoMode: capabilities.contains(.autoApproval) ? conversation.autoApprove : nil,
      modelChip: modelChip(for: conversation),
      notice: engine.notices[id]?.text,
      handOverNote: handOvers[id]?.sentence,
      retryPrompt: failedPanelPrompts[id]
        ?? (pending == nil && !conversation.draft.isEmpty ? conversation.draft : nil)
        ?? requestToRetryOnAnotherModel(in: id),
      queuedPrompt: queuedPanelPrompts[id]
    )
  }

  @discardableResult
  func answer(_ question: AgentQuestion, with values: [String]) async throws -> Bool {
    guard let conversationID = store.conversations
      .first(where: { conversation in
        store.transcript(id: conversation.id)
          .interactions.contains { $0.id == question.requestID }
      })?.id
    else { return false }

    switch question.kind {
    case .question:
      let transcript = store.transcript(id: conversationID)
      guard let interaction = transcript.openInteraction ?? transcript.lateQuestion,
            interaction.id == question.requestID,
            case let .question(prompt) = interaction.kind,
            self.question(from: interaction, in: conversationID) == question else { return false }
      var answers = questionAnswers[conversationID]?[question.requestID] ?? []
      answers.append(values)
      if answers.count < prompt.items.count {
        questionAnswers[conversationID, default: [:]][question.requestID] = answers
        store.objectWillChange.send()
        return true
      }
      if interaction.isLate {
        return deliverLateAnswer(answers, to: prompt, interactionID: question.requestID, in: conversationID)
      }
      let delivered = await engine.answer(
        interactionID: question.requestID,
        in: conversationID,
        answers: answers
      )
      // The ask was gone when the answer reached it: the answer is not.
      if !delivered,
         store.transcript(id: conversationID).interactions
           .first(where: { $0.id == question.requestID })?.isLate == true {
        return deliverLateAnswer(answers, to: prompt, interactionID: question.requestID, in: conversationID)
      }
      if store.transcript(id: conversationID).openInteraction?.id != question.requestID {
        questionAnswers[conversationID]?[question.requestID] = nil
      }
      return delivered
    case .permission:
      guard let decision = values.first.flatMap(PermissionDecision.init(rawValue:)) else { return false }
      let words = values.dropFirst().first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if decision == .reject, !words.isEmpty {
        return await refuse(permissionID: question.requestID, in: conversationID, saying: words)
      }
      return await engine.reply(
        permissionID: question.requestID,
        in: conversationID,
        decision: decision
      )
    case .plan:
      guard let decision = values.first.flatMap(PlanDecision.init(rawValue:)) else { return false }
      return await engine.reply(
        planID: question.requestID,
        in: conversationID,
        decision: decision,
        feedback: decision == .cancelled ? values.dropFirst().first : nil
      )
    }
  }

  private static func planBubble(
    _ plan: PlanPrompt,
    id: String,
    unless messages: [ConversationMessage]
  ) -> ConversationMessage? {
    let markdown = plan.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !markdown.isEmpty else { return nil }
    let written = messages.contains { message in
      message.parts.contains { part in
        guard case let .text(text) = part else { return false }
        return text.text.trimmingCharacters(in: .whitespacesAndNewlines) == markdown
      }
    }
    guard !written else { return nil }
    return ConversationMessage(
      id: "plan-\(id)", role: .agent, createdAt: Date(),
      parts: [.text(TextPart(id: "plan-\(id)-text", kind: .text, text: plan.markdown))]
    )
  }

  private func question(from interaction: PendingInteraction, in conversationID: UUID) -> AgentQuestion? {
    guard interaction.isOpen || interaction.isLate else { return nil }

    switch interaction.kind {
    case let .question(prompt):
      let index = questionAnswers[conversationID]?[interaction.id]?.count ?? 0
      guard prompt.items.indices.contains(index) else { return nil }
      let item = prompt.items[index]
      return AgentQuestion(
        kind: .question,
        requestID: interaction.id,
        header: prompt.items.count > 1 ? "\(index + 1)/\(prompt.items.count) · \(item.header)" : item.header,
        prompt: item.question,
        options: item.choices.map {
          AgentQuestion.Option(label: $0.label, detail: $0.detail, value: $0.value)
        },
        allowsMultiple: item.allowsMultiple,
        allowsCustom: item.allowsCustom,
        isLate: interaction.isLate
      )

    case let .permission(prompt):
      return AgentQuestion(
        kind: .permission,
        requestID: interaction.id,
        header: "Permission",
        prompt: PermissionSentence.sentence(
          action: prompt.action,
          resources: prompt.resources
        ),
        detail: PermissionSentence.detail(
          action: prompt.action,
          resources: prompt.resources
        ),
        options: [
          AgentQuestion.Option(
            label: "Allow Once",
            detail: nil,
            value: PermissionDecision.once.rawValue
          ),
          AgentQuestion.Option(
            label: "Always Allow",
            detail: AgentQuestion.alwaysAllowScope(savePatterns: prompt.savePatterns),
            value: PermissionDecision.always.rawValue
          ),
          AgentQuestion.Option(
            label: "Deny",
            detail: nil,
            value: PermissionDecision.reject.rawValue
          )
        ],
        allowsMultiple: false,
        allowsCustom: false
      )

    case let .plan(plan):
      let empty = plan.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      return AgentQuestion(
        kind: .plan,
        requestID: interaction.id,
        header: plan.title,
        prompt: empty ? PlanPrompt.emptyText : "",
        options: [
          AgentQuestion.Option(label: "Approve", detail: nil, value: PlanDecision.approved.rawValue),
          AgentQuestion.Option(
            label: "Request Changes", detail: nil, value: PlanDecision.cancelled.rawValue),
          AgentQuestion.Option(label: "Quit", detail: nil, value: PlanDecision.abandoned.rawValue),
        ],
        allowsMultiple: false,
        allowsCustom: false,
        copyText: empty ? nil : plan.markdown
      )
    }
  }
}

@MainActor
private enum LiftedRequests {
  private typealias Request = (sent: ConversationMessage, lifted: ConversationMessage)

  private static var slot: (conversation: UUID, files: [SentFile], requests: [String: Request])?

  static func lift(
    _ messages: [ConversationMessage],
    files: [SentFile],
    in conversation: UUID
  ) -> [ConversationMessage] {
    guard !files.isEmpty else {
      slot = nil
      return messages
    }
    var known: [String: Request] = [:]
    if let last = slot, last.conversation == conversation, last.files == files {
      known = last.requests
    }
    var kept: [String: Request] = [:]
    let lifted = messages.map { message -> ConversationMessage in
      guard message.role == .user else { return message }
      if let request = known[message.id], request.sent == message {
        kept[message.id] = request
        return request.lifted
      }
      let request: Request = (sent: message, lifted: SentFile.lift(message, files: files))
      kept[message.id] = request
      return request.lifted
    }
    slot = (conversation: conversation, files: files, requests: kept)
    return lifted
  }
}
