import Foundation
import os

enum AntigravityComputerUse {
  static let environmentKey = "BOLTTY_COMPUTER_USE"
  static let pluginName = "boltty"
  static let server = "computer"
  static var serverName: String { "\(pluginName)_\(server)" }

  private static let log = Logger(subsystem: "com.boltty", category: "antigravity-computer-use")
  private static let installed = OSAllocatedUnfairLock(initialState: false)

  static var pluginFolder: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/config/plugins/\(pluginName)")
  }

  static var scriptFile: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Boltty/computer-use-bridge.sh")
  }

  static func installIfNeeded() {
    guard installed.withLock({ was in defer { was = true }; return !was }) else { return }
    do {
      try write(script, to: scriptFile, executable: true)
      let manifest: [String: Any] = [
        "name": pluginName, "displayName": "Boltty",
        "description": "Boltty's Computer Use. It offers tools only in chats Boltty runs.",
      ]
      let servers: [String: Any] = ["mcpServers": [server: ["command": scriptFile.path, "args": [String]()]]]
      try write(JSONObject.encode(manifest) ?? "{}", to: pluginFolder.appendingPathComponent("plugin.json"))
      try write(JSONObject.encode(servers) ?? "{}", to: pluginFolder.appendingPathComponent("mcp_config.json"))
    } catch {
      installed.withLock { $0 = false }
      log.error("could not install the plugin: \(String(describing: error), privacy: .public)")
    }
  }

  private static func write(_ text: String, to url: URL, executable: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? String(contentsOf: url, encoding: .utf8)) != text {
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    if executable {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
  }

  static let script = """
    #!/bin/sh
    # Boltty's Computer Use for Antigravity (agy), installed by Boltty.
    # In a chat Boltty runs it joins Boltty; anywhere else it offers no tools.
    if [ -n "$\(environmentKey)" ] && [ -S "$\(environmentKey)" ]; then
      exec /usr/bin/nc -U "$\(environmentKey)"
    fi
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*("[^"]*"|[0-9]+).*/\\1/p')
      [ -n "$id" ] || continue
      case "$line" in
        *'"initialize"'*)
          version=$(printf '%s' "$line" | sed -nE 's/.*"protocolVersion"[[:space:]]*:[[:space:]]*"([^"]*)".*/\\1/p')
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"%s","capabilities":{"tools":{}},"serverInfo":{"name":"Boltty","version":"1"}}}\\n' "$id" "${version:-2025-06-18}" ;;
        *'"tools/list"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[]}}\\n' "$id" ;;
        *)
          printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Boltty is not running this chat."}}\\n' "$id" ;;
      esac
    done
    """
}
