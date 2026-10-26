import Combine
import XCTest
@testable import Boltty

@MainActor
final class FakeBolttyAIConversations: BolttyAIConversations {
  private(set) var startedPrompts: [String] = []
  private(set) var startedIdentities: [(id: UUID, providerID: String)] = []
  private(set) var followUps: [(prompt: String, id: UUID)] = []
  private(set) var answered: [(question: AgentQuestion, values: [String])] = []
  private(set) var observed: Set<UUID> = []
  private(set) var startedDirectories: [String] = []
  private(set) var directoryChanges: [(id: UUID, path: String)] = []
  var inheritedDirectory = "/tmp"
  var agentsIgnoringWorkingDirectory: Set<String> = []
  var plannedProvider: String? = AgentId.opencode.rawValue
  private(set) var queued: [UUID: String] = [:]

  var rows: [BolttyAISessionItem] = []
  var conversationsByID: [UUID: Conversation] = [:]
  var previews: [UUID: BolttyAISessionPreview] = [:]
  var canStart = true
  var providerAvailability: AgentAvailability? = .available(version: "test")
  var followUpResult = true

  private let changes = PassthroughSubject<Void, Never>()

  var conversationsChanged: AnyPublisher<Void, Never> {
    changes.eraseToAnyPublisher()
  }

  func saveDraft(_ draft: PromptDraft, for id: UUID) { conversationsByID[id]?.panelDraft = draft }
  func stopConversation(id: UUID) async {}

  private(set) var switcherReads = 0
  func switcherItems() -> [BolttyAISessionItem] {
    switcherReads += 1
    return rows
  }

  func notifyChanged() { changes.send() }

  func conversation(id: UUID) -> Conversation? { conversationsByID[id] }

  var finderLocations: [UUID: URL] = [:]
  var deletableChats: Set<UUID> = []
  func finderLocation(forRow id: UUID) -> URL? { finderLocations[id] }
  func canDeleteChat(_ id: UUID) -> Bool { deletableChats.contains(id) }

  var launchable: [String] = []
  func launchableProviderIDs() -> [String] { launchable }

  private(set) var startedPictures: [[ConversationAttachment]] = []
  func startConversation(
    prompt: String, id: UUID, workingDirectory: String, providerID requested: String?,
    pictures: [ConversationAttachment]
  ) -> UUID? {
    guard canStart else { return nil }
    let providerID = requested ?? AgentId.opencode.rawValue
    startedPrompts.append(prompt)
    startedPictures.append(pictures)
    startedIdentities.append((id, providerID))
    startedDirectories.append(workingDirectory)
    let conversation = Conversation(
      id: id,
      providerID: providerID,
      title: prompt,
      workingDirectory: workingDirectory
    )
    conversationsByID[conversation.id] = conversation
    previews[id] = BolttyAISessionPreview(id: id, title: prompt, agent: AgentId(rawValue: providerID) ?? .opencode, state: .running, body: "", messages: [ConversationMessage(id: "user", role: .user, createdAt: Date(), parts: [.text(TextPart(id: "text", kind: .text, text: prompt))])])
    return conversation.id
  }

  private(set) var sentFiles: [UUID: [SentFile]] = [:]
  func recordSentFiles(_ files: [SentFile], in id: UUID) {
    sentFiles[id, default: []] += files
  }

  private(set) var followUpPictures: [[ConversationAttachment]] = []
  func sendFollowUp(_ prompt: String, pictures: [ConversationAttachment], to id: UUID) -> Bool {
    followUps.append((prompt, id))
    followUpPictures.append(pictures)
    return followUpResult
  }

  @discardableResult
  func queueFollowUp(_ prompt: String, to id: UUID) -> BolttyAIFollowUp.QueuedSend {
    let outcome: BolttyAIFollowUp.QueuedSend = queued[id] == nil ? .queued : .replaced
    queued[id] = prompt
    previews[id]?.queuedPrompt = prompt
    changes.send()
    return outcome
  }

