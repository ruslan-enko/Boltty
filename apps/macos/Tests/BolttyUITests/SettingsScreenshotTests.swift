import Carbon.HIToolbox
import XCTest

@MainActor
final class SettingsScreenshotTests: XCTestCase {
  private var app: XCUIApplication!

  private var outputDirectory: URL {
    if let path = ProcessInfo.processInfo.environment["BOLTTY_SCREENSHOT_DIR"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("boltty-shots", isDirectory: true)
  }

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

  private var settingsWindow: XCUIElement {
    app.windows["boltty.settings.window"]
  }

  private func save(_ screenshot: XCUIScreenshot, as name: String) throws {
    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true
    )
    let url = outputDirectory.appendingPathComponent("\(name).png")
    try screenshot.pngRepresentation.write(to: url)
    print("BOLTTY_SHOT \(url.path)")
  }

  func testCaptureEverySettingsPage() throws {
    XCTAssertTrue(waitForApp(timeout: 10))
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
    for page in ["general", "agents", "usage", "voice", "shortcuts"] {
      let row = settingsWindow.descendants(matching: .any)["boltty.settings.page.\(page)"]
      XCTAssertTrue(row.waitForExistence(timeout: 5), "no sidebar row for \(page)")
      row.click()
      Thread.sleep(forTimeInterval: 1.2)
      try save(settingsWindow.screenshot(), as: "settings-\(page)")
    }
  }
}
