import Foundation

enum PaletteMessageBlock: Equatable {
  case prose(String)
  case activity(AgentActivity)
  case attachment(ConversationAttachment)
  case reasoning(String)
  case failure(String)
}

enum PaletteSegment: Equatable {
  case text([PaletteMessageBlock])
  case activity(AgentActivity)
  case group([AgentActivity])
}

enum PaletteAnswerRun {
  static func shown(_ blocks: [PaletteMessageBlock]) -> [PaletteMessageBlock] {
    blocks.filter { block in
      switch block {
      case .prose, .attachment: true
      case .failure, .reasoning, .activity: false
      }
    }
  }

  enum Piece: Equatable {
    case text([PaletteMessageBlock])
    case code(String)
  }

  static func pieces(of blocks: [PaletteMessageBlock]) -> [Piece] {
    var pieces: [Piece] = []
    var text: [PaletteMessageBlock] = []
    func closeText() {
      if !text.isEmpty { pieces.append(.text(text)) }
      text = []
    }
    for block in shown(blocks) {
      guard case let .prose(markdown) = block else {
        text.append(block)
        continue
      }
      var prose: [Substring] = []
      var code: [Substring]?
      var fence = ""
      func closeProse() {
        let joined = prose.joined(separator: "\n")
        if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text.append(.prose(joined)) }
        prose = []
      }
      let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
      for line in lines {
        let indent = line.prefix { $0 == " " }.count
        let trimmed = line.dropFirst(indent)
        if let open = code {
          if trimmed.hasPrefix(fence),
             trimmed.drop(while: { $0 == fence.first }).allSatisfy(\.isWhitespace) {
            closeText()
            pieces.append(.code(open.joined(separator: "\n")))
            code = nil
          } else {
            code = open + [line]
          }
          continue
        }
        if indent < 4, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
          fence = String(trimmed.prefix { $0 == trimmed.first })
          closeProse()
          code = []
          continue
        }
        prose.append(line)
      }
      if let open = code {
        closeText()
        pieces.append(.code(open.joined(separator: "\n")))
      }
      closeProse()
    }
    closeText()
    return pieces
  }
}

extension ConversationMessage {
  var paletteSegments: [PaletteSegment] {
    var segments: [PaletteSegment] = []
    var text: [PaletteMessageBlock] = []
    var work: [AgentActivity] = []
    var thoughts: [AgentActivity] = []
    func closeText() {
      if !text.isEmpty { segments.append(.text(text)) }
      text = []
    }
    func closeWork() {
      work += thoughts
      thoughts = []
      if work.contains(where: { !$0.isThought }) { segments.append(.group(work)) }
      work = []
    }
    for (index, block) in paletteBlocks.enumerated() {
      switch block {
      case let .activity(activity):
        closeText()
        guard AgentActivityGroup.isGroupable(activity) else {
          closeWork()
          segments.append(.activity(activity))
          continue
        }
        work += thoughts + [activity]
        thoughts = []
      case .reasoning:
        thoughts.append(AgentActivityGroup.thought(id: "\(id)#thought\(index)"))
      case .prose, .attachment, .failure:
        if work.isEmpty { thoughts = [] } else { closeWork() }
        text.append(block)
      }
    }
    closeText()
    closeWork()
    return segments
  }
}

extension ConversationMessage {
  var paletteBlocks: [PaletteMessageBlock] {
    var blocks: [PaletteMessageBlock] = parts.compactMap { part in
      guard !part.isEmpty else { return nil }
      switch part {
      case let .text(value):
        // An Ask Boltty answer's `<point …/>` tags are for the mascot, not for reading.
        return .prose(role == .agent ? AskBolttyMark.stripped(value.text) : value.text)
      case let .reasoning(value): return .reasoning(value.text)
      case let .activity(value): return .activity(value)
      case let .attachment(value): return .attachment(value)
      }
    }
    if let failure {
      blocks.append(.failure(failure.isAbort ? "Stopped" : failure.message))
    }
    return blocks
  }

  var paletteText: String {
    paletteBlocks.compactMap { block -> String? in
      switch block {
      case let .prose(text): return text
      case let .activity(activity): return activity.headline
      case let .attachment(attachment): return attachment.displayName
      case let .failure(message): return message
      case .reasoning: return nil
      }
    }.joined(separator: "\n\n")
  }

  var copyableText: String {
    paletteBlocks.compactMap { block -> String? in
      if case let .prose(text) = block { return text }
      return nil
    }
    .joined(separator: "\n\n")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var typedBlocks: [PaletteMessageBlock] {
    paletteBlocks.filter { block in
      if case let .attachment(attachment) = block { return attachment.url == nil }
      return true
    }
  }

  var fileCardNames: [String: String] {
    parts.reduce(into: [:]) { names, part in
      guard case let .attachment(attachment) = part, let url = attachment.url,
            names[url.path] == nil else { return }
      names[url.path] = attachment.displayName
    }
  }

  var resultFiles: [String] {
    var seen = Set<String>()
    var paths: [String] = []
    func add(_ path: String) {
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
      paths.append(trimmed)
    }
    for part in parts {
      switch part {
      case let .activity(activity):
        switch AgentActivityGroup.kind(of: activity) {
        case .read, .search, .browse: continue
        case .edit, .command, .other: activity.files.forEach(add)
        }
      case let .attachment(attachment):
        if let url = attachment.url { add(url.path) }
      case .text, .reasoning:
        break
      }
    }
    return paths
  }
}
