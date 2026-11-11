import Foundation

/// Boltty's Auto Mode for commands, where the CLI has none Boltty can use
/// (Antigravity, Grok, OpenCode). A command goes through when every part of it
/// reads, builds, tests, or changes files inside the chat's folder; anything it
/// cannot read with confidence asks.
enum AutoModeCommands {
  struct Segment: Equatable {
    var words: [String] = []
    var writes: [String] = []
    var reads: [String] = []
  }

  static func allows(
    _ line: String,
    in directory: String,
    cwd: String? = nil,
    autoMode: Bool,
    granted: Set<String> = [],
    home: String = NSHomeDirectory()
  ) -> Bool {
    guard let segments = segments(of: line), !segments.isEmpty else { return false }
    var context = Context(
      directory: standard(directory, home: home) ?? directory,
      home: home,
      cwd: cwd.flatMap { standard($0, home: home) } ?? standard(directory, home: home) ?? directory
    )
    for segment in segments {
      let words = stripped(segment.words)
      guard let words, !words.isEmpty else { return false }
      if words[0] == "cd" {
        guard segment.writes.isEmpty, segment.reads.isEmpty, words.count <= 2 else { return false }
        let target = words.count == 2 ? words[1] : "~"
        guard target != "-", let path = context.resolve(target) else { return false }
        context.cwd = path
        continue
      }
      if granted.contains("command:" + key(of: words)) { continue }
      guard autoMode,
            segment.writes.allSatisfy({ $0 == "/dev/null" || context.writable($0) }),
            segment.reads.allSatisfy(context.readable),
            judge(words, &context)
      else { return false }
    }
    return true
  }

  /// What "Always Allow" remembers: the program and its subcommand for tools that
  /// have them (`git commit`, `npm test`), the whole line otherwise.
  static func alwaysKey(for line: String) -> String {
    guard let segments = segments(of: line), segments.count == 1,
          segments[0].writes.isEmpty, segments[0].reads.isEmpty,
          let words = stripped(segments[0].words), !words.isEmpty
    else { return "command:" + line }
    let key = key(of: words)
    return "command:" + (key == words.joined(separator: " ") ? line : key)
  }

  /// A path an agent may read without asking in Auto Mode: anything but where
  /// credentials are kept.
  static func isReadable(_ path: String, home: String = NSHomeDirectory()) -> Bool {
    Context(directory: home, home: home, cwd: home).readable(path)
  }

  // MARK: - Reading the line

  private enum Token: Equatable {
    case word(String)
    case op(String)
  }

  static func segments(of line: String) -> [Segment]? {
    guard let tokens = tokens(line) else { return nil }
    var segments: [Segment] = []
    var current = Segment()
    var index = 0
    while index < tokens.count {
      switch tokens[index] {
      case let .word(word):
        current.words.append(word)
      case let .op(op) where [";", "&&", "||", "|", "&"].contains(op):
        if !current.words.isEmpty { segments.append(current) }
        else if !current.writes.isEmpty || !current.reads.isEmpty { return nil }
        current = Segment()
      case let .op(op):
        guard index + 1 < tokens.count, case let .word(target) = tokens[index + 1] else { return nil }
        index += 1
        switch op {
        case "<": current.reads.append(target)
        case ">&": if !(target == "-" || target.allSatisfy(\.isNumber)) { current.writes.append(target) }
        default: current.writes.append(target)
        }
      }
      index += 1
    }
    if !current.words.isEmpty { segments.append(current) }
    else if !current.writes.isEmpty || !current.reads.isEmpty { return nil }
    return segments
  }

