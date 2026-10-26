import Carbon.HIToolbox
import XCTest

@MainActor
final class ShortcutRoutingUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    try await super.setUp()
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = ["--ui-testing"]
      app.launch()
    }
  }

  override func tearDown() async throws {
    await MainActor.run {
      app.terminate()
      app = nil
    }
    try await super.tearDown()
  }

  private var mainWindow: XCUIElement {
    app.windows.firstMatch
  }

  @discardableResult
  private func waitForApp(timeout: TimeInterval = 10) -> Bool {
    app.activate()
    guard app.wait(for: .runningForeground, timeout: timeout) else { return false }
    return settingsWindow.waitForExistence(timeout: timeout)
  }

  private var askInput: XCUIElement {
    app.descendants(matching: .any)["boltty.ask.input"]
  }

  private var settingsWindow: XCUIElement {
    app.windows["boltty.settings.window"]
  }

  private func physicalShortcutKey(_ keyCode: Int, fallback: String) -> String {
    UITestKeyboard.key(keyCode, fallback: fallback)
  }

  func testBolttyAIPromptAppearsOnOpen() {
    XCTAssertTrue(waitForApp(timeout: 5))
    settingsWindow.click()
    app.typeKey(
      physicalShortcutKey(kVK_ANSI_P, fallback: "p"),
      modifierFlags: [.command, .shift]
    )
    XCTAssertTrue(askInput.waitForExistence(timeout: 3))
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
  }

  func testEscapeClosesPanelWithoutSessionCreation() {
    XCTAssertTrue(waitForApp(timeout: 5))
    settingsWindow.click()

    app.typeKey(
      physicalShortcutKey(kVK_ANSI_P, fallback: "p"),
      modifierFlags: [.command, .shift]
    )
    XCTAssertTrue(askInput.waitForExistence(timeout: 3))
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    XCTAssertFalse(askInput.waitForExistence(timeout: 3))
  }

  func testCloseBolttyShortcutBackgroundsInsteadOfQuitting() {
    XCTAssertTrue(waitForApp(timeout: 5))
    settingsWindow.click()

    app.typeKey(
      physicalShortcutKey(kVK_ANSI_Q, fallback: "q"),
      modifierFlags: [.command]
    )
    XCTAssertFalse(app.wait(for: .notRunning, timeout: 3))
    XCTAssertFalse(settingsWindow.waitForExistence(timeout: 3))
  }
}
