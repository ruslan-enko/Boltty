import Foundation

struct WorkingDirectoryChip: Equatable, Sendable {
  let path: String
  let isEditable: Bool
  let isIgnoredByAgent: Bool
  var branch: String?

  init(path: String, isEditable: Bool, isIgnoredByAgent: Bool, branch: String? = nil) {
    self.path = path
    self.isEditable = isEditable
    self.isIgnoredByAgent = isIgnoredByAgent
    self.branch = branch
  }

  func withBranch(_ branch: String?) -> WorkingDirectoryChip {
    var chip = self
    chip.branch = branch
    return chip
  }

  var displayPath: String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "Home" }
    if trimmed == WorkingDirectoryResolver.homeDirectoryPath { return "Home" }
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

  var warning: String? {
    guard isIgnoredByAgent else { return nil }
    return "This chat doesn't work in the folder you choose — "
      + "its agent keeps its own scratch directory, and files land there."
  }

  var tooltip: String {
    var lines = [path]
    if let warning { lines.append(warning) }
    if isEditable {
      lines.append("Click to choose the folder this chat works in.")
    } else {
      lines.append(
        "Fixed when the conversation started — the session is rooted here. "
          + "A new chat can start somewhere else."
      )
    }
    return lines.joined(separator: "\n")
  }

  var accessibilityLabel: String {
    let state = isEditable ? "Working folder" : "Working folder, fixed"
    return "\(state), \(displayPath)"
  }

  static func forNewPrompt(
    path: String,
    honoursWorkingDirectory: Bool
  ) -> WorkingDirectoryChip {
    WorkingDirectoryChip(
      path: path,
      isEditable: true,
      isIgnoredByAgent: !honoursWorkingDirectory
    )
  }

  static func forConversation(
    _ conversation: Conversation,
    honoursWorkingDirectory: Bool
  ) -> WorkingDirectoryChip {
    WorkingDirectoryChip(
      path: conversation.workingDirectory,
      isEditable: conversation.canChangeWorkingDirectory,
      isIgnoredByAgent: !honoursWorkingDirectory
    )
  }
}
