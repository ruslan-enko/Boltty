import Foundation
import UniformTypeIdentifiers

final class PromptAttachmentStore: PromptAttachmentStoring, @unchecked Sendable {
  static let shared = PromptAttachmentStore()

  static let maxAge: TimeInterval = 7 * 24 * 60 * 60

  private let fileManager: FileManager
  let directory: URL

  init(fileManager: FileManager = .default, directory: URL? = nil) {
    self.fileManager = fileManager
    self.directory = directory ?? fileManager
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("Boltty/Pasteboard", isDirectory: true)
  }

  func fileURL(for attachment: PromptAttachment) throws -> URL {
    let (data, fileExtension): (Data, String)
    switch attachment.payload {
    case let .imageData(bytes, type):
      (data, fileExtension) = (bytes, type.preferredFilenameExtension ?? "png")
    case let .screen(selection):
      (data, fileExtension) = (selection.region, "png")
    case let .text(text):
      (data, fileExtension) = (Data(text.utf8), "txt")
    case let .file(url):
      return url
    }

    return try write(data, named: fileName(for: attachment, extension: fileExtension), for: attachment)
  }

  func screenFileURL(for attachment: PromptAttachment) throws -> URL {
    guard case let .screen(selection) = attachment.payload else {
      throw PromptExpansionError.attachmentUnavailable(attachment.label)
    }
    let region = fileName(for: attachment, extension: "png")
    return try write(selection.screen, named: region.dropLast(".png".count) + "-screen.png", for: attachment)
  }

  private func write(_ data: Data, named name: String, for attachment: PromptAttachment) throws -> URL {
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent(name)
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      throw PromptExpansionError.attachmentUnavailable(attachment.label)
    }
  }

  private func fileName(for attachment: PromptAttachment, extension fileExtension: String) -> String {
    let stem = attachment.label
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: "-")
    let safeStem = stem.isEmpty ? "pasted" : stem
    return "\(safeStem)-\(attachment.id.uuidString.prefix(8)).\(fileExtension)"
  }

  @discardableResult
  func purgeExpired(now: Date = Date(), maxAge: TimeInterval = PromptAttachmentStore.maxAge) -> Int {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return 0 }

    var removed = 0
    for entry in entries {
      guard
        let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate,
        now.timeIntervalSince(modified) > maxAge
      else { continue }
      if (try? fileManager.removeItem(at: entry)) != nil { removed += 1 }
    }
    return removed
  }
}
