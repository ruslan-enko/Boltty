import XCTest
@testable import Boltty

final class MascotRosterTests: XCTestCase {
  private func palette(_ id: String) -> MascotPalette {
    MascotPalette.palette(withID: id)!
  }

  private func defaults(legacy: [String: String]? = nil, stored: [String: MascotSelection]? = nil) -> UserDefaults {
    let defaults = isolatedDefaults("boltty.tests.roster")
    if let legacy {
      defaults.set(try! JSONEncoder().encode(legacy), forKey: MascotRoster.legacyPaletteKey)
    }
    if let stored {
      defaults.set(try! JSONEncoder().encode(stored), forKey: MascotRoster.storageKey)
    }
    return defaults
  }

  // MARK: - What an agent wears when nobody chose

  func testTheShapeCatalogMatchesTheSixReferenceOutlines() {
    XCTAssertEqual(
      MascotShape.allCases.map(\.rawValue),
      ["bloom", "capsule", "daisy", "hex", "orb", "triangle"]
    )
    XCTAssertEqual(Set(MascotShape.allCases.map { $0.shaderID.rawValue }).count, 6)
  }

  func testEveryAdapterHasADefaultLookOfItsOwn() {
    let looks = AgentId.adapterCases.map { MascotRoster().look(for: $0) }
    XCTAssertEqual(Set(looks).count, looks.count, "no two agents look alike")
    XCTAssertEqual(
      Set(looks.map(\.shape)).count, looks.count,
      "and no two even share an outline, so they differ before the colour is read"
    )
    XCTAssertEqual(
      Set(looks.map(\.palette.id)).count, looks.count, "nor a gradient"
    )
    XCTAssertFalse(
      looks.contains { $0.palette.id == MascotPalette.standard.id },
      "and nobody opens on Daybreak"
    )
  }

  func testTheDefaultGradientsAllComeFromTheReferenceCatalog() {
    let roster = MascotRoster()
    XCTAssertEqual(roster.look(for: .claude).palette.id, "ember")
    XCTAssertEqual(roster.look(for: .codex).palette.id, "slate")
    XCTAssertEqual(roster.look(for: .opencode).palette.id, "lagoon")
    XCTAssertEqual(roster.look(for: .grok).palette.id, "citrus")
    for agent in AgentId.adapterCases {
      XCTAssertTrue(MascotPalette.catalog.contains(roster.look(for: agent).palette))
    }
  }

  func testARetiredGradientStaysChosenAcrossSettingsLoadsAndSaves() throws {
    let choice = MascotSelection(shape: "orb", palette: "abyss")
    let stored = defaults(stored: ["grok": choice])
    let original = try XCTUnwrap(stored.data(forKey: MascotRoster.storageKey))
    XCTAssertEqual(MascotRoster.load(defaults: stored).look(for: .grok).palette.id, "abyss")
    XCTAssertEqual(stored.data(forKey: MascotRoster.storageKey), original, "reading never rewrites")

    let settings = AppSettings.load(defaults: stored)
    settings.save(defaults: stored)
    XCTAssertEqual(AppSettings.load(defaults: stored).mascotSelections["grok"], choice)
    XCTAssertEqual(MascotRoster.load(defaults: stored).look(for: .grok).palette.id, "abyss")
  }

  func testTheDefaultShapesAllComeFromTheReferenceCatalog() {
    let roster = MascotRoster()
    XCTAssertEqual(roster.look(for: .claude).shape, .daisy)
    XCTAssertEqual(roster.look(for: .codex).shape, .bloom)
    XCTAssertEqual(roster.look(for: .opencode).shape, .capsule)
    XCTAssertEqual(roster.look(for: .grok).shape, .orb)
  }

  func testNoAgentWearsThePreferredAgentsFace() {
    XCTAssertEqual(MascotRoster().look(for: nil), MascotRoster().look(for: .claude))
    let roster = MascotRoster(preferred: .grok)
    XCTAssertEqual(roster.look(for: nil), roster.look(for: .grok))
    XCTAssertEqual(MascotRoster(preferred: .custom).restingAgent, .claude, "not an adapter: the first tab")

    let defaults = defaults()
    defaults.set(AgentId.codex.rawValue, forKey: AppSettings.agentPresetKey)
    XCTAssertEqual(MascotLook.face(for: nil, defaults: defaults), MascotLook.face(for: .codex, defaults: defaults))
  }

  func testThePreferredAgentIsNotSpecial() throws {
    let defaults = defaults()
    defaults.set(AgentId.opencode.rawValue, forKey: AppSettings.agentPresetKey)
    XCTAssertNotEqual(MascotLook.face(for: .opencode, defaults: defaults).palette.id, "daybreak")
  }

  // MARK: - What was chosen

