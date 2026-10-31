import Combine
import Foundation

@MainActor
final class ConversationStore: ObservableObject {
  @Published private(set) var conversations: [Conversation] = []
  @Published private(set) var transcripts: [UUID: ConversationTranscript] = [:]
  @Published var selectedConversationID: UUID?
  @Published private(set) var damagedConversationIDs: Set<UUID> = []

  private let persistence: ConversationPersistence
  private let clock: () -> Date

  private var seenEventIDs: [String] = []
  private var seenEventIDSet: Set<String> = []
  private static let seenEventLimit = 4096

  private var appliedSequence: [String: Int] = [:]

  private var pendingSaves: Set<UUID> = []
  private var saveTimer: Timer?
  private static let saveDebounce: TimeInterval = 0.75

  init(
    persistence: ConversationPersistence = ConversationPersistence(),
    clock: @escaping () -> Date = Date.init
  ) {
    self.persistence = persistence
    self.clock = clock
    let loaded = persistence.load()
    conversations = loaded.conversations
    transcripts = loaded.transcripts
    selectedConversationID = loaded.selectedConversationID
    damagedConversationIDs = Set(loaded.damaged)
    // Waiting is mid-turn too: the process that asked is gone, so its card
    // can no longer be answered and must not hold the chat.
    for index in conversations.indices where conversations[index].lastKnownState.blocksSending {
      conversations[index].lastKnownState = .interrupted
      let id = conversations[index].id
      guard var transcript = transcripts[id] else { continue }
      for asked in transcript.interactions.indices where transcript.interactions[asked].isOpen {
        transcript.interactions[asked].resolution = .expired
        transcript.interactions[asked].isSubmitting = false
      }
      transcripts[id] = transcript
    }
  }

  // MARK: - Reading

  func conversation(id: UUID) -> Conversation? {
    conversations.first { $0.id == id }
  }

  func conversation(remoteSessionID: String, providerID: String? = nil) -> Conversation? {
    conversations.first {
      $0.remoteSessionID == remoteSessionID
        && (providerID == nil || $0.providerID == providerID)
    }
  }

  func transcript(id: UUID) -> ConversationTranscript {
    transcripts[id] ?? ConversationTranscript()
  }

  var selectedConversation: Conversation? {
    selectedConversationID.flatMap(conversation(id:))
  }

  var orderedConversations: [Conversation] {
    conversations.sorted { $0.updatedAt > $1.updatedAt }
  }