  private static func tokens(_ line: String) -> [Token]? {
    let chars = Array(line)
    var tokens: [Token] = []
    var word = ""
    var inWord = false
    var quoted = false
    func flush() {
      if inWord { tokens.append(.word(word)) }
      word = ""
      inWord = false
      quoted = false
    }
    func next(_ offset: Int, _ index: Int) -> Character? {
      index + offset < chars.count ? chars[index + offset] : nil
    }
    var i = 0
    while i < chars.count {
      let c = chars[i]
      switch c {
      case "'":
        guard let end = chars[(i + 1)...].firstIndex(of: "'") else { return nil }
        word += String(chars[(i + 1)..<end])
        inWord = true
        quoted = true
        i = end + 1
        continue
      case "\"":
        var j = i + 1
        while j < chars.count, chars[j] != "\"" {
          if chars[j] == "$" || chars[j] == "`" { return nil }
          if chars[j] == "\\", j + 1 < chars.count { j += 1 }
          word.append(chars[j])
          j += 1
        }
        guard j < chars.count else { return nil }
        inWord = true
        quoted = true
        i = j + 1
        continue
      case "\\":
        guard let escaped = next(1, i) else { return nil }
        if escaped != "\n" {
          word.append(escaped)
          inWord = true
        }
        i += 2
        continue
      case "$", "`", "(", ")", "{", "}":
        return nil
      case "#" where !inWord:
        flush()
        return tokens
      case " ", "\t":
        flush()
      case "\n", ";":
        flush()
        tokens.append(.op(";"))
      case "&":
        flush()
        if next(1, i) == "&" { tokens.append(.op("&&")); i += 1 }
        else if next(1, i) == ">" {
          i += 1
          if next(1, i) == ">" { i += 1 }
          tokens.append(.op(">"))
        } else { tokens.append(.op("&")) }
      case "|":
        flush()
        if next(1, i) == "|" { tokens.append(.op("||")); i += 1 }
        else {
          if next(1, i) == "&" { i += 1 }
          tokens.append(.op("|"))
        }
      case ">":
        if inWord, !quoted, word.allSatisfy(\.isNumber) {
          word = ""
          inWord = false
        } else {
          flush()
        }
        if next(1, i) == ">" { tokens.append(.op(">>")); i += 1 }
        else if next(1, i) == "&" { tokens.append(.op(">&")); i += 1 }
        else if next(1, i) == "|" { tokens.append(.op(">")); i += 1 }
        else { tokens.append(.op(">")) }
      case "<":
        flush()
        guard next(1, i) != "<", next(1, i) != "(", next(1, i) != ">" else { return nil }
        tokens.append(.op("<"))
      default:
        word.append(c)
        inWord = true
      }
      i += 1
    }
    flush()
    return tokens
  }

