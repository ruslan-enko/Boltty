import Foundation
import os

/// Print mode cannot ask, and a `PreToolUse` hook can deny but not allow, so the
/// process runs with `--dangerously-skip-permissions` and this gate decides every
/// call. The hook fails closed.
final class AntigravityPermissionGate: @unchecked Sendable {
  static let hookName = "boltty-permission-gate"
  static let environmentKey = "BOLTTY_AGY_GATE"
  static let hookTimeout = 900
  static let scriptPatience: TimeInterval = 870
  static let cardLifetime: TimeInterval = 840

  struct Request: Sendable {
    let id: String
    let conversationID: String
    let tool: String
    let arguments: JSONObject
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

enum AntigravityToolPolicy {
  enum Verdict: Equatable {
    case allow
    case ask(action: String, resources: [String], always: String)
  }

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
    let paths = absolutePaths(in: arguments, base: arguments.string("Cwd") ?? directory)
    let outside = paths.filter { !inside($0, directory) && !inside($0, agentHome) }

    if quiet.contains(tool) {
      guard let path = outside.first(where: {
        !granted.contains(readKey($0)) && !(autoApprove && AutoModeCommands.isReadable($0))
      }) else { return .allow }
      return .ask(action: "read", resources: [path], always: readKey(path))
    }
    if edits.contains(tool) {
      let target = arguments.string("TargetFile") ?? paths.first
      if autoApprove, outside.isEmpty { return .allow }
      return granted.contains("edit") && outside.isEmpty
        ? .allow
        : .ask(action: "edit", resources: target.map { [$0] } ?? [], always: "edit")
    }
    if tool == "run_command" {
      let command = arguments.string("CommandLine") ?? tool
      if granted.contains("command:\(command)")
        || AutoModeCommands.allows(
          command, in: directory, cwd: arguments.string("Cwd"), autoMode: autoApprove, granted: granted
        ) {
        return .allow
      }
      return .ask(action: "command", resources: [command], always: AutoModeCommands.alwaysKey(for: command))
    }
    if tool == "send_command_input" {
      let input = arguments.string("Input") ?? tool
      let key = "command:\(input)"
      return granted.contains(key) ? .allow : .ask(action: "command", resources: [input], always: key)
    }
    return granted.contains(tool) ? .allow : .ask(action: tool, resources: paths, always: tool)
  }

  static func readKey(_ path: String) -> String {
    "read:" + (path as NSString).standardizingPath
  }

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

  /// `~/x` and `../x` are read too: taken as plain words they counted as inside
  /// the folder, and Auto Mode let them through.
  static func absolutePaths(in arguments: JSONObject, base: String) -> [String] {
    arguments.raw.keys.sorted().compactMap { key in
      guard key != "Cwd", let value = arguments.string(key) else { return nil }
      let path = value.hasPrefix("file://") ? String(value.dropFirst(7)) : value
      guard !path.contains("\n") else { return nil }
      if path.hasPrefix("/") { return path }
      if path == "~" || path.hasPrefix("~/") { return (path as NSString).expandingTildeInPath }
      if path == ".." || path.hasPrefix("../") || path.contains("/../") || path.hasSuffix("/..") {
        return ((base as NSString).appendingPathComponent(path) as NSString).standardizingPath
      }
      return nil
    }
  }
}