  func conversations(matching query: String) -> [Conversation] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return orderedConversations }
    return orderedConversations.filter { conversation in
      if conversation.title.range(of: needle, options: [.caseInsensitive]) != nil { return true }
      return transcript(id: conversation.id).messages.reversed().contains {
        $0.containsText(needle)
      }
    }
  }

  func subtitle(for id: UUID) -> String {
    guard let conversation = conversation(id: id) else { return "" }
    return BolttyAISessionList.subtitle(
      for: conversation,
      transcript: transcript(id: id),
      damaged: damagedConversationIDs.contains(id)
    )
  }

  // MARK: - Conversation lifecycle

  @discardableResult
  func createConversation(
    id: UUID = UUID(),
    title: String = "New conversation",
    workingDirectory: String,
    providerID: String = AgentId.opencode.rawValue,
    model: ModelSelection? = nil,
    reasoningEffort: String? = nil,
    autoApprove: Bool = false,
    readOnly: Bool = false,
    isAskBoltty: Bool = false
  ) -> Conversation {
    if let existing = conversation(id: id) { return existing }
    var conversation = Conversation(
      id: id,
      providerID: providerID,
      title: title,
      workingDirectory: workingDirectory,
      model: model,
      reasoningEffort: reasoningEffort,
      autoApprove: autoApprove,
      createdAt: clock(),
      updatedAt: clock()
    )
    conversation.readOnly = readOnly
    conversation.isAskBoltty = isAskBoltty
    conversations.append(conversation)
    transcripts[conversation.id] = ConversationTranscript()
    saveIndexNow()
    return conversation
  }

  func defaultWorkingDirectory() -> String {
    WorkingDirectoryResolver.homeDirectoryPath
  }

  func setWorkingDirectory(_ path: String, for id: UUID) {
    guard let index = conversations.firstIndex(where: { $0.id == id }),
          conversations[index].canChangeWorkingDirectory
    else { return }
    guard conversations[index].workingDirectory != path else { return }
    conversations[index].workingDirectory = path
    conversations[index].updatedAt = clock()
    saveIndexNow()
    objectWillChange.send()
  }

  func deleteConversation(id: UUID) {
    conversations.removeAll { $0.id == id }
    transcripts[id] = nil
    damagedConversationIDs.remove(id)
    if selectedConversationID == id {
      selectedConversationID = orderedConversations.first?.id
    }
    persistence.deleteConversation(id)
    saveIndexNow()
  }

  func trashConversation(id: UUID) {
    guard let conversation = conversations.first(where: { $0.id == id }) else { return }
    flushPendingSaves()
    conversations.removeAll { $0.id == id }
    transcripts[id] = nil
    damagedConversationIDs.remove(id)
    if selectedConversationID == id {
      selectedConversationID = orderedConversations.first?.id
    }
    let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
    persistence.trashConversations(
      [conversation],
      named: "Boltty Chat – \(title.isEmpty ? "Untitled" : String(title.prefix(60)))"
    )
    saveIndexNow()
  }

  func folder(of id: UUID) -> URL? {
    persistence.existingDirectory(of: id)
  }

  @discardableResult
  func deleteAllConversations() -> Int {
    let cleared = conversations
    guard !cleared.isEmpty else { return 0 }
    flushPendingSaves()
    conversations.removeAll()
    transcripts.removeAll()
    damagedConversationIDs.removeAll()
    selectedConversationID = nil
    persistence.trashConversations(cleared)
    saveIndexNow()
    return cleared.count
  }

  func rename(id: UUID, to title: String) {
    update(id) { $0.title = title }
  }

  func setModel(_ model: ModelSelection?, for id: UUID) {
    update(id) {
      $0.model = model
      $0.reasoningEffort = nil
    }
  }

  func setReasoningEffort(_ effort: String?, for id: UUID) {
    update(id) { $0.reasoningEffort = effort }
  }

  func setAutoApprove(_ enabled: Bool, for id: UUID) {
    update(id) { $0.autoApprove = enabled }
  }

  func setReadOnly(_ readOnly: Bool, for id: UUID) {
    update(id) { $0.readOnly = readOnly }
  }

  func setProvider(_ providerID: String, for id: UUID) {
    guard let conversation = conversation(id: id), conversation.remoteSessionID == nil else {
      return
    }
    guard conversation.providerID != providerID else { return }
    update(id) {
      $0.providerID = providerID
      $0.model = nil
    }
  }

  func setPanelDraft(_ draft: PromptDraft, for id: UUID) {
    guard conversation(id: id)?.panelDraft != draft else { return }
    let oldAttachments = conversation(id: id)?.panelDraft?.attachments ?? []
    var durable = draft
    durable.elements = draft.elements.map { element in
      guard case var .attachment(attachment) = element,
            case let .file(source) = attachment.payload else { return element }
      if let old = oldAttachments.first(where: { $0.id == attachment.id }),
         case let .file(saved) = old.payload, FileManager.default.fileExists(atPath: saved.path) {
        attachment.payload = .file(saved)
      } else if let copy = try? persistence.importAttachment(from: source, into: id) {
        attachment.payload = .file(copy)
      }
      return .attachment(attachment)
    }
    updateWithoutTouching(id) { $0.panelDraft = durable }
    scheduleIndexSave()
  }

  nonisolated static func attachedName(of url: URL, in conversationID: UUID) -> String {
    let name = url.lastPathComponent
    let folder = url.deletingLastPathComponent()
    guard folder.lastPathComponent == "attachments",
          folder.deletingLastPathComponent().lastPathComponent == conversationID.uuidString
    else { return name }
    let prefix = name.prefix(9)
    guard name.count > 9, prefix.last == "-",
          prefix.dropLast().allSatisfy({ $0.isHexDigit && !$0.isLowercase })
    else { return name }
    return String(name.dropFirst(9))
  }

  func recordSentFiles(_ files: [SentFile], for id: UUID) {
    guard let known = conversation(id: id)?.sentFiles else { return }
    let new = files.filter { file in !known.contains { $0.path == file.path } }
    guard !new.isEmpty else { return }
    updateWithoutTouching(id) { $0.sentFiles += new }
    saveIndexNow()
  }

  func setDraft(_ text: String, for id: UUID) {
    guard conversation(id: id)?.draft != text else { return }
    updateWithoutTouching(id) { $0.draft = text }
    scheduleIndexSave()
  }

  func addDraftAttachment(_ attachment: ConversationAttachment, to id: UUID) {
    guard conversation(id: id) != nil else { return }
    updateWithoutTouching(id) { $0.draftAttachments.append(attachment) }
    saveIndexNow()
  }

  func markRead(_ id: UUID) {
    guard conversation(id: id)?.hasUnread == true else { return }
    updateWithoutTouching(id) { $0.hasUnread = false }
    saveIndexNow()
  }

  func select(_ id: UUID?) {
    selectedConversationID = id
    if let id { markRead(id) }
    saveIndexNow()
  }

  func attachRemoteSession(_ remoteID: String, to id: UUID, model: ModelSelection?) {
    update(id) {
      $0.remoteSessionID = remoteID
      if let model { $0.model = model }
    }
  }

  func setExecutionState(_ state: ConversationExecutionState, for id: UUID) {
    guard conversation(id: id)?.lastKnownState != state else { return }
    update(id) { $0.lastKnownState = state }
  }

  // MARK: - Messages

  func appendUserMessage(
    id messageID: String,
    text: String,
    attachments: [ConversationAttachment],
    to conversationID: UUID
  ) {
    var message = ConversationMessage(
      id: messageID,
      role: .user,
      createdAt: clock(),
      completedAt: clock()
    )
    if !text.isEmpty {
      message.parts.append(.text(TextPart(id: "\(messageID)-text", kind: .text, text: text)))
    }
    message.parts.append(contentsOf: attachments.map { ConversationPart.attachment($0) })
    upsert(message, in: conversationID)
    let sent = Set(attachments.map(\.id))
    update(conversationID) {
      $0.draft = ""
      $0.draftAttachments.removeAll { sent.contains($0.id) }
    }
    saveTranscriptNow(conversationID)
  }

  func revertUserMessage(
    id messageID: String,
    restoringDraft text: String,
    attachments: [ConversationAttachment],
    in conversationID: UUID
  ) {
    var transcript = transcript(id: conversationID)
    transcript.messages.removeAll { $0.id == messageID }
    transcripts[conversationID] = transcript
    update(conversationID) { conversation in
      conversation.draft = conversation.draft.isEmpty ? text : text + "\n" + conversation.draft
      let staged = Set(conversation.draftAttachments.map(\.id))
      conversation.draftAttachments.insert(
        contentsOf: attachments.filter { !staged.contains($0.id) }, at: 0
      )
    }
    saveTranscriptNow(conversationID)
  }

  func upsert(_ message: ConversationMessage, in conversationID: UUID) {
    var transcript = transcript(id: conversationID)
    if let index = transcript.messages.firstIndex(where: { $0.id == message.id }) {
      var merged = message
      if merged.parts.isEmpty { merged.parts = transcript.messages[index].parts }
      transcript.messages[index] = merged
    } else {
      transcript.messages.append(message)
      transcript.messages.sort { $0.createdAt < $1.createdAt }
    }
    transcripts[conversationID] = transcript
    touch(conversationID)
  }

  func replaceMessages(
    _ messages: [ConversationMessage],
    in conversationID: UUID,
    openInteractions: [PendingInteraction]
  ) {
    var transcript = transcript(id: conversationID)
    var byID = Dictionary(uniqueKeysWithValues: transcript.messages.map { ($0.id, $0) })
    var merged: [ConversationMessage] = []
    for message in messages {
      if var existing = byID.removeValue(forKey: message.id) {
        existing.role = message.role
        existing.completedAt = message.completedAt
        existing.failure = message.failure
        if !message.parts.isEmpty { existing.parts = message.parts }
        merged.append(existing)
      } else {
        merged.append(message)
      }
    }
    let straggling = byID.values.filter { $0.completedAt == nil }
    merged.append(contentsOf: straggling)
    merged.sort { $0.createdAt < $1.createdAt }
    transcript.messages = merged

    let openIDs = Set(openInteractions.map(\.id))
    for index in transcript.interactions.indices where transcript.interactions[index].isOpen {
      if !openIDs.contains(transcript.interactions[index].id) {
        transcript.interactions[index].resolution = .resolvedElsewhere
        transcript.interactions[index].isSubmitting = false
      }
    }
    for interaction in openInteractions
    where !transcript.interactions.contains(where: { $0.id == interaction.id }) {
      transcript.interactions.append(interaction)
    }
    transcripts[conversationID] = transcript
    damagedConversationIDs.remove(conversationID)
    saveTranscriptNow(conversationID)
  }

  // MARK: - Interactions

  func recordInteraction(_ interaction: PendingInteraction) {
    var transcript = transcript(id: interaction.conversationID)
    if let index = transcript.interactions.firstIndex(where: { $0.id == interaction.id }) {
      guard transcript.interactions[index].isOpen else { return }
      transcript.interactions[index].kind = interaction.kind
    } else {
      transcript.interactions.append(interaction)
    }
    transcripts[interaction.conversationID] = transcript
    setExecutionState(.waiting, for: interaction.conversationID)
    flagUnread(interaction.conversationID)
    saveTranscriptNow(interaction.conversationID)
  }

  func beginSubmitting(interactionID: String, in conversationID: UUID) -> Bool {
    var transcript = transcript(id: conversationID)
    guard let index = transcript.interactions.firstIndex(where: { $0.id == interactionID }),
          transcript.interactions[index].acceptsInput
    else { return false }
    transcript.interactions[index].isSubmitting = true
    transcripts[conversationID] = transcript
    return true
  }

  func resolveInteraction(
    id interactionID: String,
    in conversationID: UUID,
    with resolution: PendingInteraction.Resolution
  ) {
    var transcript = transcript(id: conversationID)
    guard let index = transcript.interactions.firstIndex(where: { $0.id == interactionID }) else {
      return
    }
    transcript.interactions[index].isSubmitting = false
    if transcript.interactions[index].resolution == nil {
      transcript.interactions[index].resolution = resolution
    }
    transcripts[conversationID] = transcript
    if transcript.openInteraction == nil,
       conversation(id: conversationID)?.lastKnownState == .waiting {
      setExecutionState(.working, for: conversationID)
    }
    saveTranscriptNow(conversationID)
  }

  func expireInteraction(id interactionID: String, in conversationID: UUID) {
    var transcript = transcript(id: conversationID)
    guard let index = transcript.interactions.firstIndex(where: { $0.id == interactionID }),
          transcript.interactions[index].isOpen
    else { return }
    transcript.interactions[index].isSubmitting = false
    transcript.interactions[index].resolution = .expired
    transcripts[conversationID] = transcript
    saveTranscriptNow(conversationID)
  }

  func cancelSubmitting(interactionID: String, in conversationID: UUID) {
    var transcript = transcript(id: conversationID)
    guard let index = transcript.interactions.firstIndex(where: { $0.id == interactionID }) else {
      return
    }
    transcript.interactions[index].isSubmitting = false
    transcripts[conversationID] = transcript
  }

  // MARK: - Event application

  @discardableResult
  func apply(_ envelope: AgentEventEnvelope) -> Bool {
    if let id = envelope.id, seenEventIDSet.contains(id) { return false }

    if case let .connection(state) = envelope.event {
      remember(envelope.id)
      connectionStates[envelope.providerID ?? ""] = state
      return true
    }

    guard let remoteID = envelope.event.sessionID else { return false }
    let watermarkKey = "\(envelope.providerID ?? "")/\(remoteID)"

    if let sequence = envelope.sequence,
       let applied = appliedSequence[watermarkKey],
       sequence <= applied {
      return false
    }

    guard let conversation = conversation(
      remoteSessionID: remoteID,
      providerID: envelope.providerID
    ) else { return false }

    remember(envelope.id)
    if let sequence = envelope.sequence {
      appliedSequence[watermarkKey] = max(appliedSequence[watermarkKey] ?? Int.min, sequence)
    }

    let id = conversation.id
    switch envelope.event {
    case .connection:
      break

    case let .messageUpdated(_, message):
      upsert(message, in: id)
      if message.role == .agent, message.completedAt != nil {
        flagUnread(id)
      }

    case let .messageRemoved(_, messageID):
      var transcript = transcript(id: id)
      transcript.messages.removeAll { $0.id == messageID }
      transcripts[id] = transcript
      touch(id)

    case let .partUpdated(_, messageID, part):
      mutateMessage(messageID, in: id) { $0.upsert(part) }

    case let .partDelta(_, messageID, partID, kind, delta):
      mutateMessage(messageID, in: id) { $0.appendDelta(delta, toPart: partID, kind: kind) }

    case let .partRemoved(_, messageID, partID):
      mutateMessage(messageID, in: id) { $0.removePart(id: partID) }

    case let .executionStateChanged(_, state):
      setExecutionState(state, for: id)
      if state == .idle || state == .rateLimited {
        finishReplyInProgress(in: id)
        flagUnread(id)
      }

    case let .sessionFailed(_, failure):
      setExecutionState(
        failure.isAbort ? .idle : failure.rateLimit != nil ? .rateLimited : .failed, for: id)
      if var last = transcript(id: id).messages.last, last.role == .agent {
        last.failure = failure
        last.completedAt = last.completedAt ?? clock()
        upsert(last, in: id)
      }
      saveTranscriptNow(id)

    case let .interactionAsked(interaction):
      recordInteraction(interaction)

    case let .interactionResolved(_, requestID, resolution):
      resolveInteraction(id: requestID, in: id, with: resolution)

    case .fileChanged:
      touch(id)

    case .sessionDeleted:
      var transcript = transcript(id: id)
      for index in transcript.interactions.indices where transcript.interactions[index].isOpen {
        transcript.interactions[index].resolution = .expired
        transcript.interactions[index].isSubmitting = false
      }
      transcripts[id] = transcript
      setExecutionState(.idle, for: id)
      update(id) { $0.remoteSessionID = nil }
      saveTranscriptNow(id)
    }
    scheduleTranscriptSave(id)
    return true
  }

  @Published private(set) var connectionStates: [String: AgentConnectionState] = [:]

  func connectionState(forProviderID providerID: String) -> AgentConnectionState {
    connectionStates[providerID] ?? .offline
  }

  private func mutateMessage(
    _ messageID: String,
    in conversationID: UUID,
    _ body: (inout ConversationMessage) -> Void
  ) {
    var transcript = transcript(id: conversationID)
    if let index = transcript.messages.firstIndex(where: { $0.id == messageID }) {
      body(&transcript.messages[index])
    } else {
      var message = ConversationMessage(id: messageID, role: .agent, createdAt: clock())
      body(&message)
      transcript.messages.append(message)
      transcript.messages.sort { $0.createdAt < $1.createdAt }
    }
    transcripts[conversationID] = transcript
    touch(conversationID)
  }

  private func remember(_ eventID: String?) {
    guard let eventID else { return }
    seenEventIDs.append(eventID)
    seenEventIDSet.insert(eventID)
    if seenEventIDs.count > Self.seenEventLimit {
      let excess = seenEventIDs.count - Self.seenEventLimit
      for id in seenEventIDs.prefix(excess) { seenEventIDSet.remove(id) }
      seenEventIDs.removeFirst(excess)
    }
  }

  // MARK: - Mutation helpers

  private func update(_ id: UUID, _ body: (inout Conversation) -> Void) {
    guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
    body(&conversations[index])
    conversations[index].updatedAt = clock()
    saveIndexNow()
  }

  private func updateWithoutTouching(_ id: UUID, _ body: (inout Conversation) -> Void) {
    guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
    body(&conversations[index])
  }

  private func touch(_ id: UUID) {
    updateWithoutTouching(id) { $0.updatedAt = clock() }
    scheduleIndexSave()
  }

  private func finishReplyInProgress(in id: UUID) {
    guard var last = transcript(id: id).messages.last,
          last.role == .agent, last.completedAt == nil
    else { return }
    last.completedAt = clock()
    upsert(last, in: id)
  }

  private func flagUnread(_ id: UUID) {
    guard selectedConversationID != id, conversation(id: id)?.isAskBoltty != true else { return }
    updateWithoutTouching(id) { $0.hasUnread = true }
    scheduleIndexSave()
  }

  // MARK: - Persistence scheduling

  private var indexSavePending = false

  private func saveIndexNow() {
    indexSavePending = false
    persistence.saveIndex(conversations, selected: selectedConversationID)
  }

  private func saveTranscriptNow(_ id: UUID) {
    pendingSaves.remove(id)
    persistence.saveTranscript(transcript(id: id), for: id)
  }

  private func scheduleIndexSave() {
    indexSavePending = true
    scheduleFlush()
  }

  private func scheduleTranscriptSave(_ id: UUID) {
    pendingSaves.insert(id)
    scheduleFlush()
  }

  private func scheduleFlush() {
    guard saveTimer == nil else { return }
    saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDebounce, repeats: false) {
      [weak self] _ in
      Task { @MainActor in self?.flushPendingSaves() }
    }
  }

  private func flushPendingSaves() {
    saveTimer?.invalidate()
    saveTimer = nil
    for id in pendingSaves where conversation(id: id) != nil {
      persistence.saveTranscript(transcript(id: id), for: id)
    }
    pendingSaves.removeAll()
    if indexSavePending { saveIndexNow() }
  }

  var isReadOnly: Bool { !persistence.isPrimary }

  func close() {
    flush()
    persistence.relinquish()
  }

  func flush() {
    flushPendingSaves()
    saveIndexNow()
    persistence.flush()
  }

  @discardableResult
  func importAttachment(from url: URL, into conversationID: UUID) -> ConversationAttachment? {
    guard let copied = try? persistence.importAttachment(from: url, into: conversationID) else {
      return nil
    }
    let values = try? copied.resourceValues(forKeys: [.fileSizeKey])
    let attachment = ConversationAttachment(
      id: UUID().uuidString,
      displayName: url.lastPathComponent,
      url: copied,
      mimeType: MIMEType.guess(for: copied),
      byteCount: values?.fileSize,
      isAnalysable: MIMEType.isAnalysable(copied)
    )
    addDraftAttachment(attachment, to: conversationID)
    return attachment
  }
}

enum MIMEType {
  static func guess(for url: URL) -> String? {
    switch url.pathExtension.lowercased() {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "pdf": return "application/pdf"
    case "txt", "md", "markdown": return "text/plain"
    case "json": return "application/json"
    case "swift", "py", "js", "ts", "rs", "go", "c", "h", "cpp", "sh":
      return "text/plain"
    default: return nil
    }
  }

  private static let analysable: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "pdf", "txt", "md", "markdown", "json",
    "swift", "py", "js", "ts", "rs", "go", "c", "h", "cpp", "sh", "yml", "yaml",
    "html", "css", "toml", "csv"
  ]

  static func isAnalysable(_ url: URL) -> Bool {
    analysable.contains(url.pathExtension.lowercased())
  }
}
