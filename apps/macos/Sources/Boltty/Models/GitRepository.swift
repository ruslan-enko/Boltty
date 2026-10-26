import Foundation

struct GitRepository: Equatable, Sendable {
  let branch: String?
  let gitHubURL: URL?

  static func read(at folder: String) -> GitRepository? {
    let manager = FileManager.default
    let dotGit = (folder as NSString).appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }

    var gitDir = dotGit
    if !isDirectory.boolValue {
      guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
            let named = gitDirectory(fromPointer: pointer, relativeTo: folder) else { return nil }
      gitDir = named
    }
    var commonDir = gitDir
    if let common = try? String(
      contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8) {
      let path = common.trimmingCharacters(in: .whitespacesAndNewlines)
      commonDir = path.hasPrefix("/")
        ? path
        : ((gitDir as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    let head = try? String(
      contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"), encoding: .utf8)
    let config = try? String(
      contentsOfFile: (commonDir as NSString).appendingPathComponent("config"), encoding: .utf8)
    return GitRepository(
      branch: head.flatMap(branch(fromHead:)),
      gitHubURL: config.flatMap(gitHubURL(fromConfig:))
    )
  }

  static func gitDirectory(fromPointer pointer: String, relativeTo folder: String) -> String? {
    let line = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.hasPrefix("gitdir:") else { return nil }
    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty else { return nil }
    return path.hasPrefix("/")
      ? path
      : ((folder as NSString).appendingPathComponent(path) as NSString).standardizingPath
  }

  static func branch(fromHead head: String) -> String? {
    let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
    if line.hasPrefix("ref:") {
      let ref = line.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
      let heads = "refs/heads/"
      return ref.hasPrefix(heads) ? String(ref.dropFirst(heads.count)) : ref
    }
    let hex = CharacterSet(charactersIn: "0123456789abcdef")
    guard line.count >= 7, line.unicodeScalars.allSatisfy(hex.contains) else { return nil }
    return String(line.prefix(7))
  }

  static func gitHubURL(fromConfig config: String) -> URL? {
    var remote: String?
    var urls: [(remote: String, url: String)] = []
    for raw in config.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        remote = line.hasPrefix("[remote \"")
          ? line.dropFirst("[remote \"".count).split(separator: "\"").first.map(String.init)
          : nil
        continue
      }
      guard let remote, line.hasPrefix("url") else { continue }
      let parts = line.split(separator: "=", maxSplits: 1)
      guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" else { continue }
      urls.append((remote, parts[1].trimmingCharacters(in: .whitespaces)))
    }
    let ordered = urls.filter { $0.remote == "origin" } + urls.filter { $0.remote != "origin" }
    return ordered.lazy.compactMap { gitHubPage(fromRemote: $0.url) }.first
  }

  static func gitHubPage(fromRemote remote: String) -> URL? {
    var rest: Substring
    if remote.hasPrefix("git@github.com:") {
      rest = remote.dropFirst("git@github.com:".count)
    } else if let url = URL(string: remote), url.host?.lowercased() == "github.com" {
      rest = Substring(url.path)
    } else {
      return nil
    }
    while rest.hasPrefix("/") { rest = rest.dropFirst() }
    while rest.hasSuffix("/") { rest = rest.dropLast() }
    if rest.hasSuffix(".git") { rest = rest.dropLast(4) }
    let parts = rest.split(separator: "/")
    guard parts.count == 2 else { return nil }
    return URL(string: "https://github.com/\(parts[0])/\(parts[1])")
  }
}