  /// Drops what only wraps the command (`time`, `timeout 60`, `CI=1`); nil when a
  /// variable could change what runs.
  private static func stripped(_ words: [String]) -> [String]? {
    var words = words[...]
    while let first = words.first {
      if first == "time" { words = words.dropFirst(); continue }
      if first == "timeout" || first == "gtimeout" { words = words.dropFirst(2); continue }
      if let equals = first.firstIndex(of: "="),
         first[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
         first.first?.isLetter == true || first.first == "_" {
        let name = String(first[..<equals])
        if name.hasPrefix("DYLD_") || name.hasPrefix("LD_") || name.hasPrefix("GIT_")
          || riskyVariables.contains(name) { return nil }
        words = words.dropFirst()
        continue
      }
      break
    }
    return Array(words)
  }

  private static let riskyVariables: Set<String> = [
    "PATH", "BASH_ENV", "ENV", "ZDOTDIR", "PAGER", "EDITOR", "VISUAL", "NODE_OPTIONS",
    "PYTHONSTARTUP", "PYTHONPATH", "PERL5OPT", "RUBYOPT", "SHELL", "IFS", "PROMPT_COMMAND",
  ]

  private static let subcommandTools: Set<String> = [
    "git", "npm", "pnpm", "yarn", "bun", "cargo", "go", "swift", "make", "gh", "brew",
    "docker", "kubectl", "xcrun", "uv", "pip", "pip3", "poetry", "deno", "dotnet", "gradle",
    "./gradlew", "mvn", "bundle", "rake", "mix", "flutter", "dart",
  ]

  private static func key(of words: [String]) -> String {
    let program = words[0]
    guard subcommandTools.contains(program),
          let sub = words.dropFirst().first(where: { !$0.hasPrefix("-") })
    else { return words.joined(separator: " ") }
    return program + " " + sub
  }

  // MARK: - Judging a command

  private struct Context {
    let directory: String
    let home: String
    var cwd: String

    func resolve(_ word: String) -> String? {
      if word == "~" { return home }
      if word.hasPrefix("~/") { return standard(home + word.dropFirst(), home: home) }
      if word.hasPrefix("~") { return nil }
      if word.hasPrefix("/") { return standard(word, home: home) }
      return standard(cwd + "/" + word, home: home)
    }

    func inside(_ path: String, _ folder: String) -> Bool {
      path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    func readable(_ word: String) -> Bool {
      guard let path = resolve(word) else { return false }
      return !Self.secrets.contains { inside(path, home + "/" + $0) }
    }

    func writable(_ word: String) -> Bool {
      guard !word.contains(where: { "*?[".contains($0) }),
            let path = resolve(word), inside(path, directory), path != directory
      else { return false }
      let parts = path.dropFirst(directory.count).split(separator: "/")
      if parts.contains(".git") { return false }
      if inside(home, directory), let first = path.dropFirst(home.count).split(separator: "/").first,
         first.hasPrefix(".") || first == "Library" {
        return false
      }
      return true
    }

    var buildsHere: Bool { cwd == directory || inside(cwd, directory) && writable(cwd) }

    static let secrets = [
      ".ssh", ".aws", ".gnupg", ".netrc", ".config/gh", ".kube", ".docker",
      "Library/Keychains", ".password-store", ".local/share/opencode", ".codex/auth.json",
      ".gemini/oauth_creds.json", ".grok/auth.json", ".npmrc", ".pypirc",
    ]
  }

  private static func standard(_ path: String, home: String) -> String? {
    let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
    guard expanded.hasPrefix("/") else { return nil }
    return (expanded as NSString).standardizingPath
  }

  private static func looksLikePath(_ word: String) -> Bool {
    word.hasPrefix("/") || word.hasPrefix("~") || word.hasPrefix(".") || word.contains("/")
  }

  /// Every argument that names a file may be read.
  private static func readsOnly(_ args: ArraySlice<String>, _ context: Context) -> Bool {
    args.allSatisfy { arg in
      let value = arg.hasPrefix("-") ? arg.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) : arg
      guard let value, looksLikePath(value) else { return true }
      return context.readable(value)
    }
  }

  private static func operands(_ args: ArraySlice<String>) -> [String] {
    var result: [String] = []
    var ended = false
    for arg in args {
      if !ended, arg == "--" { ended = true; continue }
      if !ended, arg.hasPrefix("-"), arg != "-" { continue }
      result.append(arg)
    }
    return result
  }

  private static let readers: Set<String> = [
    "ls", "cat", "head", "tail", "wc", "pwd", "echo", "printf", "grep", "egrep", "fgrep",
    "ag", "file", "stat", "du", "df", "which", "whereis", "type", "whoami", "id",
    "hostname", "date", "cal", "uname", "sw_vers", "cut", "tr", "paste", "diff", "cmp",
    "comm", "basename", "dirname", "realpath", "readlink", "jq", "nl", "column",
    "hexdump", "od", "strings", "md5", "md5sum", "shasum", "sha1sum", "sha256sum", "cksum",
    "true", "false", "test", "[", "seq", "sleep", "otool", "nm", "lipo", "mdls", "mdfind",
    "ps", "lsof", "pgrep", "printenv", "fold", "expand", "rev", "look", "tac",
  ]

  private static let systemBins = ["/bin/", "/usr/bin/", "/usr/local/bin/", "/opt/homebrew/bin/", "/usr/sbin/"]

  private static let riskyNames = [
    "deploy", "publish", "release", "upload", "push", "install", "uninstall", "delete",
    "clean", "migrate", "prod", "destroy", "drop", "wipe", "reset",
  ]

  private static func risky(_ name: String) -> Bool {
    let name = name.lowercased()
    return riskyNames.contains { name.contains($0) }
  }

  private static func judge(_ words: [String], _ context: inout Context) -> Bool {
    var program = words[0]
    if program.contains("/"), let bin = systemBins.first(where: { program.hasPrefix($0) }) {
      program = String(program.dropFirst(bin.count))
    }
    let args = words.dropFirst()
    let ops = operands(args)

    if program.contains("/") { return script(program, context) }
    if readers.contains(program) { return readsOnly(args, context) }

    switch program {
    case "sort":
      return !args.contains { $0 == "-o" || $0.hasPrefix("--output") } && readsOnly(args, context)
    case "uniq", "xxd":
      return ops.count <= 1 && readsOnly(args, context)
    case "rg":
      return !args.contains { $0.hasPrefix("--pre") } && readsOnly(args, context)
    case "fd":
      return !args.contains { ["-x", "-X", "--exec", "--exec-batch"].contains($0) } && readsOnly(args, context)
    case "tree":
      return !args.contains("-o") && readsOnly(args, context)
    case "env":
      return args.isEmpty
    case "find":
      let acts: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"]
      return !args.contains(where: acts.contains) && readsOnly(args, context)
    case "sed":
      let inPlace = args.contains { $0 == "-i" || $0.hasPrefix("-i") || $0.hasPrefix("--in-place") }
      let writesOrRuns = #"(^|[;}\s])[we]\b|/[gIpi0-9]*w\s"#
      if args.contains(where: { $0.range(of: writesOrRuns, options: .regularExpression) != nil }) { return false }
      if inPlace { return ops.dropFirst().filter { !$0.isEmpty }.allSatisfy(context.writable) }
      return readsOnly(args, context)
    case "mkdir", "touch", "tee":
      return !ops.isEmpty && ops.allSatisfy(context.writable)
    case "rm", "rmdir", "unlink":
      let recursive = args.contains { arg in
        arg == "--recursive" || (arg.hasPrefix("-") && !arg.hasPrefix("--") && (arg.contains("r") || arg.contains("R")))
      }
      return !recursive && !ops.isEmpty && ops.allSatisfy(context.writable)
    case "cp", "mv", "ln":
      guard ops.count >= 2, !args.contains(where: { $0 == "-t" || $0.hasPrefix("--target") }) else { return false }
      let sources = ops.dropLast()
      let sourcesOK = program == "mv" ? sources.allSatisfy(context.writable) : sources.allSatisfy(context.readable)
      return sourcesOK && context.writable(ops.last!)
    case "chmod":
      guard ops.count >= 2, !ops[0].contains("s") else { return false }
      return ops.dropFirst().allSatisfy(context.writable)
    case "git":
      return git(args, &context)
    case "gh":
      return gh(ops)
    case "brew":
      return ["list", "ls", "info", "search", "--prefix", "config", "doctor", "outdated", "deps", "--version"]
        .contains(ops.first ?? args.first ?? "")
    case "swift":
      guard let sub = ops.first else { return args.allSatisfy { $0 == "--version" } }
      return ["build", "test", "run"].contains(sub) && context.buildsHere
    case "xcodebuild":
      return !args.contains("-exportArchive") && context.buildsHere
    case "make", "gmake":
      return ops.allSatisfy { !risky($0) } && !args.contains("-C") && context.buildsHere
    case "cargo":
      return ["build", "test", "check", "run", "fmt", "clippy", "doc", "bench", "tree", "metadata"]
        .contains(ops.first ?? "") && context.buildsHere
    case "go":
      return ["build", "test", "run", "vet", "fmt", "list", "doc", "env", "version"]
        .contains(ops.first ?? "") && context.buildsHere
    case "npm", "pnpm", "yarn", "bun":
      return packageScript(program, ops, args, context)
    case "python", "python3", "node", "ruby", "deno", "tsx", "ts-node":
      return interpreter(program, args, context)
    case "sh", "bash", "zsh":
      guard let first = args.first, !first.hasPrefix("-") else { return false }
      return script(first, context)
    case "pytest", "jest", "vitest", "tsc", "eslint", "prettier", "black", "ruff", "mypy",
         "swiftformat", "swiftlint", "rubocop", "phpunit", "mocha":
      let fixes = args.contains { $0.hasPrefix("--write") || $0 == "--fix" || $0 == "-w" || $0 == "--in-place" }
      return context.buildsHere
        && ops.allSatisfy { !looksLikePath($0) || (fixes ? context.writable($0) : context.readable($0)) }
    default:
      return false
    }
  }

  private static func script(_ path: String, _ context: Context) -> Bool {
    guard let resolved = context.resolve(path), context.inside(resolved, context.directory),
          context.buildsHere
    else { return false }
    return !risky((resolved as NSString).lastPathComponent)
  }

  private static func interpreter(_ program: String, _ args: ArraySlice<String>, _ context: Context) -> Bool {
    guard context.buildsHere else { return false }
    let modules: Set<String> = ["pytest", "unittest", "mypy", "ruff", "black", "py_compile", "compileall", "json.tool"]
    var rest = args[...]
    while let arg = rest.first, arg.hasPrefix("-") {
      if arg == "-m" {
        guard let module = rest.dropFirst().first else { return false }
        return modules.contains(module)
      }
      if ["--test", "-u", "-B", "-O", "-OO", "-W", "--no-warnings", "run", "--allow-read"].contains(arg)
        || arg.hasPrefix("-W") || arg.hasPrefix("-X") {
        rest = rest.dropFirst()
        continue
      }
      return false
    }
    if program == "deno" {
      guard rest.first == "run" || rest.first == "test" else { return false }
      rest = rest.dropFirst()
      while let arg = rest.first, arg.hasPrefix("-") {
        if arg.hasPrefix("--allow-read") { rest = rest.dropFirst(); continue }
        return false
      }
    }
    guard let file = rest.first else { return false }
    return script(file, context)
  }

  private static func packageScript(
    _ program: String, _ ops: [String], _ args: ArraySlice<String>, _ context: Context
  ) -> Bool {
    guard context.buildsHere, let sub = ops.first else { return false }
    if ["run", "run-script"].contains(sub) {
      guard let name = ops.dropFirst().first else { return false }
      return !risky(name)
    }
    if ["test", "t", "tst", "build", "lint", "start", "dev", "typecheck", "check", "ls", "list", "outdated", "why"]
      .contains(sub) {
      return true
    }
    if program == "bun", looksLikePath(sub) || sub.hasSuffix(".ts") || sub.hasSuffix(".js") {
      return script(sub, context)
    }
    return false
  }

  private static func git(_ args: ArraySlice<String>, _ context: inout Context) -> Bool {
    var rest = args[...]
    while let arg = rest.first, arg.hasPrefix("-") {
      switch arg {
      case "--no-pager", "-P", "--no-optional-locks":
        rest = rest.dropFirst()
      case "-C":
        guard let folder = rest.dropFirst().first, let path = context.resolve(folder) else { return false }
        context.cwd = path
        rest = rest.dropFirst(2)
      default:
        return false
      }
    }
    guard let sub = rest.first else { return false }
    let flags = rest.dropFirst()
    let has: (Set<String>) -> Bool = { set in flags.contains(where: set.contains) }
    switch sub {
    case "status", "diff", "log", "show", "rev-parse", "ls-files", "ls-tree", "blame", "describe",
         "fetch", "grep", "shortlog", "reflog", "cat-file", "merge-base", "rev-list", "check-ignore",
         "show-ref", "whatchanged", "count-objects", "version", "help":
      return !flags.contains { $0.hasPrefix("--output") }
    case "add", "commit", "init":
      return true
    case "branch":
      return !has(["-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy", "-f", "--force"])
    case "switch":
      return !has(["-f", "--force", "--discard-changes", "-C", "--force-create"])
    case "stash":
      return [nil, "push", "list", "show"].contains(flags.first(where: { !$0.hasPrefix("-") }))
    case "remote":
      return flags.allSatisfy { $0 == "-v" || $0 == "--verbose" }
    case "tag":
      return flags.allSatisfy { $0 == "-l" || $0 == "--list" || $0.hasPrefix("--sort") }
    case "config":
      return flags.first.map { ["--get", "--get-all", "--list", "-l", "--get-regexp"].contains($0) } ?? false
    case "worktree":
      return flags.first == "list"
    default:
      return false
    }
  }

  private static func gh(_ ops: [String]) -> Bool {
    guard ops.count >= 2 else { return ops.first == "status" }
    let reads: [String: Set<String>] = [
      "pr": ["view", "list", "status", "diff", "checks"],
      "issue": ["view", "list", "status"],
      "run": ["view", "list", "watch"],
      "repo": ["view", "list"],
      "release": ["view", "list"],
      "workflow": ["view", "list"],
    ]
    return reads[ops[0]]?.contains(ops[1]) ?? false
  }
}
