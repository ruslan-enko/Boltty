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

  /// The words, then what came with them: the shape the composer keeps a
  /// draft in, since an attachment stands over the sentence and not in it.
  ///
  /// Words after an attachment mean a draft stored while attachments stood
  /// in the sentence, each with a space either side that was only there for
  /// it, or dictation added to what was already here.
  var separated: (words: String, attachments: [PromptAttachment]) {
    var words = ""
    var attachments: [PromptAttachment] = []
    var wordsFollowAnAttachment = false
    for element in elements {
      switch element {
      case let .text(text):
        wordsFollowAnAttachment = wordsFollowAnAttachment || !attachments.isEmpty
        let doubled = words.last?.isWhitespace == true && text.first == " "
        words += doubled ? String(text.dropFirst()) : text
      case let .attachment(attachment):
        // A link saved as an attachment by an older build is words again.
        if attachment.kind == .link, case let .text(url) = attachment.payload {
          words += url
        } else {
          attachments.append(attachment)
        }
      }
    }
    if wordsFollowAnAttachment {
      words = words.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return (words, attachments)
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
  ) throws -> (text: String, files: [(attachment: UUID, file: SentFile)]) {
    var result = ""
    var files: [(attachment: UUID, file: SentFile)] = []
    var followsAttachment = false
    for element in draft.elements {
      switch element {
      case let .text(text):
        if followsAttachment, text.first?.isWhitespace != true { result += separator(after: result, followsAttachment: true) }
        result += text
        followsAttachment = false
      case let .attachment(attachment):
        result += separator(after: result, followsAttachment: followsAttachment)
        followsAttachment = true
        if case let .screen(selection) = attachment.payload {
          let (text, sent) = try expandScreen(attachment, selection, store: store)
          result += text
          files += sent.map { (attachment.id, $0) }
          continue
        }
        let (text, path) = try expand(attachment, store: store)
        result += text
        if let path {
          let name = names[attachment.id] ?? Self.fileName(of: attachment, at: path)
          files.append((attachment.id, SentFile(path: path, label: "", name: name)))
        } else if case .text = attachment.payload, attachment.kind != .link,
                  let written = try? store.fileURL(for: attachment).path {
          // The words go inline; the file is what the card over the bubble
          // stands on, so one that could not be written costs only the card.
          let name = Self.fileName(of: attachment, at: written)
          files.append((attachment.id, SentFile(path: written, label: "", name: name, expansion: text)))
        }
      }
    }
    return (result, files)
  }

  /// An attachment no longer stands where it was typed, so nothing in the
  /// sentence parts it from its neighbours: a blank line under the words, a
  /// space between files, and nothing where there is whitespace already.
  private static func separator(after text: String, followsAttachment: Bool) -> String {
    guard let last = text.last, !last.isWhitespace else { return "" }
    return followsAttachment ? " " : "\n\n"
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
      + "The screen, the selection outlined and all but its window hidden: \(quotedIfNeeded(screen))"
    if let read = selection.recognizedText {
      text += ". Text read from the selection: \(screenTextOpenTag)\(read)\(screenTextCloseTag)"
    }
    text += "]"
    return (text, [
      SentFile(path: region, label: "", name: "\(attachment.label).png", expansion: text),
      SentFile(path: screen, label: "", name: "\(attachment.label)-screen.png"),
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
      // What parted the words from the files they came with goes with them.
      while words.last?.isWhitespace == true { words.removeLast() }
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
