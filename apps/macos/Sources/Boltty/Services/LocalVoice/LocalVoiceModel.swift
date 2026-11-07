import Foundation

struct LocalVoiceModel: Identifiable, Equatable, Sendable {
  enum ID: String, CaseIterable, Sendable {
    case parakeetUltra = "parakeet-ultra"
    case supertonic3 = "supertonic-3"
  }

  struct File: Equatable, Sendable {
    let path: String
    let size: Int64
    let sha256: String
  }

  struct Licence: Equatable, Sendable {
    let name: String
    let url: URL
  }

  let id: ID
  let name: String
  let repository: String
  let revision: String
  let licence: Licence
  let files: [File]

  var size: Int64 { files.reduce(0) { $0 + $1.size } }

  var folderName: String { "\(id.rawValue)-\(revision.prefix(12))" }

  func source(of file: File) -> URL {
    let path = file.path.split(separator: "/").map {
      $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
    }.joined(separator: "/")
    return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")!
  }

  var isWellFormed: Bool {
    files.allSatisfy { file in
      let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
      return !file.path.hasPrefix("/")
        && !parts.isEmpty
        && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        && file.size > 0
        && file.sha256.count == 64
        && file.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
  }
}
