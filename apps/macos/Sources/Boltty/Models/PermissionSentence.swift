import Foundation

enum PermissionSentence {
  static func sentence(action: String, resources: [String]) -> String {
    let verb = Verb(action: action)
    guard let subject = singleFileName(in: resources), let phrase = verb.phrase(for: subject) else {
      return verb.general
    }
    return phrase
  }

  static func detail(action: String, resources: [String]) -> String {
    ([action] + resources).joined(separator: "\n")
  }

  private static func singleFileName(in resources: [String]) -> String? {
    guard resources.count == 1 else { return nil }
    let value = resources[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.contains(" "), value.contains("/") else { return nil }
    let name = (value as NSString).lastPathComponent
    return name.isEmpty ? nil : name
  }

  private enum Verb {
    case run, edit, read, delete, fetch, outside
    case other(String)

    init(action: String) {
      switch action.lowercased() {
      case "bash", "shell", "run", "execute", "exec", "command", "terminal":
        self = .run
      case "edit", "write", "patch", "apply_patch", "multiedit", "create", "str_replace":
        self = .edit
      case "read", "view", "cat", "open":
        self = .read
      case "delete", "remove", "rm", "unlink":
        self = .delete
      case "webfetch", "fetch", "web_search", "websearch", "browse":
        self = .fetch
      case "external_directory":
        self = .outside
      default:
        self = .other(action)
      }
    }

    var general: String {
      switch self {
      case .run: "Run this command?"
      case .edit: "Edit a file?"
      case .read: "Read a file?"
      case .delete: "Delete a file?"
      case .fetch: "Fetch from the web?"
      case .outside: "Work outside the project folder?"
      case let .other(action): "Allow “\(action)”?"
      }
    }

    func phrase(for name: String) -> String? {
      switch self {
      case .edit: "Edit \(name)?"
      case .read: "Read \(name)?"
      case .delete: "Delete \(name)?"
      case .run, .fetch, .outside, .other: nil
      }
    }
  }
}
