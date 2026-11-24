import Foundation

/// Runs an agent's own installer, as its site tells people to, when the person asks.
@MainActor
final class AgentInstaller: ObservableObject {
  enum State: Equatable {
    case installing
    case failed(String)
  }

  struct Recipe: Equatable {
    let script: URL
    let shell: String

    var command: String {
      "curl -fsSL \(script.absoluteString) | \((shell as NSString).lastPathComponent)"
    }
  }

  typealias Fetch = @Sendable (URL) async throws -> String
  typealias Run = @Sendable (Recipe, String) async -> OneShotCommand.Result?
  typealias Locate = @Sendable (String) async -> Bool

  @Published private(set) var states: [AgentId: State] = [:]

  private let fetch: Fetch
  private let run: Run
  private let locate: Locate

  nonisolated static let deadline: TimeInterval = 600

  init(
    fetch: @escaping Fetch = AgentInstaller.download,
    run: @escaping Run = AgentInstaller.execute,
    locate: @escaping Locate = AgentInstaller.isHere
  ) {
    self.fetch = fetch
    self.run = run
    self.locate = locate
  }

  nonisolated static func recipe(for agent: AgentId) -> Recipe? {
    switch agent {
    case .claude: Recipe(script: URL(string: "https://claude.ai/install.sh")!, shell: "/bin/bash")
    case .codex: Recipe(script: URL(string: "https://chatgpt.com/codex/install.sh")!, shell: "/bin/sh")
    case .grok: Recipe(script: URL(string: "https://x.ai/cli/install.sh")!, shell: "/bin/bash")
    case .antigravity: Recipe(script: URL(string: "https://antigravity.google/cli/install.sh")!, shell: "/bin/bash")
    // The address without v2 installs OpenCode 1.
    case .opencode: Recipe(script: URL(string: "https://opencode.ai/v2/install")!, shell: "/bin/bash")
    default: nil
    }
  }

  func isInstalling(_ agent: AgentId) -> Bool { states[agent] == .installing }

  /// `then` finds the agent before the installing state goes, so its button does
  /// not come back for a moment.
  func install(_ agent: AgentId, then: @MainActor () async -> Void) async {
    guard !isInstalling(agent), let recipe = Self.recipe(for: agent) else { return }
    states[agent] = .installing
    if let failure = await attempt(agent, recipe) {
      states[agent] = .failed(failure)
      return
    }
    await then()
    states[agent] = nil
  }

  private func attempt(_ agent: AgentId, _ recipe: Recipe) async -> String? {
    let script: String
    do {
      script = try await fetch(recipe.script)
    } catch {
      return error.localizedDescription
    }
    guard let result = await run(recipe, script) else {
      return String(localized: "The installer took too long.")
    }
    guard result.exitCode == 0 else {
      return Self.lastLine(of: result.output)
        ?? String(localized: "The installer failed.")
    }
    guard await locate(agent.program) else {
      return String(localized: "The installer finished, but \(agent.displayName) was not found.")
    }
    return nil
  }

  nonisolated static func lastLine(of output: String) -> String? {
    output
      .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
      .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .last { !$0.isEmpty }
      .map { String($0.prefix(200)) }
  }

  nonisolated static func download(_ url: URL) async throws -> String {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    let script = String(decoding: data, as: UTF8.self)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
          response.url?.scheme == "https", script.hasPrefix("#!")
    else { throw URLError(.badServerResponse) }
    return script
  }

  /// The person's own PATH, not the widened one: an installer adds its folder to
  /// the shell's profile only when PATH does not already hold it.
  nonisolated static func execute(_ recipe: Recipe, script: String) async -> OneShotCommand.Result? {
    await OneShotCommand.run(
      recipe.shell, ["-s"], deadline: deadline, includeStandardError: true,
      searchPath: false, input: script,
      directory: FileManager.default.homeDirectoryForCurrentUser
    )
  }

  nonisolated static func isHere(_ program: String) async -> Bool {
    await Task.detached { JSONLineProcess.locate(program) != nil }.value
  }
}
