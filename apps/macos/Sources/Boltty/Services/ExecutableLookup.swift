import Foundation

enum ExecutableLookup {
  static func searchDirectories(
    path: String? = ProcessInfo.processInfo.environment["PATH"]
  ) -> [String] {
    let home = NSHomeDirectory()
    var directories = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin")
      .split(separator: ":").map(String.init)
    directories += [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
      "\(home)/.local/bin",
      "\(home)/.grok/bin",
      "\(home)/.opencode/bin",
      "\(home)/.bun/bin",
      "\(home)/.cargo/bin",
      "\(home)/.volta/bin",
      "\(home)/.deno/bin",
      "\(home)/.npm-global/bin",
      "\(home)/.asdf/shims",
      "\(home)/.local/share/mise/shims",
      "\(home)/Library/pnpm",
    ]
    directories += versionManagerBinDirectories(
      root: URL(fileURLWithPath: home).appendingPathComponent(".nvm/versions/node"),
      suffix: "bin"
    )
    directories += versionManagerBinDirectories(
      root: URL(fileURLWithPath: home).appendingPathComponent(".fnm/node-versions"),
      suffix: "installation/bin"
    )
    var seen = Set<String>()
    return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  static func resolve(_ name: String) -> String? {
    let fileManager = FileManager.default
    if name.contains("/") {
      return fileManager.isExecutableFile(atPath: name) ? name : nil
    }
    return searchDirectories()
      .map { "\($0)/\(name)" }
      .first { fileManager.isExecutableFile(atPath: $0) }
  }

  private static func versionManagerBinDirectories(root: URL, suffix: String) -> [String] {
    guard let versions = try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else { return [] }
    return versions
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
      .map { $0.appendingPathComponent(suffix).path }
  }
}
