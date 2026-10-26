import Foundation

enum MascotFinish: String, CaseIterable, Codable, Identifiable, Sendable {
  case velvet
  case fur

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .velvet: "Velvet"
    case .fur: "Fur"
    }
  }
}

struct MascotLook: Equatable, Hashable, Identifiable, Sendable {
  var shape: MascotShape
  var palette: MascotPalette
  var finish: MascotFinish = .velvet

  var id: String { "\(faceID)/\(finish.rawValue)" }

  var faceID: String { "\(shape.rawValue)/\(palette.id)" }

  var displayName: String {
    "\(shape.displayName) · \(palette.displayName) · \(finish.displayName)"
  }

  static func face(for agent: AgentId?, defaults: UserDefaults = .standard) -> MascotLook {
    MascotRoster.load(defaults: defaults).look(for: agent)
  }
}

extension MascotPalette {
  static func face(for agent: AgentId?, defaults: UserDefaults = .standard) -> MascotPalette {
    MascotLook.face(for: agent, defaults: defaults).palette
  }
}

struct MascotSelection: Codable, Equatable, Sendable {
  var shape: String
  var palette: String
  var finish: String?

  init(shape: String, palette: String, finish: String? = nil) {
    self.shape = shape
    self.palette = palette
    self.finish = finish
  }

  init(_ look: MascotLook) {
    shape = look.shape.rawValue
    palette = look.palette.id
    finish = look.finish.rawValue
  }

  func look(fallback: MascotLook) -> MascotLook {
    MascotLook(
      shape: MascotShape(rawValue: shape) ?? fallback.shape,
      palette: MascotPalette.palette(withID: palette) ?? fallback.palette,
      finish: finish.flatMap(MascotFinish.init(rawValue:)) ?? fallback.finish
    )
  }
}

struct MascotRoster: Equatable, Sendable {
  private(set) var selections: [String: MascotSelection]

  let restingAgent: AgentId

  init(selections: [String: MascotSelection] = [:], preferred: AgentId? = nil) {
    self.selections = selections
    restingAgent = preferred.flatMap { AgentId.adapterCases.contains($0) ? $0 : nil }
      ?? AgentHistory.tabOrder.first ?? .claude
  }

  // MARK: - Storage

  static let storageKey = "boltty.mascotByProvider"
  static let legacyPaletteKey = "boltty.mascotPaletteByProvider"

  static func load(defaults: UserDefaults = .standard) -> MascotRoster {
    let preferred = defaults.string(forKey: AppSettings.agentPresetKey).flatMap(AgentId.init(rawValue:))
    if let data = defaults.data(forKey: storageKey),
       let stored = try? JSONDecoder().decode([String: MascotSelection].self, from: data)
    {
      return MascotRoster(selections: stored, preferred: preferred)
    }
    return MascotRoster(selections: migratedSelections(defaults: defaults), preferred: preferred)
  }

  private static func migratedSelections(defaults: UserDefaults) -> [String: MascotSelection] {
    guard let data = defaults.data(forKey: legacyPaletteKey),
          let stored = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    var migrated: [String: MascotSelection] = [:]
    for agent in AgentId.adapterCases {
      guard let id = stored[agent.rawValue],
            id != MascotPalette.standard.id,
            let palette = MascotPalette.palette(withID: id)
      else { continue }
      let shape = defaultLook(for: agent)?.shape ?? .hex
      migrated[agent.rawValue] = MascotSelection(MascotLook(shape: shape, palette: palette))
    }
    return migrated
  }

  // MARK: - What an agent wears

  static func defaultLook(for agent: AgentId) -> MascotLook? {
    let choice: (MascotShape, String)
    switch agent {
    case .claude: choice = (.daisy, "ember")
    case .codex: choice = (.bloom, "slate")
    case .opencode: choice = (.capsule, "lagoon")
    case .grok: choice = (.orb, "citrus")
    case .antigravity: choice = (.triangle, "candy")
    default: return nil
    }
    guard let palette = MascotPalette.palette(withID: choice.1) else { return nil }
    return MascotLook(shape: choice.0, palette: palette)
  }

  func look(for agent: AgentId?) -> MascotLook {
    let agent = agent ?? restingAgent
    return looks()[agent] ?? Self.orphanLook(for: agent)
  }

  func looks() -> [AgentId: MascotLook] {
    var claimed: Set<String> = []
    var result: [AgentId: MascotLook] = [:]
    let agents = AgentId.adapterCases
    for agent in agents {
      guard let selection = selections[agent.rawValue],
            let fallback = Self.defaultLook(for: agent)
      else { continue }
      let chosen = selection.look(fallback: fallback)
      if claimed.insert(chosen.faceID).inserted { result[agent] = chosen }
    }
    for agent in agents where result[agent] == nil {
      guard let preferred = Self.defaultLook(for: agent) else { continue }
      var wanted = preferred
      if let finish = selections[agent.rawValue]?.finish.flatMap(MascotFinish.init(rawValue:)) {
        wanted.finish = finish
      }
      let look = claimed.contains(wanted.faceID) ? Self.nearestFree(to: wanted, claimed: claimed) : wanted
      claimed.insert(look.faceID)
      result[agent] = look
    }
    return result
  }

  private static func nearestFree(to look: MascotLook, claimed: Set<String>) -> MascotLook {
    let shapes = MascotShape.allCases
    let palettes = MascotPalette.catalog
    let shapeStart = shapes.firstIndex(of: look.shape) ?? 0
    let paletteStart = palettes.firstIndex(of: look.palette) ?? 0
    for shapeStep in 0..<shapes.count {
      for paletteStep in 0..<palettes.count {
        let candidate = MascotLook(
          shape: shapes[(shapeStart + shapeStep) % shapes.count],
          palette: palettes[(paletteStart + paletteStep) % palettes.count],
          finish: look.finish
        )
        if !claimed.contains(candidate.faceID) { return candidate }
      }
    }
    return look
  }

  private static func orphanLook(for agent: AgentId) -> MascotLook {
    let pool = MascotPalette.catalog.filter { $0.id != MascotPalette.standard.id }
    let hash = agent.rawValue.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    return MascotLook(shape: .hex, palette: pool[Int(hash % UInt32(pool.count))])
  }

  // MARK: - Choosing

  func owner(of look: MascotLook, besides agent: AgentId) -> AgentId? {
    looks().first { $0.key != agent && $0.value.faceID == look.faceID }?.key
  }

  @discardableResult
  mutating func choose(_ look: MascotLook, for agent: AgentId) -> Bool {
    guard owner(of: look, besides: agent) == nil else { return false }
    selections[agent.rawValue] = MascotSelection(look)
    return true
  }
}
