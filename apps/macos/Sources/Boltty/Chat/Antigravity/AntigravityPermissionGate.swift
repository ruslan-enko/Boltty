import Foundation
import os

/// How Boltty asks before `agy` acts.
///
/// Print mode cannot ask: a tool that needs a permission is refused on the
/// spot. A `PreToolUse` hook can *deny* but cannot *allow* there — `allow` and
/// `permissionOverrides` were both refused (agy 1.3.4). So the
/// process runs with `--dangerously-skip-permissions` and this gate is what
/// decides: the hook hands each call to Boltty and waits for its answer.
///
/// The hook fails closed, measured: a crash, garbage, `{}`, a timeout or a
/// killed hook all block the call. **Exit 0 with nothing on stdout lets it
/// through**, which is why the script checks the answer file is not empty
/// and exits 1 on anything it does not understand.
///
/// The hook lives in the person's `~/.gemini/config/hooks.json` under one
/// named key, and outside Boltty it answers `ask`, which leaves `agy` to its
/// own rules (measured: a read went through with and without it).
final class AntigravityPermissionGate: @unchecked Sendable {
  static let hookName = "boltty-permission-gate"
  static let environmentKey = "BOLTTY_AGY_GATE"
  /// `agy` kills a hook past its `timeout`; the script gives up a little
  /// sooner, and Boltty puts the card away sooner still.
  static let hookTimeout = 900
  static let scriptPatience: TimeInterval = 870
  static let cardLifetime: TimeInterval = 840

  struct Request: Sendable {
    let id: String
    let conversationID: String
    let tool: String
    let arguments: JSONObject
    /// The folder `agy` works in, as the hook was told it.
    let workspace: String?
  }

  let directory: URL
  private let lock = NSLock()
  private var source: DispatchSourceFileSystemObject?
  private var seen: Set<String> = []
  private let queue = DispatchQueue(label: "com.boltty.antigravity-gate")
  private let log = Logger(subsystem: "com.boltty", category: "antigravity-gate")
  var onRequest: (@Sendable (Request) -> Void)?

  init(directory: URL) {
    self.directory = directory
  }

  /// Makes the hand-over folder and starts watching it.
  func start() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else {
      throw AgentClientError.transport("Boltty could not watch \(directory.path).")
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write], queue: queue
    )
    source.setEventHandler { [weak self] in self?.scan() }
    source.setCancelHandler { close(descriptor) }
    lock.withLock { self.source = source }
    source.resume()
    queue.async { [weak self] in self?.scan() }
  }

  func stop() {
    lock.withLock { source }?.cancel()
    try? FileManager.default.removeItem(at: directory)
  }

  /// Writes the hook's answer. Atomic, so the script never reads half a file.
  func answer(_ id: String, decision: String, reason: String? = nil) {
    var body: [String: Any] = ["decision": decision]
    if let reason, !reason.isEmpty { body["reason"] = reason }
    guard let text = JSONObject.encode(body) else { return }
    let target = directory.appendingPathComponent("\(id).ans")
    let temporary = directory.appendingPathComponent("\(id).ans.tmp")
    do {
      try Data(text.utf8).write(to: temporary)
      try FileManager.default.moveItem(at: temporary, to: target)
    } catch {
      log.error("could not answer \(id, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }

  private func scan() {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
    for name in names where name.hasSuffix(".req") {
      let id = String(name.dropLast(4))
      guard lock.withLock({ seen.insert(id).inserted }) else { continue }
      let file = directory.appendingPathComponent(name)
      defer { try? FileManager.default.removeItem(at: file) }
      guard let data = try? Data(contentsOf: file), let payload = JSONObject(line: data) else {
        answer(id, decision: "deny", reason: "Boltty could not read this request.")
        continue
      }
      let call = payload.object("toolCall")
      onRequest?(Request(
        id: id,
        conversationID: payload.string("conversationId") ?? "",
        tool: call?.string("name") ?? "",
        arguments: call?.object("args") ?? JSONObject([:]),
        workspace: payload.strings("workspacePaths").first
      ))
    }
  }

  // MARK: - The hook

  static var defaultHooksFile: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/config/hooks.json")
  }

  static var defaultScriptFile: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Boltty/antigravity-permission-gate.sh")
  }

  static let script = """
    #!/bin/sh
    # Boltty's permission gate for Antigravity (agy), installed by Boltty.
    # Outside Boltty it has no opinion, and agy decides as it always does.
    if [ -z "$\(environmentKey)" ] || [ ! -d "$\(environmentKey)" ]; then
      cat >/dev/null
      echo '{"decision":"ask"}'
      exit 0
    fi
    id="$$-$(date +%s)"
    cat > "$\(environmentKey)/$id.tmp" || exit 1
    mv "$\(environmentKey)/$id.tmp" "$\(environmentKey)/$id.req" || exit 1
    answer="$\(environmentKey)/$id.ans"
    waited=0
    while [ ! -f "$answer" ]; do
      [ -d "$\(environmentKey)" ] || exit 1
      waited=$((waited + 1))
      [ "$waited" -gt \(Int(scriptPatience * 5)) ] && exit 1
      sleep 0.2
    done
    # Exit 0 with nothing on stdout would let the call through.
    [ -s "$answer" ] || exit 1
    cat "$answer" || exit 1
    rm -f "$answer"
    exit 0
    """

  /// Puts the script in Application Support and Boltty's key in `hooks.json`,
  /// leaving every other key as it was. A `hooks.json` that is not plain JSON
  /// is not touched: the gate is then unavailable and `agy` runs as before.
  static func install(hooksFile: URL = defaultHooksFile, scriptFile: URL = defaultScriptFile) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: scriptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? String(contentsOf: scriptFile, encoding: .utf8)) != script {
      try script.write(to: scriptFile, atomically: true, encoding: .utf8)
    }
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)

    var hooks: [String: Any] = [:]
    if manager.fileExists(atPath: hooksFile.path) {
      let data = try Data(contentsOf: hooksFile)
      if !data.isEmpty {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          throw AgentClientError.transport(
            "\(hooksFile.path) is not plain JSON, so Boltty left it alone."
          )
        }
        hooks = parsed
      }
    }
    let entry: [String: Any] = [
      "PreToolUse": [[
        "matcher": "*",
        "hooks": [[
          "type": "command",
          "command": "/bin/sh '\(scriptFile.path)'",
          "timeout": hookTimeout,
        ]],
      ]],
    ]
    if let current = hooks[hookName], NSDictionary(dictionary: ["k": current])
      .isEqual(to: ["k": entry]) {
      return
    }
    hooks[hookName] = entry
    try manager.createDirectory(at: hooksFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: hooksFile, options: .atomic)
  }
}

