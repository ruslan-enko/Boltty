import Foundation

protocol PromptAttachmentStoring: Sendable {
  func fileURL(for attachment: PromptAttachment) throws -> URL
  func screenFileURL(for attachment: PromptAttachment) throws -> URL
}

struct PromptDraft: Sendable, Equatable, Codable {
  enum Element: Sendable, Equatable, Codable {
    case text(String)
    case attachment(PromptAttachment)
  }

  var elements: [Element] = []

  init(elements: [Element] = []) {
    self.elements = elements
  }

  init(_ text: String) {
    self.elements = text.isEmpty ? [] : [.text(text)]
  }

  var attachments: [PromptAttachment] {
    elements.compactMap {
      if case let .attachment(attachment) = $0 { return attachment }
      return nil
    }
  }

  var typedText: String {
    elements.reduce(into: "") { result, element in
      if case let .text(text) = element { result += text }
    }
  }

  var isEffectivelyEmpty: Bool {
    attachments.isEmpty
      && typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func nextGeneratedLabel(for kind: PromptAttachmentKind) -> String {
    generatedLabels(for: [kind])[0]
  }

  func generatedLabels(for kinds: [PromptAttachmentKind]) -> [String] {
    var used: [PromptAttachmentKind: Int] = [:]
    for attachment in attachments {
      used[attachment.kind, default: 0] += 1
    }
    return kinds.map { kind in
      let next = used[kind, default: 0] + 1
      used[kind] = next
      return "\(kind.rawValue)\(next)"
    }
  }

  mutating func append(_ attachment: PromptAttachment) {
    elements.append(.attachment(attachment))
  }

  mutating func append(text: String) {
    guard !text.isEmpty else { return }
    if case let .text(existing) = elements.last {
      elements[elements.count - 1] = .text(existing + text)
    } else {
      elements.append(.text(text))
    }
  }
}

enum PromptExpansionError: Error, LocalizedError, Equatable {
  case attachmentUnavailable(String)

  var errorDescription: String? {
    switch self {
    case let .attachmentUnavailable(label):
      "Could not prepare “\(label)” for the agent."
    }
  }
}

enum PromptExpansion {
  static let inlineTextByteLimit = 8 * 1024

  static let textOpenTag = "<pasted-text>"
  static let textCloseTag = "</pasted-text>"
  static let screenTextOpenTag = "<screen-text>"
  static let screenTextCloseTag = "</screen-text>"

  static func expand(_ draft: PromptDraft, store: PromptAttachmentStoring) throws -> String {
    try expandRecordingFiles(draft, store: store).text
  }

  static func expandRecordingFiles(
    _ draft: PromptDraft,
    names: [UUID: String] = [:],
    store: PromptAttachmentStoring
  ) throws -> (text: String, files: [(chip: UUID, file: SentFile)]) {
    var result = ""
    var files: [(chip: UUID, file: SentFile)] = []
    for element in draft.elements {
      switch element {
      case let .text(text):
        result += text
      case let .attachment(attachment):
        if case let .screen(selection) = attachment.payload {
          let (text, sent) = try expandScreen(attachment, selection, store: store)
          result += text
          files += sent.map { (attachment.id, $0) }
          continue
        }
        let (text, path) = try expand(attachment, store: store)
        result += text
        guard let path else { continue }
        let name = names[attachment.id] ?? Self.fileName(of: attachment, at: path)
        files.append((attachment.id, SentFile(path: path, label: attachment.label, name: name)))
      }
    }
    return (result, files)
  }

  private static func expandScreen(
    _ attachment: PromptAttachment,
    _ selection: ScreenSelection,
    store: PromptAttachmentStoring
  ) throws -> (text: String, files: [SentFile]) {
    let region = try store.fileURL(for: attachment).path
    let screen = try store.screenFileURL(for: attachment).path
    let place = selection.context.map { " in \($0)" } ?? ""
    var text = "[Selected on screen\(place): \(quotedIfNeeded(region)). "
      + "The whole screen, the selection outlined: \(quotedIfNeeded(screen))"
    if let read = selection.recognizedText {
      text += ". Text read from the selection: \(screenTextOpenTag)\(read)\(screenTextCloseTag)"
    }
    text += "]"
    return (text, [
      SentFile(path: region, label: attachment.label, name: "\(attachment.label).png", expansion: text),
      SentFile(path: screen, label: attachment.label, name: "\(attachment.label)-screen.png"),
    ])
  }

