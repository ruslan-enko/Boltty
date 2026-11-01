import CryptoKit
import Foundation

enum FileDigest {
  /// Lowercase hex SHA-256 of a file, read a megabyte at a time. Blocking:
  /// a 600 MB model takes a second or two, so callers run it off the main
  /// thread and outside any actor.
  static func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