  @discardableResult
  func cancelQueuedFollowUp(for id: UUID) -> String? {
    guard let prompt = queued.removeValue(forKey: id) else { return nil }
    previews[id]?.queuedPrompt = nil
    changes.send()
    return prompt
  }

  private(set) var autoApproveChanges: [(id: UUID, enabled: Bool)] = []
  func setAutoApprove(_ enabled: Bool, for id: UUID) {
    autoApproveChanges.append((id, enabled))
    conversationsByID[id]?.autoApprove = enabled
    previews[id]?.autoMode = enabled
    changes.send()
  }

  func defaultWorkingDirectory() -> String { inheritedDirectory }
  var recentFolders: [String] = []
  func recentWorkingDirectories() -> [String] { recentFolders }

  func setWorkingDirectory(_ path: String, for id: UUID) {
    directoryChanges.append((id, path))
    guard conversationsByID[id]?.canChangeWorkingDirectory == true else { return }
    conversationsByID[id]?.workingDirectory = path
  }

  func honoursWorkingDirectory(providerID: String) -> Bool {
    !agentsIgnoringWorkingDirectory.contains(providerID)
  }

  var agentsAcceptingAttachments: Set<String> = [AgentId.opencode.rawValue]
  func acceptsAttachments(providerID: String) -> Bool {
    agentsAcceptingAttachments.contains(providerID)
  }

  func plannedProviderID() -> String? { plannedProvider }

  var fallback: AgentRoutingFallback?
  func routingFallback() -> AgentRoutingFallback? { fallback }

  func preview(for id: UUID) -> BolttyAISessionPreview? { previews[id] }

  func observePreview(of id: UUID, _ handler: (@Sendable () -> Void)?) {
    if handler == nil { observed.remove(id) } else { observed.insert(id) }
  }

  var answerDelivers = true

  @discardableResult
  func answer(_ question: AgentQuestion, with values: [String]) async throws -> Bool {
    answered.append((question, values))
    return answerDelivers
  }

  private(set) var addressed: UUID?
  private(set) var addressedHistory: [UUID?] = []

  func setAddressedConversation(_ id: UUID?) {
    addressed = id
    addressedHistory.append(id)
  }

  @discardableResult
  func addConversation(
    title: String,
    state: ConversationExecutionState = .idle,
    isCurrent: Bool = false
  ) -> Conversation {
    let conversation = Conversation(
      title: title,
      workingDirectory: "/tmp",
      lastKnownState: state
    )
    conversationsByID[conversation.id] = conversation
    rows.append(
      BolttyAISessionItem(
        id: conversation.id,
        title: title,
        subtitle: AgentId.opencode.displayName,
        agent: .opencode,
        isCurrent: isCurrent,
        updatedAt: conversation.updatedAt
      )
    )
    changes.send()
    return conversation
  }
}

extension BolttyAISessionItem {
  nonisolated(unsafe) private static var lastRowStamp = Date()

  private static func nextRowStamp() -> Date {
    lastRowStamp = lastRowStamp.addingTimeInterval(-60)
    return lastRowStamp
  }

  static func row(
    _ title: String,
    _ agent: AgentId = .opencode,
    id: UUID = UUID(),
    updatedAt: Date? = nil
  ) -> BolttyAISessionItem {
    BolttyAISessionItem(
      id: id,
      title: title,
      subtitle: agent.displayName,
      agent: agent,
      isCurrent: false,
      updatedAt: updatedAt ?? nextRowStamp()
    )
  }
}

extension AgentPaletteView {
  func setSessions(
    _ rows: [BolttyAISessionItem],
    activeSessionID: UUID?,
    transcripts: [UUID: ConversationTranscript] = [:]
  ) {
    setSessions(
      rows.map {
        BolttyAISessionItem(
          id: $0.id,
          title: $0.title,
          subtitle: $0.subtitle,
          agent: $0.agent,
          isCurrent: $0.id == activeSessionID,
          updatedAt: $0.updatedAt,
          state: $0.state
        )
      },
      transcripts: transcripts
    )
  }
}
