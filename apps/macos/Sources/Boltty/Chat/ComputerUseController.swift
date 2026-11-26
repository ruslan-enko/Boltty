import AppKit
import Carbon
import Combine

@MainActor
final class ComputerUseController {
  private let server = ComputerUseServer()
  private let mac = MacControl()
  private let engine: ConversationEngine
  private let store: ConversationStore
  private let stopTurn: (UUID) async -> Void
  private let indicator = ComputerUseIndicator()
  private var holder: (id: UUID, app: MacApp)?
  private var holdsEscape = false
  private var panelIsUp = false
  private var turnGrants: [UUID: Set<String>] = [:]
  private var chatGrants: [UUID: Set<String>] = [:]
  private var stopped: Set<UUID> = []
  private var cancellable: AnyCancellable?
  private lazy var escapeKey = GlobalHotkeyService(number: 3) { [weak self] in
    MainActor.assumeIsolated { self?.escapePressed() }
  }

  nonisolated static let notOn = "Computer Use is not on in this chat. The person turns it on by writing @computer in a request."

  init(engine: ConversationEngine, store: ConversationStore, stopTurn: @escaping (UUID) async -> Void) {
    self.engine = engine
    self.store = store
    self.stopTurn = stopTurn
    // A second Boltty runs nothing: its sockets would take the first one's place.
    guard !store.isReadOnly else { return }
    server.handler = { [weak self] caller, tool, arguments in
      guard let self else { return .refusal("Boltty is closing.") }
      guard let id = await self.chat(of: caller) else { return .refusal(Self.notOn) }
      return await self.handle(tool, arguments: arguments, in: id)
    }
    engine.computerUseEndpoint = { [weak self] id in self?.server.endpoint(for: id) }
    ComputerUseServer.openCodeSocket = server.sharedEndpoint(AgentId.opencode.rawValue)
    cancellable = store.$conversations
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.letGoOfEndedTurns() }
  }

  func shutDown() {
    letGo()
    server.close()
  }

  func setPanelVisible(_ visible: Bool) {
    panelIsUp = visible
    syncEscape()
  }

  private func handle(_ tool: String, arguments: JSONObject, in id: UUID) async -> ComputerUseResult {
    if let refusal = refusal(for: id) { return .refusal(refusal) }
    if tool == "list_apps" { return listApps() }

    guard let wanted = arguments.string("app"), !wanted.isEmpty else {
      return .refusal("Name the app: its name or bundle id.")
    }
    var app = MacControl.find(wanted)
    if tool == "open_app" || app == nil {
      guard let url = await Task.detached(operation: { MacControl.applicationURL(named: wanted) }).value else {
        return .refusal("There is no app called \(wanted) on this Mac. list_apps names the running ones.")
      }
      let probe = MacApp(pid: 0, name: url.deletingPathExtension().lastPathComponent, bundleID: MacControl.bundleID(of: url))
      if let refused = refusedApp(probe) { return .refusal(refused) }
      if let refused = await mayUse(probe, in: id) { return .refusal(refused) }
      do {
        app = try await MacControl.open(url)
      } catch {
        return .refusal("\(probe.name) did not open: \(error.localizedDescription)")
      }
    }
    guard let app else { return .refusal("\(wanted) is not running.") }
    if let refused = refusedApp(app) { return .refusal(refused) }
    if let refused = await mayUse(app, in: id) { return .refusal(refused) }
    if let refusal = refusal(for: id) { return .refusal(refusal) }
    take(for: id, app: app)

    do {
      let done: String
      switch tool {
      case "open_app", "get_app_state":
        let reading = await mac.read(app)
        return ComputerUseResult(text: reading.text, picture: reading.picture)
      case "click":
        done = try await mac.click(
          app, element: arguments.int("element"), at: Self.point(in: arguments),
          right: arguments.string("button") == "right", count: arguments.int("count") ?? 1)
      case "type_text":
        done = try await mac.type(app, text: arguments.string("text") ?? "", into: arguments.int("element"))
      case "set_value":
        guard let element = arguments.int("element") else { return .refusal("Give the element's index.") }
        done = try await mac.setValue(app, element: element, value: arguments.rendered("value") ?? "")
      case "press_key":
        done = try await mac.press(app, keys: arguments.string("key") ?? "")
      case "scroll":
        done = try await mac.scroll(
          app, element: arguments.int("element"), at: Self.point(in: arguments),
          direction: arguments.string("direction") ?? "down", amount: arguments.int("amount") ?? 1)
      default:
        return .refusal("Boltty has no tool called \(tool).")
      }
      try? await Task.sleep(for: .seconds(MacControl.settle))
      let reading = await mac.read(app)
      return ComputerUseResult(text: done + "\n\n" + reading.text, picture: reading.picture)
    } catch let MacControlError.refused(reason) {
      return .refusal(reason)
    } catch {
      return .refusal(error.localizedDescription)
    }
  }

  private static func point(in arguments: JSONObject) -> CGPoint? {
    guard let x = arguments.double("x"), let y = arguments.double("y") else { return nil }
    return CGPoint(x: x, y: y)
  }

  private func listApps() -> ComputerUseResult {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let lines = MacControl.runningApps().map { app in
      var line = "\(app.name)"
      if let bundle = app.bundleID { line += " (\(bundle))" }
      if app.pid == front { line += " — in front" }
      if MacControl.isRefused(app.bundleID) { line += " — not allowed" }
      return line
    }
    return ComputerUseResult(text: "Running apps:\n" + lines.joined(separator: "\n"))
  }

  // OpenCode's server runs every chat and gives each the tool, so a call is the chat its `_meta`
  // names; with no chat named, only when that agent runs one request at all.
  private func chat(of caller: ComputerUseServer.Caller) -> UUID? {
    switch caller {
    case let .chat(id):
      return id
    case let .shared(providerID, meta):
      let chats = store.conversations.filter { $0.providerID == providerID }
      let named = Self.strings(in: meta.raw)
      if let match = chats.first(where: { $0.remoteSessionID.map(named.contains) == true }) { return match.id }
      let running = chats.filter { store.isRunning($0.id) }
      return running.count == 1 ? running[0].id : nil
    }
  }

  private static func strings(in value: Any, depth: Int = 0) -> Set<String> {
    guard depth < 4 else { return [] }
    if let text = value as? String { return [text] }
    if let object = value as? [String: Any] {
      return object.values.reduce(into: Set<String>()) { $0.formUnion(strings(in: $1, depth: depth + 1)) }
    }
    if let list = value as? [Any] {
      return list.reduce(into: Set<String>()) { $0.formUnion(strings(in: $1, depth: depth + 1)) }
    }
    return []
  }

  private func refusal(for id: UUID) -> String? {
    guard let conversation = store.conversation(id: id), conversation.computerUse,
          engine.mayUseComputer(conversation)
    else { return Self.notOn }
    guard MacControl.isTrusted else {
      MacControl.askForTrust()
      return "Boltty may not control this Mac yet. Ask the person to turn Boltty on in System Settings › Privacy & Security › Accessibility, then try again."
    }
    guard store.isRunning(id) else {
      return "Computer Use works only while one of the person's requests is running."
    }
    if stopped.contains(id) { return "The person stopped Computer Use for this request (Escape). Do not try again; say what is left." }
    if let holder, holder.id != id, store.isRunning(holder.id) {
      return "Another chat is using the Mac. Try again when it is done."
    }
    return nil
  }

  private func refusedApp(_ app: MacApp) -> String? {
    guard MacControl.isRefused(app.bundleID) else { return nil }
    return "Boltty does not let Computer Use into \(app.name): terminals, password managers, System Settings and Boltty itself stay the person's."
  }

  private func mayUse(_ app: MacApp, in id: UUID) async -> String? {
    if turnGrants[id]?.contains(app.key) == true || chatGrants[id]?.contains(app.key) == true { return nil }
    let agent = agent(of: id)
    let prompt = PermissionPrompt(
      action: String(localized: "Computer Use"),
      resources: [agent.map { String(localized: "Allow \($0) to use “\(app.name)”?") }
        ?? String(localized: "Allow the agent to use “\(app.name)”?")],
      savePatterns: [],
      toolCallID: nil,
      offersAlways: true)
    let answer = await engine.ask(prompt, in: id)
    switch answer?.decision {
    case .once:
      turnGrants[id, default: []].insert(app.key)
      return nil
    case .always:
      chatGrants[id, default: []].insert(app.key)
      return nil
    case .reject, nil:
      var refusal = "The person did not allow using \(app.name). Do not try it again in this request."
      if let words = answer?.words?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
        refusal += " They said: \(words)"
      }
      return refusal
    }
  }

  private func agent(of id: UUID) -> String? {
    store.conversation(id: id).flatMap { AgentId(rawValue: $0.providerID) }?.shortDisplayName
  }

  private func take(for id: UUID, app: MacApp) {
    holder = (id, app)
    syncEscape()
  }

  private func syncEscape() {
    let wanted = holder != nil && !panelIsUp
    if wanted != holdsEscape {
      if wanted {
        holdsEscape = escapeKey.register(HotkeyBinding(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)).isFree
      } else {
        escapeKey.stop()
        holdsEscape = false
      }
    }
    guard let holder else { return indicator.hide() }
    let words = agent(of: holder.id).map { String(localized: "\($0) is using \(holder.app.name)") }
      ?? String(localized: "The agent is using \(holder.app.name)")
    indicator.show(words: words, stops: holdsEscape)
  }

  private func letGo() {
    holder = nil
    syncEscape()
  }

  private func escapePressed() {
    guard let holder else { return }
    stopped.insert(holder.id)
    letGo()
    Task { [stopTurn] in await stopTurn(holder.id) }
  }

  private func letGoOfEndedTurns() {
    for id in turnGrants.keys where !store.isRunning(id) { turnGrants[id] = nil }
    stopped = stopped.filter(store.isRunning)
    chatGrants = chatGrants.filter { store.conversation(id: $0.key) != nil }
    if let holder, !store.isRunning(holder.id) { letGo() }
  }
}
