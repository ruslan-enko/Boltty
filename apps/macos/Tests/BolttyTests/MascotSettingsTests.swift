import XCTest
@testable import Boltty

@MainActor
final class MascotSettingsTests: XCTestCase {
  private var suites: [String] = []

  private func makeModel(
    selections: [String: MascotSelection] = [:]
  ) -> (model: BolttyAISettingsModel, defaults: UserDefaults) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("boltty-mascot-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = isolatedDefaults("boltty.tests.mascotSettings")
    let store = ConversationStore(persistence: ConversationPersistence(root: root))
    let engine = ConversationEngine(store: store, registry: AgentRegistry(clients: []))
    let appModel = AppModel(settings: AppSettings(mascotSelections: selections), defaults: defaults)
    return (BolttyAISettingsModel(appModel: appModel, engine: engine), defaults)
  }

  private func look(_ shape: MascotShape, _ palette: String) -> MascotLook {
    MascotLook(shape: shape, palette: MascotPalette.palette(withID: palette)!)
  }

  func testTheRowShowsWhatEachAgentWearsAndNoTwoAlike() {
    let (model, _) = makeModel()
    let looks = AgentId.adapterCases.map { model.mascotLook(for: $0) }
    XCTAssertEqual(Set(looks).count, looks.count)
  }

  func testAnOldShapeShowsTheCurrentDefaultWithTheChosenGradient() {
    let retired = MascotSelection(shape: "tile", palette: "aurora")
    let (model, _) = makeModel(selections: ["opencode": retired])

    XCTAssertEqual(model.mascotLook(for: .opencode), look(.capsule, "aurora"))
    XCTAssertEqual(model.appModel.settings.mascotSelections["opencode"], retired)
  }

  func testAChoiceReachesTheSettingsAndTheDisk() {
    let (model, defaults) = makeModel()
    let chosen = look(.triangle, "aurora")
    model.chooseMascot(chosen, for: .codex)

    XCTAssertEqual(model.mascotLook(for: .codex), chosen)
    XCTAssertEqual(model.appModel.settings.mascotSelections["codex"], MascotSelection(chosen))
    XCTAssertEqual(
      MascotLook.face(for: .codex, defaults: defaults), chosen,
      "the panel reads it from disk, so it has to have been written"
    )
  }

  func testAFaceAnotherAgentWearsCannotBeChosen() {
    let (model, _) = makeModel()
    let claudes = model.mascotLook(for: .claude)
    XCTAssertEqual(model.mascotOwner(of: claudes, besides: .codex), .claude)
    let before = model.mascotLook(for: .codex)

    model.chooseMascot(claudes, for: .codex)

    XCTAssertEqual(model.mascotLook(for: .codex), before, "refused, and nothing changed")
    XCTAssertEqual(model.name(of: .claude), "Claude")
  }

  func testTheHexagonInDaybreakCanBeChosen() {
    let (model, _) = makeModel()
    let daybreakHexagon = MascotLook(shape: .hex, palette: .standard)
    XCTAssertNil(model.mascotOwner(of: daybreakHexagon, besides: .grok))
    model.chooseMascot(daybreakHexagon, for: .grok)
    XCTAssertEqual(model.mascotLook(for: .grok), daybreakHexagon)
  }

  func testAFaceIsFreeOnceItsWearerHasMovedOn() {
    let (model, _) = makeModel()
    let claudes = model.mascotLook(for: .claude)
    model.chooseMascot(look(.triangle, "citrus"), for: .claude)
    XCTAssertNil(model.mascotOwner(of: claudes, besides: .codex))
    model.chooseMascot(claudes, for: .codex)
    XCTAssertEqual(model.mascotLook(for: .codex), claudes)
  }

  func testTheUsageBarWearsTheColourOfTheFace() {
    let (model, _) = makeModel()
    model.chooseMascot(look(.orb, "solar"), for: .grok)
    XCTAssertEqual(
      model.usageTint(for: .grok).usingColorSpace(.sRGB),
      MascotPalette.palette(withID: "solar")?.colors.first?.usingColorSpace(.sRGB)
    )
  }

  // MARK: - The swatches

  func testASwatchIsDrawnOnceAndKept() throws {
    let face = look(.capsule, "candy")
    let first = try XCTUnwrap(MascotStill.image(face, size: 40, scale: 2))
    let again = try XCTUnwrap(MascotStill.image(face, size: 40, scale: 2))
    XCTAssertTrue(first === again, "the second ask is the same picture")
    XCTAssertEqual(first.width, 80)
    XCTAssertEqual(first.height, 80)
    let other = try XCTUnwrap(MascotStill.image(look(.capsule, "lagoon"), size: 40, scale: 2))
    XCTAssertFalse(first === other, "another face is another picture")
    let bigger = try XCTUnwrap(MascotStill.image(face, size: 60, scale: 2))
    XCTAssertEqual(bigger.width, 120, "and another size is drawn again")
  }
}
