import Foundation

/// A model Boltty can download to listen or speak on this Mac: where it comes
/// from, pinned to one commit, and every file with its size and digest
/// (`LocalVoiceCatalog`, written by `scripts/pin-local-model.py`). A
/// repository that changes later serves nothing Boltty takes.
struct LocalVoiceModel: Identifiable, Equatable, Sendable {
  /// Stored as the start of a folder name, so the spelling stays.
  enum ID: String, CaseIterable, Sendable {
    case parakeetUltra = "parakeet-ultra"
    case supertonic3 = "supertonic-3"
  }

  struct File: Equatable, Sendable {
    /// Relative to the model's folder, `/`-separated.
    let path: String
    let size: Int64
    /// Lowercase hex.
    let sha256: String
  }

  struct Licence: Equatable, Sendable {
    let name: String
    let url: URL
  }

  let id: ID
  /// What Settings calls it: "Parakeet", "Supertonic".
  let name: String
  /// `owner/name` on Hugging Face.
  let repository: String
  /// A full commit hash.
  let revision: String
  let licence: Licence
  let files: [File]

  var size: Int64 { files.reduce(0) { $0 + $1.size } }

  /// One folder per revision, so a newer pin never mixes with an older one.
  var folderName: String { "\(id.rawValue)-\(revision.prefix(12))" }

  func source(of file: File) -> URL {
    let path = file.path.split(separator: "/").map {
      $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
    }.joined(separator: "/")
    return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")!
  }

  /// Every path stays inside the model's folder and every digest is one: a
  /// catalog that fails this is never downloaded.
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
