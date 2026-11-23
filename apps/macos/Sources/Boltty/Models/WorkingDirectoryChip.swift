import Foundation

struct WorkingDirectoryChip: Equatable, Sendable {
  let path: String
  let isEditable: Bool
  var branch: String?

  init(path: String, isEditable: Bool, branch: String? = nil) {
    self.path = path
    self.isEditable = isEditable
    self.branch = branch
  }

  func withBranch(_ branch: String?) -> WorkingDirectoryChip {
    var chip = self
    chip.branch = branch
    return chip
  }

  var displayPath: String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return String(localized: "Home") }
    if trimmed == WorkingDirectoryResolver.homeDirectoryPath { return String(localized: "Home") }
    if trimmed == "/" { return "/" }
    let name = (trimmed as NSString).lastPathComponent
    return name.isEmpty ? trimmed : name
  }

  var isHome: Bool {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed == WorkingDirectoryResolver.homeDirectoryPath
  }

  var folderName: String? { isHome ? nil : displayPath }

  var folderLabel: String? {
    guard let name = folderName else { return nil }
    guard let branch, !branch.isEmpty else { return name }
    return "\(name) · \(branch)"
  }

  var tooltip: String {
    var lines = [path]
    if isEditable {
      lines.append(String(localized: "Click to choose the folder this chat works in."))
    } else {
      lines.append(
        String(localized: "Fixed when the conversation started — the session is rooted here. A new chat can start somewhere else.")
      )
    }
    return lines.joined(separator: "\n")
  }

  var accessibilityLabel: String {
    let state = isEditable ? String(localized: "Working folder") : String(localized: "Working folder, fixed")
    return "\(state), \(displayPath)"
  }

  static func forNewPrompt(
    path: String
  ) -> WorkingDirectoryChip {
    WorkingDirectoryChip(
      path: path,
      isEditable: true
    )
  }

  static func forConversation(
    _ conversation: Conversation,
    canChange: Bool? = nil
  ) -> WorkingDirectoryChip {
    WorkingDirectoryChip(
      path: conversation.workingDirectory,
      isEditable: canChange ?? conversation.canChangeWorkingDirectory
    )
  }
}
