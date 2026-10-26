import Foundation
import UniformTypeIdentifiers

enum PromptAttachmentKind: String, Sendable, CaseIterable, Equatable, Codable {
  case image
  case file
  case text
  case link

  static func resolve(for url: URL) -> PromptAttachmentKind {
    let type =
      (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
      ?? UTType(filenameExtension: url.pathExtension)
    return resolve(for: type)
  }

  static func resolve(for type: UTType?) -> PromptAttachmentKind {
    guard let type else { return .file }
    if type.conforms(to: .image) { return .image }
    return .file
  }

  static func isLink(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
    guard let components = URLComponents(string: trimmed) else { return false }
    guard let scheme = components.scheme?.lowercased(), !scheme.isEmpty else { return false }
    guard scheme != "file" else { return false }
    return !(components.host ?? "").isEmpty
  }

  /// The links in a sentence, as ranges of `text` (UTF-16, `NSString`'s).
  ///
  /// A link is a word `isLink` agrees with, or one that opens with `www.`,
  /// with the punctuation a sentence puts round it left out ("(see
  /// https://a.com/x)." is the address alone). An attachment's placeholder
  /// character parts words like a space does. Links are not chips: they
  /// stay text in the draft and are only drawn as links.
  static func linkRanges(in text: String) -> [NSRange] {
    guard text.contains("://") || text.localizedCaseInsensitiveContains("www.") else { return [] }
    let source = text as NSString
    let leading = CharacterSet(charactersIn: "([{<\"'“‘«")
    let trailing = CharacterSet(charactersIn: ".,;:!?)]}>\"'”’»…")
    var ranges: [NSRange] = []
    var start: Int?
    func close(at end: Int) {
      guard let from = start else { return }
      start = nil
      var range = NSRange(location: from, length: end - from)
      while range.length > 0, contains(leading, source.character(at: range.location)) {
        range.location += 1
        range.length -= 1
      }
      while range.length > 0, contains(trailing, source.character(at: range.location + range.length - 1)) {
        range.length -= 1
      }
      guard range.length > 0 else { return }
      let word = source.substring(with: range)
      if isLink(word) || isWebAddress(word) { ranges.append(range) }
    }
    for index in 0..<source.length {
      let unit = source.character(at: index)
      if unit == 0xFFFC || contains(.whitespacesAndNewlines, unit) {
        close(at: index)
      } else if start == nil {
        start = index
      }
    }
    close(at: source.length)
    return ranges
  }

  private static func contains(_ set: CharacterSet, _ unit: unichar) -> Bool {
    Unicode.Scalar(unit).map(set.contains) ?? false
  }

  private static func isWebAddress(_ word: String) -> Bool {
    guard word.lowercased().hasPrefix("www.") else { return false }
    let host = word.dropFirst(4).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
  }
}

enum PromptAttachmentPayload: Sendable, Equatable, Codable {
  case file(URL)
  case imageData(Data, type: UTType)
  case text(String)
  case screen(ScreenSelection)
}

struct PromptAttachment: Sendable, Equatable, Identifiable, Codable {
  let id: UUID
  var kind: PromptAttachmentKind
  var payload: PromptAttachmentPayload
  var label: String

  init(
    id: UUID = UUID(),
    kind: PromptAttachmentKind,
    payload: PromptAttachmentPayload,
    label: String
  ) {
    self.id = id
    self.kind = kind
    self.payload = payload
    self.label = label
  }

  static func file(_ url: URL, label: String, id: UUID = UUID()) -> PromptAttachment {
    PromptAttachment(
      id: id,
      kind: .resolve(for: url),
      payload: .file(url),
      label: label
    )
  }

  func displayLabel(maxCharacters: Int = PromptAttachment.defaultLabelLimit) -> String {
    label.middleTruncated(to: maxCharacters)
  }

  static let defaultLabelLimit = 22
}

extension String {
  func middleTruncated(to maxCharacters: Int, ellipsis: String = "…") -> String {
    guard maxCharacters > 0 else { return "" }
    guard count > maxCharacters else { return self }
    guard maxCharacters > ellipsis.count else { return String(prefix(maxCharacters)) }

    let budget = maxCharacters - ellipsis.count
    let tailLength = budget - budget / 2
    let headLength = budget - tailLength
    return prefix(headLength) + ellipsis + suffix(tailLength)
  }
}