/// What a call needs before it runs: nothing, or the person.
enum AntigravityToolPolicy {
  enum Verdict: Equatable {
    case allow
    case ask(action: String, resources: [String], always: String)
  }

  /// Reads and the agent's own bookkeeping: they change nothing. `read_file`
  /// is what `agy` 1.4 opens a picture with — not `view_file` — and, missing
  /// here, every Ask Boltty screenshot asked and a read-only chat refused it.
  static let quiet: Set<String> = [
    "view_file", "read_file", "view_file_outline", "view_code_item", "list_dir",
    "list_directory", "find_by_name", "file_search", "grep_search", "search_web",
    "read_url_content",
    "read_resource", "list_resources", "list_permissions", "list_plugin_accounts",
    "command_status", "finish", "wait", "wait_5_seconds", "manage_task", "schedule",
    "ask_permission", "ask_custom_permission", "ask_question", "send_message", "manage_inbox",
    "define_subagent", "invoke_subagent", "manage_subagents", "search_marketplace",
    "generate_image", "list_browser_pages", "read_browser_page", "browser_get_dom",
    "browser_get_network_request", "browser_list_network_requests",
    "capture_browser_console_logs", "capture_browser_screenshot",
  ]

  static let edits: Set<String> = [
    "write_to_file", "replace_file_content", "multi_replace_file_content", "sed_file",
    "notebook_edit",
  ]

  static func verdict(
    tool: String,
    arguments: JSONObject,
    directory: String,
    autoApprove: Bool,
    granted: Set<String>
  ) -> Verdict {
    let paths = absolutePaths(in: arguments)
    let outside = paths.filter { !inside($0, directory) && !inside($0, agentHome) }

    if quiet.contains(tool) {
      guard let path = outside.first(where: { !granted.contains(readKey($0)) }) else { return .allow }
      return .ask(action: "read", resources: [path], always: readKey(path))
    }
    if edits.contains(tool) {
      let target = arguments.string("TargetFile") ?? paths.first
      if autoApprove, outside.isEmpty { return .allow }
      return granted.contains("edit") && outside.isEmpty
        ? .allow
        : .ask(action: "edit", resources: target.map { [$0] } ?? [], always: "edit")
    }
    if tool == "run_command" || tool == "send_command_input" {
      let command = arguments.string("CommandLine") ?? arguments.string("Input") ?? tool
      let key = "command:\(command)"
      return granted.contains(key) ? .allow : .ask(action: "command", resources: [command], always: key)
    }
    return granted.contains(tool) ? .allow : .ask(action: tool, resources: paths, always: tool)
  }

  static func readKey(_ path: String) -> String {
    "read:" + (path as NSString).standardizingPath
  }

  /// A file the person sent is theirs to show the agent: `agy` takes no
  /// picture in its input (1.4.0 ends the run on an `image` block) and opens
  /// one only with `view_file`, so the copy Boltty made of it, outside the
  /// chat's folder, is read without a card.
  static func readGrants(for attachments: [OutgoingAttachment]) -> Set<String> {
    Set(attachments.filter(\.url.isFileURL).map { readKey($0.url.path) })
  }

  private static var agentHome: String {
    NSHomeDirectory() + "/.gemini/antigravity-cli"
  }

  private static func inside(_ path: String, _ folder: String) -> Bool {
    let folder = (folder as NSString).standardizingPath
    let path = (path as NSString).standardizingPath
    return path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
  }

  private static func absolutePaths(in arguments: JSONObject) -> [String] {
    arguments.raw.keys.sorted().compactMap { key in
      guard key != "Cwd", let value = arguments.string(key) else { return nil }
      let path = value.hasPrefix("file://") ? String(value.dropFirst(7)) : value
      return path.hasPrefix("/") && !path.contains("\n") ? path : nil
    }
  }
}