  private static func fileName(of attachment: PromptAttachment, at path: String) -> String {
    let url = URL(fileURLWithPath: path)
    if case .file = attachment.payload { return url.lastPathComponent }
    return url.pathExtension.isEmpty ? attachment.label : "\(attachment.label).\(url.pathExtension)"
  }

  private static func expand(
    _ attachment: PromptAttachment,
    store: PromptAttachmentStoring
  ) throws -> (text: String, path: String?) {
    if attachment.kind == .link, case let .text(url) = attachment.payload {
      return (url, nil)
    }
    let path: String
    switch attachment.payload {
    case let .file(url):
      path = url.path
    case .imageData, .screen:
      path = try store.fileURL(for: attachment).path
    case let .text(text):
      guard text.utf8.count > inlineTextByteLimit else {
        return (textOpenTag + text + textCloseTag, nil)
      }
      path = try store.fileURL(for: attachment).path
    }
    return (quotedIfNeeded(path), path)
  }

  private static func quotedIfNeeded(_ path: String) -> String {
    guard path.contains(" ") else { return path }
    return "\"\(path)\""
  }
}

struct SentFile: Codable, Equatable, Hashable, Sendable {
  var path: String
  var label: String
  var name: String
  var expansion: String?

  static func lift(_ message: ConversationMessage, files: [SentFile]) -> ConversationMessage {
    guard message.role == .user, !files.isEmpty else { return message }
    let candidates = files.sorted { $0.path.count > $1.path.count }
    let spellings: [(text: String, file: SentFile)] =
      candidates
        .compactMap { file in file.expansion.map { ($0, file) } }
        .sorted { $0.text.count > $1.text.count }
      + candidates.flatMap { file in [("\"\(file.path)\"", file), (file.path, file)] }
    var found: [SentFile] = []
    var lifted = message
    lifted.parts = message.parts.compactMap { part in
      guard case var .text(text) = part, text.kind == .text else { return part }
      let source = text.text
      var matches: [(range: Range<String.Index>, file: SentFile)] = []
      for (spelling, file) in spellings {
        var from = source.startIndex
        while let range = source.range(of: spelling, range: from..<source.endIndex) {
          if !matches.contains(where: { $0.range.overlaps(range) }) {
            matches.append((range, file))
          }
          from = range.upperBound
        }
      }
      guard !matches.isEmpty else { return part }
      matches.sort { $0.range.lowerBound < $1.range.lowerBound }
      var words = ""
      var rest = ""
      var cursor = source.startIndex
      for match in matches {
        words += source[cursor..<match.range.lowerBound]
        rest += source[cursor..<match.range.lowerBound]
        words += match.file.label
        cursor = match.range.upperBound
        if !found.contains(match.file) { found.append(match.file) }
        guard match.file.expansion != nil else { continue }
        let inside = source[match.range]
        for file in files where file != match.file && inside.contains(file.path) {
          if !found.contains(file) { found.append(file) }
        }
      }
      words += source[cursor...]
      rest += source[cursor...]
      guard !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      text.text = words
      return .text(text)
    }
    let attached = Set(message.parts.compactMap { part -> String? in
      if case let .attachment(attachment) = part { return attachment.url?.path }
      return nil
    })
    lifted.parts += found.filter { !attached.contains($0.path) }.map { file in
      ConversationPart.attachment(ConversationAttachment(
        id: "sent-\(file.path)", displayName: file.name, url: URL(fileURLWithPath: file.path)))
    }
    return lifted
  }
}

extension SentFile {
  static let pictureByteLimit = 3_750_000

  var picture: ConversationAttachment? {
    let url = URL(fileURLWithPath: path)
    guard let mime = MIMEType.guess(for: url), mime.hasPrefix("image/"),
          let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
          size <= Self.pictureByteLimit
    else { return nil }
    return ConversationAttachment(
      id: "sent-\(path)", displayName: name, url: url, mimeType: mime, byteCount: size)
  }
}
