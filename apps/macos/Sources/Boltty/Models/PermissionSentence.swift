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
      case .run: String(localized: "Run this command?")
      case .edit: String(localized: "Edit a file?")
      case .read: String(localized: "Read a file?")
      case .delete: String(localized: "Delete a file?")
      case .fetch: String(localized: "Fetch from the web?")
      case .outside: String(localized: "Work outside the project folder?")
      case let .other(action): String(localized: "Allow “\(action)”?")
      }
    }

    func phrase(for name: String) -> String? {
      switch self {
      case .edit: String(localized: "Edit \(name)?")
      case .read: String(localized: "Read \(name)?")
      case .delete: String(localized: "Delete \(name)?")
      case .run, .fetch, .outside, .other: nil
      }
    }
  }
}