  func testAChoiceIsWhatTheAgentWears() {
    var roster = MascotRoster()
    let look = MascotLook(shape: .triangle, palette: palette("aurora"))
    XCTAssertTrue(roster.choose(look, for: .codex))
    XCTAssertEqual(roster.look(for: .codex), look)
    XCTAssertEqual(roster.look(for: .claude), MascotRoster().look(for: .claude), "nobody else moved")
  }

  func testAChoiceSurvivesStorage() throws {
    var roster = MascotRoster()
    let look = MascotLook(shape: .capsule, palette: palette("solar"))
    roster.choose(look, for: .grok)
    let stored = defaults(stored: roster.selections)
    XCTAssertEqual(MascotRoster.load(defaults: stored).look(for: .grok), look)
  }

  func testTheOtherHalfOfAChoiceFallsBackWhenItNamesSomethingGone() {
    let stored = MascotRoster(selections: [
      "codex": MascotSelection(shape: "no-such-shape", palette: "aurora"),
      "grok": MascotSelection(shape: "triangle", palette: "no-such-gradient"),
    ])
    let codex = stored.look(for: .codex)
    XCTAssertEqual(codex.shape, MascotRoster.defaultLook(for: .codex)?.shape, "the shape is the default's")
    XCTAssertEqual(codex.palette.id, "aurora", "and the gradient is the choice")
    let grok = stored.look(for: .grok)
    XCTAssertEqual(grok.shape, .triangle)
    XCTAssertEqual(grok.palette.id, MascotRoster.defaultLook(for: .grok)?.palette.id)
  }

  func testEveryRetiredShapeFallsBackWithoutLosingItsPaletteOrStoredName() throws {
    for retired in ["tile", "gem", "star", "ghost", "cub", "cloud"] {
      XCTAssertNil(MascotShape(rawValue: retired), "retired outline \(retired) is not selectable")
      for agent in AgentId.adapterCases {
        let selection = MascotSelection(shape: retired, palette: "aurora")
        let stored = defaults(stored: [agent.rawValue: selection])
        let original = try XCTUnwrap(stored.data(forKey: MascotRoster.storageKey))
        let roster = MascotRoster.load(defaults: stored)

        XCTAssertEqual(roster.look(for: agent).shape, MascotRoster.defaultLook(for: agent)?.shape)
        XCTAssertEqual(roster.look(for: agent).palette.id, "aurora")
        XCTAssertEqual(roster.selections[agent.rawValue], selection)
        XCTAssertEqual(stored.data(forKey: MascotRoster.storageKey), original, "reading does not rewrite")

        let loaded = AppSettings.load(defaults: stored)
        loaded.save(defaults: stored)
        XCTAssertEqual(AppSettings.load(defaults: stored).mascotSelections[agent.rawValue], selection)
      }
    }
  }

  // MARK: - Two locks

  func testAFaceAnotherAgentWearsIsRefused() {
    var roster = MascotRoster()
    let claudes = roster.look(for: .claude)
    XCTAssertEqual(roster.owner(of: claudes, besides: .codex), .claude)
    XCTAssertFalse(roster.choose(claudes, for: .codex))
    XCTAssertNotEqual(roster.look(for: .codex), claudes, "and nothing was written")
    XCTAssertEqual(roster.owner(of: claudes, besides: .claude), nil, "it is not taken from itself")
    XCTAssertTrue(roster.choose(claudes, for: .claude), "choosing what you already wear is fine")
  }

  func testTheHexagonInDaybreakIsAChoiceLikeAnyOther() {
    var roster = MascotRoster()
    let daybreakHexagon = MascotLook(shape: .hex, palette: .standard)
    XCTAssertNil(roster.owner(of: daybreakHexagon, besides: .claude))
    XCTAssertTrue(roster.choose(daybreakHexagon, for: .claude))
    XCTAssertEqual(roster.look(for: .claude), daybreakHexagon)
    XCTAssertEqual(roster.owner(of: daybreakHexagon, besides: .codex), .claude)
  }

  func testAStoreThatGivesTwoAgentsOneFaceIsRepaired() {
    let look = MascotLook(shape: .triangle, palette: palette("frost"))
    let roster = MascotRoster(selections: [
      "claude": MascotSelection(look),
      "codex": MascotSelection(look),
    ])
    let looks = AgentId.adapterCases.map { roster.look(for: $0) }
    XCTAssertEqual(Set(looks).count, looks.count, "still no two alike")
    XCTAssertEqual(roster.look(for: .claude), look, "the first in the adapters' order keeps it")
    XCTAssertNotEqual(roster.look(for: .codex), look)
  }

