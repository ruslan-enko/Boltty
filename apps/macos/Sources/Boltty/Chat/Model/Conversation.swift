import Foundation

enum ConversationExecutionState: String, Codable, Equatable, Sendable {
  case idle
  case working
  case waiting
  case failed
  case interrupted
  case rateLimited

  var blocksSending: Bool {
    switch self {
    case .working, .waiting: return true
    case .idle, .failed, .interrupted, .rateLimited: return false
    }
  }
}

enum AgentConnectionState: Equatable, Sendable {
  case offline
  case starting
  case connected
  case reconnecting
  case failed(String)

}

struct Conversation: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var providerID: String
  var remoteSessionID: String?
  var title: String
  var workingDirectory: String
  var canChangeWorkingDirectory: Bool { remoteSessionID == nil }
  var model: ModelSelection?
  var reasoningEffort: String?
  var autoApprove: Bool
  /// A chat that may look but not change anything (Ask Boltty's default): every
  /// permission it is asked is refused, and the CLIs that can be started
  /// without write tools are.
  var readOnly: Bool = false
  /// A chat Ask Boltty asked out loud: its answer is heard, so it raises no
  /// banner, no unread mark and no line beside the notch.
  var isAskBoltty: Bool = false
  var createdAt: Date
  var updatedAt: Date
  var draft: String
  var panelDraft: PromptDraft? = nil
  var draftAttachments: [ConversationAttachment]
  var sentFiles: [SentFile] = []
  var hasUnread: Bool
  var lastKnownState: ConversationExecutionState

  init(
    id: UUID = UUID(),
    providerID: String = OpenCodeProvider.identifier,
    remoteSessionID: String? = nil,
    title: String,
    workingDirectory: String,
    model: ModelSelection? = nil,
    reasoningEffort: String? = nil,
    autoApprove: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    draft: String = "",
    draftAttachments: [ConversationAttachment] = [],
    hasUnread: Bool = false,
    lastKnownState: ConversationExecutionState = .idle
  ) {
    self.id = id
    self.providerID = providerID
    self.remoteSessionID = remoteSessionID
    self.title = title
    self.workingDirectory = workingDirectory
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.autoApprove = autoApprove
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.draft = draft
    self.draftAttachments = draftAttachments
    self.hasUnread = hasUnread
    self.lastKnownState = lastKnownState
  }

  private enum CodingKeys: String, CodingKey {
    case id, providerID, remoteSessionID, title, workingDirectory, model
    case reasoningEffort, autoApprove, readOnly, createdAt, updatedAt, draft, draftAttachments
    case hasUnread, lastKnownState, panelDraft, sentFiles
    /// Written as "isTalk" before Talk was named Ask Boltty; chats on disk carry it.
    case isAskBoltty = "isTalk"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
      ?? OpenCodeProvider.identifier
    remoteSessionID = try container.decodeIfPresent(String.self, forKey: .remoteSessionID)
    title = try container.decode(String.self, forKey: .title)
    workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
    model = try container.decodeIfPresent(ModelSelection.self, forKey: .model)
    reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
    autoApprove = try container.decodeIfPresent(Bool.self, forKey: .autoApprove) ?? false
    readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    isAskBoltty = try container.decodeIfPresent(Bool.self, forKey: .isAskBoltty) ?? false
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    draft = try container.decodeIfPresent(String.self, forKey: .draft) ?? ""
    panelDraft = try container.decodeIfPresent(PromptDraft.self, forKey: .panelDraft)
    draftAttachments = try container.decodeIfPresent(
      [ConversationAttachment].self, forKey: .draftAttachments
    ) ?? []
    sentFiles = try container.decodeIfPresent([SentFile].self, forKey: .sentFiles) ?? []
    hasUnread = try container.decodeIfPresent(Bool.self, forKey: .hasUnread) ?? false
    lastKnownState = try container.decodeIfPresent(
      ConversationExecutionState.self, forKey: .lastKnownState
    ) ?? .idle
  }
}

struct ModelSelection: Codable, Equatable, Hashable, Sendable {
  let providerID: String
  let modelID: String
  var displayName: String

  init(providerID: String, modelID: String, displayName: String? = nil) {
    self.providerID = providerID
    self.modelID = modelID
    self.displayName = displayName ?? modelID
  }
}

enum OpenCodeProvider {
  static let identifier = "opencode"
}
