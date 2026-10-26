import Foundation
import os

final class ConversationPersistence {
  static let formatVersion = 1

  private let root: URL
  private let queue = DispatchQueue(label: "com.boltty.conversation-store", qos: .utility)
  private let log = Logger(subsystem: "com.boltty", category: "conversations")

  private(set) var isPrimary = true
  private var lockDescriptor: CInt = -1

  private let trash: @Sendable (URL) throws -> Void

  init(
    root: URL? = nil,
    claimingOwnership: Bool = true,
    trash: @escaping @Sendable (URL) throws -> Void = { item in
      try FileManager.default.trashItem(at: item, resultingItemURL: nil)
    }
  ) {
    self.trash = trash
    self.root = root ?? ConversationPersistence.defaultRoot()
    try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    if claimingOwnership {
      isPrimary = acquireLock()
      if !isPrimary {
        log.error("another Boltty owns the conversation store; this one is read-only")
      }
    }
  }

  deinit {
    if lockDescriptor >= 0 { close(lockDescriptor) }
  }

  func relinquish() {
    guard lockDescriptor >= 0 else { return }
    close(lockDescriptor)
    lockDescriptor = -1
    isPrimary = false
  }

  private func acquireLock() -> Bool {
    let path = root.appendingPathComponent("owner.lock").path
    let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
    guard descriptor >= 0 else { return true }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      return false
    }
    lockDescriptor = descriptor
    return true
  }

  static func defaultRoot() -> URL {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("Boltty/Conversations", isDirectory: true)
  }

  var directory: URL { root }

  private var indexURL: URL { root.appendingPathComponent("index.json") }

  private func conversationDirectory(_ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  func existingDirectory(of id: UUID) -> URL? {
    let directory = conversationDirectory(id)
    return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
  }

  func transcriptURL(_ id: UUID) -> URL {
    conversationDirectory(id).appendingPathComponent("transcript.json")
  }

  func attachmentsDirectory(_ id: UUID) -> URL {
    conversationDirectory(id).appendingPathComponent("attachments", isDirectory: true)
  }

  // MARK: - Envelopes

  private struct IndexFile: Codable {
    var version: Int
    var conversations: [Conversation]
    var selectedConversationID: UUID?
  }

  private struct TranscriptFile: Codable {
    var version: Int
    var conversationID: UUID
    var messages: [ConversationMessage]
    var interactions: [PendingInteraction]
  }

  struct LoadedState {
    var conversations: [Conversation] = []
    var selectedConversationID: UUID?
    var transcripts: [UUID: ConversationTranscript] = [:]
    var damaged: [UUID] = []
  }

  // MARK: - Reading

  func load() -> LoadedState {
    var state = LoadedState()
    guard let data = try? Data(contentsOf: indexURL) else { return state }
    guard let index = try? decoder.decode(IndexFile.self, from: data) else {
      log.error("conversation index unreadable; quarantining")
      quarantine(indexURL)
      return state
    }
    guard index.version <= Self.formatVersion else {
      log.error("conversation index written by a newer Boltty; ignoring")
      return state
    }
    var seen = Set<UUID>()
    state.conversations = index.conversations.filter { seen.insert($0.id).inserted }
    let dropped = index.conversations.count - state.conversations.count
    if dropped > 0 {
      log.error("conversation index listed \(dropped) duplicate id(s); keeping the first of each")
    }
    state.selectedConversationID = index.selectedConversationID
    for conversation in state.conversations {
      let url = transcriptURL(conversation.id)
      guard let data = try? Data(contentsOf: url) else {
        state.transcripts[conversation.id] = ConversationTranscript()
        continue
      }
      do {
        let file = try decoder.decode(TranscriptFile.self, from: data)
        state.transcripts[conversation.id] = ConversationTranscript(
          messages: file.messages,
          interactions: file.interactions
        )
      } catch {
        log.error("transcript for \(conversation.id.uuidString) unreadable; quarantining")
        quarantine(url)
        state.transcripts[conversation.id] = ConversationTranscript()
        state.damaged.append(conversation.id)
      }
    }
    return state
  }

  private func quarantine(_ url: URL) {
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let target = url.deletingPathExtension()
      .appendingPathExtension("damaged-\(stamp).json")
    try? FileManager.default.moveItem(at: url, to: target)
  }

  // MARK: - Writing

  func saveIndex(_ conversations: [Conversation], selected: UUID?) {
    guard isPrimary else { return }
    let file = IndexFile(
      version: Self.formatVersion,
      conversations: conversations,
      selectedConversationID: selected
    )
    write(file, to: indexURL)
  }

  func saveTranscript(_ transcript: ConversationTranscript, for id: UUID) {
    guard isPrimary else { return }
    let file = TranscriptFile(
      version: Self.formatVersion,
      conversationID: id,
      messages: transcript.messages,
      interactions: transcript.interactions
    )
    let directory = conversationDirectory(id)
    queue.async { [encoder] in
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      guard let data = try? encoder.encode(file) else { return }
      let url = directory.appendingPathComponent("transcript.json")
      try? data.write(to: url, options: .atomic)
    }
  }

  func deleteConversation(_ id: UUID) {
    guard isPrimary else { return }
    let directory = conversationDirectory(id)
    queue.async {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  func trashConversations(
    _ conversations: [Conversation],
    at date: Date = Date(),
    named name: String? = nil
  ) {
    guard isPrimary, !conversations.isEmpty else { return }
    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")
    stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let label = (name ?? "Boltty History")
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    let folder = root.appendingPathComponent(
      "\(label) \(stamp.string(from: date))", isDirectory: true
    )
    let index = IndexFile(
      version: Self.formatVersion,
      conversations: conversations,
      selectedConversationID: nil
    )
    let directories = conversations.map { conversationDirectory($0.id) }
    queue.async { [encoder, trash, log] in
      let manager = FileManager.default
      do {
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(index)
          .write(to: folder.appendingPathComponent("index.json"), options: .atomic)
        for directory in directories where manager.fileExists(atPath: directory.path) {
          try manager.moveItem(
            at: directory,
            to: folder.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
          )
        }
        try trash(folder)
      } catch {
        log.error("Clear History could not reach the Trash; the history stays in \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
  }


  func importAttachment(from source: URL, into id: UUID) throws -> URL {
    guard isPrimary else { throw CocoaError(.fileWriteNoPermission) }
    let directory = attachmentsDirectory(id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let unique = "\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)"
    let target = directory.appendingPathComponent(unique)
    try FileManager.default.copyItem(at: source, to: target)
    return target
  }

  private func write<T: Encodable & Sendable>(_ value: T, to url: URL) {
    queue.async { [encoder] in
      guard let data = try? encoder.encode(value) else { return }
      try? data.write(to: url, options: .atomic)
    }
  }

  func flush() {
    queue.sync {}
  }

  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }()

  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}

struct ConversationTranscript: Equatable, Sendable {
  var messages: [ConversationMessage] = []
  var interactions: [PendingInteraction] = []

  var openInteraction: PendingInteraction? {
    interactions.first { $0.isOpen }
  }
}
