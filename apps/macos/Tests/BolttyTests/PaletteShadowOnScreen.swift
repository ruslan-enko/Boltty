import XCTest
@testable import Boltty

@MainActor
final class PaletteShadowOnScreen: XCTestCase {
  func testPhotographThePrompt() async throws {
    guard let path = ProcessInfo.processInfo.environment["BOLTTY_PALETTE_SHOT"] else {
      throw XCTSkip("set TEST_RUNNER_BOLTTY_PALETTE_SHOT=<png> to photograph it")
    }
    let model = AppModel(settings: AppSettings(), defaults: isolatedDefaults("boltty.tests.paletteShot"))
    let controller = AgentPaletteController(model: model)
    controller.show()
    controller.window?.orderFrontRegardless()
    try await Task.sleep(for: .seconds(2))
    let screen = try XCTUnwrap(NSScreen.main)
    let width: CGFloat = 900
    let x = Int((screen.frame.width - width) / 2)
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-R", "\(x),0,\(Int(width)),260", path]
    try shot.run()
    shot.waitUntilExit()
    controller.hide()
  }
}