  func testAStoredDaybreakHexagonIsHonoured() {
    let daybreakHexagon = MascotLook(shape: .hex, palette: .standard)
    let roster = MascotRoster(selections: ["claude": MascotSelection(daybreakHexagon)])
    XCTAssertEqual(roster.look(for: .claude), daybreakHexagon)
  }

  func testAChoiceBeatsAnotherAgentsDefault() {
    let codexDefault = MascotRoster.defaultLook(for: .codex)!
    let roster = MascotRoster(selections: ["claude": MascotSelection(codexDefault)])
    XCTAssertEqual(roster.look(for: .claude), codexDefault)
    XCTAssertNotEqual(roster.look(for: .codex), codexDefault, "the default gives way")
    let looks = AgentId.adapterCases.map { roster.look(for: $0) }
    XCTAssertEqual(Set(looks).count, looks.count)
  }

  // MARK: - From the old picker

  func testTheOldPerAgentColoursBecomeChoices() {
    let old = defaults(legacy: ["opencode": "citrus", "claude": "ember", "grok": "abyss", "codex": "slate"])
    let roster = MascotRoster.load(defaults: old)
    XCTAssertEqual(roster.look(for: .opencode).palette.id, "citrus")
    XCTAssertEqual(
      roster.look(for: .opencode).shape, MascotRoster.defaultLook(for: .opencode)?.shape,
      "on the shape the agent wears by default"
    )
    XCTAssertEqual(roster.look(for: .grok).palette.id, "abyss")
  }

  func testADaybreakFromTheOldPickerIsDropped() {
    let old = defaults(legacy: ["codex": "daybreak"])
    XCTAssertNotEqual(MascotRoster.load(defaults: old).look(for: .codex).palette.id, "daybreak")
  }

  func testANewChoiceBeatsTheOldPickers() {
    let look = MascotLook(shape: .capsule, palette: palette("rose"))
    let both = defaults(legacy: ["codex": "moss"], stored: ["codex": MascotSelection(look)])
    XCTAssertEqual(MascotRoster.load(defaults: both).look(for: .codex), look)
  }

  func testSettingsCarryTheChoicesAcrossASave() throws {
    var settings = AppSettings()
    settings.mascotSelections = ["grok": MascotSelection(MascotLook(shape: .capsule, palette: palette("tide")))]
    let stored = defaults()
    settings.save(defaults: stored)
    XCTAssertEqual(
      AppSettings.load(defaults: stored).mascotSelections["grok"],
      MascotSelection(shape: "capsule", palette: "tide", finish: "velvet")
    )
    XCTAssertEqual(MascotLook.face(for: .grok, defaults: stored).shape, .capsule)
  }

  // MARK: - Finish

  func testAChoiceStoredWithoutAFinishIsVelvet() throws {
    let json = Data(#"{"claude":{"shape":"hex","palette":"citrus"}}"#.utf8)
    let stored = try JSONDecoder().decode([String: MascotSelection].self, from: json)
    let roster = MascotRoster(selections: stored)
    XCTAssertEqual(roster.look(for: .claude).shape, .hex)
    XCTAssertEqual(roster.look(for: .claude).finish, .velvet)
  }

  func testTheFinishIsChosenAndKept() {
    var roster = MascotRoster()
    var look = roster.look(for: .codex)
    look.finish = .fur
    XCTAssertTrue(roster.choose(look, for: .codex))
    XCTAssertEqual(roster.look(for: .codex).finish, .fur)
    XCTAssertEqual(roster.selections["codex"]?.finish, "fur")
  }

  func testAFaceInAnotherFinishIsStillTaken() {
    var roster = MascotRoster()
    var claudes = roster.look(for: .claude)
    claudes.finish = .fur
    XCTAssertEqual(roster.owner(of: claudes, besides: .codex), .claude)
    XCTAssertFalse(roster.choose(claudes, for: .codex))
    XCTAssertNil(roster.owner(of: claudes, besides: .claude), "its own face, in fur, is free to it")
  }

  func testAChoiceThatLosesItsFaceKeepsItsFinish() {
    let taken = MascotSelection(MascotRoster.defaultLook(for: .claude)!)
    var fur = taken
    fur.finish = "fur"
    let roster = MascotRoster(selections: ["claude": taken, "codex": fur])
    let codex = roster.look(for: .codex)
    XCTAssertNotEqual(codex.faceID, roster.look(for: .claude).faceID)
    XCTAssertEqual(codex.finish, .fur)
  }

  // MARK: - Agents that are not adapters

  func testAnAgentWithNoAdapterStillWearsSomethingSteady() {
    let roster = MascotRoster()
    let first = roster.look(for: .pi)
    XCTAssertEqual(first, roster.look(for: .pi))
    XCTAssertNotEqual(roster.look(for: .custom).palette.id, "daybreak")
  }
}
