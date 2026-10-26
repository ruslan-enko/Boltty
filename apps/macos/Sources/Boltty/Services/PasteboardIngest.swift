import AppKit
import UniformTypeIdentifiers

enum PasteboardIngest {
  enum Outcome: Equatable {
    case attachments([PromptAttachment])
    case plainText(String)
    case tooManyFiles(limit: Int)
    case nothing
  }

  static let maxFileCount = 10

  static let textChipThreshold = 500

  static func read(
    _ pasteboard: NSPasteboard,
    into draft: PromptDraft,
    forcePlainText: Bool = false
  ) -> Outcome {
    if forcePlainText {
      if let string = pasteboard.string(forType: .string), !string.isEmpty {
        return .plainText(string)
      }
      let paths = fileURLs(on: pasteboard).map(\.path)
      return paths.isEmpty ? .nothing : .plainText(paths.joined(separator: " "))
    }

    let urls = fileURLs(on: pasteboard)
    if !urls.isEmpty { return attachments(for: urls, into: draft) }

    if let image = imageAttachment(from: pasteboard, into: draft) {
      return .attachments([image])
    }

    guard let string = pasteboard.string(forType: .string), !string.isEmpty else {
      return .nothing
    }

    // A link is words in the sentence, drawn as a link (`PromptTextView.styleLinks`),
    // not a chip: a chip in the middle of a sentence
    // breaks the line it stands in. Trimmed, since a copied address brings its newline.
    if PromptAttachmentKind.isLink(string) {
      return .plainText(string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    if isChipWorthy(string) {
      return .attachments([
        PromptAttachment(
          kind: .text,
          payload: .text(string),
          label: draft.nextGeneratedLabel(for: .text)
        )
      ])
    }
    return .plainText(string)
  }

  static func attachments(for urls: [URL], into draft: PromptDraft) -> Outcome {
    guard !urls.isEmpty else { return .nothing }
    guard urls.count <= maxFileCount else { return .tooManyFiles(limit: maxFileCount) }
    let labels = draft.generatedLabels(for: urls.map { PromptAttachmentKind.resolve(for: $0) })
    return .attachments(zip(urls, labels).map { PromptAttachment.file($0, label: $1) })
  }

  private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
    pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] ?? []
  }

  static func isChipWorthy(_ text: String) -> Bool {
    text.contains(where: \.isNewline) || text.count > textChipThreshold
  }

  private static func imageAttachment(
    from pasteboard: NSPasteboard,
    into draft: PromptDraft
  ) -> PromptAttachment? {
    let candidates: [(NSPasteboard.PasteboardType, UTType)] = [
      (.png, .png),
      (.tiff, .tiff),
    ]
    for (pasteboardType, contentType) in candidates {
      guard let data = pasteboard.data(forType: pasteboardType), !data.isEmpty else { continue }
      return PromptAttachment(
        kind: .image,
        payload: .imageData(data, type: contentType),
        label: draft.nextGeneratedLabel(for: .image)
      )
    }
    return nil
  }
}
